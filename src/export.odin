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
	nnodes, njuncs, nlinks, npumps, nvalves, ncurves: c.int,
	el, ke:                                            [^]f64,
	link_type, n1, n2:                                 [^]c.int,
	diam, km, kc, r:                                   [^]f64,
	link_pump, link_valve:                             [^]c.int,
	pump_type, pump_hcurve:                            [^]c.int,
	pump_h0, pump_r, pump_n:                           [^]f64,
	valve_link, valve_curve:                           [^]c.int,
	curve_npts:                                        [^]c.int,
	curve_x, curve_y:                                  [^][^]f64,
	ucf_flow, ucf_head:                                f64,
}

Hydraulics_C :: struct {
	formflag, demand_model, emit_backflow, has_leakage: c.int,
	hexp, qexp, pexp, pmin, preq, rqtol, viscos:        f64,
	head, demand_flow, full_demand, emitter_flow, xflow: [^]f64,
	flow, setting:                                      [^]f64,
	status:                                             [^]c.int,
	p, y:                                               [^]f64,
}

Matrix_C :: struct {
	ncoeffs:     c.int,
	aii, aij, f: [^]f64,
	row, ndx:    [^]c.int,
}

// view_network needs an allocator for the curve table only.
view_network :: proc(n: ^Network_C) -> Network {
	nn, nl, np, nv, nc := int(n.nnodes), int(n.nlinks), int(n.npumps), int(n.nvalves), int(n.ncurves)
	curves := make([]Curve, nc + 1, context.temp_allocator)
	for i in 1 ..= nc {
		curves[i] = {n.curve_x[i][:n.curve_npts[i]], n.curve_y[i][:n.curve_npts[i]]}
	}
	return {
		nnodes = nn,
		njuncs = int(n.njuncs),
		nlinks = nl,
		npumps = np,
		nvalves = nv,
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
		pump_type = ([^]Pump_Type)(n.pump_type)[:np + 1],
		pump_hcurve = n.pump_hcurve[:np + 1],
		pump_h0 = n.pump_h0[:np + 1],
		pump_r = n.pump_r[:np + 1],
		pump_n = n.pump_n[:np + 1],
		valve_link = n.valve_link[:nv + 1],
		valve_curve = n.valve_curve[:nv + 1],
		curves = curves,
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
		head = h.head[:nnodes + 1],
		demand_flow = h.demand_flow[:nnodes + 1],
		full_demand = h.full_demand[:nnodes + 1],
		emitter_flow = h.emitter_flow[:nnodes + 1],
		xflow = h.xflow[:nnodes + 1],
		flow = h.flow[:nlinks + 1],
		setting = h.setting[:nlinks + 1],
		status = ([^]Status)(h.status)[:nlinks + 1],
		p = h.p[:nlinks + 1],
		y = h.y[:nlinks + 1],
	}
}

view_matrix :: proc "contextless" (m: ^Matrix_C, nnodes, nlinks: int) -> Matrix {
	return {
		aii = m.aii[:nnodes + 1],
		aij = m.aij[:m.ncoeffs + 1],
		f = m.f[:nnodes + 1],
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
odin_matrixcoeffs :: proc "c" (n: ^Network_C, h: ^Hydraulics_C, mc: ^Matrix_C, leakage: proc "c" (ctx: rawptr), ctx: rawptr) {
	context = runtime.default_context()
	defer free_all(context.temp_allocator)
	net := view_network(n)
	hyd := view_hydraulics(h, net.nnodes, net.nlinks)
	m := view_matrix(mc, net.nnodes, net.nlinks)
	matrix_coeffs(&net, &hyd, &m, leakage, ctx)
}
