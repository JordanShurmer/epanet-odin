package epanet

// rules.odin — the rule-based controls at run time (EPANET's rules.c,
// the half that fires; parsing them is still C's). A rule is premises
// joined by AND/OR, THEN actions and ELSE actions; every rule that fires
// puts its actions on one list, one per link, the higher priority
// winning, and then the list is carried out.

// Pending is an action waiting on the list: which rule, which action.
Pending :: struct {
	rule, action: i32,
}

// check_rules evaluates every rule for the interval ending now (the last
// dt seconds), carries out the actions that fire, and returns how many
// links actually changed.
check_rules :: proc(net: ^Network, hyd: ^Hydraulics, t: ^Times, pr: ^Project, dt: i64) -> int {
	time1 := t.htime - dt + 1 // start of the interval
	list := make([]Pending, len(net.action_link), context.temp_allocator)
	n := 0
	for i in 1 ..= net.nrules {
		if !net.rule_enabled[i] do continue
		if eval_premises(net, hyd, t, time1, i) {
			n = add_actions(net, list[:], n, i, net.rule_then_first[i], net.rule_else_first[i])
		} else {
			n = add_actions(net, list[:], n, i, net.rule_else_first[i], net.rule_then_first[i + 1])
		}
	}
	if n == 0 do return 0
	return take_actions(net, hyd, pr, list[:n])
}

eval_premises :: proc "contextless" (net: ^Network, hyd: ^Hydraulics, t: ^Times, time1: i64, i: int) -> bool {
	result := true
	for p in net.rule_premise_first[i] ..< net.rule_premise_first[i + 1] {
		if net.premise_logop[p] == .OR {
			if !result do result = check_premise(net, hyd, t, time1, int(p))
		} else {
			if !result do return false
			result = check_premise(net, hyd, t, time1, int(p))
		}
	}
	return result
}

check_premise :: proc "contextless" (net: ^Network, hyd: ^Hydraulics, t: ^Times, time1: i64, p: int) -> bool {
	v := net.premise_variable[p]
	if v == .TIME || v == .CLOCKTIME do return check_time(net, t, time1, p)
	if net.premise_status[p] > .IS_NUMBER do return check_status(net, hyd, p)
	return check_value(net, hyd, p)
}

// check_time: an inequality is tested against the end of the interval,
// an equality against the whole of it (which may wrap midnight).
check_time :: proc "contextless" (net: ^Network, t: ^Times, time1: i64, p: int) -> bool {
	t1, t2: i64
	#partial switch net.premise_variable[p] {
	case .TIME:
		t1, t2 = time1, t.htime
	case .CLOCKTIME:
		t1 = (time1 + t.tstart) % SEC_PER_DAY
		t2 = (t.htime + t.tstart) % SEC_PER_DAY
	case:
		return false
	}
	x := i64(net.premise_value[p])
	#partial switch net.premise_relop[p] {
	case .LT:
		if t2 >= x do return false
	case .LE:
		if t2 > x do return false
	case .GT:
		if t2 <= x do return false
	case .GE:
		if t2 < x do return false
	case .EQ, .NE:
		flag := false
		if t2 < t1 {
			if x >= t1 || x <= t2 do flag = true
		} else {
			if x >= t1 && x <= t2 do flag = true
		}
		if net.premise_relop[p] == .EQ && !flag do return false
		if net.premise_relop[p] == .NE && flag do return false
	}
	return true
}

check_status :: proc "contextless" (net: ^Network, hyd: ^Hydraulics, p: int) -> bool {
	#partial switch net.premise_status[p] {
	case .IS_OPEN, .IS_CLOSED, .IS_ACTIVE:
		s := hyd.status[net.premise_index[p]]
		j: Rule_Status
		if s <= .CLOSED {
			j = .IS_CLOSED
		} else if s == .ACTIVE {
			j = .IS_ACTIVE
		} else {
			j = .IS_OPEN
		}
		if j == net.premise_status[p] && net.premise_relop[p] == .EQ do return true
		if j != net.premise_status[p] && net.premise_relop[p] == .NE do return true
	}
	return false
}

// check_value compares a variable, in user units, with a tolerance of
// 0.001.
check_value :: proc "contextless" (net: ^Network, hyd: ^Hydraulics, p: int) -> bool {
	tol := 1e-3
	i := int(net.premise_index[p])
	x: f64
	switch net.premise_variable[p] {
	case .DEMAND:
		if net.premise_object[p] == .SYSTEM {
			x = hyd.dsystem * net.ucf_demand
		} else {
			x = hyd.node_demand[i] * net.ucf_demand
		}
	case .HEAD, .GRADE:
		x = hyd.head[i] * net.ucf_head
	case .PRESSURE:
		x = (hyd.head[i] - net.el[i]) * net.ucf_pressure
	case .LEVEL:
		x = (hyd.head[i] - net.el[i]) * net.ucf_head
	case .FLOW:
		x = abs(hyd.flow[i]) * net.ucf_flow
	case .SETTING:
		if hyd.setting[i] == MISSING do return false
		x = hyd.setting[i]
		#partial switch net.link_type[i] {
		case .PRV, .PSV, .PBV:
			x = x * net.ucf_pressure
		case .FCV:
			x = x * net.ucf_flow
		}
	case .FILLTIME:
		if i <= net.njuncs do return false
		j := i - net.njuncs
		if net.tank_area[j] == 0 do return false
		if hyd.node_demand[i] <= TINY do return false
		x = (net.tank_vmax[j] - hyd.tank_volume[j]) / hyd.node_demand[i]
	case .DRAINTIME:
		if i <= net.njuncs do return false
		j := i - net.njuncs
		if net.tank_area[j] == 0 do return false
		if hyd.node_demand[i] >= -TINY do return false
		x = (net.tank_vmin[j] - hyd.tank_volume[j]) / hyd.node_demand[i]
	case .STATUS, .POWER, .TIME, .CLOCKTIME:
		return false
	}
	value := net.premise_value[p]
	#partial switch net.premise_relop[p] {
	case .EQ:
		if abs(x - value) > tol do return false
	case .NE:
		if abs(x - value) < tol do return false
	case .LT:
		if x > value + tol do return false
	case .LE:
		if x > value - tol do return false
	case .GT:
		if x < value - tol do return false
	case .GE:
		if x < value + tol do return false
	}
	return true
}

// add_actions puts rule i's actions [from, to) on the list, each link
// once: a later rule of higher priority takes the link over. EPANET
// prepends to its list, so the list here runs newest first too.
add_actions :: proc "contextless" (net: ^Network, list: []Pending, n0: int, i: int, from, to: i32) -> int {
	n := n0
	for a in from ..< to {
		link := net.action_link[a]
		taken := false
		for e in 0 ..< n {
			if net.action_link[list[e].action] == link {
				if net.rule_priority[i] > net.rule_priority[list[e].rule] do list[e] = {i32(i), a}
				taken = true
				break
			}
		}
		if !taken {
			list[n] = {i32(i), a}
			n += 1
		}
	}
	return n
}

// take_actions carries the list out, newest first, and counts the links
// that changed.
take_actions :: proc "contextless" (net: ^Network, hyd: ^Hydraulics, pr: ^Project, list: []Pending) -> int {
	tol := 1e-3
	n := 0
	for e := len(list) - 1; e >= 0; e -= 1 {
		a := int(list[e].action)
		k := int(net.action_link[a])
		s := hyd.status[k]
		v := hyd.setting[k]
		x := net.action_setting[a]
		flag := false
		if net.action_status[a] == .IS_OPEN && s <= .CLOSED {
			set_link_status(net, hyd, k, 1)
			flag = true
		} else if net.action_status[a] == .IS_CLOSED && s > .CLOSED {
			set_link_status(net, hyd, k, 0)
			flag = true
		} else if x != MISSING {
			#partial switch net.link_type[k] {
			case .PRV, .PSV, .PBV:
				x = x / net.ucf_pressure
			case .FCV:
				x = x / net.ucf_flow
			}
			if abs(x - v) > tol {
				set_link_setting(net, hyd, k, x)
				flag = true
			}
		}
		if flag {
			n += 1
			if hyd.status_report_any do writeruleaction(pr, int(k), pr.rule_label[list[e].rule])
		}
	}
	return n
}
