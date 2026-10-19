package epanet

// hydstatus.odin — the status checks between Newton iterations (EPANET's
// hydstatus.c): a check valve that sees reverse flow closes, a pump that is
// asked for more than its shutoff head closes, a pressure valve moves
// between open, active and closed, a flow control valve gives up when it
// cannot hold its setting, and a link into a full tank or out of an empty
// one is shut for this step. A pass over every link a trial, marked
// #no_bounds_check (network.odin).

// valve_status re-evaluates every PRV and PSV that has a setting. Returns
// whether any changed.
valve_status :: proc "contextless" (pr: ^Project) -> bool #no_bounds_check {
	net, hyd := &pr.net, &pr.hyd
	t0 := prof_begin()
	defer prof_end(.valves, t0)
	change := false
	for i in 1 ..= net.nvalves {
		k := net.valve_link[i]
		if hyd.setting[k] == MISSING do continue
		n1, n2 := net.n1[k], net.n2[k]
		status := hyd.status[k]
		#partial switch net.link_type[k] {
		case .PRV:
			hset := net.el[n2] + hyd.setting[k]
			hyd.status[k] = prv_status(net, hyd, int(k), status, hset, hyd.head[n1], hyd.head[n2])
		case .PSV:
			hset := net.el[n1] + hyd.setting[k]
			hyd.status[k] = psv_status(net, hyd, int(k), status, hset, hyd.head[n1], hyd.head[n2])
		case:
			continue
		}
		if status != hyd.status[k] {
			if hyd.status_report do writestatchange(pr, int(k), status, hyd.status[k])
			change = true
		}
	}
	return change
}

// link_status re-evaluates check valves, pumps, FCVs and links at tanks.
link_status :: proc "contextless" (pr: ^Project) -> bool #no_bounds_check {
	net, hyd := &pr.net, &pr.hyd
	t0 := prof_begin()
	defer prof_end(.status, t0)
	change := false
	for k in 1 ..= net.nlinks {
		n1, n2 := net.n1[k], net.n2[k]
		dh := hyd.head[n1] - hyd.head[n2]

		// A link shut for a step gets another chance.
		status := hyd.status[k]
		if status == .XHEAD || status == .TEMPCLOSED do hyd.status[k] = .OPEN

		if net.link_type[k] == .CVPIPE {
			hyd.status[k] = cv_status(hyd, hyd.status[k], dh, hyd.flow[k])
		}
		if net.link_type[k] == .PUMP && hyd.status[k] >= .OPEN && hyd.setting[k] > 0 {
			hyd.status[k] = pump_status(net, hyd, k, -dh)
		}
		if net.link_type[k] == .FCV && hyd.setting[k] != MISSING {
			hyd.status[k] = fcv_status(net, hyd, k, status, hyd.head[n1], hyd.head[n2])
		}
		if int(n1) > net.njuncs do tank_status(net, hyd, k, int(n1), hyd.flow[k])
		if int(n2) > net.njuncs do tank_status(net, hyd, k, int(n2), -hyd.flow[k])

		if status != hyd.status[k] {
			change = true
			if hyd.status_report do writestatchange(pr, int(k), status, hyd.status[k])
		}
	}
	return change
}

cv_status :: proc "contextless" (hyd: ^Hydraulics, s: Status, dh, q: f64) -> Status {
	if abs(dh) > hyd.htol {
		if dh < -hyd.htol do return .CLOSED
		if q < -hyd.qtol do return .CLOSED
		return .OPEN
	}
	if q < -hyd.qtol do return .CLOSED
	return s
}

// pump_status: dh is the head gain asked of the pump.
pump_status :: proc "contextless" (net: ^Network, hyd: ^Hydraulics, k: int, dh: f64) -> Status #no_bounds_check {
	p := net.link_pump[k]
	hmax: f64
	if net.pump_type[p] == .CONST_HP {
		hmax = BIG
		if hyd.flow[k] < TINY do return .TEMPCLOSED
	} else {
		hmax = (hyd.setting[k] * hyd.setting[k]) * net.pump_hmax[p]
	}
	if dh > hmax + hyd.htol do return .XHEAD
	return .OPEN
}

prv_status :: proc "contextless" (net: ^Network, hyd: ^Hydraulics, k: int, s: Status, hset, h1, h2: f64) -> Status #no_bounds_check {
	htol := hyd.htol
	hml := net.km[k] * (hyd.flow[k] * hyd.flow[k]) // loss when fully open
	status := s
	#partial switch s {
	case .ACTIVE:
		if hyd.flow[k] < -hyd.qtol {
			status = .CLOSED
		} else if h1 - hml < hset - htol {
			status = .OPEN
		} else {
			status = .ACTIVE
		}
	case .OPEN:
		if hyd.flow[k] < -hyd.qtol {
			status = .CLOSED
		} else if h2 >= hset + htol {
			status = .ACTIVE
		} else {
			status = .OPEN
		}
	case .CLOSED:
		if h1 >= hset + htol && h2 < hset - htol {
			status = .ACTIVE
		} else if h1 < hset - htol && h1 > h2 + htol {
			status = .OPEN
		} else {
			status = .CLOSED
		}
	case .XPRESSURE:
		if hyd.flow[k] < -hyd.qtol do status = .CLOSED
	}
	return status
}

psv_status :: proc "contextless" (net: ^Network, hyd: ^Hydraulics, k: int, s: Status, hset, h1, h2: f64) -> Status #no_bounds_check {
	htol := hyd.htol
	hml := net.km[k] * (hyd.flow[k] * hyd.flow[k])
	status := s
	#partial switch s {
	case .ACTIVE:
		if hyd.flow[k] < -hyd.qtol {
			status = .CLOSED
		} else if h2 + hml > hset + htol {
			status = .OPEN
		} else {
			status = .ACTIVE
		}
	case .OPEN:
		if hyd.flow[k] < -hyd.qtol {
			status = .CLOSED
		} else if h1 < hset - htol {
			status = .ACTIVE
		} else {
			status = .OPEN
		}
	case .CLOSED:
		if h2 > hset + htol && h1 > h2 + htol {
			status = .OPEN
		} else if h1 >= hset + htol && h1 > h2 + htol {
			status = .ACTIVE
		} else {
			status = .CLOSED
		}
	case .XPRESSURE:
		if hyd.flow[k] < -hyd.qtol do status = .CLOSED
	}
	return status
}

// fcv_status: reverse flow makes it XFCV; from XFCV it goes active once
// the flow reaches the setting; an active valve whose implied loss
// coefficient falls under its fully-open one cannot hold and is XFCV.
fcv_status :: proc "contextless" (net: ^Network, hyd: ^Hydraulics, k: int, s: Status, h1, h2: f64) -> Status #no_bounds_check {
	status := s
	if h1 - h2 < -hyd.htol {
		status = .XFCV
	} else if hyd.flow[k] < -hyd.qtol {
		status = .XFCV
	} else if s == .XFCV && hyd.flow[k] >= hyd.setting[k] {
		status = .ACTIVE
	} else if status == .ACTIVE {
		if (h1 - h2) / (hyd.flow[k] * hyd.flow[k]) < net.km[k] do status = .XFCV
	}
	return status
}

// tank_status: q is the flow out of (+) or into (−) tank node n.
tank_status :: proc "contextless" (net: ^Network, hyd: ^Hydraulics, k: int, n: int, q: f64) #no_bounds_check {
	if hyd.status[k] <= .CLOSED do return
	i := n - net.njuncs
	if net.tank_area[i] == 0 do return // a reservoir
	if hyd.head[n] >= net.tank_hmax[i] && !net.tank_overflow[i] && q < 0 {
		hyd.status[k] = .TEMPCLOSED
	} else if hyd.head[n] <= net.tank_hmin[i] && q > 0 {
		hyd.status[k] = .TEMPCLOSED
	}
}
