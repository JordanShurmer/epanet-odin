package epanet

// quality.odin — the water quality engine (EPANET's quality.c,
// qualroute.c and qualreact.c): a constituent carried through the network
// as volume segments in every pipe and tank, reacting as it goes.
//
// Each link and each tank is a chain of segments, upstream to downstream.
// EPANET keeps them as linked lists in a memory pool; here they are one
// array of Segment — volume, quality and the slot of the segment behind
// — with a free list through the same prev field. The chains and every
// operation on them are EPANET's, so the numbers come out the same.
//
// The procs that walk a chain run without bounds checks: a slot comes
// from the store's own first, last and prev, kept by add_seg and
// recycle_seg below, and the walks are most of a quality step.


// Mass_Balance is the running account of a constituent.
Mass_Balance :: struct {
	initial, inflow, outflow, reacted, final, ratio: f64,
	seg_count:                                       int,
}

// Segment is one slug of water: its volume, its quality, and the slot of
// the one behind it (upstream), 0 being none.
Segment :: struct {
	v, c: f64,
	prev: i32,
}

// Segments is the store: at[i] is segment i. Chain k (a link, or nlinks
// + a tank index) runs from first[k] to last[k]; free heads the free
// list, chained through prev. Slot 0 is unused.
Segments :: struct {
	at:          [dynamic]Segment,
	first, last: []i32,
	free:        i32,
}

// Quality is the engine's settings and state. The per-element arrays are
// EPANET's (or mirrored by the bridge); segs is the engine's own.
Quality :: struct {
	kind:                                      Qual_Type,
	trace_node:                                int,
	ctol:                                      f64, // segments closer than this merge
	diffus:                                    f64, // molecular diffusivity
	climit:                                    f64, // limiting potential
	bulk_order, wall_order, tank_order:        f64,
	sc, bucf, tucf:                            f64, // Schmidt number, unit factors (from init)
	reactive:                                  bool,

	node_qual:                                 []f64,
	tank_c:                                    []f64,
	link_rc:                                   []f64, // wall reaction coefficient per pipe
	pipe_rate:                                 []f64, // average reaction rate per pipe
	flow_dir:                                  []i32, // −1, 0, +1 per link
	sorted:                                    []i32, // nodes, upstream first
	indegree, stack:                           []i32, // sort_nodes's scratch
	source_mass:                               []f64, // mass each source has added
	wbulk, wwall, wtank, wsource, source_qual: f64,
	balance:                                   Mass_Balance,
	segs:                                      ^Segments,
}

// ── segments ──────────────────────────────────────────────────────────

// segments_make: the store for nchains chains, with room for two
// segments each before it grows (a run settles near that).
segments_make :: proc(nchains: int) -> ^Segments {
	s := new(Segments)
	s.first = make([]i32, nchains + 1)
	s.last = make([]i32, nchains + 1)
	reserve(&s.at, 2 * nchains + 1)
	append(&s.at, Segment{})
	return s
}

segments_delete :: proc(s: ^Segments) {
	delete(s.at)
	delete(s.first)
	delete(s.last)
	free(s)
}

// segments_reset forgets every segment (EPANET resets its pool).
segments_reset :: proc(s: ^Segments) {
	resize(&s.at, 1)
	for i in 0 ..< len(s.first) {
		s.first[i] = 0
		s.last[i] = 0
	}
	s.free = 0
}

// add_seg puts a segment of volume v and quality c at the upstream end
// of chain k.
add_seg :: proc(q: ^Quality, k: int, v, c: f64) {
	s := q.segs
	seg: i32
	if s.free != 0 {
		seg = s.free
		s.free = s.at[seg].prev
	} else {
		seg = i32(len(s.at))
		append(&s.at, Segment{})
	}
	s.at[seg] = {v, c, 0}
	if s.first[k] == 0 do s.first[k] = seg
	if s.last[k] != 0 do s.at[s.last[k]].prev = seg
	s.last[k] = seg
	q.balance.seg_count += 1
}

// recycle_seg hands a used-up segment to the free list.
recycle_seg :: #force_inline proc "contextless" (s: ^Segments, seg: i32) {
	s.at[seg].prev = s.free
	s.free = seg
}

// reverse_segs turns chain k around, when its flow does.
reverse_segs :: proc "contextless" (s: ^Segments, k: int) {
	seg := s.first[k]
	s.first[k] = s.last[k]
	s.last[k] = seg
	pseg: i32 = 0
	for seg != 0 {
		nseg := s.at[seg].prev
		s.at[seg].prev = pseg
		pseg = seg
		seg = nseg
	}
}

// init_segs gives each pipe one segment at its downstream node's quality
// and each tank one (two for a two-compartment tank).
init_segs :: proc(net: ^Network, q: ^Quality) {
	s := q.segs
	for k in 1 ..= net.nlinks {
		s.first[k] = 0
		s.last[k] = 0
		if net.link_type[k] == .PIPE {
			add_seg(q, k, link_vol(net, k), q.node_qual[net.n2[k]])
		}
	}
	for j in 1 ..= net.ntanks {
		if net.tank_area[j] == 0 do continue
		c := net.c0[net.tank_node[j]]
		v := net.tank_v0[j]
		k := net.nlinks + j
		s.first[k] = 0
		s.last[k] = 0
		add_seg(q, k, v, c)
		if net.tank_mix[j] == .MIX2 {
			v1 := max(0, v - net.tank_v1frac[j] * net.tank_vmax[j])
			s.at[s.first[k]].v = v1
			v = v - v1
			add_seg(q, k, v, c)
		}
	}
}

link_vol :: #force_inline proc "contextless" (net: ^Network, k: int) -> f64 {
	return 0.785398 * net.len[k] * (net.diam[k] * net.diam[k])
}

// link_flow: a closed link's flow counts as none.
link_flow :: #force_inline proc "contextless" (hyd: ^Hydraulics, k: int) -> f64 {
	return hyd.status[k] <= .CLOSED ? 0 : hyd.flow[k]
}

// ── setup ─────────────────────────────────────────────────────────────

// init_qual starts a quality run: node, tank and segment quality from
// the initial values, the reaction factors, the sums at zero.
init_qual :: proc(net: ^Network, hyd: ^Hydraulics, q: ^Quality) {
	for i in 1 ..= net.nnodes {
		q.node_qual[i] = q.kind == .TRACE ? 0 : net.c0[i]
		if net.has_source[i] do q.source_mass[i] = 0
	}
	if q.kind == .NONE do return
	for i in 1 ..= net.ntanks do q.tank_c[i] = q.node_qual[net.tank_node[i]]
	if q.kind == .TRACE do q.node_qual[q.trace_node] = 100

	q.sc = q.diffus > 0 ? hyd.viscos / q.diffus : 0
	q.bucf = getucf(q.bulk_order)
	q.tucf = getucf(q.tank_order)
	q.reactive = set_react_flag(net, q)

	segments_reset(q.segs)
	init_segs(net, q)
	for i in 1 ..= net.nlinks do q.flow_dir[i] = 0

	q.wbulk, q.wwall, q.wtank, q.wsource = 0, 0, 0, 0
	q.balance = {initial = stored_mass(net, q)}
}

// set_react_flag: is there anything to react?
set_react_flag :: proc "contextless" (net: ^Network, q: ^Quality) -> bool {
	if q.kind == .TRACE do return false
	if q.kind == .AGE do return true
	for i in 1 ..= net.nlinks {
		if net.link_type[i] <= .PIPE && (net.link_kb[i] != 0 || net.link_kw[i] != 0) do return true
	}
	for i in 1 ..= net.ntanks do if net.tank_kb[i] != 0 do return true
	return false
}

// getucf converts a bulk rate of the given order from per litre to per
// cubic foot.
getucf :: proc "contextless" (order0: f64) -> f64 {
	order := order0
	if order < 0 do order = 0
	if order == 1 do return 1
	return 1 / c_pow(L_PER_FT3, order - 1)
}

// new_hydraulics is what a new hydraulic solution needs before transport:
// wall rate coefficients, flow directions (segments reversed where the
// flow did), and, when a direction changed, the nodes re-sorted. Returns
// 0 or the sort's error code.
new_hydraulics :: proc(net: ^Network, hyd: ^Hydraulics, q: ^Quality) -> int {
	if q.reactive && q.kind != .AGE do rate_coeffs(net, hyd, q)
	if flow_dir_changed(net, hyd, q) do return sort_nodes(net, q)
	return 0
}

// rate_coeffs: each pipe's effective wall reaction coefficient at the
// current flow.
rate_coeffs :: proc "contextless" (net: ^Network, hyd: ^Hydraulics, q: ^Quality) {
	sc3 := c_pow(q.sc, 0.333) // the same for every pipe
	for k in 1 ..= net.nlinks {
		kw := net.link_kw[k]
		if kw != 0 do kw = wall_rate_coeff(net, hyd, q, k, sc3)
		q.link_rc[k] = kw
		q.pipe_rate[k] = 0
	}
}

flow_dir_changed :: proc "contextless" (net: ^Network, hyd: ^Hydraulics, q: ^Quality) -> bool {
	result := false
	for k in 1 ..= net.nlinks {
		olddir := q.flow_dir[k]
		flow := link_flow(hyd, k)
		newdir := i32(sgn(flow))
		if abs(flow) < Q_STAGNANT do newdir = 0
		if newdir * olddir < 0 do reverse_segs(q.segs, k)
		if newdir != olddir do result = true
		q.flow_dir[k] = newdir
	}
	return result
}

// sort_nodes orders the nodes upstream to downstream (links with no flow
// ignored, since they make false cycles). Returns 0, or 120 when the
// sort could not finish.
sort_nodes :: proc(net: ^Network, q: ^Quality) -> int {
	indegree, stack := q.indegree, q.stack
	for i in 0 ..= net.nnodes do indegree[i] = 0
	stacksize := 0
	numsorted := 0

	for k in 1 ..= net.nlinks {
		n: i32
		switch q.flow_dir[k] {
		case 1:
			n = net.n2[k]
		case -1:
			n = net.n1[k]
		case:
			continue
		}
		indegree[n] += 1
	}
	for i in 1 ..= net.nnodes {
		if indegree[i] == 0 {
			stacksize += 1
			stack[stacksize] = i32(i)
		}
	}
	for numsorted < net.nnodes {
		if stacksize == 0 {
			// A cycle: pick an unsorted node next to a sorted one.
			j := select_nonstack_node(net, q, numsorted, indegree)
			if j == 0 do break
			indegree[j] = 0
			stacksize += 1
			stack[stacksize] = j
		}
		i := stack[stacksize]
		stacksize -= 1
		numsorted += 1
		q.sorted[numsorted] = i
		for a in net.adj_first[i] ..< net.adj_first[i + 1] {
			k := net.adj_link[a]
			if q.flow_dir[k] == 0 do continue
			n := net.n2[k]
			if q.flow_dir[k] < 0 do n = net.n1[k]
			if n != i && indegree[n] > 0 {
				indegree[n] -= 1
				if indegree[n] == 0 {
					stacksize += 1
					stack[stacksize] = n
				}
			}
		}
	}
	return numsorted < net.nnodes ? int(Error.Quality_Unsolvable) : 0
}

select_nonstack_node :: proc "contextless" (net: ^Network, q: ^Quality, numsorted: int, indegree: []i32) -> i32 {
	for i := numsorted; i > 0; i -= 1 {
		m := q.sorted[i]
		for a in net.adj_first[m] ..< net.adj_first[m + 1] {
			n := net.adj_node[a]
			if indegree[n] > 0 do return n
		}
	}
	for i in 1 ..= net.nnodes do if indegree[i] > 0 do return i32(i)
	return 0
}

// ── transport ─────────────────────────────────────────────────────────

// transport moves the constituent through the network over tstep
// seconds of steady flow: react every segment, then take each node in
// flow order, gathering what its inflow links deliver and sending the
// mixed result into its outflow links.
transport :: proc(net: ^Network, hyd: ^Hydraulics, t: ^Times, q: ^Quality, tstep: i64) #no_bounds_check {
	if q.reactive {
		t0 := prof_begin()
		react_pipes(net, q, t, tstep)
		react_tanks(net, q, t, tstep)
		prof_end(.react, t0)
	}
	t0 := prof_begin()
	defer prof_end(.transport, t0)
	for j in 1 ..= net.nnodes {
		n := int(q.sorted[j])
		volin, massin, volout := 0.0, 0.0, 0.0
		for a in net.adj_first[n] ..< net.adj_first[n + 1] {
			k := int(net.adj_link[a])
			m := net.n2[k]
			if q.flow_dir[k] < 0 do m = net.n1[k]
			if int(m) == n {
				eval_node_inflow(hyd, q, k, tstep, &volin, &massin)
			} else {
				volout += abs(link_flow(hyd, k))
			}
		}
		if net.node_type[n] == .JUNCTION do volout += max(0, hyd.node_demand[n])
		volout *= f64(tstep)
		nodequal := find_node_qual(net, hyd, t, q, n, volin, massin, volout, tstep)
		for a in net.adj_first[n] ..< net.adj_first[n + 1] {
			k := int(net.adj_link[a])
			m := net.n1[k]
			if q.flow_dir[k] < 0 do m = net.n2[k]
			if int(m) == n do eval_node_outflow(hyd, q, k, nodequal, tstep)
		}
		update_mass_balance(net, hyd, q, n, massin, volout, tstep)
	}
}

// eval_node_inflow takes a link's flow volume over the step from its
// leading segments into its downstream node.
eval_node_inflow :: proc "contextless" (hyd: ^Hydraulics, q: ^Quality, k: int, tstep: i64, volin, massin: ^f64) #no_bounds_check {
	s := q.segs
	v := abs(link_flow(hyd, k)) * f64(tstep)
	for v > 0 {
		i := s.first[k]
		if i == 0 do break
		seg := &s.at[i]
		vseg := min(seg.v, v)
		volin^ += vseg
		massin^ += vseg * seg.c
		v -= vseg
		if v >= 0 && vseg >= seg.v {
			s.first[k] = seg.prev
			if s.first[k] == 0 do s.last[k] = 0
			recycle_seg(s, i)
			q.balance.seg_count -= 1
		} else {
			seg.v -= vseg
		}
	}
}

// find_node_qual: the quality leaving node n, from what came in, any
// source, and for a tank its mixing model.
find_node_qual :: proc(net: ^Network, hyd: ^Hydraulics, t: ^Times, q: ^Quality, n: int, volin0, massin, volout: f64, tstep: i64) -> f64 {
	volin := volin0
	switch net.node_type[n] {
	case .JUNCTION:
		volin -= min(0, hyd.node_demand[n]) * f64(tstep)
		if volin > 0 {
			q.node_qual[n] = massin / volin
		} else if q.reactive {
			q.node_qual[n] = no_flow_qual(net, q, n)
		}
	case .TANK:
		q.node_qual[n] = mix_tank(net, hyd, q, n, volin, massin, volout)
	case .RESERVOIR:
	}

	q.source_qual = 0
	if q.kind == .TRACE {
		if n == q.trace_node {
			if net.node_type[n] == .RESERVOIR {
				q.source_qual = 100
			} else {
				q.source_qual = max(100 - q.node_qual[n], 0)
			}
			q.node_qual[n] = 100
		}
		return q.node_qual[n]
	}
	q.source_qual = find_source_qual(net, hyd, t, q, n, volout, tstep)
	if q.source_qual == 0 do return q.node_qual[n]
	switch net.node_type[n] {
	case .JUNCTION:
		q.node_qual[n] += q.source_qual
		return q.node_qual[n]
	case .TANK:
		return q.node_qual[n] + q.source_qual
	case .RESERVOIR:
		q.node_qual[n] = q.source_qual
		return q.source_qual
	}
	return q.node_qual[n]
}

// no_flow_qual: a junction with no inflow takes the average of the
// nearest segments of its links (a reactive constituent only).
no_flow_qual :: proc "contextless" (net: ^Network, q: ^Quality, n: int) -> f64 {
	s := q.segs
	c := 0.0
	kount := 0
	for a in net.adj_first[n] ..< net.adj_first[n + 1] {
		k := net.adj_link[a]
		dir := q.flow_dir[k]
		inflow := false
		if int(net.n2[k]) == n && dir >= 0 {
			inflow = true
		} else if int(net.n1[k]) == n && dir < 0 {
			inflow = true
		}
		if inflow && s.first[k] != 0 {
			c += s.at[s.first[k]].c
			kount += 1
		} else if !inflow && s.last[k] != 0 {
			c += s.at[s.last[k]].c
			kount += 1
		}
	}
	if kount > 0 do c = c / f64(kount)
	return c
}

// eval_node_outflow releases the step's flow volume at quality c into
// the upstream end of link k, merging with the last segment when close.
eval_node_outflow :: proc(hyd: ^Hydraulics, q: ^Quality, k: int, c: f64, tstep: i64) #no_bounds_check {
	s := q.segs
	v := abs(link_flow(hyd, k)) * f64(tstep)
	if v == 0 do return
	if s.last[k] != 0 {
		seg := &s.at[s.last[k]]
		if abs(seg.c - c) < q.ctol {
			seg.c = (seg.c * seg.v + c * v) / (seg.v + v)
			seg.v += v
			return
		}
	}
	add_seg(q, k, v, c)
}

update_mass_balance :: proc "contextless" (net: ^Network, hyd: ^Hydraulics, q: ^Quality, n: int, massin, volout: f64, tstep: i64) {
	masslost, massadded := 0.0, 0.0
	switch net.node_type[n] {
	case .JUNCTION:
		masslost = max(0, hyd.node_demand[n]) * f64(tstep) * q.node_qual[n]
		massadded = q.source_qual * volout
	case .RESERVOIR:
		masslost = massin
		if q.source_qual > 0 {
			massadded = q.source_qual * volout
		} else {
			massadded = q.node_qual[n] * volout
		}
	case .TANK:
		massadded = q.source_qual * volout
	}
	q.balance.outflow += masslost
	q.balance.inflow += massadded
}

// ── sources ───────────────────────────────────────────────────────────

// find_source_qual: the concentration a node's external source adds to
// its outflow over the step.
find_source_qual :: proc "contextless" (net: ^Network, hyd: ^Hydraulics, t: ^Times, q: ^Quality, n: int, volout: f64, tstep: i64) -> f64 {
	if q.kind != .CHEM do return 0
	if !net.has_source[n] do return 0
	if net.source_c0[n] == 0 do return 0
	if volout / f64(tstep) <= Q_STAGNANT do return 0

	c := source_qual(net, t, q, n)
	switch net.source_type[n] {
	case .CONCEN:
		if net.node_type[n] == .JUNCTION {
			// Needs a negative demand (an inflow) at the node.
			if hyd.node_demand[n] < 0 {
				c = -c * hyd.node_demand[n] * f64(tstep) / volout
			} else {
				c = 0
			}
		}
	case .MASS:
		c = c * f64(tstep) / volout
	case .SETPOINT:
		c = max(c - q.node_qual[n], 0)
	case .FLOWPACED:
	}
	massadded := c * volout
	q.source_mass[n] += massadded
	if t.htime >= t.rstart do q.wsource += massadded
	return c
}

// source_qual: the source's strength now, in the engine's units.
source_qual :: proc "contextless" (net: ^Network, t: ^Times, q: ^Quality, n: int) -> f64 {
	c := net.source_c0[n]
	if net.source_type[n] == .MASS {
		c /= 60 // per minute to per second
	} else {
		c /= net.ucf_quality
	}
	i := int(net.source_pat[n])
	if i == 0 do return c
	return c * pattern_at(net, i, (t.qtime + t.pstart) / t.pstep)
}

// ── reactions ─────────────────────────────────────────────────────────

react_pipes :: proc "contextless" (net: ^Network, q: ^Quality, t: ^Times, dt: i64) #no_bounds_check {
	s := q.segs
	for k in 1 ..= net.nlinks {
		if net.link_type[k] != .PIPE do continue
		rsum, vsum := 0.0, 0.0
		for i := s.first[k]; i != 0; i = s.at[i].prev {
			seg := &s.at[i]
			cseg := seg.c
			seg.c = pipe_react(net, q, t, k, seg.c, seg.v, dt)
			q.balance.reacted += (cseg - seg.c) * seg.v
			if q.kind == .CHEM {
				rsum += abs(seg.c - cseg) * seg.v
				vsum += seg.v
			}
		}
		if vsum > 0 {
			q.pipe_rate[k] = rsum / vsum / f64(dt) * SEC_PER_DAY
		} else {
			q.pipe_rate[k] = 0
		}
	}
}

react_tanks :: proc "contextless" (net: ^Network, q: ^Quality, t: ^Times, dt: i64) #no_bounds_check {
	s := q.segs
	for i in 1 ..= net.ntanks {
		if net.tank_area[i] == 0 do continue
		k := net.nlinks + i
		for j := s.first[k]; j != 0; j = s.at[j].prev {
			seg := &s.at[j]
			c := seg.c
			seg.c = tank_react(q, t, seg.c, seg.v, net.tank_kb[i], dt)
			q.balance.reacted += (c - seg.c) * seg.v
		}
	}
}

// wall_rate_coeff: a pipe's wall reaction rate coefficient (first order)
// or mass transfer coefficient (zero order) at the current flow; sc3 is
// the Schmidt number to the 0.333. (EPANET's piperate; q.pipe_rate is
// something else, the average reaction rate reported per pipe.)
wall_rate_coeff :: proc "contextless" (net: ^Network, hyd: ^Hydraulics, q: ^Quality, k: int, sc3: f64) -> f64 {
	d := net.diam[k]
	if q.sc == 0 {
		if q.wall_order == 0 do return BIG
		return net.link_kw[k] * (4 / d) / net.ucf_elev
	}
	flow := link_flow(hyd, k)
	a := PI * d * d / 4
	u := abs(flow) / a
	re := u * d / hyd.viscos
	sh: f64
	if re < 1 {
		sh = 2
	} else if re >= 2300 {
		sh = 0.0149 * c_pow(re, 0.88) * sc3
	} else {
		y := d / net.len[k] * re * q.sc
		sh = 3.65 + 0.0668 * y / (1 + 0.04 * c_pow(y, 0.667))
	}
	kf := sh * q.diffus / d
	if q.wall_order == 0 do return kf
	kw := net.link_kw[k] / net.ucf_elev
	kw = (4 / d) * kw * kf / (kf + abs(kw))
	return kw
}

PI : f64 : 3.14159265358979323846

pipe_react :: proc "contextless" (net: ^Network, q: ^Quality, t: ^Times, k: int, c, v: f64, dt: i64) -> f64 {
	if q.kind == .AGE {
		dc := f64(dt) / 3600
		return max(0, c + dc)
	}
	rbulk := bulk_rate(q, c, net.link_kb[k], q.bulk_order) * q.bucf
	rwall := wall_rate(net, q, c, net.diam[k], net.link_kw[k], q.link_rc[k])
	dcbulk := rbulk * f64(dt)
	dcwall := rwall * f64(dt)
	if t.htime >= t.rstart {
		q.wbulk += abs(dcbulk) * v
		q.wwall += abs(dcwall) * v
	}
	dc := dcbulk + dcwall
	return max(0, c + dc)
}

tank_react :: proc "contextless" (q: ^Quality, t: ^Times, c, v, kb: f64, dt: i64) -> f64 {
	dc: f64
	if q.kind == .AGE {
		dc = f64(dt) / 3600
	} else {
		rbulk := bulk_rate(q, c, kb, q.tank_order) * q.tucf
		dc = rbulk * f64(dt)
		if t.htime >= t.rstart do q.wtank += abs(dc) * v
	}
	return max(0, c + dc)
}

// bulk_rate: kb times the reaction potential at concentration c for the
// given order (0, Michaelis-Menten below 0, or n-th order).
bulk_rate :: proc "contextless" (q: ^Quality, c0, kb, order: f64) -> f64 {
	c := c0
	if order == 0 {
		c = 1
	} else if order < 0 {
		c1 := q.climit + sgn(kb) * c
		if abs(c1) < TINY do c1 = sgn(c1) * TINY
		c = c / c1
	} else {
		c1: f64
		if q.climit == 0 {
			c1 = c
		} else {
			c1 = max(0, sgn(kb) * (q.climit - c))
		}
		if order == 1 {
			c = c1
		} else if order == 2 {
			c = c1 * c
		} else {
			c = c1 * c_pow(max(0, c), order - 1)
		}
	}
	if c < 0 do c = 0
	return kb * c
}

wall_rate :: proc "contextless" (net: ^Network, q: ^Quality, c, d, kw0, kf0: f64) -> f64 {
	kw, kf := kw0, kf0
	if kw == 0 || d == 0 do return 0
	if q.wall_order == 0 {
		kf = sgn(kw) * c * kf
		kw = kw * (net.ucf_elev * net.ucf_elev)
		if abs(kf) < abs(kw) do kw = kf
		return kw * 4 / d
	}
	return c * kf
}

// ── tanks ─────────────────────────────────────────────────────────────

// mix_tank: the tank's quality after this step's flows, by its mixing
// model. tank_mix1..4 keep EPANET's names: complete mix, two
// compartments, first in first out, last in first out.
mix_tank :: proc(net: ^Network, hyd: ^Hydraulics, q: ^Quality, n: int, volin, massin, volout: f64) -> f64 {
	i := n - net.njuncs
	vnet := volin - volout
	switch net.tank_mix[i] {
	case .MIX1:
		tank_mix1(net, q, i, volin, massin, vnet)
	case .MIX2:
		tank_mix2(net, q, i, volin, massin, vnet)
	case .FIFO:
		tank_mix3(net, hyd, q, i, volin, massin, vnet)
	case .LIFO:
		tank_mix4(net, hyd, q, i, volin, massin, vnet)
	}
	return q.tank_c[i]
}

// A completely mixed tank: one segment.
tank_mix1 :: proc "contextless" (net: ^Network, q: ^Quality, i: int, vin, win, vnet: f64) {
	s := q.segs
	k := net.nlinks + i
	if s.first[k] == 0 do return
	seg := &s.at[s.first[k]]
	vnew := seg.v + vin
	if vnew > 0 do seg.c = (seg.c * seg.v + win) / vnew
	seg.v += vnet
	seg.v = max(0, seg.v)
	q.tank_c[i] = seg.c
	if seg.v > net.tank_vmax[i] {
		q.balance.outflow += (seg.v - net.tank_vmax[i]) * q.tank_c[i]
		seg.v = net.tank_vmax[i]
	}
}

// Two compartments: a mixing zone at the inlet (the last segment) and a
// stagnant zone behind it (the first).
tank_mix2 :: proc "contextless" (net: ^Network, q: ^Quality, i: int, vin, win, vnet: f64) {
	s := q.segs
	k := net.nlinks + i
	if s.last[k] == 0 || s.first[k] == 0 do return
	mix := &s.at[s.last[k]]
	stag := &s.at[s.first[k]]
	vmz := net.tank_v1frac[i] * net.tank_vmax[i]
	vt := 0.0
	if vnet > 0 {
		vt = max(0, mix.v + vnet - vmz)
		if vin > 0 do mix.c = (mix.c * mix.v + win) / (mix.v + vin)
		if vt > 0 do stag.c = (stag.c * stag.v + mix.c * vt) / (stag.v + vt)
	} else if vnet < 0 {
		if stag.v > 0 do vt = min(stag.v, -vnet)
		if vin + vt > 0 {
			mix.c = (mix.c * mix.v + win + stag.c * vt) / (mix.v + vin + vt)
		}
	}
	if vt > 0 {
		if vnet > 0 {
			mix.v = vmz
			stag.v += vt
			vsz := net.tank_vmax[i] - vmz
			if stag.v > vsz {
				q.balance.outflow += (stag.v - vsz) * stag.c
				stag.v = vsz
			}
		} else {
			stag.v = max(0, stag.v - vt)
			mix.v = vmz + vt + vnet
		}
	} else {
		mix.v += vnet
		mix.v = min(mix.v, vmz)
		mix.v = max(0, mix.v)
		if vmz - mix.v > 0 do stag.v = 0
	}
	q.tank_c[i] = mix.c
}

// First in, first out: a plug flow tank.
tank_mix3 :: proc(net: ^Network, hyd: ^Hydraulics, q: ^Quality, i: int, vin, win, vnet: f64) {
	s := q.segs
	k := net.nlinks + i
	if s.last[k] == 0 || s.first[k] == 0 do return
	if vin > 0 {
		cin := win / vin
		seg := s.last[k]
		if abs(s.at[seg].c - cin) < q.ctol {
			s.at[seg].v += vin
		} else {
			add_seg(q, k, vin, cin)
		}
	}
	vout := vin - vnet
	if hyd.tank_volume[i] >= net.tank_vmax[i] && vnet > 0 do vout = vin
	vsum, wsum := tank_drain(s, k, vout)
	if vsum > 0 {
		q.tank_c[i] = wsum / vsum
	} else if s.first[k] == 0 {
		q.tank_c[i] = 0
	} else {
		q.tank_c[i] = s.at[s.first[k]].c
	}
	if hyd.tank_volume[i] >= net.tank_vmax[i] && vnet > 0 do q.balance.outflow += vnet * q.tank_c[i]
}

// Last in, first out: what came in last leaves first.
tank_mix4 :: proc(net: ^Network, hyd: ^Hydraulics, q: ^Quality, i: int, vin, win, vnet0: f64) {
	s := q.segs
	k := net.nlinks + i
	vnet := vnet0
	if s.last[k] == 0 || s.first[k] == 0 do return
	cin := vin > 0 ? win / vin : 0
	q.tank_c[i] = s.at[s.last[k]].c
	seg := s.last[k]
	if vnet > 0 {
		if abs(s.at[seg].c - cin) < q.ctol {
			s.at[seg].v += vnet
		} else {
			add_seg(q, k, vnet, cin)
		}
		q.tank_c[i] = s.at[s.last[k]].c
		if hyd.tank_volume[i] >= net.tank_vmax[i] {
			_, wsum := tank_drain(s, k, vnet)
			q.balance.outflow += wsum
		}
	} else if vnet < 0 {
		reverse_segs(s, k)
		vsum, wsum := tank_drain(s, k, -vnet)
		reverse_segs(s, k)
		q.tank_c[i] = (wsum + win) / (vsum + vin)
	}
}

// tank_drain takes volume vol off the front of tank chain k and returns
// what came out, volume and mass. The chain's last segment is never
// dropped, only emptied (it is asked for the whole remainder), so a tank
// always keeps one.
tank_drain :: proc "contextless" (s: ^Segments, k: int, vol0: f64) -> (vsum, wsum: f64) #no_bounds_check {
	vol := vol0
	for vol > 0 {
		i := s.first[k]
		if i == 0 do break
		seg := &s.at[i]
		vseg := min(seg.v, vol)
		if i == s.last[k] do vseg = vol
		vsum += vseg
		wsum += seg.c * vseg
		vol -= vseg
		if vol >= 0 && vseg >= seg.v {
			if seg.prev != 0 {
				s.first[k] = seg.prev
				recycle_seg(s, i)
			}
		} else {
			seg.v -= vseg
		}
	}
	return
}

// ── readings ──────────────────────────────────────────────────────────

// avg_qual: the volume-weighted quality in link k, or the mean of its
// ends when it holds no volume.
avg_qual :: proc "contextless" (net: ^Network, q: ^Quality, k: int) -> f64 #no_bounds_check {
	if q.kind == .NONE do return 0
	s := q.segs
	vsum, msum := 0.0, 0.0
	for i := s.first[k]; i != 0; i = s.at[i].prev {
		seg := &s.at[i]
		vsum += seg.v
		msum += seg.c * seg.v
	}
	if vsum > 0 do return msum / vsum
	return (q.node_qual[net.n1[k]] + q.node_qual[net.n2[k]]) / 2
}

// eval_mass_balance closes the account: what is stored now against what
// came in, went out and reacted.
eval_mass_balance :: proc "contextless" (net: ^Network, q: ^Quality) {
	if q.kind == .NONE {
		q.balance.ratio = 1
		return
	}
	q.balance.final = stored_mass(net, q)
	massin := q.balance.initial + q.balance.inflow
	massout := q.balance.outflow + q.balance.final
	massreacted := q.balance.reacted
	if massreacted > 0 {
		massout += massreacted
	} else {
		massin -= massreacted
	}
	q.balance.ratio = massin == 0 ? 1 : massout / massin
}

stored_mass :: proc "contextless" (net: ^Network, q: ^Quality) -> f64 {
	s := q.segs
	total := 0.0
	for k in 1 ..= net.nlinks do add_chain_mass(s, k, &total)
	for i in 1 ..= net.ntanks {
		if net.tank_area[i] == 0 do continue
		add_chain_mass(s, net.nlinks + i, &total)
	}
	return total
}

// add_chain_mass adds chain k's mass to total, segment by segment (the
// order of the additions is EPANET's, so the last bit is).
add_chain_mass :: proc "contextless" (s: ^Segments, k: int, total: ^f64) #no_bounds_check {
	for i := s.first[k]; i != 0; i = s.at[i].prev {
		seg := &s.at[i]
		total^ += seg.c * seg.v
	}
}
