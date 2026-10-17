package epanet

// hydraul.odin — the hydraulic engine around the solver (EPANET's
// hydraul.c): the demands of the period, the simple controls, the length
// of the next time step with the tank levels it ends at, pump energy, and
// the small things that set a link's flow, status and setting.

import "core:c/libc"
import "core:math"

// interp reads y at xx off a curve by straight lines, holding the end
// values beyond the ends.
interp :: proc "contextless" (x, y: []f64, xx: f64) -> f64 {
	n := len(x)
	if n == 0 do return 0
	m := n - 1
	if xx <= x[0] do return y[0]
	for k in 1 ..= m {
		if x[k] >= xx {
			dx := x[k] - x[k - 1]
			dy := y[k] - y[k - 1]
			if abs(dx) < TINY do return y[k]
			return y[k] - (x[k] - xx) * dy / dx
		}
	}
	return y[m]
}

// pattern_at: the multiplier in force p periods in.
pattern_at :: #force_inline proc "contextless" (net: ^Network, j: int, p: i64) -> f64 {
	f := net.patterns[j].f
	return f[p % i64(len(f))]
}

// ── resistance ────────────────────────────────────────────────────────

// resist_coeff sets link k's flow resistance from its size and roughness
// (a pipe's depends on the head loss formula; a pump's is huge; a PCV's
// comes from its percent open; any other valve's is tiny).
resist_coeff :: proc "contextless" (net: ^Network, hyd: ^Hydraulics, k: int) {
	#partial switch net.link_type[k] {
	case .CVPIPE, .PIPE:
		e, d, l := net.kc[k], net.diam[k], net.len[k]
		switch hyd.formflag {
		case .HW:
			net.r[k] = 4.727 * l / libc.pow(e, hyd.hexp) / libc.pow(d, 4.871)
		case .DW:
			a := math.PI * (d * d) / 4
			net.r[k] = l / 2 / 32.2 / d / (a * a)
		case .CM:
			x := 4 * e / (1.49 * math.PI * (d * d))
			net.r[k] = (x * x) * libc.pow(d / 4, -1.333) * l
		}
	case .PUMP:
		net.r[k] = CBIG
	case .PCV:
		net.r[k] = pcv_loss_coeff(net, k, net.kc[k])
	case:
		net.r[k] = CSMALL
	}
}

// pcv_loss_coeff: a positional control valve's minor loss coefficient at
// s percent open, from its Kv curve (or a straight line without one).
pcv_loss_coeff :: proc "contextless" (net: ^Network, k: int, s: f64) -> f64 {
	if s == MISSING do return 0
	kmo := net.km[k] // fully open
	if s >= 100 do return kmo
	if s <= 0 do return CBIG

	kvr: f64
	c := net.valve_curve[net.link_valve[k]]
	if c == 0 {
		kvr = s
	} else {
		x, y := net.curves[c].x, net.curves[c].y
		npts := len(x)
		if s < x[0] {
			kvr = s / x[0] * y[0]
		} else if s > x[npts - 1] {
			k2 := npts - 1
			kvr = (s - x[k2]) / (1 - x[k2]) * (1 - y[k2]) + y[k2]
		} else {
			k2 := 0
			for k2 < npts && x[k2] < s do k2 += 1
			if k2 == 0 {
				k2 += 1
			} else if k2 == npts {
				k2 -= 1
			}
			k1 := k2 - 1
			kvr = (y[k2] - y[k1]) / (x[k2] - x[k1])
			kvr = y[k1] + kvr * (s - x[k1])
		}
	}
	kvr /= 100
	kvr = min(kvr, 1)
	kvr = max(kvr, CSMALL)
	km := kmo / (kvr * kvr)
	return min(km, CBIG)
}

// ── flows, statuses, settings ─────────────────────────────────────────

// init_link_flow starts link i at no flow when closed, a pump at its
// design flow times its speed, anything else at 1 ft/s.
init_link_flow :: proc "contextless" (net: ^Network, hyd: ^Hydraulics, i: int, s: Status, k: f64) {
	if s == .CLOSED {
		hyd.flow[i] = QZERO
	} else if net.link_type[i] == .PUMP {
		hyd.flow[i] = k * net.pump_q0[net.link_pump[i]]
	} else {
		hyd.flow[i] = math.PI * (net.diam[i] * net.diam[i]) / 4
	}
}

// reset_pump_flow puts a constant-horsepower pump back at its initial
// flow, which its head loss relation needs to be nonzero.
reset_pump_flow :: proc "contextless" (net: ^Network, hyd: ^Hydraulics, i: int) {
	p := net.link_pump[i]
	if net.pump_type[p] == .CONST_HP do hyd.flow[i] = net.pump_q0[p]
}

// set_link_status opens (value 1) or closes (0) link k, fixing a pump's
// speed and unsetting a valve's setting to match.
set_link_status :: proc "contextless" (net: ^Network, hyd: ^Hydraulics, k: int, value: int) {
	t := net.link_type[k]
	if value == 1 {
		if t == .PUMP {
			hyd.setting[k] = 1
			if hyd.status[k] == .CLOSED do reset_pump_flow(net, hyd, k)
		}
		if t > .PUMP && t != .GPV do hyd.setting[k] = MISSING
		hyd.status[k] = .OPEN
	} else if value == 0 {
		if t == .PUMP do hyd.setting[k] = 0
		if t > .PUMP && t != .GPV do hyd.setting[k] = MISSING
		hyd.status[k] = .CLOSED
	}
}

// set_link_setting gives link k a pump speed or valve setting and the
// status that goes with it.
set_link_setting :: proc "contextless" (net: ^Network, hyd: ^Hydraulics, k: int, value: f64) {
	t := net.link_type[k]
	if t == .PUMP {
		hyd.setting[k] = value
		if value > 0 && hyd.status[k] <= .CLOSED {
			reset_pump_flow(net, hyd, k)
			hyd.status[k] = .OPEN
		}
		if value == 0 && hyd.status[k] > .CLOSED do hyd.status[k] = .CLOSED
	} else if t == .FCV {
		hyd.setting[k] = value
		hyd.status[k] = .ACTIVE
	} else {
		if hyd.setting[k] == MISSING && hyd.status[k] <= .CLOSED do hyd.status[k] = .OPEN
		if t == .PCV do net.r[k] = pcv_loss_coeff(net, k, value)
		hyd.setting[k] = value
	}
}

// ── the period ────────────────────────────────────────────────────────

// demands sets every junction's demand for the current period from its
// patterns, a reservoir's head from its pattern, and a pump's speed from
// its utilization pattern.
demands :: proc "contextless" (net: ^Network, hyd: ^Hydraulics, t: ^Times) {
	p := (t.htime + t.pstart) / t.pstep // elapsed pattern periods
	hyd.dsystem = 0
	for i in 1 ..= net.njuncs {
		sum := 0.0
		for d in net.demand_first[i] ..< net.demand_first[i + 1] {
			j := int(net.demand_pat[d])
			if j == 0 do j = net.def_pat
			djunc := net.demand_base[d] * pattern_at(net, j, p) * hyd.dmult
			if djunc > 0 do hyd.dsystem += djunc
			sum += djunc
		}
		hyd.full_demand[i] = sum
		hyd.demand_flow[i] = sum
	}
	for n in 1 ..= net.ntanks {
		if net.tank_area[n] != 0 do continue
		j := int(net.tank_pat[n])
		if j > 0 {
			i := net.tank_node[n]
			hyd.head[i] = net.el[i] * pattern_at(net, j, p)
		}
	}
	for n in 1 ..= net.npumps {
		j := int(net.pump_upat[n])
		if j > 0 {
			set_link_setting(net, hyd, int(net.pump_link[n]), pattern_at(net, j, p))
		}
	}
}

// controls applies the simple controls that act on a tank level or the
// clock. Returns how many links changed.
controls :: proc "contextless" (net: ^Network, hyd: ^Hydraulics, t: ^Times, pr: ^Project) -> int {
	setsum := 0
	for i in 1 ..= net.ncontrols {
		if !net.control_enabled[i] do continue
		k := int(net.control_link[i])
		if k <= 0 do continue
		reset := false

		n := int(net.control_node[i])
		if n > 0 && n > net.njuncs {
			h := hyd.head[n]
			vplus := abs(hyd.node_demand[n])
			v1 := tank_volume(net, hyd, n - net.njuncs, h)
			v2 := tank_volume(net, hyd, n - net.njuncs, net.control_grade[i])
			if net.control_type[i] == .LOWLEVEL && v1 <= v2 + vplus do reset = true
			if net.control_type[i] == .HILEVEL && v1 >= v2 - vplus do reset = true
		}
		if net.control_type[i] == .TIMER {
			if net.control_time[i] == t.htime do reset = true
		}
		if net.control_type[i] == .TIMEOFDAY {
			if (t.htime + t.tstart) % SEC_PER_DAY == net.control_time[i] do reset = true
		}
		if !reset do continue

		s1: Status = hyd.status[k] <= .CLOSED ? .CLOSED : .OPEN
		s2 := net.control_status[i]
		k1 := hyd.setting[k]
		k2 := k1
		if net.link_type[k] > .PIPE do k2 = net.control_setting[i]
		if net.link_type[k] == .PUMP && s1 == .CLOSED && s2 == .OPEN do reset_pump_flow(net, hyd, k)
		if s1 != s2 || k1 != k2 {
			hyd.status[k] = s2
			hyd.setting[k] = k2
			if net.link_type[k] == .PCV do net.r[k] = pcv_loss_coeff(net, k, k2)
			if hyd.status_report_any do writecontrolaction(pr, int(k), i)
			setsum += 1
		}
	}
	return setsum
}

// ── the time step ─────────────────────────────────────────────────────

// timestep: how long until something changes — the next pattern period,
// report time, a tank filling or emptying, a control, or a rule — and
// moves the tanks to the levels they will have then.
timestep :: proc(net: ^Network, hyd: ^Hydraulics, t: ^Times, pr: ^Project, nrules: int) -> i64 {
	tstep := t.hstep
	n := (t.htime + t.pstart) / t.pstep + 1
	dt := n * t.pstep - t.htime
	if dt > 0 && dt < tstep do tstep = dt
	dt = t.rtime - t.htime
	if dt > 0 && dt < tstep do tstep = dt
	tank_timestep(net, hyd, &tstep)
	control_timestep(net, hyd, t, &tstep)
	if nrules > 0 {
		rule_timestep(net, hyd, t, pr, &tstep)
	} else {
		tank_levels(net, hyd, tstep)
	}
	return tstep
}

// tank_timestep shortens tstep to the soonest a tank fills or drains.
// Returns that tank's node, or 0.
tank_timestep :: proc "contextless" (net: ^Network, hyd: ^Hydraulics, tstep: ^i64) -> int {
	tank_node := 0
	for i in 1 ..= net.ntanks {
		if net.tank_area[i] == 0 do continue
		n := net.tank_node[i]
		h := hyd.head[n]
		q := hyd.node_demand[n]
		if abs(q) <= QZERO do continue
		v: f64
		if q > 0 && h < net.tank_hmax[i] {
			v = net.tank_vmax[i] - hyd.tank_volume[i]
		} else if q < 0 && h > net.tank_hmin[i] {
			v = net.tank_vmin[i] - hyd.tank_volume[i]
		} else {
			continue
		}
		xt := v / q
		if abs(xt) > f64(tstep^ + 1) do continue
		dt := i64(math.round(xt))
		if dt > 0 && dt < tstep^ {
			tstep^ = dt
			tank_node = int(n)
		}
	}
	return tank_node
}

// control_timestep shortens tstep to the soonest a simple control fires
// and would actually change its link. Returns that control, or 0.
control_timestep :: proc "contextless" (net: ^Network, hyd: ^Hydraulics, t: ^Times, tstep: ^i64) -> int {
	which := 0
	for i in 1 ..= net.ncontrols {
		if !net.control_enabled[i] do continue
		dt: i64 = 0
		n := int(net.control_node[i])
		if n > 0 {
			j := n - net.njuncs
			if j <= 0 do continue
			h := hyd.head[n]
			q := hyd.node_demand[n]
			if abs(q) <= QZERO do continue
			if (h < net.control_grade[i] && net.control_type[i] == .HILEVEL && q > 0) ||
			   (h > net.control_grade[i] && net.control_type[i] == .LOWLEVEL && q < 0) {
				v := tank_volume(net, hyd, j, net.control_grade[i]) - hyd.tank_volume[j]
				dt = i64(math.round(v / q))
			}
		}
		if net.control_type[i] == .TIMER {
			if net.control_time[i] > t.htime do dt = net.control_time[i] - t.htime
		}
		if net.control_type[i] == .TIMEOFDAY {
			t1 := (t.htime + t.tstart) % SEC_PER_DAY
			t2 := net.control_time[i]
			dt = t2 >= t1 ? t2 - t1 : SEC_PER_DAY - t1 + t2
		}
		if dt > 0 && dt < tstep^ {
			k := net.control_link[i]
			if (net.link_type[k] > .PIPE && hyd.setting[k] != net.control_setting[i]) ||
			   hyd.status[k] != net.control_status[i] {
				tstep^ = dt
				which = i
			}
		}
	}
	return which
}

// rule_timestep walks the clock forward in rule-evaluation steps, moving
// the tanks as it goes, until a rule fires or tstep is used up.
rule_timestep :: proc(net: ^Network, hyd: ^Hydraulics, t: ^Times, pr: ^Project, tstep: ^i64) {
	tnow := t.htime
	tmax := tnow + tstep^
	dt := t.rulestep
	dt1 := t.rulestep - (tnow % t.rulestep)
	dt = min(dt, tstep^)
	dt1 = min(dt1, tstep^)
	if dt1 == 0 do dt1 = dt
	htime := tnow
	for {
		htime += dt1
		tank_levels(net, hyd, dt1)
		// The rules see the clock at the end of the increment.
		t.htime = htime
		fired := check_rules(net, hyd, t, pr, dt1) > 0
		t.htime = tnow
		if fired do break
		dt = min(dt, tmax - htime)
		dt1 = dt
		if dt <= 0 do break
	}
	tstep^ = htime - tnow
}

// tank_levels moves each tank by its net inflow over tstep seconds,
// stopping at full or empty.
tank_levels :: proc "contextless" (net: ^Network, hyd: ^Hydraulics, tstep: i64) {
	for i in 1 ..= net.ntanks {
		if net.tank_area[i] == 0 do continue
		n := net.tank_node[i]
		q := hyd.node_demand[n]
		if abs(q) <= QZERO do continue
		hyd.tank_volume[i] += q * f64(tstep)
		if hyd.tank_volume[i] + q >= net.tank_vmax[i] {
			hyd.tank_volume[i] = net.tank_vmax[i]
		} else if hyd.tank_volume[i] - q <= net.tank_vmin[i] {
			hyd.tank_volume[i] = net.tank_vmin[i]
		}
		hyd.head[n] = tank_grade(net, hyd, i, hyd.tank_volume[i])
	}
}

// tank_volume: the volume in tank i at water elevation h, by area or by
// its volume curve (which is in user units).
tank_volume :: proc "contextless" (net: ^Network, hyd: ^Hydraulics, i: int, h: f64) -> f64 {
	j := net.tank_vcurve[i]
	if j == 0 do return net.tank_vmin[i] + (h - net.tank_hmin[i]) * net.tank_area[i]
	y := (h - net.el[net.tank_node[i]]) * net.ucf_head
	return interp(net.curves[j].x, net.curves[j].y, y) / net.ucf_volume
}

// tank_grade: the water elevation in tank i holding volume v.
tank_grade :: proc "contextless" (net: ^Network, hyd: ^Hydraulics, i: int, v: f64) -> f64 {
	j := net.tank_vcurve[i]
	if j == 0 do return net.tank_hmin[i] + (v - net.tank_vmin[i]) / net.tank_area[i]
	y := interp(net.curves[j].y, net.curves[j].x, v * net.ucf_volume)
	return net.el[net.tank_node[i]] + y / net.ucf_head
}

// ── energy ────────────────────────────────────────────────────────────

// get_energy: the power link k is using (kW) and, for a pump, its
// efficiency at this flow and speed.
get_energy :: proc "contextless" (net: ^Network, hyd: ^Hydraulics, k: int) -> (kw, eff: f64) {
	if hyd.status[k] <= .CLOSED do return 0, 0
	q := abs(hyd.flow[k])
	dh := abs(hyd.head[net.n1[k]] - hyd.head[net.n2[k]])
	e := 1.0
	if net.link_type[k] == .PUMP {
		j := net.link_pump[k]
		e = hyd.epump
		speed := hyd.setting[k]
		if i := net.pump_ecurve[j]; i > 0 {
			q4eff := q / speed * net.ucf_flow
			e = interp(net.curves[i].x, net.curves[i].y, q4eff)
			// Sarbu and Borza's speed adjustment.
			e = 100 - ((100 - e) * libc.pow(1 / speed, 0.1))
		}
		e = min(e, 100)
		e = max(e, 1)
		e /= 100
	}
	kw = dh * q * hyd.spgrav / 8.814 / e * KW_PER_HP
	return kw, e
}

get_all_pumps_energy :: proc "contextless" (net: ^Network, hyd: ^Hydraulics) {
	for j in 1 ..= net.npumps {
		k := int(net.pump_link[j])
		hyd.energy[j].current_power, hyd.energy[j].current_effic = get_energy(net, hyd, k)
	}
}

// add_energy charges hstep seconds of every running pump's power to its
// statistics, at the energy price in force.
add_energy :: proc "contextless" (net: ^Network, hyd: ^Hydraulics, t: ^Times, hstep: i64) {
	dt: f64
	if t.dur == 0 {
		dt = 1
	} else if t.htime < t.dur {
		dt = f64(hstep) / 3600
	} else {
		dt = 0
	}
	if dt == 0 do return
	n := (t.htime + t.pstart) / t.pstep

	c0 := hyd.ecost
	f0 := 1.0
	if hyd.epat > 0 do f0 = pattern_at(net, hyd.epat, n)

	psum := 0.0
	for j in 1 ..= net.npumps {
		en := &hyd.energy[j]
		if en.current_effic == 0 do continue
		k := int(net.pump_link[j])
		q := max(QZERO, abs(hyd.flow[k]))
		c := net.pump_ecost[j] > 0 ? net.pump_ecost[j] : c0
		if i := net.pump_epat[j]; i > 0 {
			c *= pattern_at(net, int(i), n)
		} else {
			c *= f0
		}
		p := en.current_power
		e := en.current_effic
		psum += p
		en.time_on_line += dt
		en.efficiency += e * dt
		en.kwhrs_per_flow += p / q * dt
		en.kwhrs += p * dt
		en.max_kwatts = max(en.max_kwatts, p)
		en.total_cost += c * p * dt
	}
	hyd.emax = max(hyd.emax, psum)
}

// ── the flow balance ──────────────────────────────────────────────────

start_flow_balance :: proc "contextless" (hyd: ^Hydraulics) {
	hyd.flow_balance^ = {}
}

// update_flow_balance adds this period's flows, weighted by its length.
update_flow_balance :: proc "contextless" (net: ^Network, hyd: ^Hydraulics, t: ^Times, hstep: i64) {
	dt: f64
	if t.dur == 0 {
		dt = 1
	} else if t.htime < t.dur {
		dt = f64(hstep)
	} else {
		return
	}
	fb: Flow_Balance
	full_demand := 0.0
	hyd.leakage_loss = 0
	for i in 1 ..= net.njuncs {
		v := hyd.demand_flow[i]
		if v < 0 {
			fb.total_inflow += (-v)
		} else {
			full_demand += hyd.full_demand[i]
			fb.consumer_demand += v
			fb.total_outflow += v
		}
		v = hyd.emitter_flow[i]
		fb.emitter_demand += v
		fb.total_outflow += v
		v = hyd.leak_flow[i]
		fb.leakage_demand += v
		fb.total_outflow += v
		if hyd.demand_model == .PDA && hyd.full_demand[i] > 0 {
			deficit := hyd.full_demand[i] - hyd.demand_flow[i]
			if deficit > 0 do fb.deficit_demand += deficit
		}
	}
	for j in 1 ..= net.ntanks {
		v := hyd.node_demand[net.tank_node[j]]
		if net.tank_area[j] == 0 {
			if v >= 0 {
				fb.total_outflow += v
			} else {
				fb.total_inflow += (-v)
			}
		} else {
			fb.storage_demand += v
		}
	}
	v := fb.total_inflow
	if fb.storage_demand < 0 do v += (-fb.storage_demand)
	if v > 0 do hyd.leakage_loss = fb.leakage_demand / v * 100
	b := hyd.flow_balance
	b.total_inflow += fb.total_inflow * dt
	b.total_outflow += fb.total_outflow * dt
	b.consumer_demand += fb.consumer_demand * dt
	b.emitter_demand += fb.emitter_demand * dt
	b.leakage_demand += fb.leakage_demand * dt
	b.deficit_demand += fb.deficit_demand * dt
	b.storage_demand += fb.storage_demand * dt
}

// end_flow_balance turns the totals into averages and a ratio out/in.
end_flow_balance :: proc "contextless" (hyd: ^Hydraulics, t: ^Times) {
	seconds := t.htime > 0 ? f64(t.htime) : 1
	b := hyd.flow_balance
	b.total_inflow /= seconds
	b.total_outflow /= seconds
	b.consumer_demand /= seconds
	b.emitter_demand /= seconds
	b.leakage_demand /= seconds
	b.deficit_demand /= seconds
	b.storage_demand /= seconds
	qin, qout, qstor := b.total_inflow, b.total_outflow, b.storage_demand
	if qstor > 0 {
		qout += qstor
	} else {
		qin -= qstor
	}
	r: f64
	if qin == qout {
		r = 1
	} else if qin > 0 {
		r = qout / qin
	} else {
		r = 0
	}
	b.ratio = r
}

// ── the run ───────────────────────────────────────────────────────────

// init_hyd starts a hydraulic run: tanks at their initial levels, links
// at their initial status, setting and flow (re-initialized when
// initflag is set), the energy and the flow balance at zero. The file
// positioning and result indexes are the caller's.
init_hyd :: proc "contextless" (net: ^Network, hyd: ^Hydraulics, t: ^Times, initflag: int) {
	for i in 1 ..= net.ntanks {
		n := net.tank_node[i]
		hyd.tank_volume[i] = net.tank_v0[i]
		hyd.head[n] = net.tank_h0[i]
		hyd.node_demand[n] = 0
		hyd.old_status[net.nlinks + i] = .TEMPCLOSED
	}
	for i in 0 ..= net.nnodes {
		hyd.demand_flow[i] = 0
		hyd.emitter_flow[i] = 0
		hyd.leak_flow[i] = 0
	}
	for i in 1 ..= net.nnodes do if net.ke[i] > 0 do hyd.emitter_flow[i] = 1

	for i in 1 ..= net.nlinks {
		t := net.link_type[i]
		hyd.status[i] = net.init_status[i]
		hyd.setting[i] = net.init_setting[i]
		if t > .PUMP && t != .GPV && net.init_status[i] != .ACTIVE do hyd.setting[i] = MISSING
		resist_coeff(net, hyd, i)
		if (t == .PRV || t == .PSV || t == .FCV) && hyd.setting[i] != MISSING do hyd.status[i] = .ACTIVE
		if hyd.status[i] <= .CLOSED {
			hyd.flow[i] = QZERO
		} else if abs(hyd.flow[i]) <= QZERO || initflag > 0 {
			init_link_flow(net, hyd, i, hyd.status[i], hyd.setting[i])
		}
		hyd.old_status[i] = hyd.status[i]
	}
	for i in 1 ..= net.npumps do hyd.energy[i] = {}
	start_flow_balance(hyd)

	hyd.haltflag = false
	t.htime = 0
	t.hydstep = 0
	t.rtime = t.rstep
}

// run_hyd solves one period: the demands and controls in force, then the
// network. Returns the error or warning code.
run_hyd :: proc "contextless" (net: ^Network, hyd: ^Hydraulics, m: ^Smatrix, t: ^Times, pr: ^Project) -> (now: i64, errcode: int) {
	now = t.htime
	demands(net, hyd, t)
	controls(net, hyd, t, pr)
	iter, relerr, err := hydsolve(net, hyd, m, pr)
	errcode = err
	if errcode == 0 {
		if hyd.status_report_any do writehydstat(pr, iter, relerr)
		if relerr > hyd.hacc && hyd.extra_iter == -1 do hyd.haltflag = true
		errcode = writehydwarn(pr, iter, relerr)
	}
	return
}

// next_hyd closes the period: pump energy, the results to the file, the
// length of the next step with the tanks moved to it, and the clock
// advanced; at the end of the run the flow balance is closed.
next_hyd :: proc(net: ^Network, hyd: ^Hydraulics, t: ^Times, pr: ^Project) -> (tstep: i64, errcode: int) {
	get_all_pumps_energy(net, hyd)
	if hyd.saveflag do errcode = savehyd(pr, t.htime)
	if hyd.haltflag do t.htime = t.dur

	hydstep: i64 = 0
	if t.htime < t.dur do hydstep = timestep(net, hyd, t, pr, net.nrules)
	if hyd.saveflag do errcode = savehydstep(pr, hydstep)

	if t.dur == 0 {
		add_energy(net, hyd, t, 0)
	} else if t.htime < t.dur {
		add_energy(net, hyd, t, hydstep)
	}
	update_flow_balance(net, hyd, t, hydstep)

	if t.htime < t.dur {
		t.htime += hydstep
		if !hyd.openqflag {
			if t.htime >= t.rtime do t.rtime += t.rstep
		}
	} else {
		end_flow_balance(hyd, t)
		if hyd.status_report_any do writeflowbalance(pr)
		t.htime += 1
		if hyd.openqflag do t.qtime += 1
	}
	return hydstep, errcode
}
