package epanet

// dump.odin — a project written out as text, every field the engine
// reads, numbers at %.17g through the C library so the same project in
// EPANET's own structs (harness/dumpnet.c) prints the same bytes.

import "core:c/libc"
import "core:strings"

dump_num :: proc(sb: ^strings.Builder, x: f64) {
	buf: [40]u8
	n := libc.snprintf(raw_data(buf[:]), len(buf), " %.17g", x)
	strings.write_string(sb, string(buf[:n]))
}

dump_int :: proc(sb: ^strings.Builder, x: int) {
	strings.write_string(sb, " ")
	strings.write_int(sb, x)
}

dump_str :: proc(sb: ^strings.Builder, s: string) {
	strings.write_string(sb, " [")
	strings.write_string(sb, s)
	strings.write_string(sb, "]")
}

dump_project :: proc(sb: ^strings.Builder, p: ^Project, errcode, valcode: int) {
	net, hyd, q, t, r := &p.net, &p.hyd, &p.q, &p.times, &p.rpt
	strings.write_string(sb, "errcode")
	dump_int(sb, errcode)
	dump_int(sb, valcode)
	strings.write_string(sb, "\ncounts")
	for n in ([?]int{net.nnodes, net.njuncs, net.ntanks, net.nlinks, net.npumps, net.nvalves, net.ncontrols, net.nrules, len(net.patterns) - 1, len(net.curves) - 1}) do dump_int(sb, n)
	strings.write_string(sb, "\ntitle")
	for s in p.title do dump_str(sb, s)
	strings.write_string(sb, "\nunits")
	dump_int(sb, int(p.units))
	dump_int(sb, int(p.flow_units))
	dump_int(sb, int(p.pressure_units))
	dump_int(sb, int(p.out.hydflag))
	dump_str(sb, p.out.hyd_fname)
	dump_str(sb, p.map_fname)
	dump_str(sb, p.chem_name)
	dump_str(sb, p.chem_units)
	dump_str(sb, p.def_pat_id)
	strings.write_string(sb, "\nucf")
	for f in Field do dump_num(sb, p.ucf[f])
	strings.write_string(sb, "\nhyd")
	dump_int(sb, int(hyd.formflag))
	dump_int(sb, int(hyd.demand_model))
	dump_int(sb, hyd.emit_backflow ? 1 : 0)
	for x in ([?]f64{hyd.hexp, hyd.qexp, hyd.pexp, hyd.pmin, hyd.preq, hyd.rqtol, hyd.viscos, hyd.htol, hyd.qtol, hyd.hacc, hyd.head_error_limit, hyd.flow_change_limit, hyd.damp_limit}) do dump_num(sb, x)
	for n in ([?]int{hyd.max_iter, hyd.extra_iter, hyd.check_freq, hyd.max_check}) do dump_int(sb, n)
	for x in ([?]f64{hyd.dmult, hyd.spgrav, hyd.epump, hyd.ecost, p.dcost}) do dump_num(sb, x)
	dump_int(sb, hyd.epat)
	dump_int(sb, net.def_pat)
	strings.write_string(sb, "\nqual")
	dump_int(sb, int(q.kind))
	dump_int(sb, q.trace_node)
	for x in ([?]f64{q.ctol, q.diffus, q.climit, q.bulk_order, q.wall_order, q.tank_order, p.kbulk, p.kwall, p.rfactor}) do dump_num(sb, x)
	strings.write_string(sb, "\ntimes")
	for n in ([?]i64{t.dur, t.tstart, t.pstart, t.hstep, t.qstep, t.pstep, t.rstep, t.rulestep, t.rstart}) do dump_int(sb, int(n))
	strings.write_string(sb, "\nreport")
	dump_int(sb, r.page_size)
	dump_int(sb, r.summary ? 1 : 0)
	dump_int(sb, r.messages ? 1 : 0)
	dump_int(sb, r.status)
	dump_int(sb, r.energy ? 1 : 0)
	dump_int(sb, r.nodes)
	dump_int(sb, r.links)
	dump_int(sb, int(r.tstat))
	dump_str(sb, r.rpt2_fname)
	for f in Field {
		strings.write_string(sb, "\nfield")
		dump_int(sb, int(f))
		dump_int(sb, r.fields[f].enabled ? 1 : 0)
		dump_int(sb, r.fields[f].precision)
		dump_num(sb, r.fields[f].lo)
		dump_num(sb, r.fields[f].hi)
	}
	for i in 1 ..= net.nnodes {
		strings.write_string(sb, "\nnode")
		dump_int(sb, i)
		dump_str(sb, p.node_id[i])
		dump_int(sb, int(net.node_type[i]))
		for x in ([?]f64{net.el[i], net.c0[i], net.ke[i], p.node_x[i], p.node_y[i]}) do dump_num(sb, x)
		dump_int(sb, p.node_rpt[i] ? 1 : 0)
		for k in net.demand_first[i] ..< net.demand_first[i + 1] {
			strings.write_string(sb, "\ndem")
			dump_int(sb, i)
			dump_num(sb, net.demand_base[k])
			dump_int(sb, int(net.demand_pat[k]))
		}
		if net.has_source[i] {
			strings.write_string(sb, "\nsrc")
			dump_int(sb, i)
			dump_int(sb, int(net.source_type[i]))
			dump_num(sb, net.source_c0[i])
			dump_int(sb, int(net.source_pat[i]))
		}
	}
	for k in 1 ..= net.nlinks {
		strings.write_string(sb, "\nlink")
		dump_int(sb, k)
		dump_str(sb, p.link_id[k])
		dump_int(sb, int(net.link_type[k]))
		dump_int(sb, int(net.n1[k]))
		dump_int(sb, int(net.n2[k]))
		for x in ([?]f64{net.diam[k], net.len[k], net.kc[k], net.km[k], net.link_kb[k], net.link_kw[k]}) do dump_num(sb, x)
		dump_int(sb, int(net.init_status[k]))
		dump_num(sb, net.init_setting[k])
		dump_num(sb, net.leak_area[k])
		dump_num(sb, net.leak_expan[k])
		dump_int(sb, p.link_rpt[k] ? 1 : 0)
	}
	for i in 1 ..= net.ntanks {
		strings.write_string(sb, "\ntank")
		dump_int(sb, i)
		dump_int(sb, int(net.tank_node[i]))
		for x in ([?]f64{net.tank_area[i], net.tank_hmin[i], net.tank_hmax[i], net.tank_h0[i], net.tank_vmin[i], net.tank_vmax[i], net.tank_v0[i], net.tank_kb[i], hyd.tank_volume[i], q.tank_c[i]}) do dump_num(sb, x)
		dump_int(sb, int(net.tank_pat[i]))
		dump_int(sb, int(net.tank_vcurve[i]))
		dump_int(sb, int(net.tank_mix[i]))
		dump_num(sb, net.tank_v1frac[i])
		dump_int(sb, net.tank_overflow[i] ? 1 : 0)
	}
	for i in 1 ..= net.npumps {
		strings.write_string(sb, "\npump")
		dump_int(sb, i)
		dump_int(sb, int(net.pump_link[i]))
		dump_int(sb, int(net.pump_type[i]))
		for x in ([?]f64{net.pump_q0[i], p.pump_qmax[i], net.pump_hmax[i], net.pump_h0[i], net.pump_r[i], net.pump_n[i]}) do dump_num(sb, x)
		dump_int(sb, int(net.pump_hcurve[i]))
		dump_int(sb, int(net.pump_ecurve[i]))
		dump_int(sb, int(net.pump_upat[i]))
		dump_int(sb, int(net.pump_epat[i]))
		dump_num(sb, net.pump_ecost[i])
	}
	for i in 1 ..= net.nvalves {
		strings.write_string(sb, "\nvalve")
		dump_int(sb, i)
		dump_int(sb, int(net.valve_link[i]))
		dump_int(sb, int(net.valve_curve[i]))
	}
	for pat, i in net.patterns {
		strings.write_string(sb, "\npat")
		dump_int(sb, i)
		dump_str(sb, p.pattern_id[i])
		dump_int(sb, len(pat.f))
		for x in pat.f do dump_num(sb, x)
	}
	for cv, i in net.curves {
		if i == 0 do continue
		strings.write_string(sb, "\ncurve")
		dump_int(sb, i)
		dump_str(sb, p.curve_id[i])
		dump_int(sb, int(p.curve_type[i]))
		dump_int(sb, len(cv.x))
		for x, k in cv.x {
			dump_num(sb, x)
			dump_num(sb, cv.y[k])
		}
	}
	for i in 1 ..= net.ncontrols {
		strings.write_string(sb, "\ncontrol")
		dump_int(sb, i)
		dump_int(sb, int(net.control_link[i]))
		dump_int(sb, int(net.control_node[i]))
		dump_int(sb, int(net.control_time[i]))
		dump_num(sb, net.control_grade[i])
		dump_num(sb, net.control_setting[i])
		dump_int(sb, int(net.control_status[i]))
		dump_int(sb, int(net.control_type[i]))
		dump_int(sb, net.control_enabled[i] ? 1 : 0)
	}
	for i in 1 ..= net.nrules {
		strings.write_string(sb, "\nrule")
		dump_int(sb, i)
		dump_str(sb, p.rule_label[i])
		dump_num(sb, net.rule_priority[i])
		dump_int(sb, net.rule_enabled[i] ? 1 : 0)
		for k in net.rule_premise_first[i] ..< net.rule_premise_first[i + 1] {
			strings.write_string(sb, "\nprem")
			dump_int(sb, int(net.premise_logop[k]))
			dump_int(sb, int(net.premise_object[k]))
			dump_int(sb, int(net.premise_index[k]))
			dump_int(sb, int(net.premise_variable[k]))
			dump_int(sb, int(net.premise_relop[k]))
			dump_int(sb, int(net.premise_status[k]))
			dump_num(sb, net.premise_value[k])
		}
		for k in net.rule_then_first[i] ..< net.rule_then_first[i + 1] {
			strings.write_string(sb, k < net.rule_else_first[i] ? "\nthen" : "\nelse")
			dump_int(sb, int(net.action_link[k]))
			dump_int(sb, int(net.action_status[k]))
			dump_num(sb, net.action_setting[k])
		}
	}
	strings.write_string(sb, "\n")
}
