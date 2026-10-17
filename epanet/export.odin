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
	ncurves, npatterns, ndemands, nadj:          c.int,
	def_pat, nrules, npremises, nactions:        c.int,
	el, ke, leak_cfa, leak_cva:                  [^]f64,
	node_type:                                   [^]c.int,
	c0:                                          [^]f64,
	has_source:                                  [^]b32,
	source_type, source_pat:                     [^]c.int,
	source_c0:                                   [^]f64,
	adj_first, adj_link, adj_node:               [^]c.int,
	demand_first, demand_pat:                    [^]c.int,
	demand_base:                                 [^]f64,
	link_type, n1, n2:                           [^]c.int,
	diam, len, km, kc, r:                        [^]f64,
	link_kb, link_kw:                            [^]f64,
	link_pump, link_valve:                       [^]c.int,
	init_status:                                 [^]c.int,
	init_setting:                                [^]f64,
	tank_node:                                   [^]c.int,
	tank_area, tank_hmin, tank_hmax:             [^]f64,
	tank_vmin, tank_vmax:                        [^]f64,
	tank_pat, tank_vcurve:                       [^]c.int,
	tank_overflow:                               [^]b32,
	tank_h0, tank_v0, tank_v1frac, tank_kb:      [^]f64,
	tank_mix:                                    [^]c.int,
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
	rule_priority:                               [^]f64,
	rule_enabled:                                [^]b32,
	rule_premise_first:                          [^]c.int,
	rule_then_first, rule_else_first:            [^]c.int,
	premise_logop, premise_object:               [^]c.int,
	premise_index, premise_variable:             [^]c.int,
	premise_relop, premise_status:               [^]c.int,
	premise_value:                               [^]f64,
	action_link, action_status:                  [^]c.int,
	action_setting:                              [^]f64,
	ucf_flow, ucf_head, ucf_volume:              f64,
	ucf_quality, ucf_elev:                       f64,
	ucf_demand, ucf_pressure:                    f64,
}

Hydraulics_C :: struct {
	formflag, demand_model, emit_backflow, has_leakage:         c.int,
	max_iter, extra_iter, check_freq, max_check:                c.int,
	status_report, status_report_any, epat:                     c.int,
	haltflag, saveflag, openqflag:                              c.int,
	hexp, qexp, pexp, pmin, preq, rqtol, viscos:                f64,
	htol, qtol, hacc, head_error_limit, flow_change_limit:      f64,
	damp_limit, dmult, spgrav, epump, ecost:                    f64,
	dsystem, emax, leakage_loss:                                f64, // written back
	relax, relative_error, max_head_error, max_flow_change:     f64, // written back
	demand_reduction:                                           f64, // written back
	iterations, deficient_nodes:                                c.int, // written back
	flow_balance:                                               ^Flow_Balance,
	head, node_demand, demand_flow, full_demand:                [^]f64,
	emitter_flow, leak_flow, leak_qfa, leak_qva, xflow:         [^]f64,
	flow, setting:                                              [^]f64,
	status, old_status:                                         [^]c.int,
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

// Quality_C: the engine's settings and state as the bridge holds them.
// segs is the engine's own store, from odin_quality_new.
Quality_C :: struct {
	kind, trace_node, reactive, out_of_memory:          c.int,
	ctol, diffus, climit:                               f64,
	bulk_order, wall_order, tank_order:                 f64,
	sc, bucf, tucf:                                     f64,
	node_qual, tank_c, link_rc, pipe_rate, source_mass: [^]f64,
	flow_dir, sorted:                                   [^]c.int,
	wbulk, wwall, wtank, wsource, source_qual:          f64,
	initial, inflow, outflow, reacted, final, ratio:    f64,
	seg_count:                                          c.int,
	segs:                                               ^Segments,
}

// Project_C is what every export takes. times is EPANET's own Times
// struct, whose layout Times matches.
Project_C :: struct {
	net:   ^Network_C,
	hyd:   ^Hydraulics_C,
	m:     ^Matrix_C,
	times: ^Times,
	hooks: ^Hooks,
	qual:  ^Quality_C,
}

// Views is the package's own types over the C memory.
Views :: struct {
	net: Network,
	hyd: Hydraulics,
	m:   Smatrix,
	q:   Quality,
}

// view builds the slices. The curve and pattern tables need an allocator:
// the temp allocator, which the export frees on the way out.
view :: proc(p: ^Project_C) -> (v: Views) {
	n, h, mc := p.net, p.hyd, p.m
	nn, nj, nl := int(n.nnodes), int(n.njuncs), int(n.nlinks)
	nt, np, nv, nk := int(n.ntanks), int(n.npumps), int(n.nvalves), int(n.ncontrols)
	nc, npat, nd, na := int(n.ncurves), int(n.npatterns), int(n.ndemands), int(n.nadj)
	nr, npr, nac := int(n.nrules), int(n.npremises), int(n.nactions)

	curves := make([]Curve, nc + 1, context.temp_allocator)
	for i in 1 ..= nc do curves[i] = {n.curve_x[i][:n.curve_npts[i]], n.curve_y[i][:n.curve_npts[i]]}
	patterns := make([]Pattern, npat + 1, context.temp_allocator)
	for i in 0 ..= npat do patterns[i] = {n.pattern_f[i][:n.pattern_len[i]]} // 0: the dummy

	v.net = {
		nnodes = nn, njuncs = nj, nlinks = nl,
		ntanks = nt, npumps = np, nvalves = nv, ncontrols = nk,
		el = n.el[:nn + 1], ke = n.ke[:nn + 1],
		leak_cfa = n.leak_cfa[:nj + 1], leak_cva = n.leak_cva[:nj + 1],
		node_type = ([^]Node_Type)(n.node_type)[:nn + 1], c0 = n.c0[:nn + 1],
		has_source = n.has_source[:nn + 1], source_type = ([^]Source_Type)(n.source_type)[:nn + 1],
		source_c0 = n.source_c0[:nn + 1], source_pat = n.source_pat[:nn + 1],
		adj_first = n.adj_first[:nn + 2], adj_link = n.adj_link[:na + 1], adj_node = n.adj_node[:na + 1],
		demand_first = n.demand_first[:nj + 2], demand_base = n.demand_base[:nd + 1],
		demand_pat = n.demand_pat[:nd + 1], def_pat = int(n.def_pat),
		link_type = ([^]Link_Type)(n.link_type)[:nl + 1], n1 = n.n1[:nl + 1], n2 = n.n2[:nl + 1],
		diam = n.diam[:nl + 1], len = n.len[:nl + 1], km = n.km[:nl + 1], kc = n.kc[:nl + 1], r = n.r[:nl + 1],
		link_kb = n.link_kb[:nl + 1], link_kw = n.link_kw[:nl + 1],
		link_pump = n.link_pump[:nl + 1], link_valve = n.link_valve[:nl + 1],
		init_status = ([^]Status)(n.init_status)[:nl + 1], init_setting = n.init_setting[:nl + 1],
		tank_node = n.tank_node[:nt + 1],
		tank_area = n.tank_area[:nt + 1], tank_hmin = n.tank_hmin[:nt + 1], tank_hmax = n.tank_hmax[:nt + 1],
		tank_vmin = n.tank_vmin[:nt + 1], tank_vmax = n.tank_vmax[:nt + 1],
		tank_pat = n.tank_pat[:nt + 1], tank_vcurve = n.tank_vcurve[:nt + 1],
		tank_overflow = n.tank_overflow[:nt + 1],
		tank_h0 = n.tank_h0[:nt + 1], tank_v0 = n.tank_v0[:nt + 1],
		tank_v1frac = n.tank_v1frac[:nt + 1], tank_kb = n.tank_kb[:nt + 1],
		tank_mix = ([^]Mix_Model)(n.tank_mix)[:nt + 1],
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
		nrules = nr, rule_priority = n.rule_priority[:nr + 1], rule_enabled = n.rule_enabled[:nr + 1],
		rule_premise_first = n.rule_premise_first[:nr + 2],
		rule_then_first = n.rule_then_first[:nr + 2], rule_else_first = n.rule_else_first[:nr + 1],
		premise_logop = ([^]Rule_Logic)(n.premise_logop)[:npr + 1],
		premise_object = ([^]Rule_Object)(n.premise_object)[:npr + 1],
		premise_index = n.premise_index[:npr + 1],
		premise_variable = ([^]Rule_Variable)(n.premise_variable)[:npr + 1],
		premise_relop = ([^]Rule_Op)(n.premise_relop)[:npr + 1],
		premise_status = ([^]Rule_Status)(n.premise_status)[:npr + 1],
		premise_value = n.premise_value[:npr + 1],
		action_link = n.action_link[:nac + 1],
		action_status = ([^]Rule_Status)(n.action_status)[:nac + 1],
		action_setting = n.action_setting[:nac + 1],
		ucf_flow = n.ucf_flow, ucf_head = n.ucf_head, ucf_volume = n.ucf_volume,
		ucf_quality = n.ucf_quality, ucf_elev = n.ucf_elev,
		ucf_demand = n.ucf_demand, ucf_pressure = n.ucf_pressure,
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
		dsystem = h.dsystem, emax = h.emax, leakage_loss = h.leakage_loss,
		relax = h.relax, relative_error = h.relative_error, max_head_error = h.max_head_error,
		max_flow_change = h.max_flow_change, demand_reduction = h.demand_reduction,
		iterations = int(h.iterations), deficient_nodes = int(h.deficient_nodes),
		haltflag = h.haltflag != 0, saveflag = h.saveflag != 0, openqflag = h.openqflag != 0,
		flow_balance = h.flow_balance,
		head = h.head[:nn + 1], node_demand = h.node_demand[:nn + 1],
		demand_flow = h.demand_flow[:nn + 1], full_demand = h.full_demand[:nn + 1],
		emitter_flow = h.emitter_flow[:nn + 1], leak_flow = h.leak_flow[:nn + 1],
		leak_qfa = h.leak_qfa[:nn + 1], leak_qva = h.leak_qva[:nn + 1], xflow = h.xflow[:nn + 1],
		flow = h.flow[:nl + 1], setting = h.setting[:nl + 1],
		status = ([^]Status)(h.status)[:nl + 1], old_status = ([^]Status)(h.old_status)[:nl + nt + 1],
		p = h.p[:nl + 1], y = h.y[:nl + 1],
		tank_volume = h.tank_volume[:nt + 1], energy = h.energy[:np + 1],
	}
	if q := p.qual; q != nil {
		v.q = {
			kind = Qual_Type(q.kind), trace_node = int(q.trace_node),
			reactive = q.reactive != 0, out_of_memory = q.out_of_memory != 0,
			ctol = q.ctol, diffus = q.diffus, climit = q.climit,
			bulk_order = q.bulk_order, wall_order = q.wall_order, tank_order = q.tank_order,
			sc = q.sc, bucf = q.bucf, tucf = q.tucf,
			node_qual = q.node_qual[:nn + 1], tank_c = q.tank_c[:nt + 1], link_rc = q.link_rc[:nl + 1],
			pipe_rate = q.pipe_rate[:nl + 1], source_mass = q.source_mass[:nn + 1],
			flow_dir = q.flow_dir[:nl + 1], sorted = q.sorted[:nn + 1],
			wbulk = q.wbulk, wwall = q.wwall, wtank = q.wtank, wsource = q.wsource, source_qual = q.source_qual,
			balance = {q.initial, q.inflow, q.outflow, q.reacted, q.final, q.ratio, int(q.seg_count)},
			segs = q.segs,
		}
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
	p.hyd.leakage_loss = v.hyd.leakage_loss
	p.hyd.haltflag = c.int(v.hyd.haltflag)
	p.hyd.relax = v.hyd.relax
	p.hyd.relative_error = v.hyd.relative_error
	p.hyd.max_head_error = v.hyd.max_head_error
	p.hyd.max_flow_change = v.hyd.max_flow_change
	p.hyd.demand_reduction = v.hyd.demand_reduction
	p.hyd.iterations = c.int(v.hyd.iterations)
	p.hyd.deficient_nodes = c.int(v.hyd.deficient_nodes)
	if q := p.qual; q != nil {
		b := v.q.balance
		q.reactive = c.int(v.q.reactive)
		q.out_of_memory = c.int(v.q.out_of_memory)
		q.sc, q.bucf, q.tucf = v.q.sc, v.q.bucf, v.q.tucf
		q.wbulk, q.wwall, q.wtank, q.wsource, q.source_qual = v.q.wbulk, v.q.wwall, v.q.wtank, v.q.wsource, v.q.source_qual
		q.initial, q.inflow, q.outflow, q.reacted, q.final, q.ratio = b.initial, b.inflow, b.outflow, b.reacted, b.final, b.ratio
		q.seg_count = c.int(b.seg_count)
	}
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
odin_hydsolve :: proc "c" (p: ^Project_C, iter: ^c.int, relerr: ^f64) -> c.int {
	context = runtime.default_context()
	defer free_all(context.temp_allocator)
	v := view(p)
	it, re, rc := hydsolve(&v.net, &v.hyd, &v.m, p.hooks)
	iter^ = c.int(it)
	relerr^ = re
	unview(p, &v)
	return c.int(rc)
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

@(export, link_name = "odin_checkrules")
odin_checkrules :: proc "c" (p: ^Project_C, dt: i64) -> c.int {
	context = runtime.default_context()
	defer free_all(context.temp_allocator)
	v := view(p)
	n := check_rules(&v.net, &v.hyd, p.times, p.hooks, dt)
	unview(p, &v)
	return c.int(n)
}

@(export, link_name = "odin_inithyd")
odin_inithyd :: proc "c" (p: ^Project_C, initflag: c.int) {
	context = runtime.default_context()
	defer free_all(context.temp_allocator)
	v := view(p)
	init_hyd(&v.net, &v.hyd, p.times, int(initflag))
	unview(p, &v)
}

@(export, link_name = "odin_runhyd")
odin_runhyd :: proc "c" (p: ^Project_C, now: ^i64) -> c.int {
	context = runtime.default_context()
	defer free_all(context.temp_allocator)
	v := view(p)
	t, rc := run_hyd(&v.net, &v.hyd, &v.m, p.times, p.hooks)
	now^ = t
	unview(p, &v)
	return c.int(rc)
}

@(export, link_name = "odin_nexthyd")
odin_nexthyd :: proc "c" (p: ^Project_C, tstep: ^i64) -> c.int {
	context = runtime.default_context()
	defer free_all(context.temp_allocator)
	v := view(p)
	ts, rc := next_hyd(&v.net, &v.hyd, p.times, p.hooks)
	tstep^ = ts
	unview(p, &v)
	return c.int(rc)
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

// ── water quality ─────────────────────────────────────────────────────

@(export, link_name = "odin_quality_new")
odin_quality_new :: proc "c" (nchains: c.int) -> ^Segments {
	context = runtime.default_context()
	return segments_make(int(nchains))
}

@(export, link_name = "odin_quality_free")
odin_quality_free :: proc "c" (s: ^Segments) {
	context = runtime.default_context()
	segments_delete(s)
}

@(export, link_name = "odin_initqual")
odin_initqual :: proc "c" (p: ^Project_C) {
	context = runtime.default_context()
	defer free_all(context.temp_allocator)
	v := view(p)
	init_qual(&v.net, &v.hyd, &v.q)
	unview(p, &v)
}

@(export, link_name = "odin_qual_newhydraulics")
odin_qual_newhydraulics :: proc "c" (p: ^Project_C) -> c.int {
	context = runtime.default_context()
	defer free_all(context.temp_allocator)
	v := view(p)
	rc := new_hydraulics(&v.net, &v.hyd, &v.q)
	unview(p, &v)
	return c.int(rc)
}

@(export, link_name = "odin_transport")
odin_transport :: proc "c" (p: ^Project_C, dt: i64) {
	context = runtime.default_context()
	defer free_all(context.temp_allocator)
	v := view(p)
	transport(&v.net, &v.hyd, p.times, &v.q, dt)
	unview(p, &v)
}

@(export, link_name = "odin_evalmassbalance")
odin_evalmassbalance :: proc "c" (p: ^Project_C) {
	context = runtime.default_context()
	defer free_all(context.temp_allocator)
	v := view(p)
	eval_mass_balance(&v.net, &v.q)
	unview(p, &v)
}

@(export, link_name = "odin_avgqual")
odin_avgqual :: proc "c" (p: ^Project_C, k: c.int) -> f64 {
	context = runtime.default_context()
	defer free_all(context.temp_allocator)
	v := view(p)
	return avg_qual(&v.net, &v.q, int(k))
}

// odin_segments lists chain k's segments, first to last, for the shadow.
@(export, link_name = "odin_segments")
odin_segments :: proc "c" (s: ^Segments, k: c.int, v, cq: [^]f64, max: c.int) -> c.int {
	n: c.int = 0
	for seg := s.first[k]; seg != 0 && n < max; seg = s.prev[seg] {
		v[n] = s.v[seg]
		cq[n] = s.c[seg]
		n += 1
	}
	return n
}
