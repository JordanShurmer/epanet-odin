package epanet

// edit.odin — the project edited after it is read (EPANET's EN_add*,
// EN_delete* and their helpers in epanet.c, project.c and rules.c): the
// tables grow, a node or link goes in or comes out and every index that
// pointed past it moves, and demands, patterns, curves, controls and rules
// follow. The toolkit (api/) checks the arguments and converts the units;
// this file moves the data. Everything here allocates from the caller's
// allocator, which the toolkit sets to the project's arena.
//
// A per-object table is longer than its count once it has grown; the
// counts (nnodes, nlinks, …) say what is in use, and nothing in the engine
// reads a table's length. Patterns and curves stay exact: their length is
// their count plus one, and the toolkit reads it so.

import "core:strings"

// grow: s holds index n (doubling, so a run of adds is linear).
grow :: proc(s: ^[]$E, n: int) {
	if n < len(s^) do return
	t := make([]E, max(2 * len(s^), n + 1, 8))
	copy(t, s^)
	s^ = t
}

// shift_up moves s[from ..= to] to s[from + 1 ..= to + 1] (room for an
// entry at from); shift_down moves s[from + 1 ..= to] down over from.
shift_up :: proc "contextless" (s: []$E, from, to: int) {
	for k := to; k >= from; k -= 1 do s[k + 1] = s[k]
}
shift_down :: proc "contextless" (s: []$E, from, to: int) {
	for k in from ..< to do s[k] = s[k + 1]
}

// without: s less entry i (a new, exact slice).
without :: proc(s: []$E, i: int) -> []E {
	t := make([]E, len(s) - 1)
	copy(t[:i], s[:i])
	copy(t[i:], s[i + 1:])
	return t
}

// plus_one: s with one more entry at the end (a new, exact slice).
plus_one :: proc(s: []$E) -> []E {
	t := make([]E, len(s) + 1)
	copy(t, s)
	return t
}

// ── room ──────────────────────────────────────────────────────────────

node_room :: proc(p: ^Project, n: int) {
	net, hyd, q := &p.net, &p.hyd, &p.q
	grow(&p.node_id, n)
	grow(&p.node_x, n)
	grow(&p.node_y, n)
	grow(&p.node_rpt, n)
	grow(&p.node_comment, n)
	grow(&p.node_tag, n)
	grow(&net.el, n)
	grow(&net.ke, n)
	grow(&net.leak_cfa, n)
	grow(&net.leak_cva, n)
	grow(&net.node_type, n)
	grow(&net.c0, n)
	grow(&net.has_source, n)
	grow(&net.source_type, n)
	grow(&net.source_c0, n)
	grow(&net.source_pat, n)
	grow(&net.demand_first, n + 1)
	grow(&hyd.head, n)
	grow(&hyd.node_demand, n)
	grow(&hyd.demand_flow, n)
	grow(&hyd.full_demand, n)
	grow(&hyd.emitter_flow, n)
	grow(&hyd.leak_flow, n)
	grow(&hyd.leak_qfa, n)
	grow(&hyd.leak_qva, n)
	grow(&q.node_qual, n)
}

link_room :: proc(p: ^Project, n: int) {
	net, hyd := &p.net, &p.hyd
	grow(&p.link_id, n)
	grow(&p.link_rpt, n)
	grow(&p.link_comment, n)
	grow(&p.link_tag, n)
	grow(&p.vertex_x, n)
	grow(&p.vertex_y, n)
	grow(&net.link_type, n)
	grow(&net.n1, n)
	grow(&net.n2, n)
	grow(&net.diam, n)
	grow(&net.len, n)
	grow(&net.km, n)
	grow(&net.kc, n)
	grow(&net.r, n)
	grow(&net.link_kb, n)
	grow(&net.link_kw, n)
	grow(&net.link_pump, n)
	grow(&net.link_valve, n)
	grow(&net.init_status, n)
	grow(&net.init_setting, n)
	grow(&net.leak_area, n)
	grow(&net.leak_expan, n)
	grow(&hyd.flow, n)
	grow(&hyd.setting, n)
	grow(&hyd.status, n)
}

tank_room :: proc(p: ^Project, n: int) {
	net, hyd, q := &p.net, &p.hyd, &p.q
	grow(&net.tank_node, n)
	grow(&net.tank_area, n)
	grow(&net.tank_hmin, n)
	grow(&net.tank_hmax, n)
	grow(&net.tank_vmin, n)
	grow(&net.tank_vmax, n)
	grow(&net.tank_pat, n)
	grow(&net.tank_vcurve, n)
	grow(&net.tank_overflow, n)
	grow(&net.tank_h0, n)
	grow(&net.tank_v0, n)
	grow(&net.tank_v1frac, n)
	grow(&net.tank_kb, n)
	grow(&net.tank_mix, n)
	grow(&hyd.tank_volume, n)
	grow(&q.tank_c, n)
}

pump_room :: proc(p: ^Project, n: int) {
	net, hyd := &p.net, &p.hyd
	grow(&p.pump_qmax, n)
	grow(&net.pump_link, n)
	grow(&net.pump_type, n)
	grow(&net.pump_hcurve, n)
	grow(&net.pump_ecurve, n)
	grow(&net.pump_h0, n)
	grow(&net.pump_r, n)
	grow(&net.pump_n, n)
	grow(&net.pump_hmax, n)
	grow(&net.pump_q0, n)
	grow(&net.pump_upat, n)
	grow(&net.pump_epat, n)
	grow(&net.pump_ecost, n)
	grow(&hyd.energy, n)
}

valve_room :: proc(p: ^Project, n: int) {
	grow(&p.net.valve_link, n)
	grow(&p.net.valve_curve, n)
}

control_room :: proc(p: ^Project, n: int) {
	net := &p.net
	grow(&net.control_link, n)
	grow(&net.control_node, n)
	grow(&net.control_type, n)
	grow(&net.control_grade, n)
	grow(&net.control_setting, n)
	grow(&net.control_status, n)
	grow(&net.control_time, n)
	grow(&net.control_enabled, n)
}

demand_room :: proc(p: ^Project, n: int) {
	grow(&p.net.demand_base, n)
	grow(&p.net.demand_pat, n)
	grow(&p.demand_name, n)
}

// ── demands: node i's are slots demand_first[i] ..< demand_first[i+1] ──

// add_demand appends a category to node i's; the slots after move up.
add_demand :: proc(p: ^Project, i: int, base: f64, pat: int, name: string) {
	net := &p.net
	nd := int(net.demand_first[net.nnodes + 1]) // the next free slot
	demand_room(p, nd)
	pos := int(net.demand_first[i + 1])
	shift_up(net.demand_base, pos, nd - 1)
	shift_up(net.demand_pat, pos, nd - 1)
	shift_up(p.demand_name, pos, nd - 1)
	net.demand_base[pos] = base
	net.demand_pat[pos] = i32(pat)
	p.demand_name[pos] = len(name) > 0 ? strings.clone(clip(name, MAXID)) : ""
	for k in i + 1 ..= net.nnodes + 1 do net.demand_first[k] += 1
}

// demand_slot: node i's k-th category (1-based), or -1.
demand_slot :: proc "contextless" (p: ^Project, i, k: int) -> int {
	net := &p.net
	first, last := int(net.demand_first[i]), int(net.demand_first[i + 1])
	if k < 1 || first + k - 1 >= last do return -1
	return first + k - 1
}

// delete_demand takes node i's k-th category out.
delete_demand :: proc(p: ^Project, i, k: int) {
	net := &p.net
	pos := demand_slot(p, i, k)
	if pos < 0 do return
	nd := int(net.demand_first[net.nnodes + 1])
	shift_down(net.demand_base, pos, nd - 1)
	shift_down(net.demand_pat, pos, nd - 1)
	shift_down(p.demand_name, pos, nd - 1)
	for j in i + 1 ..= net.nnodes + 1 do net.demand_first[j] -= 1
}

// ── nodes ─────────────────────────────────────────────────────────────

// add_node puts a new node in: a junction right after the last junction
// (the tanks move up one), a tank or reservoir at the end. Defaults are
// EPANET's. Returns the new index.
add_node :: proc(p: ^Project, id: string, kind: Node_Type) -> int {
	net, hyd, q := &p.net, &p.hyd, &p.q
	nn := net.nnodes + 1
	node_room(p, nn)
	i: int
	if kind == .JUNCTION {
		i = net.njuncs + 1
		last := nn - 1 // the old last node
		shift_up(p.node_id, i, last)
		shift_up(p.node_x, i, last)
		shift_up(p.node_y, i, last)
		shift_up(p.node_rpt, i, last)
		shift_up(p.node_comment, i, last)
		shift_up(p.node_tag, i, last)
		shift_up(net.el, i, last)
		shift_up(net.ke, i, last)
		shift_up(net.leak_cfa, i, last)
		shift_up(net.leak_cva, i, last)
		shift_up(net.node_type, i, last)
		shift_up(net.c0, i, last)
		shift_up(net.has_source, i, last)
		shift_up(net.source_type, i, last)
		shift_up(net.source_c0, i, last)
		shift_up(net.source_pat, i, last)
		shift_up(hyd.head, i, last)
		shift_up(hyd.node_demand, i, last)
		shift_up(hyd.demand_flow, i, last)
		shift_up(hyd.full_demand, i, last)
		shift_up(hyd.emitter_flow, i, last)
		shift_up(hyd.leak_flow, i, last)
		shift_up(hyd.leak_qfa, i, last)
		shift_up(hyd.leak_qva, i, last)
		shift_up(q.node_qual, i, last)
		for k in i + 1 ..= nn do p.nodes_by_id[p.node_id[k]] = i32(k)
		// an empty demand range at i: the firsts after it move up one
		for k := nn + 1; k > i; k -= 1 do net.demand_first[k] = net.demand_first[k - 1]
		for t in 1 ..= net.ntanks do net.tank_node[t] += 1
		for k in 1 ..= net.nlinks {
			if int(net.n1[k]) >= i do net.n1[k] += 1
			if int(net.n2[k]) >= i do net.n2[k] += 1
		}
		for c in 1 ..= net.ncontrols do if int(net.control_node[c]) >= i do net.control_node[c] += 1
		adjust_tank_rules(p, 1)
		if q.trace_node >= i do q.trace_node += 1 // (EPANET leaves the trace node where it was)
		net.njuncs += 1
	} else {
		i = nn
		t := net.ntanks + 1
		tank_room(p, t)
		net.tank_node[t] = i32(i)
		net.tank_area[t] = kind == .TANK ? 1.0 : 0.0
		net.tank_hmin[t], net.tank_hmax[t], net.tank_h0[t] = 0, 0, 0
		net.tank_vmin[t], net.tank_vmax[t], net.tank_v0[t] = 0, 0, 0
		net.tank_kb[t] = 0
		net.tank_pat[t] = 0
		net.tank_vcurve[t] = 0
		net.tank_mix[t] = .MIX1
		net.tank_v1frac[t] = 1
		net.tank_overflow[t] = false
		hyd.tank_volume[t] = 0
		q.tank_c[t] = 0
		net.ntanks = t
		net.demand_first[nn + 1] = net.demand_first[nn]
	}
	net.nnodes = nn
	p.node_id[i] = strings.clone(id)
	p.nodes_by_id[p.node_id[i]] = i32(i)
	net.node_type[i] = kind
	net.el[i], net.ke[i], net.c0[i] = 0, 0, 0
	net.leak_cfa[i], net.leak_cva[i] = 0, 0
	net.has_source[i] = false
	net.source_type[i], net.source_c0[i], net.source_pat[i] = .CONCEN, 0, 0
	p.node_rpt[i] = false
	p.node_x[i], p.node_y[i] = MISSING, MISSING
	p.node_comment[i], p.node_tag[i] = "", ""
	hyd.head[i], hyd.node_demand[i], hyd.demand_flow[i], hyd.full_demand[i] = 0, 0, 0, 0
	hyd.emitter_flow[i], hyd.leak_flow[i], hyd.leak_qfa[i], hyd.leak_qva[i] = 0, 0, 0, 0
	q.node_qual[i] = 0
	if kind == .JUNCTION do add_demand(p, i, 0, 0, "")
	return i
}

// delete_node takes node i out with its demands, its links, the controls
// and rules that name it, and moves every higher index down.
delete_node :: proc(p: ^Project, i: int) {
	net, hyd, q := &p.net, &p.hyd, &p.q
	kind := net.node_type[i]
	// its links first (in reverse, so their indices hold)
	for k := net.nlinks; k >= 1; k -= 1 {
		if int(net.n1[k]) == i || int(net.n2[k]) == i do delete_link(p, k)
	}
	// its demands
	first, last := int(net.demand_first[i]), int(net.demand_first[i + 1])
	count := last - first
	nd := int(net.demand_first[net.nnodes + 1])
	if count > 0 {
		for k in first ..< nd - count {
			net.demand_base[k] = net.demand_base[k + count]
			net.demand_pat[k] = net.demand_pat[k + count]
			p.demand_name[k] = p.demand_name[k + count]
		}
	}
	for k in i ..= net.nnodes do net.demand_first[k] = net.demand_first[k + 1] - i32(count)
	delete_key(&p.nodes_by_id, p.node_id[i])
	last_node := net.nnodes - 1
	shift_down(p.node_id, i, last_node)
	shift_down(p.node_x, i, last_node)
	shift_down(p.node_y, i, last_node)
	shift_down(p.node_rpt, i, last_node)
	shift_down(p.node_comment, i, last_node)
	shift_down(p.node_tag, i, last_node)
	shift_down(net.el, i, last_node)
	shift_down(net.ke, i, last_node)
	shift_down(net.leak_cfa, i, last_node)
	shift_down(net.leak_cva, i, last_node)
	shift_down(net.node_type, i, last_node)
	shift_down(net.c0, i, last_node)
	shift_down(net.has_source, i, last_node)
	shift_down(net.source_type, i, last_node)
	shift_down(net.source_c0, i, last_node)
	shift_down(net.source_pat, i, last_node)
	shift_down(hyd.head, i, last_node)
	shift_down(hyd.node_demand, i, last_node)
	shift_down(hyd.demand_flow, i, last_node)
	shift_down(hyd.full_demand, i, last_node)
	shift_down(hyd.emitter_flow, i, last_node)
	shift_down(hyd.leak_flow, i, last_node)
	shift_down(hyd.leak_qfa, i, last_node)
	shift_down(hyd.leak_qva, i, last_node)
	shift_down(q.node_qual, i, last_node)
	for k in i ..= last_node do p.nodes_by_id[p.node_id[k]] = i32(k)
	if i < q.trace_node do q.trace_node -= 1
	if kind != .JUNCTION {
		t := find_tank(net, i)
		lt := net.ntanks - 1
		shift_down(net.tank_node, t, lt)
		shift_down(net.tank_area, t, lt)
		shift_down(net.tank_hmin, t, lt)
		shift_down(net.tank_hmax, t, lt)
		shift_down(net.tank_vmin, t, lt)
		shift_down(net.tank_vmax, t, lt)
		shift_down(net.tank_pat, t, lt)
		shift_down(net.tank_vcurve, t, lt)
		shift_down(net.tank_overflow, t, lt)
		shift_down(net.tank_h0, t, lt)
		shift_down(net.tank_v0, t, lt)
		shift_down(net.tank_v1frac, t, lt)
		shift_down(net.tank_kb, t, lt)
		shift_down(net.tank_mix, t, lt)
		shift_down(hyd.tank_volume, t, lt)
		shift_down(q.tank_c, t, lt)
		net.ntanks = lt
	} else {
		net.njuncs -= 1
	}
	for t in 1 ..= net.ntanks do if int(net.tank_node[t]) > i do net.tank_node[t] -= 1
	for k in 1 ..= net.nlinks {
		if int(net.n1[k]) > i do net.n1[k] -= 1
		if int(net.n2[k]) > i do net.n2[k] -= 1
	}
	for c := net.ncontrols; c >= 1; c -= 1 do if int(net.control_node[c]) == i do delete_control(p, c)
	for c in 1 ..= net.ncontrols do if int(net.control_node[c]) > i do net.control_node[c] -= 1
	adjust_rules(p, .NODE, i)
	net.nnodes = last_node
}

find_tank :: proc "contextless" (net: ^Network, node: int) -> int {
	for t in 1 ..= net.ntanks do if int(net.tank_node[t]) == node do return t
	return 0
}

// ── links ─────────────────────────────────────────────────────────────

// add_link puts a new link at the end, with EPANET's defaults for its
// kind (a 10-inch pipe a city block long, a pump at full speed, an
// active valve). Returns the new index.
add_link :: proc(p: ^Project, id: string, kind: Link_Type, n1, n2: int) -> int {
	net, hyd := &p.net, &p.hyd
	k := net.nlinks + 1
	link_room(p, k)
	p.link_id[k] = strings.clone(id)
	p.links_by_id[p.link_id[k]] = i32(k)
	net.link_type[k] = kind
	net.n1[k], net.n2[k] = i32(n1), i32(n2)
	net.init_status[k] = .OPEN
	net.link_pump[k], net.link_valve[k] = 0, 0
	if kind == .PUMP {
		m := net.npumps + 1
		pump_room(p, m)
		net.pump_link[m] = i32(k)
		net.pump_type[m] = .NOCURVE
		net.pump_q0[m], p.pump_qmax[m], net.pump_hmax[m] = 0, 0, 0
		net.pump_h0[m], net.pump_r[m], net.pump_n[m] = 0, 0, 0
		net.pump_hcurve[m], net.pump_ecurve[m] = 0, 0
		net.pump_upat[m], net.pump_epat[m] = 0, 0
		net.pump_ecost[m] = 0
		hyd.energy[m] = {total_cost = MISSING}
		net.npumps = m
		net.link_pump[k] = i32(m)
		net.kc[k] = 1.0 // speed
		net.km[k] = 0.0 // horsepower
		net.len[k] = 0.0
		net.diam[k] = 0.0
	} else if kind <= .PIPE {
		net.diam[k] = 10 / p.ucf[.DIAM]
		switch hyd.formflag {
		case .HW:
			net.kc[k] = 130
		case .DW:
			net.kc[k] = 0.0005
		case .CM:
			net.kc[k] = 0.01
		}
		net.km[k] = 0.0
		net.len[k] = 330.0
	} else {
		v := net.nvalves + 1
		valve_room(p, v)
		net.valve_link[v] = i32(k)
		net.valve_curve[v] = 0
		net.nvalves = v
		net.link_valve[k] = i32(v)
		net.diam[k] = 10 / p.ucf[.DIAM]
		net.kc[k] = 0.0
		net.km[k] = 0.0
		net.len[k] = 0.0
		net.init_status[k] = .ACTIVE
	}
	net.link_kb[k], net.link_kw[k] = 0, 0
	net.leak_area[k], net.leak_expan[k] = 0, 0
	net.init_setting[k] = net.kc[k]
	net.r[k] = 0
	p.link_rpt[k] = false
	p.link_comment[k], p.link_tag[k] = "", ""
	p.vertex_x[k], p.vertex_y[k] = nil, nil
	hyd.flow[k], hyd.setting[k] = 0, 0
	hyd.status[k] = .OPEN
	net.nlinks = k
	return k
}

// delete_link takes link k out with its pump or valve record, the
// controls and rules that name it, and moves every higher index down.
delete_link :: proc(p: ^Project, k: int) {
	net, hyd := &p.net, &p.hyd
	kind := net.link_type[k]
	delete_key(&p.links_by_id, p.link_id[k])
	if kind == .PUMP {
		m := int(net.link_pump[k])
		lm := net.npumps - 1
		shift_down(p.pump_qmax, m, lm)
		shift_down(net.pump_link, m, lm)
		shift_down(net.pump_type, m, lm)
		shift_down(net.pump_hcurve, m, lm)
		shift_down(net.pump_ecurve, m, lm)
		shift_down(net.pump_h0, m, lm)
		shift_down(net.pump_r, m, lm)
		shift_down(net.pump_n, m, lm)
		shift_down(net.pump_hmax, m, lm)
		shift_down(net.pump_q0, m, lm)
		shift_down(net.pump_upat, m, lm)
		shift_down(net.pump_epat, m, lm)
		shift_down(net.pump_ecost, m, lm)
		shift_down(hyd.energy, m, lm)
		net.npumps = lm
		for j in 1 ..= net.nlinks do if int(net.link_pump[j]) > m do net.link_pump[j] -= 1
	} else if kind > .PUMP {
		v := int(net.link_valve[k])
		lv := net.nvalves - 1
		shift_down(net.valve_link, v, lv)
		shift_down(net.valve_curve, v, lv)
		net.nvalves = lv
		for j in 1 ..= net.nlinks do if int(net.link_valve[j]) > v do net.link_valve[j] -= 1
	}
	last := net.nlinks - 1
	shift_down(p.link_id, k, last)
	shift_down(p.link_rpt, k, last)
	shift_down(p.link_comment, k, last)
	shift_down(p.link_tag, k, last)
	shift_down(p.vertex_x, k, last)
	shift_down(p.vertex_y, k, last)
	shift_down(net.link_type, k, last)
	shift_down(net.n1, k, last)
	shift_down(net.n2, k, last)
	shift_down(net.diam, k, last)
	shift_down(net.len, k, last)
	shift_down(net.km, k, last)
	shift_down(net.kc, k, last)
	shift_down(net.r, k, last)
	shift_down(net.link_kb, k, last)
	shift_down(net.link_kw, k, last)
	shift_down(net.link_pump, k, last)
	shift_down(net.link_valve, k, last)
	shift_down(net.init_status, k, last)
	shift_down(net.init_setting, k, last)
	shift_down(net.leak_area, k, last)
	shift_down(net.leak_expan, k, last)
	shift_down(hyd.flow, k, last)
	shift_down(hyd.setting, k, last)
	shift_down(hyd.status, k, last)
	for j in k ..= last do p.links_by_id[p.link_id[j]] = i32(j)
	for m in 1 ..= net.npumps do if int(net.pump_link[m]) > k do net.pump_link[m] -= 1
	for v in 1 ..= net.nvalves do if int(net.valve_link[v]) > k do net.valve_link[v] -= 1
	for c := net.ncontrols; c >= 1; c -= 1 do if int(net.control_link[c]) == k do delete_control(p, c)
	for c in 1 ..= net.ncontrols do if int(net.control_link[c]) > k do net.control_link[c] -= 1
	adjust_rules(p, .LINK, k)
	net.nlinks = last
}

// ── controls ──────────────────────────────────────────────────────────

// add_control makes room for one more and returns its index.
add_control :: proc(p: ^Project) -> int {
	net := &p.net
	c := net.ncontrols + 1
	control_room(p, c)
	net.ncontrols = c
	return c
}

delete_control :: proc(p: ^Project, c: int) {
	net := &p.net
	last := net.ncontrols - 1
	shift_down(net.control_link, c, last)
	shift_down(net.control_node, c, last)
	shift_down(net.control_type, c, last)
	shift_down(net.control_grade, c, last)
	shift_down(net.control_setting, c, last)
	shift_down(net.control_status, c, last)
	shift_down(net.control_time, c, last)
	shift_down(net.control_enabled, c, last)
	net.ncontrols = last
}

// ── patterns and curves ───────────────────────────────────────────────

// add_pattern_entry appends a pattern of one 1.0 and returns its index.
add_pattern_entry :: proc(p: ^Project, id: string) -> int {
	net := &p.net
	p.pattern_id = plus_one(p.pattern_id)
	p.pattern_comment = plus_one(p.pattern_comment)
	net.patterns = plus_one(net.patterns)
	n := len(net.patterns) - 1
	p.pattern_id[n] = strings.clone(id)
	p.patterns_by_id[p.pattern_id[n]] = i32(n)
	f := make([]f64, 1)
	f[0] = 1.0
	net.patterns[n] = {f}
	return n
}

// adjust_pattern: a reference to a deleted pattern becomes 0, higher
// ones move down.
adjust_pattern :: proc "contextless" (pat: ^i32, index: int) {
	if int(pat^) == index {
		pat^ = 0
	} else if int(pat^) > index {
		pat^ -= 1
	}
}

delete_pattern_entry :: proc(p: ^Project, index: int) {
	net, hyd := &p.net, &p.hyd
	nd := int(net.demand_first[net.nnodes + 1])
	for k in 1 ..< nd do adjust_pattern(&net.demand_pat[k], index)
	for i in 1 ..= net.nnodes do adjust_pattern(&net.source_pat[i], index)
	for t in 1 ..= net.ntanks do adjust_pattern(&net.tank_pat[t], index)
	for m in 1 ..= net.npumps {
		adjust_pattern(&net.pump_upat[m], index)
		adjust_pattern(&net.pump_epat[m], index)
	}
	e := i32(hyd.epat)
	adjust_pattern(&e, index)
	hyd.epat = int(e)
	d := i32(net.def_pat)
	adjust_pattern(&d, index)
	net.def_pat = int(d)
	delete_key(&p.patterns_by_id, p.pattern_id[index])
	p.pattern_id = without(p.pattern_id, index)
	p.pattern_comment = without(p.pattern_comment, index)
	net.patterns = without(net.patterns, index)
	for i in index ..< len(p.pattern_id) do p.patterns_by_id[p.pattern_id[i]] = i32(i)
}

// add_curve_entry appends a generic curve of one point (1, 1).
add_curve_entry :: proc(p: ^Project, id: string) -> int {
	net := &p.net
	p.curve_id = plus_one(p.curve_id)
	p.curve_comment = plus_one(p.curve_comment)
	p.curve_type = plus_one(p.curve_type)
	net.curves = plus_one(net.curves)
	n := len(net.curves) - 1
	p.curve_id[n] = strings.clone(id)
	p.curves_by_id[p.curve_id[n]] = i32(n)
	p.curve_type[n] = .GENERIC_CURVE
	x := make([]f64, 1)
	y := make([]f64, 1)
	x[0], y[0] = 1.0, 1.0
	net.curves[n] = {x, y}
	return n
}

adjust_curve :: proc "contextless" (curve: ^i32, index: int) {
	if int(curve^) == index {
		curve^ = 0
	} else if int(curve^) > index {
		curve^ -= 1
	}
}

delete_curve_entry :: proc(p: ^Project, index: int) {
	net := &p.net
	for t in 1 ..= net.ntanks do adjust_curve(&net.tank_vcurve[t], index)
	for m in 1 ..= net.npumps {
		adjust_curve(&net.pump_hcurve[m], index)
		adjust_curve(&net.pump_ecurve[m], index)
	}
	for v in 1 ..= net.nvalves {
		k := int(net.valve_link[v])
		if net.link_type[k] == .PCV && net.valve_curve[v] > 0 {
			adjust_curve(&net.valve_curve[v], index)
			if net.valve_curve[v] == 0 do net.kc[k] = 0
		}
		if net.link_type[k] == .GPV {
			c := i32(net.kc[k])
			adjust_curve(&c, index)
			net.kc[k] = f64(c)
		}
	}
	delete_key(&p.curves_by_id, p.curve_id[index])
	p.curve_id = without(p.curve_id, index)
	p.curve_comment = without(p.curve_comment, index)
	p.curve_type = without(p.curve_type, index)
	net.curves = without(net.curves, index)
	for i in index ..< len(p.curve_id) do p.curves_by_id[p.curve_id[i]] = i32(i)
}

// ── rules ─────────────────────────────────────────────────────────────

// delete_rule takes rule r out: its premises and actions leave the flat
// tables and the firsts after it move down.
delete_rule :: proc(p: ^Project, r: int) {
	net := &p.net
	pf, pl := int(net.rule_premise_first[r]), int(net.rule_premise_first[r + 1])
	af, al := int(net.rule_then_first[r]), int(net.rule_then_first[r + 1])
	np, na := pl - pf, al - af
	ptotal := int(net.rule_premise_first[net.nrules + 1])
	atotal := int(net.rule_then_first[net.nrules + 1])
	if np > 0 {
		for k in pf ..< ptotal - np {
			net.premise_logop[k] = net.premise_logop[k + np]
			net.premise_object[k] = net.premise_object[k + np]
			net.premise_index[k] = net.premise_index[k + np]
			net.premise_variable[k] = net.premise_variable[k + np]
			net.premise_relop[k] = net.premise_relop[k + np]
			net.premise_status[k] = net.premise_status[k + np]
			net.premise_value[k] = net.premise_value[k + np]
		}
	}
	if na > 0 {
		for k in af ..< atotal - na {
			net.action_link[k] = net.action_link[k + na]
			net.action_status[k] = net.action_status[k + na]
			net.action_setting[k] = net.action_setting[k + na]
		}
	}
	for k in r ..= net.nrules {
		net.rule_premise_first[k] = net.rule_premise_first[k + 1] - i32(np)
		net.rule_then_first[k] = net.rule_then_first[k + 1] - i32(na)
		if k < net.nrules do net.rule_else_first[k] = net.rule_else_first[k + 1] - i32(na)
	}
	last := net.nrules - 1
	shift_down(p.rule_label, r, last)
	shift_down(net.rule_priority, r, last)
	shift_down(net.rule_enabled, r, last)
	net.nrules = last
}

// adjust_rules, when node or link index is deleted: the rules that name
// it go, and higher indices move down (rules.c adjustrules).
adjust_rules :: proc(p: ^Project, object: Rule_Object, index: int) {
	net := &p.net
	for r := net.nrules; r >= 1; r -= 1 {
		gone := false
		for k in net.rule_premise_first[r] ..< net.rule_premise_first[r + 1] {
			if net.premise_object[k] == object && int(net.premise_index[k]) == index do gone = true
		}
		if object == .LINK {
			for k in net.rule_then_first[r] ..< net.rule_then_first[r + 1] {
				if int(net.action_link[k]) == index do gone = true
			}
		}
		if gone do delete_rule(p, r)
	}
	for k in 1 ..< int(net.rule_premise_first[net.nrules + 1]) {
		if net.premise_object[k] == object && int(net.premise_index[k]) > index do net.premise_index[k] -= 1
	}
	if object == .LINK {
		for k in 1 ..< int(net.rule_then_first[net.nrules + 1]) {
			if int(net.action_link[k]) > index do net.action_link[k] -= 1
		}
	}
}

// adjust_tank_rules moves every premise on a tank or reservoir by ndiff
// (a junction was added before them).
adjust_tank_rules :: proc "contextless" (p: ^Project, ndiff: int) {
	net := &p.net
	for k in 1 ..< int(net.rule_premise_first[net.nrules + 1]) {
		if net.premise_object[k] == .NODE && int(net.premise_index[k]) > net.njuncs do net.premise_index[k] += i32(ndiff)
	}
}

// update_rule_units rescales the premises and actions that carry a value
// when the flow or pressure units change.
update_rule_units :: proc "contextless" (p: ^Project, dcf, pcf, hcf, qcf: f64) {
	net := &p.net
	for k in 1 ..< int(net.rule_premise_first[net.nrules + 1]) {
		#partial switch net.premise_variable[k] {
		case .DEMAND:
			net.premise_value[k] *= dcf
		case .HEAD, .GRADE, .LEVEL:
			net.premise_value[k] *= hcf
		case .PRESSURE:
			net.premise_value[k] *= pcf
		case .FLOW:
			net.premise_value[k] *= qcf
		case .SETTING:
			#partial switch net.link_type[net.premise_index[k]] {
			case .PRV, .PSV, .PBV:
				net.premise_value[k] *= pcf
			case .FCV:
				net.premise_value[k] *= qcf
			}
		}
	}
	for k in 1 ..< int(net.rule_then_first[net.nrules + 1]) {
		if net.action_setting[k] == MISSING do continue
		#partial switch net.link_type[net.action_link[k]] {
		case .PRV, .PSV, .PBV:
			net.action_setting[k] *= pcf
		case .FCV:
			net.action_setting[k] *= qcf
		}
	}
}

// in_controls: is node (object .NODE) or link (.LINK) index named by a
// control or a rule?
in_controls :: proc "contextless" (p: ^Project, object: Rule_Object, index: int) -> bool {
	net := &p.net
	for c in 1 ..= net.ncontrols {
		if object == .NODE && int(net.control_node[c]) == index do return true
		if object == .LINK && int(net.control_link[c]) == index do return true
	}
	for k in 1 ..< int(net.rule_premise_first[net.nrules + 1]) {
		if net.premise_object[k] == object && int(net.premise_index[k]) == index do return true
	}
	if object == .LINK {
		for k in 1 ..< int(net.rule_then_first[net.nrules + 1]) {
			if int(net.action_link[k]) == index do return true
		}
	}
	return false
}

// add_rule_text parses one rule statement (lines separated by newlines)
// with the reader's own rule parser, onto the rules the project has.
// Returns EPANET's error code; a failed rule leaves nothing behind.
add_rule_text :: proc(p: ^Project, text: string) -> int {
	net := &p.net
	ps := Parser{p = p}
	// the rules as the reader keeps them while it reads
	np := int(net.rule_premise_first[net.nrules + 1])
	na := int(net.rule_then_first[net.nrules + 1])
	append(&ps.rule_label, ..p.rule_label[:net.nrules + 1])
	append(&ps.rule_priority, ..net.rule_priority[:net.nrules + 1])
	append(&ps.rule_enabled, ..net.rule_enabled[:net.nrules + 1])
	append(&ps.rule_premise_first, ..net.rule_premise_first[:net.nrules + 1])
	append(&ps.rule_then_first, ..net.rule_then_first[:net.nrules + 1])
	append(&ps.rule_else_first, ..net.rule_else_first[:net.nrules + 1])
	append(&ps.premise_logop, ..net.premise_logop[:np])
	append(&ps.premise_object, ..net.premise_object[:np])
	append(&ps.premise_index, ..net.premise_index[:np])
	append(&ps.premise_variable, ..net.premise_variable[:np])
	append(&ps.premise_relop, ..net.premise_relop[:np])
	append(&ps.premise_status, ..net.premise_status[:np])
	append(&ps.premise_value, ..net.premise_value[:np])
	append(&ps.action_link, ..net.action_link[:na])
	append(&ps.action_status, ..net.action_status[:na])
	append(&ps.action_setting, ..net.action_setting[:na])
	ps.rule_state = .PRIORITY
	ps.rule_errcode = 0
	nrules := net.nrules
	rest := text
	for len(rest) > 0 {
		line := rest
		if nl := strings.index_byte(rest, '\n'); nl >= 0 {
			line = rest[:nl]
			rest = rest[nl + 1:]
		} else {
			rest = ""
		}
		ps.comment = gettokens(&ps, line)
		if ps.ntok > 0 && ps.tok[0][0] != ';' {
			ruledata(&ps)
			if ps.rule_errcode != 0 do break
		}
	}
	if ps.rule_errcode != 0 {
		if net.nrules > nrules do delete_last_rule(&ps)
		net.nrules = nrules
		return ps.rule_errcode == 201 ? 250 : ps.rule_errcode
	}
	if net.nrules == nrules do return 0 // nothing was added
	append(&ps.rule_premise_first, i32(len(ps.premise_logop)))
	append(&ps.rule_then_first, i32(len(ps.action_link)))
	p.rule_label = ps.rule_label[:]
	net.rule_priority = ps.rule_priority[:]
	net.rule_enabled = ps.rule_enabled[:]
	net.rule_premise_first = ps.rule_premise_first[:]
	net.rule_then_first = ps.rule_then_first[:]
	net.rule_else_first = ps.rule_else_first[:]
	net.premise_logop = ps.premise_logop[:]
	net.premise_object = ps.premise_object[:]
	net.premise_index = ps.premise_index[:]
	net.premise_variable = ps.premise_variable[:]
	net.premise_relop = ps.premise_relop[:]
	net.premise_status = ps.premise_status[:]
	net.premise_value = ps.premise_value[:]
	net.action_link = ps.action_link[:]
	net.action_status = ps.action_status[:]
	net.action_setting = ps.action_setting[:]
	return 0
}

// ── vertices, comments, tags ──────────────────────────────────────────

set_vertices :: proc(p: ^Project, k: int, x, y: []f64) {
	if len(x) == 0 {
		p.vertex_x[k], p.vertex_y[k] = nil, nil
		return
	}
	vx := make([]f64, len(x))
	vy := make([]f64, len(y))
	copy(vx, x)
	copy(vy, y)
	p.vertex_x[k], p.vertex_y[k] = vx, vy
}
