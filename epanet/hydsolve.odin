package epanet

// hydsolve.odin — one hydraulic solution by Todini's global gradient
// algorithm (EPANET's hydsolver.c). Each trial builds the linearized
// equations from the current flows, solves for the heads, corrects the
// flows, and asks the status checks whether anything switched; it ends
// when the flow corrections are small and nothing switched, or when the
// trials run out. The per-link and per-junction passes run without
// bounds checks, as the coefficients do (hydcoeffs.odin).


// Balance is the worst remaining error after a trial and where it is.
Balance :: struct {
	max_head_error:  f64,
	max_flow_change: f64,
	max_head_link:   int,
	max_flow_node:   int,
	max_flow_link:   int,
}

// hydsolve returns the trials taken, the convergence error and 0 or 110
// (the matrix went ill-conditioned), and leaves the rest of what it
// found in hyd.
hydsolve :: proc "contextless" (pr: ^Project) -> (iter: int, relerr: f64, errcode: int) {
	net, hyd, m := &pr.net, &pr.hyd, &pr.m
	next_check := hyd.check_freq
	hyd.relax = 1
	bal: Balance
	hyd.deficient_nodes = 0
	hyd.demand_reduction = 0

	if hyd.status_report do writerelerr(pr, 0, 0)
	max_trials := hyd.max_iter
	if hyd.extra_iter > 0 do max_trials += hyd.extra_iter
	iter = 1
	for iter <= max_trials {
		// A·H = F for the heads; H comes back in f.
		t0 := prof_begin()
		headloss_coeffs(net, hyd)
		prof_end(.headloss_coeffs, t0)
		t0 = prof_begin()
		matrix_coeffs(net, hyd, m)
		prof_end(.matrix_coeffs, t0)
		t0 = prof_begin()
		errcode = linsolve(m, net.njuncs)
		prof_end(.linsolve, t0)

		// Ill-conditioned: a control valve at that row is fixed and we
		// go round again; anything else ends it with no solution.
		if errcode > 0 {
			if bad_valve(pr, int(m.order[errcode])) do continue
			break
		}

		t0 = prof_begin()
		for i in 1 ..= net.njuncs do hyd.head[i] = m.f[m.row[i]]
		relerr = new_flows(net, hyd, &bal)
		prof_end(.new_flows, t0)
		if hyd.status_report do writerelerr(pr, iter, relerr)

		// Damping and the valve checks.
		t0 = prof_begin()
		hyd.relax = 1
		valve_change := false
		if hyd.damp_limit > 0 {
			if relerr <= hyd.damp_limit {
				hyd.relax = 0.6
				valve_change = valve_status(pr)
			}
		} else {
			valve_change = valve_status(pr)
		}

		prof_end(.valves, t0)

		t0 = prof_begin()
		converged := has_converged(pr, relerr, &bal)
		prof_end(.converge, t0)
		t0 = prof_begin()
		if converged {
			if iter > hyd.max_iter do break
			stat_change := valve_change
			if link_status(pr) do stat_change = true
			if pswitch(pr) do stat_change = true
			if !stat_change do break
			next_check = iter + hyd.check_freq
		} else if iter <= hyd.max_check && iter == next_check {
			link_status(pr)
			next_check += hyd.check_freq
		}
		prof_end(.status, t0)
		iter += 1
	}

	if errcode > 0 {
		writehyderr(pr, int(m.order[errcode]))
		errcode = int(Error.Unsolvable)
	}

	// node_demand is everything leaving a junction, summed here once; at
	// a tank it is the net inflow, which new_link_flows kept every trial
	for i in 1 ..= net.njuncs {
		hyd.node_demand[i] = hyd.demand_flow[i] + hyd.emitter_flow[i] + hyd.leak_flow[i]
	}

	hyd.relative_error = relerr
	hyd.max_head_error = bal.max_head_error
	hyd.max_flow_change = bal.max_flow_change
	hyd.iterations = iter
	return
}

// bad_valve: does node n belong to an active PRV, PSV or FCV? Then that
// valve's setting cannot be met: fix its status and say so. Only the
// first valve on the node is looked at, as EPANET looks.
bad_valve :: proc "contextless" (pr: ^Project, n: int) -> bool {
	net, hyd := &pr.net, &pr.hyd
	for i in 1 ..= net.nvalves {
		k := net.valve_link[i]
		n1, n2 := int(net.n1[k]), int(net.n2[k])
		if n != n1 && n != n2 do continue
		t := net.link_type[k]
		if t == .PRV || t == .PSV || t == .FCV {
			if hyd.status[k] == .ACTIVE {
				if hyd.status_report do writebadvalve(pr, int(k))
				hyd.status[k] = t == .FCV ? .XFCV : .XPRESSURE
				return true
			}
		}
		return false
	}
	return false
}

// pswitch applies the simple controls that watch a junction's pressure,
// once a solution is in hand. Returns whether any link changed.
pswitch :: proc "contextless" (pr: ^Project) -> bool {
	net, hyd := &pr.net, &pr.hyd
	anychange := false
	for i in 1 ..= net.ncontrols {
		k := net.control_link[i]
		if k <= 0 do continue
		n := net.control_node[i]
		reset := false
		if n > 0 && int(n) <= net.njuncs {
			if net.control_type[i] == .LOWLEVEL && hyd.head[n] <= net.control_grade[i] + hyd.htol do reset = true
			if net.control_type[i] == .HILEVEL && hyd.head[n] >= net.control_grade[i] - hyd.htol do reset = true
		}
		if !reset do continue

		s := hyd.status[k]
		change := false
		t := net.link_type[k]
		if t == .PIPE {
			if s != net.control_status[i] do change = true
		}
		if t == .PUMP {
			if hyd.setting[k] != net.control_setting[i] do change = true
		}
		if t >= .PRV {
			if hyd.setting[k] != net.control_setting[i] {
				change = true
			} else if hyd.setting[k] == MISSING && s != net.control_status[i] {
				change = true
			}
		}
		if change {
			hyd.status[k] = net.control_status[i]
			if t > .PIPE do hyd.setting[k] = net.control_setting[i]
			if hyd.status_report do writestatchange(pr, int(k), s, hyd.status[k])
			anychange = true
		}
	}
	return anychange
}

// new_flows corrects every flow from the new heads and returns the
// relative flow change (or the absolute one when the total flow is tiny).
new_flows :: proc "contextless" (net: ^Network, hyd: ^Hydraulics, bal: ^Balance) -> f64 #no_bounds_check {
	qsum, dqsum := 0.0, 0.0
	bal.max_flow_change = 0
	bal.max_flow_link = 1
	bal.max_flow_node = -1

	new_link_flows(net, hyd, bal, &qsum, &dqsum)
	new_emitter_flows(net, hyd, bal, &qsum, &dqsum)
	new_demand_flows(net, hyd, bal, &qsum, &dqsum)
	if hyd.has_leakage do new_leakage_flows(net, hyd, bal, &qsum, &dqsum)

	if qsum > hyd.hacc do return dqsum / qsum
	return dqsum
}

// dq = Y − P·(new head loss): the Newton step for a link's flow.
new_link_flows :: proc "contextless" (net: ^Network, hyd: ^Hydraulics, bal: ^Balance, qsum, dqsum: ^f64) #no_bounds_check {
	for n in net.njuncs + 1 ..= net.nnodes do hyd.node_demand[n] = 0

	for k in 1 ..= net.nlinks {
		n1, n2 := net.n1[k], net.n2[k]
		dh := hyd.head[n1] - hyd.head[n2]
		dq := hyd.y[k] - hyd.p[k] * dh
		dq *= hyd.relax

		// A constant-horsepower pump's flow must not go negative.
		if net.link_type[k] == .PUMP {
			p := net.link_pump[k]
			if net.pump_type[p] == .CONST_HP && dq > hyd.flow[k] do dq = hyd.flow[k] / 2
		}

		hyd.flow[k] -= dq
		qsum^ += abs(hyd.flow[k])
		dqsum^ += abs(dq)
		if abs(dq) > bal.max_flow_change {
			bal.max_flow_change = abs(dq)
			bal.max_flow_link = k
			bal.max_flow_node = -1
		}

		// Net inflow at the fixed-grade nodes.
		if hyd.status[k] > .CLOSED {
			if int(n1) > net.njuncs do hyd.node_demand[n1] -= hyd.flow[k]
			if int(n2) > net.njuncs do hyd.node_demand[n2] += hyd.flow[k]
		}
	}
}

new_emitter_flows :: proc "contextless" (net: ^Network, hyd: ^Hydraulics, bal: ^Balance, qsum, dqsum: ^f64) #no_bounds_check {
	for i in 1 ..= net.njuncs {
		if net.ke[i] == 0 do continue
		hloss, hgrad := emitter_headloss(net, hyd, i)
		dh := hyd.head[i] - net.el[i]
		dq := (hloss - dh) / hgrad
		dq *= hyd.relax
		hyd.emitter_flow[i] -= dq
		qsum^ += abs(hyd.emitter_flow[i])
		dqsum^ += abs(dq)
		if abs(dq) > bal.max_flow_change {
			bal.max_flow_change = abs(dq)
			bal.max_flow_node = i
			bal.max_flow_link = -1
		}
	}
}

new_leakage_flows :: proc "contextless" (net: ^Network, hyd: ^Hydraulics, bal: ^Balance, qsum, dqsum: ^f64) #no_bounds_check {
	for i in 1 ..= net.njuncs {
		dq := leakage_flow_change(net, hyd, i)
		if dq == 0 do continue
		qsum^ += abs(hyd.leak_flow[i])
		dqsum^ += abs(dq)
		if abs(dq) > bal.max_flow_change {
			bal.max_flow_change = abs(dq)
			bal.max_flow_node = i
			bal.max_flow_link = -1
		}
	}
}

new_demand_flows :: proc "contextless" (net: ^Network, hyd: ^Hydraulics, bal: ^Balance, qsum, dqsum: ^f64) #no_bounds_check {
	if hyd.demand_model == .DDA do return
	dp := max(hyd.preq - hyd.pmin, MINPDIFF)
	n := 1 / hyd.pexp
	for i in 1 ..= net.njuncs {
		if hyd.full_demand[i] <= 0 do continue
		hloss, hgrad := demand_headloss(hyd, i, dp, n)
		dh := hyd.head[i] - net.el[i] - hyd.pmin
		dq := (hloss - dh) / hgrad
		dq *= hyd.relax
		// Never more than 40 % of the full demand in one step.
		if abs(dq) > 0.4 * hyd.full_demand[i] do dq = 0.4 * sgn(dq) * hyd.full_demand[i]
		hyd.demand_flow[i] -= dq
		qsum^ += abs(hyd.demand_flow[i])
		dqsum^ += abs(dq)
		if abs(dq) > bal.max_flow_change {
			bal.max_flow_change = abs(dq)
			bal.max_flow_node = i
			bal.max_flow_link = -1
		}
	}
}

// check_hyd_balance finds the link whose head loss disagrees most with
// the heads at its ends.
check_hyd_balance :: proc "contextless" (net: ^Network, hyd: ^Hydraulics, bal: ^Balance) #no_bounds_check {
	bal.max_head_error = 0
	bal.max_head_link = 1
	headloss_coeffs(net, hyd)
	for k in 1 ..= net.nlinks {
		if hyd.status[k] <= .CLOSED do continue
		if hyd.p[k] == 0 do continue
		n1, n2 := net.n1[k], net.n2[k]
		dh := hyd.head[n1] - hyd.head[n2]
		headloss := hyd.y[k] / hyd.p[k]
		headerror := abs(dh - headloss)
		if headerror > bal.max_head_error {
			bal.max_head_error = headerror
			bal.max_head_link = k
		}
	}
}

has_converged :: proc "contextless" (pr: ^Project, relerr: f64, bal: ^Balance) -> bool {
	net, hyd := &pr.net, &pr.hyd
	if relerr > hyd.hacc do return false
	check_hyd_balance(net, hyd, bal)
	if hyd.status_report {
		writehydbal(pr, bal.max_flow_change * net.ucf_flow, bal.max_head_error * net.ucf_head, bal.max_flow_link, bal.max_flow_node, bal.max_head_link)
	}
	if hyd.head_error_limit > 0 && bal.max_head_error > hyd.head_error_limit do return false
	if hyd.flow_change_limit > 0 && bal.max_flow_change > hyd.flow_change_limit do return false
	if hyd.has_leakage && !leakage_converged(net, hyd) do return false
	if hyd.demand_model == .PDA do return pda_converged(net, hyd)
	return true
}

// pda_converged: every pressure-dependent demand must agree with the
// demand equation at the solved pressure. Also totals the shortfall.
pda_converged :: proc "contextless" (net: ^Network, hyd: ^Hydraulics) -> bool #no_bounds_check {
	QTOL :: 0.0001 // cfs, about 0.05 gpm
	converged := true
	total_demand, total_reduction := 0.0, 0.0
	dp := hyd.preq - hyd.pmin
	hyd.deficient_nodes = 0
	hyd.demand_reduction = 0
	for i in 1 ..= net.njuncs {
		if hyd.full_demand[i] <= 0 do continue
		p := hyd.head[i] - net.el[i]
		q: f64
		if p <= hyd.pmin {
			q = 0
		} else if p >= hyd.preq {
			q = hyd.full_demand[i]
		} else {
			r := (p - hyd.pmin) / dp
			q = hyd.full_demand[i] * c_pow(r, hyd.pexp)
		}
		if abs(q - hyd.demand_flow[i]) > QTOL do converged = false
		if hyd.demand_flow[i] + QTOL < hyd.full_demand[i] {
			hyd.deficient_nodes += 1
			total_demand += hyd.full_demand[i]
			total_reduction += hyd.full_demand[i] - hyd.demand_flow[i]
		}
	}
	if total_demand > 0 do hyd.demand_reduction = total_reduction / total_demand * 100
	return converged
}
