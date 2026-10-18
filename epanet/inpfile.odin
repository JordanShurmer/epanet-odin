package epanet

// inpfile.odin — the project written back as an EPANET input file
// (inpfile.c saveinpfile), section by section with EPANET's own formats,
// so the two write the same bytes from the same project. The [LABELS] and
// [BACKDROP] sections, which the engine never reads, are copied from the
// file the project came from, as EPANET copies them.

import "core:c"
import "core:c/libc"
import "core:strings"

INP_LINK_TEXT := [Link_Type]string {
	.CVPIPE = "CV", .PIPE = "Pipe", .PUMP = "Pump", .PRV = "PRV", .PSV = "PSV",
	.PBV = "PBV", .FCV = "FCV", .TCV = "TCV", .GPV = "GPV", .PCV = "PCV",
}
INP_STAT_TEXT := [Status]string {
	.XHEAD = "closed because cannot deliver head", .TEMPCLOSED = "temporarily closed",
	.CLOSED = "closed", .OPEN = "open", .ACTIVE = "active",
	.XFLOW = "open but exceeds maximum flow", .XFCV = "open but cannot deliver flow",
	.XPRESSURE = "open but cannot deliver pressure", .FILLING = "filling",
	.EMPTYING = "emptying", .OVERFLOWING = "overflowing",
}
INP_FORM_TEXT := [Headloss_Formula]string{.HW = "H-W", .DW = "D-W", .CM = "C-M"}
INP_FLOW_UNITS_TEXT := [Flow_Units]string {
	.CFS = "CFS", .GPM = "GPM", .MGD = "MGD", .IMGD = "IMGD", .AFD = "AFD",
	.LPS = "LPS", .LPM = "LPM", .MLD = "MLD", .CMH = "CMH", .CMD = "CMD", .CMS = "CMS",
}
INP_PRESSURE_UNITS_TEXT := [Pressure_Units]string {
	.PSI = "PSI", .KPA = "KPA", .METERS = "METERS", .BAR = "BAR", .FEET = "FEET", .DEFAULTUNIT = "",
}
INP_SOURCE_TEXT := [Source_Type]string{.CONCEN = "CONCEN", .MASS = "MASS", .SETPOINT = "SETPOINT", .FLOWPACED = "FLOWPACED"}
INP_CONTROL_TEXT := [Control_Type]string{.LOWLEVEL = "BELOW", .HILEVEL = "ABOVE", .TIMER = "TIME", .TIMEOFDAY = "CLOCKTIME"}
INP_MIX_TEXT := [Mix_Model]string{.MIX1 = "MIXED", .MIX2 = "2COMP", .FIFO = "FIFO", .LIFO = "LIFO"}
INP_TSTAT_TEXT := [Time_Stat]string{.SERIES = "NONE", .AVG = "AVERAGE", .MIN = "MINIMUM", .MAX = "MAXIMUM", .RANGE = "RANGE"}
INP_CURVE_TYPE_TEXT := [Curve_Type]string {
	.VOLUME_CURVE = "VOLUME", .PUMP_CURVE = "PUMP", .EFFIC_CURVE = "EFFIC",
	.HLOSS_CURVE = "HEADLOSS", .GENERIC_CURVE = "GENERIC", .VALVE_CURVE = "VALVE",
}
INP_RULE_WORD := [Rule_Logic]string {
	.RULE = "RULE", .IF = "IF", .AND = "AND", .OR = "OR", .THEN = "THEN", .ELSE = "ELSE",
	.PRIORITY = "PRIO", .DISABLED = "DISABLED", .ERROR = "",
}
INP_RULE_VARIABLE := [Rule_Variable]string {
	.DEMAND = "DEMAND", .HEAD = "HEAD", .GRADE = "GRADE", .LEVEL = "LEVEL", .PRESSURE = "PRESSURE",
	.FLOW = "FLOW", .STATUS = "STATUS", .SETTING = "SETTING", .POWER = "POWER", .TIME = "TIME",
	.CLOCKTIME = "CLOCKTIME", .FILLTIME = "FILLTIME", .DRAINTIME = "DRAINTIME",
}
INP_RULE_OPERATOR := [Rule_Op]string {
	.EQ = "=", .NE = "<>", .LE = "<=", .GE = ">=", .LT = "<", .GT = ">",
	.IS = "IS", .NOT = "NOT", .BELOW = "BELOW", .ABOVE = "ABOVE",
}
INP_RULE_VALUE := [Rule_Status]string{.IS_NUMBER = "XXXX", .IS_OPEN = "OPEN", .IS_CLOSED = "CLOSED", .IS_ACTIVE = "ACTIVE"}
YES_NO := [2]string{"NO", "YES"}

// tc: s as a C string, until the temp allocator is freed.
tc :: proc(s: string) -> cstring {
	return strings.clone_to_cstring(s, context.temp_allocator)
}

// save_inp writes the project to fname. Returns 0, or 302 when the file
// cannot be made.
save_inp :: proc(p: ^Project, fname: string) -> int {
	net, hyd, q, t, r := &p.net, &p.hyd, &p.q, &p.times, &p.rpt
	u := &p.ucf
	defer free_all(context.temp_allocator)
	f := libc.fopen(tc(fname), "wt")
	if f == nil do return 302
	defer libc.fclose(f)
	clock: [16]u8
	nid :: #force_inline proc(p: ^Project, i: i32) -> cstring {return tc(p.node_id[i])}

	libc.fprintf(f, "[TITLE]")
	for i in 0 ..< 3 {
		if len(p.title[i]) > 0 do libc.fprintf(f, "\n%s", tc(p.title[i]))
	}

	libc.fprintf(f, "\n\n[JUNCTIONS]")
	libc.fprintf(f, "\n;;%-31s\t%-12s\t%-12s\t%-31s", cstring("ID"), cstring("Elev"), cstring("Demand"), cstring("Pattern"))
	for i in 1 ..= net.njuncs {
		libc.fprintf(f, "\n %-31s\t%-12.4f", tc(p.node_id[i]), net.el[i] * u[.ELEV])
		if len(p.node_comment[i]) > 0 do libc.fprintf(f, "\t;%s", tc(p.node_comment[i]))
	}

	libc.fprintf(f, "\n\n[RESERVOIRS]")
	libc.fprintf(f, "\n;;%-31s\t%-12s\t%-31s", cstring("ID"), cstring("Head"), cstring("Pattern"))
	for j in 1 ..= net.ntanks {
		if net.tank_area[j] != 0 do continue
		i := net.tank_node[j]
		pat := net.tank_pat[j] > 0 ? p.pattern_id[net.tank_pat[j]] : " "
		libc.fprintf(f, "\n %-31s\t%-12.4f\t%-31s", nid(p, i), net.el[i] * u[.ELEV], tc(pat))
		if len(p.node_comment[i]) > 0 do libc.fprintf(f, "\t;%s", tc(p.node_comment[i]))
	}

	libc.fprintf(f, "\n\n[TANKS]")
	libc.fprintf(f, "\n;;%-31s\t%-12s\t%-12s\t%-12s\t%-12s\t%-12s\t%-12s\t%-31s\t%-12s",
		cstring("ID"), cstring("Elevation"), cstring("InitLevel"), cstring("MinLevel"), cstring("MaxLevel"), cstring("Diameter"), cstring("MinVol"), cstring("VolCurve"), cstring("Overflow"))
	for j in 1 ..= net.ntanks {
		if net.tank_area[j] <= 0 do continue
		i := net.tank_node[j]
		el := net.el[i]
		s1: string
		if net.tank_vcurve[j] > 0 {
			s1 = p.curve_id[net.tank_vcurve[j]]
		} else if net.tank_overflow[j] {
			s1 = "*"
		} else {
			s1 = " "
		}
		libc.fprintf(f, "\n %-31s\t%-12.4f\t%-12.4f\t%-12.4f\t%-12.4f\t%-12.4f\t%-12.4f\t%-31s",
			nid(p, i), el * u[.ELEV], (net.tank_h0[j] - el) * u[.ELEV], (net.tank_hmin[j] - el) * u[.ELEV],
			(net.tank_hmax[j] - el) * u[.ELEV], libc.sqrt(4.0 * net.tank_area[j] / PI) * u[.ELEV],
			net.tank_vmin[j] * (u[.ELEV] * u[.ELEV]) * u[.ELEV], tc(s1))
		if net.tank_overflow[j] do libc.fprintf(f, "\t%-12s", cstring("YES"))
		if len(p.node_comment[i]) > 0 do libc.fprintf(f, "\t;%s", tc(p.node_comment[i]))
	}

	libc.fprintf(f, "\n\n[PIPES]")
	libc.fprintf(f, "\n;;%-31s\t%-31s\t%-31s\t%-12s\t%-12s\t%-12s\t%-12s\t%-6s",
		cstring("ID"), cstring("Node1"), cstring("Node2"), cstring("Length"), cstring("Diameter"), cstring("Roughness"), cstring("MinorLoss"), cstring("Status"))
	for k in 1 ..= net.nlinks {
		if net.link_type[k] > .PIPE do continue
		d := net.diam[k]
		kc := net.init_setting[k]
		if hyd.formflag == .DW do kc = kc * u[.ELEV] * 1000.0
		km := net.km[k] * (d * d) * (d * d) / 0.02517
		s2: string
		if net.link_type[k] == .CVPIPE {
			s2 = "CV"
		} else if net.init_status[k] == .CLOSED {
			s2 = "CLOSED"
		} else {
			s2 = " "
		}
		libc.fprintf(f, "\n %-31s\t%-31s\t%-31s\t%-12.4f\t%-12.4f\t%-12.4f\t%-12.4f\t%-6s",
			tc(p.link_id[k]), nid(p, net.n1[k]), nid(p, net.n2[k]),
			net.len[k] * u[.LENGTH], d * u[.DIAM], kc, km, tc(s2))
		if len(p.link_comment[k]) > 0 do libc.fprintf(f, "\t;%s", tc(p.link_comment[k]))
	}

	libc.fprintf(f, "\n\n[PUMPS]")
	libc.fprintf(f, "\n;;%-31s\t%-31s\t%-31s\t%-12s", cstring("ID"), cstring("Node1"), cstring("Node2"), cstring("Parameters"))
	for m in 1 ..= net.npumps {
		k := net.pump_link[m]
		head: [256]u8
		n := libc.snprintf(raw_data(head[:]), len(head), " %-31s\t%-31s\t%-31s", tc(p.link_id[k]), nid(p, net.n1[k]), nid(p, net.n2[k]))
		s := string(head[:n])
		if net.pump_type[m] == .CONST_HP {
			s = strings.concatenate({s, "\tPOWER ", fmt4(net.km[k])}, context.temp_allocator)
		} else if net.pump_hcurve[m] > 0 {
			s = strings.concatenate({s, "\tHEAD ", p.curve_id[net.pump_hcurve[m]]}, context.temp_allocator)
		} else {
			libc.fprintf(f, "\n%s %12.4f %12.4f %12.4f          0.0 %12.4f", tc(s),
				-net.pump_h0[m] * u[.HEAD],
				(-net.pump_h0[m] - net.pump_r[m] * libc.pow(net.pump_q0[m], net.pump_n[m])) * u[.HEAD],
				net.pump_q0[m] * u[.FLOW], p.pump_qmax[m] * u[.FLOW])
			continue
		}
		if net.pump_upat[m] > 0 do s = strings.concatenate({s, "\tPATTERN ", p.pattern_id[net.pump_upat[m]]}, context.temp_allocator)
		if net.init_setting[k] != 1.0 do s = strings.concatenate({s, "\tSPEED ", fmt4(net.init_setting[k])}, context.temp_allocator)
		libc.fprintf(f, "\n%s", tc(s))
		if len(p.link_comment[k]) > 0 do libc.fprintf(f, "\t;%s", tc(p.link_comment[k]))
	}

	libc.fprintf(f, "\n\n[VALVES]")
	libc.fprintf(f, "\n;;%-31s\t%-31s\t%-31s\t%-12s\t%-6s\t%-12s\t%-12s",
		cstring("ID"), cstring("Node1"), cstring("Node2"), cstring("Diameter"), cstring("Type"), cstring("Setting"), cstring("MinorLoss"))
	for v in 1 ..= net.nvalves {
		k := net.valve_link[v]
		d := net.diam[k]
		kc := net.init_setting[k]
		#partial switch net.link_type[k] {
		case .FCV:
			kc *= u[.FLOW]
		case .PRV, .PSV, .PBV:
			kc *= u[.PRESSURE]
		}
		km := net.km[k] * (d * d) * (d * d) / 0.02517
		libc.fprintf(f, "\n %-31s\t%-31s\t%-31s\t%-12.4f\t%-6s\t", tc(p.link_id[k]), nid(p, net.n1[k]), nid(p, net.n2[k]),
			d * u[.DIAM], tc(INP_LINK_TEXT[net.link_type[k]]))
		if ci := int(libc.round(kc)); net.link_type[k] == .GPV && ci > 0 {
			libc.fprintf(f, "%-31s\t%-12.4f", tc(p.curve_id[ci]), km)
		} else if ci := net.valve_curve[v]; net.link_type[k] == .PCV && ci > 0 {
			libc.fprintf(f, "%-12.4f\t%-12.4f\t%-31s", kc, km, tc(p.curve_id[ci]))
		} else {
			libc.fprintf(f, "%-12.4f\t%-12.4f", kc, km)
		}
		if len(p.link_comment[k]) > 0 do libc.fprintf(f, "\t;%s", tc(p.link_comment[k]))
	}

	libc.fprintf(f, "\n\n[DEMANDS]")
	libc.fprintf(f, "\n;;%-31s\t%-14s\t%-31s\t%-31s", cstring("Junction"), cstring("Demand"), cstring("Pattern"), cstring("Category"))
	for i in 1 ..= net.njuncs {
		for s in net.demand_first[i] ..< net.demand_first[i + 1] {
			if net.demand_base[s] == 0 do continue
			pat := net.demand_pat[s] > 0 ? p.pattern_id[net.demand_pat[s]] : " "
			libc.fprintf(f, "\n %-31s\t%-14.6f\t%-31s", tc(p.node_id[i]), u[.DEMAND] * net.demand_base[s], tc(pat))
			if len(p.demand_name[s]) > 0 do libc.fprintf(f, "\t;%s", tc(p.demand_name[s]))
		}
	}

	libc.fprintf(f, "\n\n[EMITTERS]")
	libc.fprintf(f, "\n;;%-31s\t%-14s", cstring("Junction"), cstring("Coefficient"))
	for i in 1 ..= net.njuncs {
		if net.ke[i] == 0 do continue
		ke := u[.FLOW] / libc.pow(u[.PRESSURE] * net.ke[i], 1.0 / hyd.qexp)
		libc.fprintf(f, "\n %-31s\t%-14.6f", tc(p.node_id[i]), ke)
	}

	libc.fprintf(f, "\n\n[LEAKAGE]")
	libc.fprintf(f, "\n;;%-31s\t%-14s\t%-14s", cstring("Pipe"), cstring("Leak Area"), cstring("Leak Expansion"))
	for k in 1 ..= net.nlinks {
		if net.leak_area[k] == 0 && net.leak_expan[k] == 0 do continue
		libc.fprintf(f, "\n %-31s %14.6f %14.6f", tc(p.link_id[k]), net.leak_area[k] / u[.LENGTH], net.leak_expan[k] / u[.LENGTH])
	}

	libc.fprintf(f, "\n\n[STATUS]")
	libc.fprintf(f, "\n;;%-31s\t%-12s", cstring("ID"), cstring("Status/Setting"))
	for k in 1 ..= net.nlinks {
		if net.link_type[k] <= .PUMP {
			if net.init_status[k] == .CLOSED {
				libc.fprintf(f, "\n %-31s\t%s", tc(p.link_id[k]), tc(INP_STAT_TEXT[.CLOSED]))
			} else if net.link_type[k] == .PUMP {
				m := net.link_pump[k]
				if net.pump_hcurve[m] == 0 && net.pump_type[m] != .CONST_HP && net.init_setting[k] != 1.0 {
					libc.fprintf(f, "\n %-31s\t%-.4f", tc(p.link_id[k]), net.init_setting[k])
				}
			}
		} else {
			if net.init_status[k] == .OPEN do libc.fprintf(f, "\n %-31s\t%s", tc(p.link_id[k]), tc(INP_STAT_TEXT[.OPEN]))
			if net.init_status[k] == .CLOSED do libc.fprintf(f, "\n%-31s\t%s", tc(p.link_id[k]), tc(INP_STAT_TEXT[.CLOSED]))
		}
	}

	libc.fprintf(f, "\n\n[PATTERNS]")
	libc.fprintf(f, "\n;;%-31s\t%-12s", cstring("ID"), cstring("Multipliers"))
	for i in 1 ..< len(net.patterns) {
		if len(p.pattern_comment[i]) > 0 do libc.fprintf(f, "\n;%s", tc(p.pattern_comment[i]))
		for x, j in net.patterns[i].f {
			if j % 6 == 0 do libc.fprintf(f, "\n %-31s", tc(p.pattern_id[i]))
			libc.fprintf(f, "\t%-12.4f", x)
		}
	}

	libc.fprintf(f, "\n\n[CURVES]")
	libc.fprintf(f, "\n;;%-31s\t%-12s\t%-12s", cstring("ID"), cstring("X-Value"), cstring("Y-Value"))
	for i in 1 ..< len(net.curves) {
		cv := net.curves[i]
		if len(p.curve_comment[i]) > 0 do libc.fprintf(f, "\n;%s", tc(p.curve_comment[i]))
		if len(cv.x) > 0 {
			libc.fprintf(f, "\n %-31s\t%-12.4f\t%-12.4f\t%s", tc(p.curve_id[i]), cv.x[0], cv.y[0], tc(INP_CURVE_TYPE_TEXT[p.curve_type[i]]))
			for j in 1 ..< len(cv.x) {
				libc.fprintf(f, "\n %-31s\t%-12.4f\t%-12.4f", tc(p.curve_id[i]), cv.x[j], cv.y[j])
			}
		}
	}

	libc.fprintf(f, "\n\n[CONTROLS]")
	for ci in 1 ..= net.ncontrols {
		k := net.control_link[ci]
		if k <= 0 do continue
		lt := net.link_type[k]
		s: string
		if net.control_setting[ci] == MISSING || lt == .GPV || lt == .PIPE ||
		   (lt == .PUMP && (net.control_setting[ci] == 0 || net.control_setting[ci] == 1)) {
			s = strings.concatenate({" LINK ", p.link_id[k], " ", INP_STAT_TEXT[net.control_status[ci]], " "}, context.temp_allocator)
		} else {
			kc := net.control_setting[ci]
			#partial switch lt {
			case .PRV, .PSV, .PBV:
				kc *= u[.PRESSURE]
			case .FCV:
				kc *= u[.FLOW]
			}
			s = strings.concatenate({" LINK ", p.link_id[k], " ", fmt4(kc)}, context.temp_allocator)
		}
		switch net.control_type[ci] {
		case .LOWLEVEL, .HILEVEL:
			n := net.control_node[ci]
			kc := net.control_grade[ci] - net.el[n]
			kc *= int(n) > net.njuncs ? u[.HEAD] : u[.PRESSURE]
			libc.fprintf(f, "\n%s IF NODE %s %s %.4f", tc(s), nid(p, n), tc(INP_CONTROL_TEXT[net.control_type[ci]]), kc)
		case .TIMER:
			libc.fprintf(f, "\n%s AT %s %.4f HOURS", tc(s), tc(INP_CONTROL_TEXT[.TIMER]), f64(net.control_time[ci]) / 3600.0)
		case .TIMEOFDAY:
			libc.fprintf(f, "\n%s AT %s %s", tc(s), tc(INP_CONTROL_TEXT[.TIMEOFDAY]), tc(clocktime(&clock, net.control_time[ci])))
		}
		if !net.control_enabled[ci] do libc.fprintf(f, "  DISABLED")
	}

	libc.fprintf(f, "\n\n[RULES]")
	for ri in 1 ..= net.nrules {
		libc.fprintf(f, "\nRULE %s", tc(p.rule_label[ri]))
		write_rule(p, f, ri)
		if !net.rule_enabled[ri] do libc.fprintf(f, "\nDISABLED")
		libc.fprintf(f, "\n")
	}

	libc.fprintf(f, "\n\n[QUALITY]")
	libc.fprintf(f, "\n;;%-31s\t%-14s", cstring("ID"), cstring("InitQual"))
	for i in 1 ..= net.nnodes {
		if net.c0[i] == 0 do continue
		libc.fprintf(f, "\n %-31s\t%-14.6f", tc(p.node_id[i]), net.c0[i] * u[.QUALITY])
	}

	libc.fprintf(f, "\n\n[SOURCES]")
	libc.fprintf(f, "\n;;%-31s\t%-9s\t%-14s\t%-31s", cstring("ID"), cstring("Type"), cstring("Quality"), cstring("Pattern"))
	for i in 1 ..= net.nnodes {
		if !net.has_source[i] do continue
		pat := net.source_pat[i] > 0 ? p.pattern_id[net.source_pat[i]] : ""
		libc.fprintf(f, "\n %-31s\t%-9s\t%-14.6f\t%s", tc(p.node_id[i]), tc(INP_SOURCE_TEXT[net.source_type[i]]), net.source_c0[i], tc(pat))
	}

	libc.fprintf(f, "\n\n[MIXING]")
	libc.fprintf(f, "\n;;%-31s\t%-8s", cstring("ID"), cstring("Model"))
	for j in 1 ..= net.ntanks {
		if net.tank_area[j] == 0 do continue
		libc.fprintf(f, "\n %-31s\t%-8s\t%12.4f", nid(p, net.tank_node[j]), tc(INP_MIX_TEXT[net.tank_mix[j]]), net.tank_v1frac[j])
	}

	libc.fprintf(f, "\n\n[REACTIONS]")
	libc.fprintf(f, "\n ORDER  BULK            %-.2f", q.bulk_order)
	libc.fprintf(f, "\n ORDER  WALL            %-.0f", q.wall_order)
	libc.fprintf(f, "\n ORDER  TANK            %-.2f", q.tank_order)
	libc.fprintf(f, "\n GLOBAL BULK            %-.6f", p.kbulk * SEC_PER_DAY)
	libc.fprintf(f, "\n GLOBAL WALL            %-.6f", p.kwall * SEC_PER_DAY)
	if q.climit > 0 do libc.fprintf(f, "\n LIMITING POTENTIAL     %-.6f", q.climit * u[.QUALITY])
	if p.rfactor != MISSING && p.rfactor != 0 do libc.fprintf(f, "\n ROUGHNESS CORRELATION  %-.6f", p.rfactor)
	libc.fprintf(f, "\n\n[REACTIONS]")
	libc.fprintf(f, "\n;%-9s\t%-31s\t%-12s", cstring("Type"), cstring("Pipe/Tank"), cstring("Coefficient"))
	for k in 1 ..= net.nlinks {
		if net.link_type[k] > .PIPE do continue
		if net.link_kb[k] != p.kbulk do libc.fprintf(f, "\n %-9s\t%-31s\t%-.6f", cstring("BULK"), tc(p.link_id[k]), net.link_kb[k] * SEC_PER_DAY)
		if net.link_kw[k] != p.kwall do libc.fprintf(f, "\n %-9s\t%-31s\t%-.6f", cstring("WALL"), tc(p.link_id[k]), net.link_kw[k] * SEC_PER_DAY)
	}
	for j in 1 ..= net.ntanks {
		if net.tank_area[j] == 0 do continue
		if net.tank_kb[j] != p.kbulk do libc.fprintf(f, "\n %-9s\t%-31s\t%-.6f", cstring("TANK"), nid(p, net.tank_node[j]), net.tank_kb[j] * SEC_PER_DAY)
	}

	libc.fprintf(f, "\n\n[ENERGY]")
	if hyd.ecost != 0 do libc.fprintf(f, "\n GLOBAL PRICE        %-.4f", hyd.ecost)
	if hyd.epat != 0 do libc.fprintf(f, "\n GLOBAL PATTERN      %s", tc(p.pattern_id[hyd.epat]))
	libc.fprintf(f, "\n GLOBAL EFFIC        %-.4f", hyd.epump)
	libc.fprintf(f, "\n DEMAND CHARGE       %-.4f", p.dcost)
	for m in 1 ..= net.npumps {
		k := net.pump_link[m]
		if net.pump_ecost[m] > 0 do libc.fprintf(f, "\n PUMP %-31s PRICE   %-.4f", tc(p.link_id[k]), net.pump_ecost[m])
		if net.pump_epat[m] > 0 do libc.fprintf(f, "\n PUMP %-31s PATTERN %s", tc(p.link_id[k]), tc(p.pattern_id[net.pump_epat[m]]))
		if net.pump_ecurve[m] > 0 do libc.fprintf(f, "\n PUMP %-31s EFFIC   %s", tc(p.link_id[k]), tc(p.curve_id[net.pump_ecurve[m]]))
	}

	libc.fprintf(f, "\n\n[TIMES]")
	libc.fprintf(f, "\n DURATION            %s", tc(clocktime(&clock, t.dur)))
	libc.fprintf(f, "\n HYDRAULIC TIMESTEP  %s", tc(clocktime(&clock, t.hstep)))
	libc.fprintf(f, "\n QUALITY TIMESTEP    %s", tc(clocktime(&clock, t.qstep)))
	libc.fprintf(f, "\n REPORT TIMESTEP     %s", tc(clocktime(&clock, t.rstep)))
	libc.fprintf(f, "\n REPORT START        %s", tc(clocktime(&clock, t.rstart)))
	libc.fprintf(f, "\n PATTERN TIMESTEP    %s", tc(clocktime(&clock, t.pstep)))
	libc.fprintf(f, "\n PATTERN START       %s", tc(clocktime(&clock, t.pstart)))
	libc.fprintf(f, "\n RULE TIMESTEP       %s", tc(clocktime(&clock, t.rulestep)))
	libc.fprintf(f, "\n START CLOCKTIME     %s", tc(clocktime(&clock, t.tstart)))
	libc.fprintf(f, "\n STATISTIC           %s", tc(INP_TSTAT_TEXT[r.tstat]))

	libc.fprintf(f, "\n\n[OPTIONS]")
	libc.fprintf(f, "\n UNITS               %s", tc(INP_FLOW_UNITS_TEXT[p.flow_units]))
	libc.fprintf(f, "\n PRESSURE            %s", tc(INP_PRESSURE_UNITS_TEXT[p.pressure_units]))
	libc.fprintf(f, "\n HEADLOSS            %s", tc(INP_FORM_TEXT[hyd.formflag]))
	#partial switch p.out.hydflag {
	case .USE:
		libc.fprintf(f, "\n HYDRAULICS USE      %s", tc(p.out.hyd_fname))
	case .SAVE:
		libc.fprintf(f, "\n HYDRAULICS SAVE     %s", tc(p.out.hyd_fname))
	}
	if hyd.extra_iter == -1 do libc.fprintf(f, "\n UNBALANCED          STOP")
	if hyd.extra_iter >= 0 do libc.fprintf(f, "\n UNBALANCED          CONTINUE %d", c.int(hyd.extra_iter))
	switch q.kind {
	case .CHEM:
		libc.fprintf(f, "\n QUALITY             %s %s", tc(p.chem_name), tc(p.chem_units))
	case .TRACE:
		libc.fprintf(f, "\n QUALITY             TRACE %-31s", tc(p.node_id[q.trace_node]))
	case .AGE:
		libc.fprintf(f, "\n QUALITY             AGE")
	case .NONE:
		libc.fprintf(f, "\n QUALITY             NONE")
	}
	if net.def_pat > 0 do libc.fprintf(f, "\n PATTERN             %s", tc(p.pattern_id[net.def_pat]))
	libc.fprintf(f, "\n DEMAND MULTIPLIER   %-.4f", hyd.dmult)
	libc.fprintf(f, "\n EMITTER EXPONENT    %-.4f", 1.0 / hyd.qexp)
	libc.fprintf(f, "\n BACKFLOW ALLOWED    %s", tc(YES_NO[hyd.emit_backflow ? 1 : 0]))
	libc.fprintf(f, "\n VISCOSITY           %-.6f", hyd.viscos / VISCOS)
	libc.fprintf(f, "\n DIFFUSIVITY         %-.6f", q.diffus / DIFFUS)
	libc.fprintf(f, "\n SPECIFIC GRAVITY    %-.6f", hyd.spgrav)
	libc.fprintf(f, "\n TRIALS              %-d", c.int(hyd.max_iter))
	libc.fprintf(f, "\n ACCURACY            %-.8f", hyd.hacc)
	libc.fprintf(f, "\n TOLERANCE           %-.8f", q.ctol * u[.QUALITY])
	libc.fprintf(f, "\n CHECKFREQ           %-d", c.int(hyd.check_freq))
	libc.fprintf(f, "\n MAXCHECK            %-d", c.int(hyd.max_check))
	libc.fprintf(f, "\n DAMPLIMIT           %-.8f", hyd.damp_limit)
	if hyd.head_error_limit > 0 do libc.fprintf(f, "\n HEADERROR           %-.8f", hyd.head_error_limit * u[.HEAD])
	if hyd.flow_change_limit > 0 do libc.fprintf(f, "\n FLOWCHANGE          %-.8f", hyd.flow_change_limit * u[.FLOW])
	if hyd.demand_model == .PDA {
		libc.fprintf(f, "\n DEMAND MODEL        PDA")
		libc.fprintf(f, "\n MINIMUM PRESSURE    %-.4f", hyd.pmin * u[.PRESSURE])
		libc.fprintf(f, "\n REQUIRED PRESSURE   %-.4f", hyd.preq * u[.PRESSURE])
		libc.fprintf(f, "\n PRESSURE EXPONENT   %-.4f", hyd.pexp)
	}

	libc.fprintf(f, "\n\n[REPORT]")
	libc.fprintf(f, "\n PAGESIZE            %d", c.int(r.page_size))
	libc.fprintf(f, "\n STATUS              %s", tc(r.status == 2 ? "FULL" : YES_NO[r.status]))
	libc.fprintf(f, "\n SUMMARY             %s", tc(YES_NO[r.summary ? 1 : 0]))
	libc.fprintf(f, "\n ENERGY              %s", tc(YES_NO[r.energy ? 1 : 0]))
	libc.fprintf(f, "\n MESSAGES            %s", tc(YES_NO[r.messages ? 1 : 0]))
	if len(r.rpt2_fname) > 0 do libc.fprintf(f, "\n FILE                %s", tc(r.rpt2_fname))
	switch r.nodes {
	case 0:
		libc.fprintf(f, "\n NODES               NONE")
	case 1:
		libc.fprintf(f, "\n NODES               ALL")
	case:
		j := 0
		for i in 1 ..= net.nnodes {
			if !p.node_rpt[i] do continue
			if j % 5 == 0 do libc.fprintf(f, "\n NODES               ")
			libc.fprintf(f, "%s ", tc(p.node_id[i]))
			j += 1
		}
	}
	switch r.links {
	case 0:
		libc.fprintf(f, "\n LINKS               NONE")
	case 1:
		libc.fprintf(f, "\n LINKS               ALL")
	case:
		j := 0
		for k in 1 ..= net.nlinks {
			if !p.link_rpt[k] do continue
			if j % 5 == 0 do libc.fprintf(f, "\n LINKS               ")
			libc.fprintf(f, "%s ", tc(p.link_id[k]))
			j += 1
		}
	}
	for fld in Field.ELEV ..< Field.FRICTION {
		field := &r.fields[fld]
		if field.enabled {
			libc.fprintf(f, "\n %-20sPRECISION %d", tc(field.name), c.int(field.precision))
			if field.lo < BIG do libc.fprintf(f, "\n %-20sBELOW %.6f", tc(field.name), field.lo)
			if field.hi > -BIG do libc.fprintf(f, "\n %-20sABOVE %.6f", tc(field.name), field.hi)
		} else {
			libc.fprintf(f, "\n %-20sNO", tc(field.name))
		}
	}

	libc.fprintf(f, "\n\n[TAGS]")
	libc.fprintf(f, "\n;;%-8s\t%-31s\t%s", cstring("Object"), cstring("ID"), cstring("Tag"))
	for i in 1 ..= net.nnodes {
		if len(p.node_tag[i]) == 0 do continue
		libc.fprintf(f, "\n %-8s\t%-31s\t%s", cstring("NODE"), tc(p.node_id[i]), tc(p.node_tag[i]))
	}
	for k in 1 ..= net.nlinks {
		if len(p.link_tag[k]) == 0 do continue
		libc.fprintf(f, "\n %-8s\t%-31s\t%s", cstring("LINK"), tc(p.link_id[k]), tc(p.link_tag[k]))
	}

	libc.fprintf(f, "\n\n[COORDINATES]")
	libc.fprintf(f, "\n;;%-31s\t%-14s\t%-14s", cstring("ID"), cstring("X-Coord"), cstring("Y-Coord"))
	for i in 1 ..= net.nnodes {
		if p.node_x[i] == MISSING || p.node_y[i] == MISSING do continue
		libc.fprintf(f, "\n %-31s\t%-14.6f\t%-14.6f", tc(p.node_id[i]), p.node_x[i], p.node_y[i])
	}

	libc.fprintf(f, "\n\n[VERTICES]")
	libc.fprintf(f, "\n;;%-31s\t%-14s\t%-14s", cstring("ID"), cstring("X-Coord"), cstring("Y-Coord"))
	for k in 1 ..= net.nlinks {
		for x, j in p.vertex_x[k] {
			libc.fprintf(f, "\n %-31s\t%-14.6f\t%-14.6f", tc(p.link_id[k]), x, p.vertex_y[k][j])
		}
	}

	libc.fprintf(f, "\n")
	save_aux_data(p, f)
	libc.fprintf(f, "\n%s\n", cstring("[END]"))
	return 0
}

// fmt4: x as %.4f.
fmt4 :: proc(x: f64) -> string {
	buf: [64]u8
	n := libc.snprintf(raw_data(buf[:]), len(buf), "%.4f", x)
	return strings.clone(string(buf[:n]), context.temp_allocator)
}

// save_aux_data copies the [LABELS] and [BACKDROP] sections of the file
// the project was read from, line for line.
save_aux_data :: proc(p: ^Project, f: ^libc.FILE) {
	if len(p.inp_fname) == 0 do return
	in_file := libc.fopen(tc(p.inp_fname), "rt")
	if in_file == nil do return
	defer libc.fclose(in_file)
	sect := -1
	line: [MAXLINE + 1]u8
	for libc.fgets(&line[0], MAXLINE, in_file) != nil {
		s := string(cstring(&line[0]))
		tok := first_token(s)
		if len(tok) == 0 do continue
		if tok[0] == '[' {
			newsect := findmatch(tok, SECTION_NAMES[:])
			if newsect >= 0 {
				sect = newsect
				if Section(sect) == .END do break
				if Section(sect) == .LABELS || Section(sect) == .BACKDROP do libc.fprintf(f, "\n%s", cstring(&line[0]))
			}
		} else if sect == int(Section.LABELS) || sect == int(Section.BACKDROP) {
			libc.fprintf(f, "%s", cstring(&line[0]))
		}
	}
}

// write_rule writes rule r's clauses (rules.c writerule).
write_rule :: proc(p: ^Project, f: ^libc.FILE, r: int) {
	net := &p.net
	libc.fprintf(f, "\nIF   ")
	for k in net.rule_premise_first[r] ..< net.rule_premise_first[r + 1] {
		if k > net.rule_premise_first[r] do libc.fprintf(f, "\n%-5s", tc(INP_RULE_WORD[net.premise_logop[k]]))
		write_premise(p, f, int(k))
	}
	if net.rule_then_first[r] < net.rule_else_first[r] do libc.fprintf(f, "\nTHEN ")
	for k in net.rule_then_first[r] ..< net.rule_else_first[r] {
		if k > net.rule_then_first[r] do libc.fprintf(f, "\nAND  ")
		write_action(p, f, int(k))
	}
	if net.rule_else_first[r] < net.rule_then_first[r + 1] do libc.fprintf(f, "\nELSE ")
	for k in net.rule_else_first[r] ..< net.rule_then_first[r + 1] {
		if k > net.rule_else_first[r] do libc.fprintf(f, "\nAND  ")
		write_action(p, f, int(k))
	}
	if net.rule_priority[r] > 0 do libc.fprintf(f, "\nPRIORITY %f", net.rule_priority[r])
}

rule_object_text :: proc "contextless" (p: ^Project, object: Rule_Object, index: i32) -> string {
	net := &p.net
	#partial switch object {
	case .NODE:
		switch node_type_of(net, int(index)) {
		case 0:
			return "JUNCTION"
		case 1:
			return "RESERVOIR"
		case 2:
			return "TANK"
		}
		return "NODE"
	case .LINK:
		#partial switch net.link_type[index] {
		case .CVPIPE, .PIPE:
			return "PIPE"
		case .PUMP:
			return "PUMP"
		}
		return "VALVE"
	}
	return "SYSTEM"
}

// time_text: seconds as h:mm:ss, or hours past a week.
time_text :: proc(secs: f64) -> string {
	buf: [64]u8
	hours := int(secs) / 3600
	n: c.int
	if hours > 24 * 7 {
		n = libc.snprintf(raw_data(buf[:]), len(buf), "%.4f", secs / 3600.0)
	} else {
		minutes := int((secs - f64(3600 * hours)) / 60)
		seconds := int(secs - f64(3600 * hours) - f64(minutes * 60))
		n = libc.snprintf(raw_data(buf[:]), len(buf), "%d:%02d:%02d", c.int(hours), c.int(minutes), c.int(seconds))
	}
	return strings.clone(string(buf[:n]), context.temp_allocator)
}

write_premise :: proc(p: ^Project, f: ^libc.FILE, k: int) {
	net := &p.net
	obj, id: string
	#partial switch net.premise_object[k] {
	case .NODE:
		obj = rule_object_text(p, .NODE, net.premise_index[k])
		id = p.node_id[net.premise_index[k]]
	case .LINK:
		obj = rule_object_text(p, .LINK, net.premise_index[k])
		id = p.link_id[net.premise_index[k]]
	case:
		obj = "SYSTEM"
		id = ""
	}
	value: string
	if net.premise_value[k] == MISSING {
		value = INP_RULE_VALUE[net.premise_status[k]]
	} else {
		#partial switch net.premise_variable[k] {
		case .CLOCKTIME, .DRAINTIME, .FILLTIME, .TIME:
			value = time_text(net.premise_value[k])
		case:
			value = fmt4(net.premise_value[k])
		}
	}
	libc.fprintf(f, "%s %s %s %s %s", tc(obj), tc(id), tc(INP_RULE_VARIABLE[net.premise_variable[k]]),
		tc(INP_RULE_OPERATOR[net.premise_relop[k]]), tc(value))
}

write_action :: proc(p: ^Project, f: ^libc.FILE, k: int) {
	net := &p.net
	link := net.action_link[k]
	obj := rule_object_text(p, .LINK, link)
	if net.action_setting[k] == MISSING {
		libc.fprintf(f, "%s %s STATUS = %s", tc(obj), tc(p.link_id[link]), tc(INP_RULE_VALUE[net.action_status[k]]))
	} else {
		libc.fprintf(f, "%s %s SETTING = %s", tc(obj), tc(p.link_id[link]), tc(fmt4(net.action_setting[k])))
	}
}
