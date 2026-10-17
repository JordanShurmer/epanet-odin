package epanet

// export.odin — the C face of the package. Each exported proc is one EPANET
// symbol, taking a Project_C (the bridge's view of EPANET's project:
// harness/bridge.c mirrors these structs field for field) plus that
// symbol's own arguments. Every array is EPANET's, 1-based, used in place;
// the per-struct fields of EPANET's nodes, links, pumps, tanks and curves
// arrive as one array per field. Nothing else in the package knows about C.

import "base:runtime"
import "core:c"
import "core:c/libc"

Network_C :: struct {
	nnodes, njuncs, nlinks:                      c.int,
	ntanks, npumps, nvalves, ncontrols:          c.int,
	ncurves, npatterns, ndemands:                c.int,
	def_pat:                                     c.int,
	el, ke, leak_cfa, leak_cva:                  [^]f64,
	demand_first, demand_pat:                    [^]c.int,
	demand_base:                                 [^]f64,
	link_type, n1, n2:                           [^]c.int,
	diam, len, km, kc, r:                        [^]f64,
	link_pump, link_valve:                       [^]c.int,
	init_status:                                 [^]c.int,
	init_setting:                                [^]f64,
	tank_node:                                   [^]c.int,
	tank_area, tank_hmin, tank_hmax:             [^]f64,
	tank_vmin, tank_vmax:                        [^]f64,
	tank_pat, tank_vcurve:                       [^]c.int,
	tank_overflow:                               [^]b32,
	pump_link, pump_type, pump_hcurve:           [^]c.int,
	pump_ecurve:                                 [^]c.int,
	pump_h0, pump_r, pump_n, pump_hmax, pump_q0: [^]f64,
	pump_upat, pump_epat:                        [^]c.int,
	pump_ecost:                                  [^]f64,
	valve_link, valve_curve:                     [^]c.int,
	curve_npts:                                  [^]c.int,
	curve_x, curve_y:                            [^][^]f64,
	pattern_len:                                 [^]c.int,
	pattern_f:                                   [^][^]f64,
	control_link, control_node, control_type:    [^]c.int,
	control_grade, control_setting:              [^]f64,
	control_status:                              [^]c.int,
	control_time:                                [^]i64,
	control_enabled:                             [^]b32,
	ucf_flow, ucf_head, ucf_volume:              f64,
}

Hydraulics_C :: struct {
	formflag, demand_model, emit_backflow, has_leakage:         c.int,
	max_iter, extra_iter, check_freq, max_check:                c.int,
	status_report, status_report_any, epat:                     c.int,
	hexp, qexp, pexp, pmin, preq, rqtol, viscos:                f64,
	htol, qtol, hacc, head_error_limit, flow_change_limit:      f64,
	damp_limit, dmult, spgrav, epump, ecost:                    f64,
	dsystem, emax:                                              f64, // written back
	head, node_demand, demand_flow, full_demand:                [^]f64,
	emitter_flow, leak_flow, leak_qfa, leak_qva, xflow:         [^]f64,
	flow, setting:                                              [^]f64,
	status:                                                     [^]c.int,
	p, y:                                                       [^]f64,
	tank_volume:                                                [^]f64,
	energy:                                                     [^]Pump_Energy,
}

Matrix_C :: struct {
	ncoeffs:                       c.int,
	aii, aij, f, temp:             [^]f64,
	xlnz, nzsub, lnz, link, first: [^]c.int,
	order, row, ndx:               [^]c.int,
}

// Project_C is what every export takes. times is EPANET's own Times
// struct, whose layout Times matches.
Project_C :: struct {
	net:   ^Network_C,
	hyd:   ^Hydraulics_C,
	m:     ^Matrix_C,
	times: ^Times,
	hooks: ^Hooks,
}

Solution_C :: struct {
	errcode, iterations, deficient_nodes:            c.int,
	relative_error, max_head_error, max_flow_change: f64,
	demand_reduction, relax:                         f64,
}

// Views is the package's own types over the C memory.
Views :: struct {
	net: Network,
	hyd: Hydraulics,
	m:   Smatrix,
}

// view builds the slices. The curve and pattern tables need an allocator:
// the temp allocator, which the export frees on the way out.
view :: proc(p: ^Project_C) -> (v: Views) {
	n, h, mc := p.net, p.hyd, p.m
	nn, nj, nl := int(n.nnodes), int(n.njuncs), int(n.nlinks)
	nt, np, nv, nk := int(n.ntanks), int(n.npumps), int(n.nvalves), int(n.ncontrols)
	nc, npat, nd := int(n.ncurves), int(n.npatterns), int(n.ndemands)

	curves := make([]Curve, nc + 1, context.temp_allocator)
	for i in 1 ..= nc do curves[i] = {n.curve_x[i][:n.curve_npts[i]], n.curve_y[i][:n.curve_npts[i]]}
	patterns := make([]Pattern, npat + 1, context.temp_allocator)
	for i in 0 ..= npat do patterns[i] = {n.pattern_f[i][:n.pattern_len[i]]} // 0: the dummy

	v.net = {
		nnodes = nn, njuncs = nj, nlinks = nl,
		ntanks = nt, npumps = np, nvalves = nv, ncontrols = nk,
		el = n.el[:nn + 1], ke = n.ke[:nn + 1],
		leak_cfa = n.leak_cfa[:nj + 1], leak_cva = n.leak_cva[:nj + 1],
		demand_first = n.demand_first[:nj + 2], demand_base = n.demand_base[:nd + 1],
		demand_pat = n.demand_pat[:nd + 1], def_pat = int(n.def_pat),
		link_type = ([^]Link_Type)(n.link_type)[:nl + 1], n1 = n.n1[:nl + 1], n2 = n.n2[:nl + 1],
		diam = n.diam[:nl + 1], len = n.len[:nl + 1], km = n.km[:nl + 1], kc = n.kc[:nl + 1], r = n.r[:nl + 1],
		link_pump = n.link_pump[:nl + 1], link_valve = n.link_valve[:nl + 1],
		init_status = ([^]Status)(n.init_status)[:nl + 1], init_setting = n.init_setting[:nl + 1],
		tank_node = n.tank_node[:nt + 1],
		tank_area = n.tank_area[:nt + 1], tank_hmin = n.tank_hmin[:nt + 1], tank_hmax = n.tank_hmax[:nt + 1],
		tank_vmin = n.tank_vmin[:nt + 1], tank_vmax = n.tank_vmax[:nt + 1],
		tank_pat = n.tank_pat[:nt + 1], tank_vcurve = n.tank_vcurve[:nt + 1],
		tank_overflow = n.tank_overflow[:nt + 1],
		pump_link = n.pump_link[:np + 1], pump_type = ([^]Pump_Type)(n.pump_type)[:np + 1],
		pump_hcurve = n.pump_hcurve[:np + 1], pump_ecurve = n.pump_ecurve[:np + 1],
		pump_h0 = n.pump_h0[:np + 1], pump_r = n.pump_r[:np + 1], pump_n = n.pump_n[:np + 1],
		pump_hmax = n.pump_hmax[:np + 1], pump_q0 = n.pump_q0[:np + 1],
		pump_upat = n.pump_upat[:np + 1], pump_epat = n.pump_epat[:np + 1], pump_ecost = n.pump_ecost[:np + 1],
		valve_link = n.valve_link[:nv + 1], valve_curve = n.valve_curve[:nv + 1],
		curves = curves, patterns = patterns,
		control_link = n.control_link[:nk + 1], control_node = n.control_node[:nk + 1],
		control_type = ([^]Control_Type)(n.control_type)[:nk + 1],
		control_grade = n.control_grade[:nk + 1], control_setting = n.control_setting[:nk + 1],
		control_status = ([^]Status)(n.control_status)[:nk + 1],
		control_time = n.control_time[:nk + 1], control_enabled = n.control_enabled[:nk + 1],
		ucf_flow = n.ucf_flow, ucf_head = n.ucf_head, ucf_volume = n.ucf_volume,
	}
	v.hyd = {
		formflag = Headloss_Formula(h.formflag), demand_model = Demand_Model(h.demand_model),
		emit_backflow = h.emit_backflow != 0, has_leakage = h.has_leakage != 0,
		hexp = h.hexp, qexp = h.qexp, pexp = h.pexp, pmin = h.pmin, preq = h.preq,
		rqtol = h.rqtol, viscos = h.viscos, htol = h.htol, qtol = h.qtol, hacc = h.hacc,
		head_error_limit = h.head_error_limit, flow_change_limit = h.flow_change_limit,
		damp_limit = h.damp_limit,
		max_iter = int(h.max_iter), extra_iter = int(h.extra_iter),
		check_freq = int(h.check_freq), max_check = int(h.max_check),
		status_report = h.status_report != 0, status_report_any = h.status_report_any != 0,
		dmult = h.dmult, spgrav = h.spgrav, epump = h.epump, ecost = h.ecost, epat = int(h.epat),
		dsystem = h.dsystem, emax = h.emax,
		head = h.head[:nn + 1], node_demand = h.node_demand[:nn + 1],
		demand_flow = h.demand_flow[:nn + 1], full_demand = h.full_demand[:nn + 1],
		emitter_flow = h.emitter_flow[:nn + 1], leak_flow = h.leak_flow[:nn + 1],
		leak_qfa = h.leak_qfa[:nn + 1], leak_qva = h.leak_qva[:nn + 1], xflow = h.xflow[:nn + 1],
		flow = h.flow[:nl + 1], setting = h.setting[:nl + 1],
		status = ([^]Status)(h.status)[:nl + 1], p = h.p[:nl + 1], y = h.y[:nl + 1],
		tank_volume = h.tank_volume[:nt + 1], energy = h.energy[:np + 1],
	}
	if mc != nil {
		ncf := int(mc.ncoeffs)
		v.m = {
			aii = mc.aii[:nn + 1], aij = mc.aij[:ncf + 1], f = mc.f[:nn + 1], temp = mc.temp[:nn + 1],
			xlnz = mc.xlnz[:nj + 2], nzsub = mc.nzsub[:ncf + 2], lnz = mc.lnz[:ncf + 2],
			link = mc.link[:nn + 1], first = mc.first[:nn + 1],
			order = mc.order[:nn + 1], row = mc.row[:nn + 1], ndx = mc.ndx[:nl + 1],
		}
	}
	return
}

// unview writes back the scalars the package keeps in its own copy.
unview :: proc "contextless" (p: ^Project_C, v: ^Views) {
	p.hyd.dsystem = v.hyd.dsystem
	p.hyd.emax = v.hyd.emax
}

// ── the linear solver ─────────────────────────────────────────────────

@(export, link_name = "odin_linsolve")
odin_linsolve :: proc "c" (n, ncoeffs: c.int, aii, aij, f, temp: [^]f64, xlnz, nzsub, lnz, link, first: [^]c.int) -> c.int {
	m := Smatrix {
		aii = aii[:n + 1], aij = aij[:ncoeffs + 1], f = f[:n + 1], temp = temp[:n + 1],
		xlnz = xlnz[:n + 2], nzsub = nzsub[:ncoeffs + 2], lnz = lnz[:ncoeffs + 2],
		link = link[:n + 1], first = first[:n + 1],
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
	g := Graph{nnodes = int(nnodes), njuncs = int(njuncs), nlinks = int(nlinks), n1 = n1[:nlinks + 1], n2 = n2[:nlinks + 1]}
	sp := create_sparse(g)
	defer {
		delete(sp.order); delete(sp.row); delete(sp.ndx)
		delete(sp.xlnz); delete(sp.nzsub); delete(sp.lnz)
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

// ── the hydraulic solver ──────────────────────────────────────────────

@(export, link_name = "odin_headlosscoeffs")
odin_headlosscoeffs :: proc "c" (p: ^Project_C) {
	context = runtime.default_context()
	defer free_all(context.temp_allocator)
	v := view(p)
	headloss_coeffs(&v.net, &v.hyd)
}

@(export, link_name = "odin_matrixcoeffs")
odin_matrixcoeffs :: proc "c" (p: ^Project_C) {
	context = runtime.default_context()
	defer free_all(context.temp_allocator)
	v := view(p)
	matrix_coeffs(&v.net, &v.hyd, &v.m)
}

@(export, link_name = "odin_hydsolve")
odin_hydsolve :: proc "c" (p: ^Project_C, out: ^Solution_C) {
	context = runtime.default_context()
	defer free_all(context.temp_allocator)
	v := view(p)
	sol := hydsolve(&v.net, &v.hyd, &v.m, p.hooks)
	out^ = {
		errcode = c.int(sol.errcode), iterations = c.int(sol.iterations),
		deficient_nodes = c.int(sol.deficient_nodes),
		relative_error = sol.relative_error, max_head_error = sol.max_head_error,
		max_flow_change = sol.max_flow_change, demand_reduction = sol.demand_reduction,
		relax = sol.relax,
	}
}

// ── the hydraulic engine ──────────────────────────────────────────────

@(export, link_name = "odin_resistcoeff")
odin_resistcoeff :: proc "c" (p: ^Project_C, k: c.int) {
	context = runtime.default_context()
	defer free_all(context.temp_allocator)
	v := view(p)
	resist_coeff(&v.net, &v.hyd, int(k))
}

@(export, link_name = "odin_pcvlosscoeff")
odin_pcvlosscoeff :: proc "c" (p: ^Project_C, k: c.int, s: f64) -> f64 {
	context = runtime.default_context()
	defer free_all(context.temp_allocator)
	v := view(p)
	return pcv_loss_coeff(&v.net, int(k), s)
}

@(export, link_name = "odin_initlinkflow")
odin_initlinkflow :: proc "c" (p: ^Project_C, i: c.int, s: c.int, k: f64) {
	context = runtime.default_context()
	defer free_all(context.temp_allocator)
	v := view(p)
	init_link_flow(&v.net, &v.hyd, int(i), Status(s), k)
}

@(export, link_name = "odin_resetpumpflow")
odin_resetpumpflow :: proc "c" (p: ^Project_C, i: c.int) {
	context = runtime.default_context()
	defer free_all(context.temp_allocator)
	v := view(p)
	reset_pump_flow(&v.net, &v.hyd, int(i))
}

@(export, link_name = "odin_setlinkstatus")
odin_setlinkstatus :: proc "c" (p: ^Project_C, k: c.int, value: c.int) {
	context = runtime.default_context()
	defer free_all(context.temp_allocator)
	v := view(p)
	set_link_status(&v.net, &v.hyd, int(k), int(value))
}

@(export, link_name = "odin_setlinksetting")
odin_setlinksetting :: proc "c" (p: ^Project_C, k: c.int, value: f64) {
	context = runtime.default_context()
	defer free_all(context.temp_allocator)
	v := view(p)
	set_link_setting(&v.net, &v.hyd, int(k), value)
}

@(export, link_name = "odin_demands")
odin_demands :: proc "c" (p: ^Project_C) {
	context = runtime.default_context()
	defer free_all(context.temp_allocator)
	v := view(p)
	demands(&v.net, &v.hyd, p.times)
	unview(p, &v)
}

@(export, link_name = "odin_controls")
odin_controls :: proc "c" (p: ^Project_C) -> c.int {
	context = runtime.default_context()
	defer free_all(context.temp_allocator)
	v := view(p)
	return c.int(controls(&v.net, &v.hyd, p.times, p.hooks))
}

@(export, link_name = "odin_timestep")
odin_timestep :: proc "c" (p: ^Project_C, nrules: c.int) -> i64 {
	context = runtime.default_context()
	defer free_all(context.temp_allocator)
	v := view(p)
	return timestep(&v.net, &v.hyd, p.times, p.hooks, int(nrules))
}

@(export, link_name = "odin_tanklevels")
odin_tanklevels :: proc "c" (p: ^Project_C, tstep: i64) {
	context = runtime.default_context()
	defer free_all(context.temp_allocator)
	v := view(p)
	tank_levels(&v.net, &v.hyd, tstep)
}

@(export, link_name = "odin_tankvolume")
odin_tankvolume :: proc "c" (p: ^Project_C, i: c.int, h: f64) -> f64 {
	context = runtime.default_context()
	defer free_all(context.temp_allocator)
	v := view(p)
	return tank_volume(&v.net, &v.hyd, int(i), h)
}

@(export, link_name = "odin_tankgrade")
odin_tankgrade :: proc "c" (p: ^Project_C, i: c.int, vol: f64) -> f64 {
	context = runtime.default_context()
	defer free_all(context.temp_allocator)
	v := view(p)
	return tank_grade(&v.net, &v.hyd, int(i), vol)
}

@(export, link_name = "odin_getenergy")
odin_getenergy :: proc "c" (p: ^Project_C, k: c.int, kw, eff: ^f64) {
	context = runtime.default_context()
	defer free_all(context.temp_allocator)
	v := view(p)
	kw^, eff^ = get_energy(&v.net, &v.hyd, int(k))
}

@(export, link_name = "odin_getallpumpsenergy")
odin_getallpumpsenergy :: proc "c" (p: ^Project_C) {
	context = runtime.default_context()
	defer free_all(context.temp_allocator)
	v := view(p)
	get_all_pumps_energy(&v.net, &v.hyd)
}

@(export, link_name = "odin_addenergy")
odin_addenergy :: proc "c" (p: ^Project_C, hstep: i64) {
	context = runtime.default_context()
	defer free_all(context.temp_allocator)
	v := view(p)
	add_energy(&v.net, &v.hyd, p.times, hstep)
	unview(p, &v)
}
