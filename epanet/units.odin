package epanet

// units.odin — what happens after the last line is read: the tanks slide
// down over the junction slots that errors left empty, the growing tables
// become the network's slices, the defaults that depend on other data are
// filled in (input1.c adjustdata / inittanks), and everything is put in
// internal units: feet, cfs, seconds (initunits / convertunits).

import "core:c/libc"

AGETOL : f64 : 0.01 // default water age tolerance, hours
CHEMTOL : f64 : 0.01 // default concentration tolerance
VISCOS : f64 : 1.1e-5 // kinematic viscosity of water, sq ft/sec
DIFFUS : f64 : 1.3e-8 // diffusivity of chlorine, sq ft/sec

GPM_PER_CFS : f64 : 448.831
AFD_PER_CFS : f64 : 1.9837
MGD_PER_CFS : f64 : 0.64632
IMGD_PER_CFS : f64 : 0.5382
LPS_PER_CFS : f64 : 28.317
LPM_PER_CFS : f64 : 1699.0
CMS_PER_CFS : f64 : 0.028317
CMH_PER_CFS : f64 : 101.94
CMD_PER_CFS : f64 : 2446.6
MLD_PER_CFS : f64 : 2.4466
M_PER_FT : f64 : 0.3048
PSI_PER_FT : f64 : 0.4333
KPA_PER_PSI : f64 : 6.895
BAR_PER_PSI : f64 : 0.068948

// reindex_tanks: when junction lines failed, the tanks were put after
// slots that stayed empty; move them down and repoint every index.
reindex_tanks :: proc(ps: ^Parser) {
	p := ps.p
	net := &p.net
	ndiff := p.max_juncs - net.njuncs
	if ndiff <= 0 do return
	for i in 1 ..= net.ntanks {
		n1 := int(net.tank_node[i])
		n2 := n1 - ndiff
		p.nodes_by_id[p.node_id[n1]] = i32(n2)
		net.tank_node[i] = i32(n2)
		p.node_id[n2] = p.node_id[n1]
		p.node_x[n2], p.node_y[n2] = p.node_x[n1], p.node_y[n1]
		p.node_rpt[n2] = p.node_rpt[n1]
		net.el[n2] = net.el[n1]
		net.ke[n2] = net.ke[n1]
		net.node_type[n2] = net.node_type[n1]
		net.c0[n2] = net.c0[n1]
		net.has_source[n2] = net.has_source[n1]
		net.source_type[n2] = net.source_type[n1]
		net.source_c0[n2] = net.source_c0[n1]
		net.source_pat[n2] = net.source_pat[n1]
		for j in 1 ..= net.nlinks {
			if int(net.n1[j]) == n1 do net.n1[j] = i32(n2)
			if int(net.n2[j]) == n1 do net.n2[j] = i32(n2)
		}
		for j in 1 ..= net.ncontrols {
			if int(net.control_node[j]) == n1 do net.control_node[j] = i32(n2)
		}
		if p.q.trace_node == n1 do p.q.trace_node = n2
	}
	// Rule premises on a tank move down once. (EPANET 2.3 shifts them once
	// per tank, which is wrong past the first tank.)
	for k in 1 ..< len(ps.premise_index) {
		if ps.premise_object[k] == .NODE && int(ps.premise_index[k]) > net.njuncs {
			ps.premise_index[k] -= i32(ndiff)
		}
	}
	p.max_juncs = net.njuncs
}

// finish_tables turns the reader's growing tables into the network's.
finish_tables :: proc(ps: ^Parser) {
	p := ps.p
	net := &p.net
	net.patterns = make([]Pattern, len(ps.pattern_f))
	for f, i in ps.pattern_f do net.patterns[i] = {f[:]}
	net.curves = make([]Curve, len(ps.curve_x))
	for x, i in ps.curve_x do net.curves[i] = {x[:], ps.curve_y[i][:]}

	nd := 0
	for d in ps.demands do nd += len(d)
	net.demand_base = make([]f64, nd + 1)
	net.demand_pat = make([]i32, nd + 1)
	k := 1
	for i in 1 ..= net.nnodes {
		net.demand_first[i] = i32(k)
		for d in ps.demands[i] {
			net.demand_base[k] = d.base
			net.demand_pat[k] = d.pat
			k += 1
		}
	}
	net.demand_first[net.nnodes + 1] = i32(k)

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
}

// adjust_data fills in what depends on other data.
adjust_data :: proc(p: ^Project) {
	net, hyd, q, t := &p.net, &p.hyd, &p.q, &p.times
	if t.pstep <= 0 do t.pstep = 3600
	if t.rstep == 0 do t.rstep = t.pstep
	if t.hstep <= 0 do t.hstep = 3600
	if t.hstep > t.pstep do t.hstep = t.pstep
	if t.hstep > t.rstep do t.hstep = t.rstep
	if t.rstart > t.dur do t.rstart = 0
	if t.qstep == 0 do t.qstep = t.hstep / 10
	if t.rulestep == 0 do t.rulestep = t.hstep / 10
	t.rulestep = min(t.rulestep, t.hstep)
	t.qstep = min(t.qstep, t.hstep)
	if q.ctol == MISSING do q.ctol = q.kind == .AGE ? AGETOL : CHEMTOL

	p.units = p.flow_units >= .LPS ? .SI : .US
	if p.pressure_units == .DEFAULTUNIT do p.pressure_units = p.units == .SI ? .METERS : .PSI

	ucf := 1.0
	if p.units == .SI do ucf = M_PER_FT * M_PER_FT
	if hyd.viscos == MISSING {
		hyd.viscos = VISCOS
	} else if hyd.viscos > 1e-3 {
		hyd.viscos = hyd.viscos * VISCOS
	} else {
		hyd.viscos = hyd.viscos / ucf
	}
	if q.diffus == MISSING {
		q.diffus = DIFFUS
	} else if q.diffus > 1e-4 {
		q.diffus = q.diffus * DIFFUS
	} else {
		q.diffus = q.diffus / ucf
	}
	hyd.hexp = hyd.formflag == .HW ? 1.852 : 2.0

	for i in 1 ..= net.nlinks {
		if net.link_type[i] > .PIPE do continue
		if net.link_kb[i] == MISSING do net.link_kb[i] = p.kbulk
		if net.link_kw[i] == MISSING {
			if p.rfactor == 0 {
				net.link_kw[i] = p.kwall
			} else if net.kc[i] > 0 && net.diam[i] > 0 {
				switch hyd.formflag {
				case .HW:
					net.link_kw[i] = p.rfactor / net.kc[i]
				case .DW:
					net.link_kw[i] = p.rfactor / abs(libc.log(net.kc[i] / net.diam[i]))
				case .CM:
					net.link_kw[i] = p.rfactor * net.kc[i]
				}
			} else {
				net.link_kw[i] = 0
			}
		}
	}
	for i in 1 ..= net.ntanks {
		if net.tank_kb[i] == MISSING do net.tank_kb[i] = p.kbulk
	}
	if i := findpattern(p, p.def_pat_id); i > 0 do net.def_pat = i
	if q.kind == .NONE do p.rpt.fields[.QUALITY].enabled = false
}

// init_tanks: the volumes of tanks with a volume curve.
init_tanks :: proc(p: ^Project) {
	net := &p.net
	for j in 1 ..= net.ntanks {
		if net.tank_area[j] == 0 do continue
		i := int(net.tank_vcurve[j])
		if i <= 0 do continue
		c := net.curves[i]
		n := len(c.x) - 1
		net.tank_vmin[j] = interp(c.x, c.y, net.tank_hmin[j])
		net.tank_vmax[j] = interp(c.x, c.y, net.tank_hmax[j])
		net.tank_v0[j] = interp(c.x, c.y, net.tank_h0[j])
		a := (c.y[n] - c.y[0]) / (c.x[n] - c.x[0])
		net.tank_area[j] = libc.sqrt(4 * a / PI)
	}
}

// init_units: the factors from internal units to the user's.
init_units :: proc(p: ^Project) {
	dcf, qcf, hcf, wcf: f64
	if p.units == .SI {
		dcf = 1000 * M_PER_FT
		qcf = LPS_PER_CFS
		#partial switch p.flow_units {
		case .LPM:
			qcf = LPM_PER_CFS
		case .MLD:
			qcf = MLD_PER_CFS
		case .CMH:
			qcf = CMH_PER_CFS
		case .CMD:
			qcf = CMD_PER_CFS
		case .CMS:
			qcf = CMS_PER_CFS
		}
		hcf = M_PER_FT
		wcf = KW_PER_HP
	} else {
		dcf = 12
		qcf = 1
		#partial switch p.flow_units {
		case .GPM:
			qcf = GPM_PER_CFS
		case .MGD:
			qcf = MGD_PER_CFS
		case .IMGD:
			qcf = IMGD_PER_CFS
		case .AFD:
			qcf = AFD_PER_CFS
		}
		hcf = 1
		wcf = 1
	}
	pcf := PSI_PER_FT * p.hyd.spgrav
	#partial switch p.pressure_units {
	case .METERS:
		pcf = M_PER_FT
	case .KPA:
		pcf = KPA_PER_PSI * PSI_PER_FT * p.hyd.spgrav
	case .BAR:
		pcf = BAR_PER_PSI * PSI_PER_FT * p.hyd.spgrav
	case .FEET:
		pcf = 1
	}
	ccf := 1.0
	if p.q.kind == .CHEM do ccf = 1 / L_PER_FT3

	u := &p.ucf
	u[.DEMAND] = qcf
	u[.ELEV] = hcf
	u[.HEAD] = hcf
	u[.PRESSURE] = pcf
	u[.QUALITY] = ccf
	u[.LENGTH] = hcf
	u[.DIAM] = dcf
	u[.FLOW] = qcf
	u[.VELOCITY] = hcf
	u[.HEADLOSS] = hcf
	u[.LINKQUAL] = ccf
	u[.REACTRATE] = ccf
	u[.FRICTION] = 1
	u[.POWER] = wcf
	u[.VOLUME] = hcf * hcf * hcf
	u[.TIME] = p.times.hstep < 1800 ? 1.0 / 60.0 : 1.0 / 3600.0

	net := &p.net
	net.ucf_flow = qcf
	net.ucf_head = hcf
	net.ucf_volume = u[.VOLUME]
	net.ucf_quality = ccf
	net.ucf_elev = hcf
	net.ucf_demand = qcf
	net.ucf_pressure = pcf
}

// convert_units puts the input in internal units.
convert_units :: proc(p: ^Project) {
	net, hyd, q := &p.net, &p.hyd, &p.q
	u := &p.ucf
	for i in 1 ..= net.nnodes {
		net.el[i] /= u[.ELEV]
		net.c0[i] /= u[.QUALITY]
	}
	for i in 1 ..= net.njuncs {
		for k in net.demand_first[i] ..< net.demand_first[i + 1] do net.demand_base[k] /= u[.DEMAND]
	}
	hyd.pmin /= u[.PRESSURE]
	hyd.preq /= u[.PRESSURE]

	ecf := p.units == .US ? PSI_PER_FT * hyd.spgrav : M_PER_FT
	ucf := libc.pow(u[.FLOW], hyd.qexp) / ecf
	for i in 1 ..= net.njuncs {
		if net.ke[i] > 0 do net.ke[i] = ucf / libc.pow(net.ke[i], hyd.qexp)
	}

	for j in 1 ..= net.ntanks {
		i := net.tank_node[j]
		el := net.el[i]
		net.tank_h0[j] = el + net.tank_h0[j] / u[.ELEV]
		net.tank_hmin[j] = el + net.tank_hmin[j] / u[.ELEV]
		net.tank_hmax[j] = el + net.tank_hmax[j] / u[.ELEV]
		d := net.tank_area[j] / u[.ELEV]
		net.tank_area[j] = PI * (d * d) / 4
		net.tank_v0[j] /= u[.VOLUME]
		net.tank_vmin[j] /= u[.VOLUME]
		net.tank_vmax[j] /= u[.VOLUME]
		net.tank_kb[j] /= SEC_PER_DAY
		hyd.tank_volume[j] = net.tank_v0[j]
		q.tank_c[j] = net.c0[i]
	}

	hyd.flow_change_limit /= u[.FLOW]
	hyd.head_error_limit /= u[.HEAD]
	q.climit /= u[.QUALITY]
	q.ctol /= u[.QUALITY]
	p.kbulk /= SEC_PER_DAY
	p.kwall /= SEC_PER_DAY

	for k in 1 ..= net.nlinks {
		t := net.link_type[k]
		if t <= .PIPE {
			if hyd.formflag == .DW do net.kc[k] /= 1000 * u[.ELEV]
			net.diam[k] /= u[.DIAM]
			net.len[k] /= u[.LENGTH]
			d2 := net.diam[k] * net.diam[k]
			net.km[k] = 0.02517 * net.km[k] / d2 / d2
			net.link_kb[k] /= SEC_PER_DAY
			net.link_kw[k] /= SEC_PER_DAY
			net.leak_area[k] *= u[.LENGTH]
			net.leak_expan[k] *= u[.LENGTH]
		} else if t == .PUMP {
			net.km[k] /= u[.POWER]
		} else {
			net.diam[k] /= u[.DIAM]
			d2 := net.diam[k] * net.diam[k]
			net.km[k] = 0.02517 * net.km[k] / d2 / d2
			if net.kc[k] != MISSING {
				#partial switch t {
				case .FCV:
					net.kc[k] /= u[.FLOW]
				case .PRV, .PSV, .PBV:
					net.kc[k] /= u[.PRESSURE]
				}
			}
		}
		net.init_setting[k] = net.kc[k]
	}

	for i in 1 ..= net.ncontrols {
		k := int(net.control_link[i])
		if k == 0 do continue
		if j := int(net.control_node[i]); j > 0 {
			if j > net.njuncs {
				net.control_grade[i] = net.el[j] + net.control_grade[i] / u[.ELEV]
			} else {
				net.control_grade[i] = net.el[j] + net.control_grade[i] / u[.PRESSURE]
			}
		}
		if net.control_setting[i] != MISSING {
			#partial switch net.link_type[k] {
			case .PRV, .PSV, .PBV:
				net.control_setting[i] /= u[.PRESSURE]
			case .FCV:
				net.control_setting[i] /= u[.FLOW]
			}
		}
	}
}
