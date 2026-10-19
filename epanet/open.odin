package epanet

// open.odin — opening and closing the solvers on a project the package
// owns (EPANET's openhyd/closehyd, openqual/closequal, the leakage setup
// and the adjacency lists). The quality run's orchestration over the
// hydraulics file (initqual, runqual, nextqual, stepqual) is in
// files.odin. The per-run arrays come from the heap and go back to it
// at close, so a project can open and close its solvers freely.

// build_adjlists lists each node's links as EPANET does: a node's run
// holds the links in reverse order of their index (EPANET pushes each
// on the front of a list).
build_adjlists :: proc(net: ^Network) {
	nn, nl := net.nnodes, net.nlinks
	net.adj_first = make([]i32, nn + 2)
	net.adj_link = make([]i32, 2 * nl + 1)
	net.adj_node = make([]i32, 2 * nl + 1)
	degree := make([]i32, nn + 2, context.temp_allocator)
	defer delete(degree, context.temp_allocator)
	for k in 1 ..= nl {
		degree[net.n1[k]] += 1
		degree[net.n2[k]] += 1
	}
	at: i32 = 1
	for i in 0 ..= nn {
		net.adj_first[i] = at
		at += degree[i]
	}
	net.adj_first[nn + 1] = at
	fill := make([]i32, nn + 1, context.temp_allocator)
	defer delete(fill, context.temp_allocator)
	copy(fill, net.adj_first[:nn + 1])
	for k := nl; k >= 1; k -= 1 {
		i, j := net.n1[k], net.n2[k]
		net.adj_link[fill[i]] = i32(k)
		net.adj_node[fill[i]] = j
		fill[i] += 1
		net.adj_link[fill[j]] = i32(k)
		net.adj_node[fill[j]] = i
		fill[j] += 1
	}
}

free_adjlists :: proc(net: ^Network) {
	delete(net.adj_first)
	delete(net.adj_link)
	delete(net.adj_node)
	net.adj_first, net.adj_link, net.adj_node = nil, nil, nil
}

// unlinked names up to ten junctions no link reaches; Unconnected_Nodes
// (233) when any.
unlinked :: proc(p: ^Project) -> int {
	net := &p.net
	count := 0
	for i in 1 ..= net.njuncs {
		if net.adj_first[i] == net.adj_first[i + 1] {
			count += 1
			l: Line
			puts(&l, "Error 234: ")
			puts(&l, error_message(234))
			puts(&l, " ")
			puts(&l, p.node_id[i])
			writeline(p, line_str(&l))
		}
		if count >= 10 do break
	}
	return count > 0 ? int(Error.Unconnected_Nodes) : 0
}

// open_hyd readies the hydraulic solver: the checks, the matrix shape,
// the per-run arrays, the starting flows.
open_hyd :: proc(p: ^Project) -> int {
	net, hyd := &p.net, &p.hyd
	if errcode := validate_project(p); errcode > 0 do return errcode
	nn, nl, nt := net.nnodes, net.nlinks, net.ntanks
	sp := create_sparse(Graph{nnodes = nn, njuncs = net.njuncs, nlinks = nl, n1 = net.n1, n2 = net.n2})
	column_order(&sp, net.njuncs, nl)
	p.m = {
		order = sp.order, row = sp.row, ndx = sp.ndx,
		xlnz = sp.xlnz, nzsub = sp.nzsub, lnz = sp.lnz,
		aii = make([]f64, nn + 1), aij = make([]f64, sp.ncoeffs + 1),
		f = make([]f64, nn + 1), temp = make([]f64, nn + 1),
		link = make([]i32, nn + 1), first = make([]i32, nn + 1),
	}
	hyd.p = make([]f64, nl + 1)
	hyd.y = make([]f64, nl + 1)
	hyd.xflow = make([]f64, nn + 1)
	hyd.old_status = make([]Status, nl + nt + 1)
	hyd.pending = make([]Pending, len(net.action_link))
	build_adjlists(net)
	if errcode := unlinked(p); errcode != 0 {
		close_hyd(p)
		return errcode
	}
	for i in 1 ..= nl do init_link_flow(net, hyd, i, net.init_status[i], net.kc[i])
	return 0
}

// column_order renumbers the coefficient slots so that the stored
// nonzeros sit in aij in the order linsolve walks them: lnz becomes the
// identity and the solver's inner loops read aij sequentially instead of
// gathering. A link's slot follows through ndx (parallel links share
// one); a link whose coefficient is not in the matrix, one end being a
// tank, gets a slot after the matrix's, written by matrix_coeffs and
// read by nobody. (EPANET numbers the slots by link, which the bridge's
// shadow compares, so create_sparse keeps that numbering and this is
// done after.)
column_order :: proc(sp: ^Sparse, njuncs, nlinks: int) {
	nnz := int(sp.xlnz[njuncs + 1]) - 1
	slot := make([]i32, sp.ncoeffs + 1, context.temp_allocator) // old slot -> new
	defer delete(slot, context.temp_allocator)
	for s in 1 ..= nnz {
		slot[sp.lnz[s]] = i32(s)
		sp.lnz[s] = i32(s)
	}
	next := i32(nnz)
	for k in 1 ..= nlinks {
		if slot[sp.ndx[k]] == 0 {
			next += 1
			slot[sp.ndx[k]] = next
		}
		sp.ndx[k] = slot[sp.ndx[k]]
	}
}

close_hyd :: proc(p: ^Project) {
	m, hyd := &p.m, &p.hyd
	delete(m.order); delete(m.row); delete(m.ndx)
	delete(m.xlnz); delete(m.nzsub); delete(m.lnz)
	delete(m.aii); delete(m.aij); delete(m.f); delete(m.temp); delete(m.link); delete(m.first)
	m^ = {}
	delete(hyd.p); delete(hyd.y); delete(hyd.xflow); delete(hyd.old_status); delete(hyd.pending)
	hyd.p, hyd.y, hyd.xflow, hyd.old_status, hyd.pending = nil, nil, nil, nil, nil
	free_adjlists(&p.net)
}

// open_leakage turns each leaking pipe into leakage at its junctions.
open_leakage :: proc(p: ^Project) {
	net, hyd := &p.net, &p.hyd
	hyd.has_leakage = false
	for i in 1 ..= net.njuncs {
		net.leak_cfa[i], net.leak_cva[i] = 0, 0
		hyd.leak_qfa[i], hyd.leak_qva[i] = 0, 0
	}
	for k in 1 ..= net.nlinks {
		if net.link_type[k] > .PIPE do continue
		if net.leak_area[k] > 0 || net.leak_expan[k] > 0 do hyd.has_leakage = true
	}
	if !hyd.has_leakage do return
	c_orif := 4.8149766e-6
	m2 := M_PER_FT * M_PER_FT
	for k in 1 ..= net.nlinks {
		if net.link_type[k] > .PIPE do continue
		n1, n2 := net.n1[k], net.n2[k]
		j1 := net.node_type[n1] == .JUNCTION
		j2 := net.node_type[n2] == .JUNCTION
		if !j1 && !j2 do continue
		if net.leak_area[k] == 0 && net.leak_expan[k] == 0 do continue
		c_area := c_orif * net.leak_area[k] / m2
		c_expan := c_orif * net.leak_expan[k] / M_PER_FT
		len := net.len[k] / 100.
		if j1 && j2 do len *= 0.5
		c_area *= len
		c_expan *= len
		if j1 {
			net.leak_cfa[n1] += c_area
			net.leak_cva[n1] += c_expan
		}
		if j2 {
			net.leak_cfa[n2] += c_area
			net.leak_cva[n2] += c_expan
		}
	}
	for i in 1 ..= net.njuncs {
		c_area := net.leak_cfa[i]
		net.leak_cfa[i] = c_area > 0 ? 1.0 / (c_area * c_area) : 0
		c_expan := net.leak_cva[i]
		net.leak_cva[i] = c_expan > 0 ? 1.0 / c_pow(c_expan, 2. / 3.) : 0
		if net.leak_cfa[i] > 0 do hyd.leak_qfa[i] = 0.001
		if net.leak_cva[i] > 0 do hyd.leak_qva[i] = 0.001
	}
}

// find_link_leakage: a pipe's leak at the current heads, for reporting.
find_link_leakage :: proc "contextless" (p: ^Project, i: int) -> f64 {
	net, hyd := &p.net, &p.hyd
	if net.link_type[i] > .PIPE do return 0
	if net.leak_area[i] == 0 && net.leak_expan[i] == 0 do return 0
	n1, n2 := int(net.n1[i]), int(net.n2[i])
	if n1 > net.njuncs && n2 > net.njuncs do return 0
	h1 := max(hyd.head[n1] - net.el[n1], 0)
	h2 := max(hyd.head[n2] - net.el[n2], 0)
	m_per_ft := M_PER_FT
	a := net.leak_area[i] / (m_per_ft * m_per_ft)
	m := net.leak_expan[i] / M_PER_FT
	c: f64 = 4.8149766
	c *= net.len[i] / 100. / 2.0
	c *= 1.0e-6
	q1, q2 := 0.0, 0.0
	if n1 <= net.njuncs do q1 = c * (a + m * h1) * c_sqrt(h1)
	if n2 <= net.njuncs do q2 = c * (a + m * h2) * c_sqrt(h2)
	if n2 > net.njuncs do q1 *= 2.0
	if n1 > net.njuncs do q2 *= 2.0
	return q1 + q2
}

// ── the quality run ───────────────────────────────────────────────────

// open_qual readies the quality solver; the adjacency lists are built
// here when hydraulics did not.
open_qual :: proc(p: ^Project) -> int {
	net, q := &p.net, &p.q
	if q.kind != .NONE && net.adj_first == nil {
		if net.nnodes < 2 do return int(Error.Too_Few_Nodes)
		if net.ntanks == 0 do return int(Error.No_Tanks)
		build_adjlists(net)
		if errcode := unlinked(p); errcode != 0 do return errcode
	}
	alloc_qual(net, q)
	return 0
}

// alloc_qual gives the quality solver its per-run arrays over net and
// its segment store (the Sim gives every chemical its own).
alloc_qual :: proc(net: ^Network, q: ^Quality) {
	nl, nn, nt := net.nlinks, net.nnodes, net.ntanks
	q.flow_dir = make([]i32, nl + 1)
	q.up = make([]i32, nl + 1)
	q.down = make([]i32, nl + 1)
	q.pipe_rate = make([]f64, nl + 1)
	q.link_rc = make([]f64, nl + 1)
	q.sorted = make([]i32, nn + 1)
	q.indegree = make([]i32, nn + 1)
	q.stack = make([]i32, nn + 1)
	q.source_mass = make([]f64, nn + 1)
	q.segs = segments_make(nl + nt)
}

close_qual :: proc(p: ^Project) {
	q := &p.q
	delete(q.flow_dir); delete(q.pipe_rate); delete(q.link_rc); delete(q.sorted); delete(q.source_mass)
	delete(q.indegree); delete(q.stack); delete(q.up); delete(q.down)
	q.flow_dir, q.pipe_rate, q.link_rc, q.sorted, q.source_mass = nil, nil, nil, nil, nil
	q.indegree, q.stack, q.up, q.down = nil, nil, nil, nil
	if q.segs != nil do segments_delete(q.segs)
	q.segs = nil
}
