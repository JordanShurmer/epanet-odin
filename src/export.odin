package epanet

// export.odin — the C face of the package. Each proc here is one EPANET
// symbol, with EPANET's own argument shapes, that the bridge
// (../bridge/bridge.c) hands straight through. Nothing else in the package
// knows about C.

import "base:runtime"
import "core:c"
import "core:c/libc"

@(export, link_name = "odin_linsolve")
odin_linsolve :: proc "c" (
	n, ncoeffs: c.int,
	aii, aij, f, temp: [^]f64,
	xlnz, nzsub, lnz, link, first: [^]c.int,
) -> c.int {
	m := Smatrix {
		aii   = aii[:n + 1],
		aij   = aij[:ncoeffs + 1],
		f     = f[:n + 1],
		temp  = temp[:n + 1],
		xlnz  = xlnz[:n + 2],
		nzsub = nzsub[:ncoeffs + 2],
		lnz   = lnz[:ncoeffs + 2],
		link  = link[:n + 1],
		first = first[:n + 1],
	}
	return c.int(linsolve(&m, int(n)))
}

// odin_createsparse builds the matrix structure for a network given as
// link end-node pairs. order, row and ndx are the caller's (nnodes+1,
// nnodes+1, nlinks+1); xlnz, nzsub and lnz come back calloc'd, so C frees
// them with free().
@(export, link_name = "odin_createsparse")
odin_createsparse :: proc "c" (
	nnodes, njuncs, nlinks: c.int,
	n1, n2: [^]c.int,
	order, row, ndx: [^]c.int,
	ncoeffs: ^c.int,
	xlnz, nzsub, lnz: ^[^]c.int,
) {
	context = runtime.default_context()
	g := Graph {
		nnodes = int(nnodes),
		njuncs = int(njuncs),
		nlinks = int(nlinks),
		n1     = n1[:nlinks + 1],
		n2     = n2[:nlinks + 1],
	}
	sp := create_sparse(g)
	defer {
		delete(sp.order)
		delete(sp.row)
		delete(sp.ndx)
		delete(sp.xlnz)
		delete(sp.nzsub)
		delete(sp.lnz)
	}
	copy(order[:nnodes + 1], sp.order)
	copy(row[:nnodes + 1], sp.row)
	copy(ndx[:nlinks + 1], sp.ndx)
	ncoeffs^ = c.int(sp.ncoeffs)
	xlnz^ = c_ints(sp.xlnz)
	nzsub^ = c_ints(sp.nzsub)
	lnz^ = c_ints(sp.lnz)
}

// c_ints copies a slice into a calloc'd array for C to own.
c_ints :: proc(s: []i32) -> [^]c.int {
	p := ([^]c.int)(libc.calloc(len(s), size_of(c.int)))
	copy(p[:len(s)], s)
	return p
}

// ── hydraulics ──────────────────────────────────────────────────────
// The bridge fills these three structs (bridge.c mirrors them field for
// field) and the exports view them as the package's own types: every
// array is EPANET's, 1-based, used in place.

Network_C :: struct {
	nnodes, njuncs, nlinks:                      c.int,
	ntanks, npumps, nvalves, ncontrols, ncurves: c.int,
	el, ke:                                      [^]f64,
	link_type, n1, n2:                           [^]c.int,
	diam, km, kc, r:                             [^]f64,
	link_pump, link_valve:                       [^]c.int,
	tank_area, tank_hmin, tank_hmax:             [^]f64,
	tank_overflow:                               [^]b32,
	pump_type, pump_hcurve:                      [^]c.int,
	pump_h0, pump_r, pump_n, pump_hmax:          [^]f64,
	valve_link, valve_curve:                     [^]c.int,
	curve_npts:                                  [^]c.int,
	curve_x, curve_y:                            [^][^]f64,
	control_link, control_node, control_type:    [^]c.int,
	control_grade, control_setting:              [^]f64,
	control_status:                              [^]c.int,
	ucf_flow, ucf_head:                          f64,
}

Hydraulics_C :: struct {
	formflag, demand_model, emit_backflow, has_leakage:         c.int,
	max_iter, extra_iter, check_freq, max_check, status_report: c.int,
	hexp, qexp, pexp, pmin, preq, rqtol, viscos:                f64,
	htol, qtol, hacc, head_error_limit, flow_change_limit:      f64,
	damp_limit:                                                 f64,
	head, node_demand, demand_flow, full_demand:                [^]f64,
	emitter_flow, leak_flow, xflow:                             [^]f64,
	flow, setting:                                              [^]f64,
	status:                                                     [^]c.int,
	p, y:                                                       [^]f64,
}

Solution_C :: struct {
	errcode, iterations, deficient_nodes:              c.int,
	relative_error, max_head_error, max_flow_change:   f64,
	demand_reduction, relax:                           f64,
}

Matrix_C :: struct {
	ncoeffs:                       c.int,
	aii, aij, f, temp:             [^]f64,
	xlnz, nzsub, lnz, link, first: [^]c.int,
	order, row, ndx:               [^]c.int,
}

// view_network needs an allocator for the curve table only.
view_network :: proc(n: ^Network_C) -> Network {
	nn, nl, nt := int(n.nnodes), int(n.nlinks), int(n.ntanks)
	np, nv, nk, nc := int(n.npumps), int(n.nvalves), int(n.ncontrols), int(n.ncurves)
	curves := make([]Curve, nc + 1, context.temp_allocator)
	for i in 1 ..= nc {
		curves[i] = {n.curve_x[i][:n.curve_npts[i]], n.curve_y[i][:n.curve_npts[i]]}
	}
	return {
		nnodes = nn,
		njuncs = int(n.njuncs),
		nlinks = nl,
		ntanks = nt,
		npumps = np,
		nvalves = nv,
		ncontrols = nk,
		el = n.el[:nn + 1],
		ke = n.ke[:nn + 1],
		link_type = ([^]Link_Type)(n.link_type)[:nl + 1],
		n1 = n.n1[:nl + 1],
		n2 = n.n2[:nl + 1],
		diam = n.diam[:nl + 1],
		km = n.km[:nl + 1],
		kc = n.kc[:nl + 1],
		r = n.r[:nl + 1],
		link_pump = n.link_pump[:nl + 1],
		link_valve = n.link_valve[:nl + 1],
		tank_area = n.tank_area[:nt + 1],
		tank_hmin = n.tank_hmin[:nt + 1],
		tank_hmax = n.tank_hmax[:nt + 1],
		tank_overflow = n.tank_overflow[:nt + 1],
		pump_type = ([^]Pump_Type)(n.pump_type)[:np + 1],
		pump_hcurve = n.pump_hcurve[:np + 1],
		pump_h0 = n.pump_h0[:np + 1],
		pump_r = n.pump_r[:np + 1],
		pump_n = n.pump_n[:np + 1],
		pump_hmax = n.pump_hmax[:np + 1],
		valve_link = n.valve_link[:nv + 1],
		valve_curve = n.valve_curve[:nv + 1],
		curves = curves,
		control_link = n.control_link[:nk + 1],
		control_node = n.control_node[:nk + 1],
		control_type = ([^]Control_Type)(n.control_type)[:nk + 1],
		control_grade = n.control_grade[:nk + 1],
		control_setting = n.control_setting[:nk + 1],
		control_status = ([^]Status)(n.control_status)[:nk + 1],
		ucf_flow = n.ucf_flow,
		ucf_head = n.ucf_head,
	}
}

view_hydraulics :: proc "contextless" (h: ^Hydraulics_C, nnodes, nlinks: int) -> Hydraulics {
	return {
		formflag = Headloss_Formula(h.formflag),
		demand_model = Demand_Model(h.demand_model),
		emit_backflow = h.emit_backflow != 0,
		has_leakage = h.has_leakage != 0,
		hexp = h.hexp,
		qexp = h.qexp,
		pexp = h.pexp,
		pmin = h.pmin,
		preq = h.preq,
		rqtol = h.rqtol,
		viscos = h.viscos,
		htol = h.htol,
		qtol = h.qtol,
		hacc = h.hacc,
		head_error_limit = h.head_error_limit,
		flow_change_limit = h.flow_change_limit,
		damp_limit = h.damp_limit,
		max_iter = int(h.max_iter),
		extra_iter = int(h.extra_iter),
		check_freq = int(h.check_freq),
		max_check = int(h.max_check),
		status_report = h.status_report != 0,
		head = h.head[:nnodes + 1],
		node_demand = h.node_demand[:nnodes + 1],
		demand_flow = h.demand_flow[:nnodes + 1],
		full_demand = h.full_demand[:nnodes + 1],
		emitter_flow = h.emitter_flow[:nnodes + 1],
		leak_flow = h.leak_flow[:nnodes + 1],
		xflow = h.xflow[:nnodes + 1],
		flow = h.flow[:nlinks + 1],
		setting = h.setting[:nlinks + 1],
		status = ([^]Status)(h.status)[:nlinks + 1],
		p = h.p[:nlinks + 1],
		y = h.y[:nlinks + 1],
	}
}

view_matrix :: proc "contextless" (m: ^Matrix_C, nnodes, njuncs, nlinks: int) -> Smatrix {
	nc := int(m.ncoeffs)
	return {
		aii = m.aii[:nnodes + 1],
		aij = m.aij[:nc + 1],
		f = m.f[:nnodes + 1],
		temp = m.temp[:nnodes + 1],
		xlnz = m.xlnz[:njuncs + 2],
		nzsub = m.nzsub[:nc + 2],
		lnz = m.lnz[:nc + 2],
		link = m.link[:nnodes + 1],
		first = m.first[:nnodes + 1],
		order = m.order[:nnodes + 1],
		row = m.row[:nnodes + 1],
		ndx = m.ndx[:nlinks + 1],
	}
}

@(export, link_name = "odin_headlosscoeffs")
odin_headlosscoeffs :: proc "c" (n: ^Network_C, h: ^Hydraulics_C) {
	context = runtime.default_context()
	defer free_all(context.temp_allocator)
	net := view_network(n)
	hyd := view_hydraulics(h, net.nnodes, net.nlinks)
	headloss_coeffs(&net, &hyd)
}

@(export, link_name = "odin_matrixcoeffs")
odin_matrixcoeffs :: proc "c" (n: ^Network_C, h: ^Hydraulics_C, mc: ^Matrix_C, hooks: ^Hooks) {
	context = runtime.default_context()
	defer free_all(context.temp_allocator)
	net := view_network(n)
	hyd := view_hydraulics(h, net.nnodes, net.nlinks)
	m := view_matrix(mc, net.nnodes, net.njuncs, net.nlinks)
	matrix_coeffs(&net, &hyd, &m, hooks)
}

@(export, link_name = "odin_hydsolve")
odin_hydsolve :: proc "c" (n: ^Network_C, h: ^Hydraulics_C, mc: ^Matrix_C, hooks: ^Hooks, out: ^Solution_C) {
	context = runtime.default_context()
	defer free_all(context.temp_allocator)
	net := view_network(n)
	hyd := view_hydraulics(h, net.nnodes, net.nlinks)
	m := view_matrix(mc, net.nnodes, net.njuncs, net.nlinks)
	sol := hydsolve(&net, &hyd, &m, hooks)
	out^ = {
		errcode = c.int(sol.errcode),
		iterations = c.int(sol.iterations),
		deficient_nodes = c.int(sol.deficient_nodes),
		relative_error = sol.relative_error,
		max_head_error = sol.max_head_error,
		max_flow_change = sol.max_flow_change,
		demand_reduction = sol.demand_reduction,
		relax = sol.relax,
	}
}
