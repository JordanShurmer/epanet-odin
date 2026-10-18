#+build !wasm32
package epanet

// report.odin — the report file (EPANET's report.c): the logo, the input
// summary, the hydraulic status lines, the warnings, the energy table and
// the results tables read back from the output file. Every line goes
// through writeline, which counts lines and pages. Text is laid out with
// the C library's formatting, so EPANET's report and this one are the
// same bytes. These run from inside the engine, so they take no context:
// scratch memory is the C library's.

import "core:c"
import "core:c/libc"

MAXCOUNT :: 10 // disconnected nodes listed before "and N more"
CODEVERSION :: 20305

Header_Kind :: enum {
	STATHDR,
	ENERHDR,
	NODEHDR,
	LINKHDR,
}

// ── numbers, through the C library's formats ─────────────────────────

// putf / puti append one number through the C library's format.
putf :: proc "contextless" (l: ^Line, format: cstring, x: f64) {
	n := int(libc.snprintf(raw_data(l.buf[l.n:]), c.size_t(MAXLINE + 1 - l.n), format, x))
	l.n = min(l.n + n, MAXLINE)
}
puti :: proc "contextless" (l: ^Line, format: cstring, x: int) {
	n := int(libc.snprintf(raw_data(l.buf[l.n:]), c.size_t(MAXLINE + 1 - l.n), format, c.int(x)))
	l.n = min(l.n + n, MAXLINE)
}
// putfp: %w.*f, the precision given at run time.
putfp :: proc "contextless" (l: ^Line, prec: int, x: f64) {
	n := int(libc.snprintf(raw_data(l.buf[l.n:]), c.size_t(MAXLINE + 1 - l.n), "%10.*f", c.int(prec), x))
	l.n = min(l.n + n, MAXLINE)
}

// cputs: a NUL-terminated string to the file (fputs).
cputs :: proc "contextless" (s: cstring, f: ^libc.FILE) -> int {
	return int(libc.fwrite(rawptr(s), 1, len(s), f))
}

// cstr: a C string as an Odin string.
cstr :: #force_inline proc "contextless" (s: [^]u8) -> string {
	return string(cstring(s))
}

// ── the file ──────────────────────────────────────────────────────────

// writeline puts one line in the report, with the page header when a
// page is full.
writeline :: proc "contextless" (p: ^Project, s: string) {
	r := &p.rpt
	if r.callback != nil {
		buf: [MAXLINE + 1]u8
		n := min(len(s), MAXLINE)
		copy(buf[:n], s[:n])
		buf[n] = 0
		r.callback(r.callback_user, p, cstring(raw_data(buf[:])))
		return
	}
	if r.file == nil do return
	if r.rptflag && r.line_num == r.page_size {
		r.page_num += 1
		t: Line
		puts(&t, "\n\f\n  Page ")
		puti(&t, "%-d", r.page_num)
		puts(&t, "    ")
		puts_left(&t, p.title[0], 60, 60)
		puts(&t, "\n")
		if cputs(cstring(raw_data(t.buf[:])), r.file) < t.n do r.fprinterr = true
		r.line_num = 3
	}
	if cputs("\n  ", r.file) < 3 do r.fprinterr = true
	if len(s) > 0 && libc.fwrite(raw_data(s), 1, c.size_t(len(s)), r.file) < c.size_t(len(s)) do r.fprinterr = true
	r.line_num += 1
}

writelogo :: proc "contextless" (p: ^Project) {
	r := &p.rpt
	r.page_num = 1
	r.line_num = 2
	timer := libc.time(nil)
	cputs("  Page 1                                    ", r.file)
	cputs(cstring(libc.ctime(&timer)), r.file)
	writeline(p, "******************************************************************")
	writeline(p, "*                           E P A N E T                          *")
	writeline(p, "*                   Hydraulic and Water Quality                  *")
	writeline(p, "*                   Analysis for Pipe Networks                   *")
	l: Line
	puts(&l, "*                          Version ")
	puti(&l, "%d", CODEVERSION / 10000)
	puts(&l, ".")
	puti(&l, "%d", (CODEVERSION % 10000) / 100)
	puts(&l, ".")
	puti(&l, "%02d", CODEVERSION % 100)
	puts(&l, "                        *")
	writeline(p, line_str(&l))
	writeline(p, "******************************************************************")
	writeline(p, "")
}

// clearreport starts the report file over.
clearreport :: proc "contextless" (p: ^Project) -> int {
	r := &p.rpt
	if r.file == nil do return 0
	buf: [1024]u8
	n := min(len(r.rpt1_fname), 1023)
	copy(buf[:n], r.rpt1_fname)
	buf[n] = 0
	if libc.freopen(cstring(raw_data(buf[:])), "w", r.file) == nil do return 303
	writelogo(p)
	return 0
}

// writetime: "Analysis begun/ended <date>".
writetime :: proc "contextless" (p: ^Project, prefix: string) {
	timer := libc.time(nil)
	l: Line
	puts(&l, prefix)
	puts(&l, cstr(libc.ctime(&timer)))
	writeline(p, line_str(&l))
}

// errmsg writes "Error N: message" when messages are on.
errmsg :: proc "contextless" (p: ^Project, errcode: int) {
	if errcode == 309 do return // the report file itself failed
	if p.rpt.file != nil && p.rpt.messages && errcode > 100 {
		l: Line
		puts(&l, "Error ")
		puti(&l, "%d", errcode)
		puts(&l, ": ")
		puts(&l, error_message(errcode))
		writeline(p, line_str(&l))
	}
}

// ── the summary ───────────────────────────────────────────────────────

summary_line :: proc "contextless" (p: ^Project, l: ^Line, label: string) {
	line_reset(l)
	puts(l, label)
}

writesummary :: proc "contextless" (p: ^Project) {
	net, hyd, q, r, t := &p.net, &p.hyd, &p.q, &p.rpt, &p.times
	l: Line
	for i in 0 ..< 3 {
		if len(p.title[i]) > 0 {
			line_reset(&l)
			puts(&l, p.title[i], 70)
			writeline(p, line_str(&l))
		}
	}
	writeline(p, " ")
	summary_line(p, &l, "    Input Data File ................... ")
	puts(&l, p.inp_fname)
	writeline(p, line_str(&l))
	summary_line(p, &l, "    Number of Junctions................ ")
	puti(&l, "%-d", net.njuncs)
	writeline(p, line_str(&l))
	nres := 0
	for i in 1 ..= net.ntanks do if net.tank_area[i] == 0 do nres += 1
	summary_line(p, &l, "    Number of Reservoirs............... ")
	puti(&l, "%-d", nres)
	writeline(p, line_str(&l))
	summary_line(p, &l, "    Number of Tanks ................... ")
	puti(&l, "%-d", net.ntanks - nres)
	writeline(p, line_str(&l))
	summary_line(p, &l, "    Number of Pipes ................... ")
	puti(&l, "%-d", net.nlinks - net.npumps - net.nvalves)
	writeline(p, line_str(&l))
	summary_line(p, &l, "    Number of Pumps ................... ")
	puti(&l, "%-d", net.npumps)
	writeline(p, line_str(&l))
	summary_line(p, &l, "    Number of Valves .................. ")
	puti(&l, "%-d", net.nvalves)
	writeline(p, line_str(&l))
	summary_line(p, &l, "    Headloss Formula .................. ")
	puts(&l, FORMULA_TEXT[hyd.formflag])
	writeline(p, line_str(&l))
	summary_line(p, &l, "    Nodal Demand Model ................ ")
	puts(&l, DEMAND_MODEL_TEXT[hyd.demand_model])
	writeline(p, line_str(&l))
	summary_line(p, &l, "    Hydraulic Timestep ................ ")
	putf(&l, "%-.2f", f64(t.hstep) * p.ucf[.TIME])
	puts(&l, " ")
	puts(&l, r.fields[.TIME].units)
	writeline(p, line_str(&l))
	summary_line(p, &l, "    Hydraulic Accuracy ................ ")
	putf(&l, "%-.6f", hyd.hacc)
	writeline(p, line_str(&l))
	if hyd.head_error_limit > 0 {
		summary_line(p, &l, "    Headloss Error Limit .............. ")
		putf(&l, "%-.6f", hyd.head_error_limit * p.ucf[.HEAD])
		puts(&l, " ")
		puts(&l, r.fields[.HEAD].units)
		writeline(p, line_str(&l))
	}
	if hyd.flow_change_limit > 0 {
		summary_line(p, &l, "    Flow Change Limit ................. ")
		putf(&l, "%-.6f", hyd.flow_change_limit * p.ucf[.FLOW])
		puts(&l, " ")
		puts(&l, r.fields[.FLOW].units)
		writeline(p, line_str(&l))
	}
	summary_line(p, &l, "    Status Check Frequency ............ ")
	puti(&l, "%-d", hyd.check_freq)
	writeline(p, line_str(&l))
	summary_line(p, &l, "    Maximum Trials Checked ............ ")
	puti(&l, "%-d", hyd.max_check)
	writeline(p, line_str(&l))
	summary_line(p, &l, "    Damping Limit Threshold ........... ")
	putf(&l, "%-.6f", hyd.damp_limit)
	writeline(p, line_str(&l))
	summary_line(p, &l, "    Maximum Trials .................... ")
	puti(&l, "%-d", hyd.max_iter)
	writeline(p, line_str(&l))

	if q.kind == .NONE || t.dur == 0 {
		summary_line(p, &l, "    Quality Analysis .................. None")
	} else if q.kind == .CHEM {
		summary_line(p, &l, "    Quality Analysis .................. ")
		puts(&l, p.chem_name)
	} else if q.kind == .TRACE {
		summary_line(p, &l, "    Quality Analysis .................. Trace From Node ")
		puts(&l, p.node_id[q.trace_node])
	} else if q.kind == .AGE {
		summary_line(p, &l, "    Quality Analysis .................. Age")
	}
	writeline(p, line_str(&l))
	if q.kind != .NONE && t.dur > 0 {
		summary_line(p, &l, "    Water Quality Time Step ........... ")
		putf(&l, "%-.2f", f64(f32(t.qstep)) / 60.0)
		puts(&l, " min")
		writeline(p, line_str(&l))
		summary_line(p, &l, "    Water Quality Tolerance ........... ")
		putf(&l, "%-.2f", q.ctol * p.ucf[.QUALITY])
		puts(&l, " ")
		puts(&l, r.fields[.QUALITY].units)
		writeline(p, line_str(&l))
	}
	summary_line(p, &l, "    Specific Gravity .................. ")
	putf(&l, "%-.2f", hyd.spgrav)
	writeline(p, line_str(&l))
	summary_line(p, &l, "    Relative Kinematic Viscosity ...... ")
	putf(&l, "%-.2f", hyd.viscos / VISCOS)
	writeline(p, line_str(&l))
	summary_line(p, &l, "    Relative Chemical Diffusivity ..... ")
	putf(&l, "%-.2f", q.diffus / DIFFUS)
	writeline(p, line_str(&l))
	summary_line(p, &l, "    Demand Multiplier ................. ")
	putf(&l, "%-.2f", hyd.dmult)
	writeline(p, line_str(&l))
	summary_line(p, &l, "    Total Duration .................... ")
	putf(&l, "%-.2f", f64(t.dur) * p.ucf[.TIME])
	puts(&l, " ")
	puts(&l, r.fields[.TIME].units)
	writeline(p, line_str(&l))

	if r.rptflag {
		writeline(p, "    Reporting Criteria:")
		switch r.nodes {
		case 0:
			writeline(p, "       No Nodes")
		case 1:
			writeline(p, "       All Nodes")
		case 2:
			writeline(p, "       Selected Nodes")
		}
		writelimits(p, .DEMAND, .QUALITY)
		switch r.links {
		case 0:
			writeline(p, "       No Links")
		case 1:
			writeline(p, "       All Links")
		case 2:
			writeline(p, "       Selected Links")
		}
		writelimits(p, .DIAM, .HEADLOSS)
	}
	writeline(p, " ")
}

writelimits :: proc "contextless" (p: ^Project, j1, j2: Field) {
	l: Line
	for j in j1 ..= j2 {
		f := &p.rpt.fields[j]
		if f.lo < BIG {
			line_reset(&l)
			puts(&l, "       with ")
			puts(&l, f.name)
			puts(&l, " below ")
			putf(&l, "%-.2f", f.lo)
			puts(&l, " ")
			puts(&l, f.units)
			writeline(p, line_str(&l))
		}
		if f.hi > -BIG {
			line_reset(&l)
			puts(&l, "       with ")
			puts(&l, f.name)
			puts(&l, " above ")
			putf(&l, "%-.2f", f.hi)
			puts(&l, " ")
			puts(&l, f.units)
			writeline(p, line_str(&l))
		}
	}
}

// ── the status report ─────────────────────────────────────────────────

// time_prefix: "%10s: " with the clock time.
time_prefix :: proc "contextless" (l: ^Line, p: ^Project) {
	buf: [16]u8
	line_reset(l)
	puts_right(l, clocktime(&buf, p.times.htime), 10)
	puts(l, ": ")
}

writehydstat :: proc "contextless" (p: ^Project, iter: int, relerr: f64) {
	net, hyd, r, t := &p.net, &p.hyd, &p.rpt, &p.times
	l: Line
	abuf: [16]u8
	atime := clocktime(&abuf, t.htime)
	if iter > 0 {
		line_reset(&l)
		puts_right(&l, atime, 10)
		if relerr <= hyd.hacc {
			puts(&l, ": Balanced after ")
			puti(&l, "%-d", iter)
			puts(&l, " trials")
		} else {
			puts(&l, ": Unbalanced after ")
			puti(&l, "%-d", iter)
			puts(&l, " trials (flow change = ")
			putf(&l, "%-.6f", relerr)
			puts(&l, ")")
		}
		writeline(p, line_str(&l))
		if hyd.demand_model == .PDA && hyd.deficient_nodes > 0 {
			line_reset(&l)
			if hyd.deficient_nodes == 1 {
				puts(&l, "            1 node had its demand reduced by a total of ")
				putf(&l, "%.2f", hyd.demand_reduction)
				puts(&l, "%")
			} else {
				puts(&l, "            ")
				puti(&l, "%-d", hyd.deficient_nodes)
				puts(&l, " nodes had demands reduced by a total of ")
				putf(&l, "%.2f", hyd.demand_reduction)
				puts(&l, "%")
			}
			writeline(p, line_str(&l))
		}
	}
	// Tanks: the net inflow says filling, emptying or neither.
	for i in 1 ..= net.ntanks {
		n := int(net.tank_node[i])
		d := hyd.node_demand[n]
		newstat: Status
		if abs(d) < 0.001 {
			newstat = .CLOSED
		} else if d < 0 {
			newstat = .EMPTYING
		} else if d > 0 {
			if net.tank_area[i] > 0 && abs(hyd.head[n] - net.tank_hmax[i]) < 0.001 {
				newstat = .OVERFLOWING
			} else {
				newstat = .FILLING
			}
		} else {
			newstat = hyd.old_status[net.nlinks + i]
		}
		if newstat != hyd.old_status[net.nlinks + i] {
			line_reset(&l)
			puts_right(&l, atime, 10)
			if net.tank_area[i] > 0 {
				puts(&l, ": Tank ")
				puts(&l, p.node_id[n])
				puts(&l, " is ")
				puts(&l, STATUS_TEXT[newstat])
				puts(&l, " at ")
				putf(&l, "%-.2f", (hyd.head[n] - net.el[n]) * p.ucf[.HEAD])
				puts(&l, " ")
				puts(&l, r.fields[.HEAD].units)
			} else {
				puts(&l, ": Reservoir ")
				puts(&l, p.node_id[n])
				puts(&l, " is ")
				puts(&l, STATUS_TEXT[newstat])
			}
			writeline(p, line_str(&l))
			hyd.old_status[net.nlinks + i] = newstat
		}
	}
	for i in 1 ..= net.nlinks {
		if hyd.status[i] != hyd.old_status[i] {
			line_reset(&l)
			puts_right(&l, atime, 10)
			puts(&l, ": ")
			puts(&l, LINK_TEXT[net.link_type[i]])
			puts(&l, " ")
			puts(&l, p.link_id[i])
			if t.htime == 0 {
				puts(&l, " ")
				puts(&l, STATUS_TEXT[hyd.status[i]])
			} else {
				puts(&l, " changed from ")
				puts(&l, STATUS_TEXT[hyd.old_status[i]])
				puts(&l, " to ")
				puts(&l, STATUS_TEXT[hyd.status[i]])
			}
			writeline(p, line_str(&l))
			hyd.old_status[i] = hyd.status[i]
		}
	}
	writeline(p, " ")
}

balance_line :: proc "contextless" (p: ^Project, label: string, x: f64) {
	l: Line
	puts(&l, label)
	putf(&l, "%12.3f", x)
	writeline(p, line_str(&l))
}

writeflowbalance :: proc "contextless" (p: ^Project) {
	fb := p.hyd.flow_balance
	ucf := p.ucf[.FLOW]
	l: Line
	puts(&l, "Hydraulic Flow Balance (")
	puts(&l, p.rpt.fields[.DEMAND].units)
	puts(&l, ")")
	writeline(p, line_str(&l))
	writeline(p, "================================")
	balance_line(p, "Total Inflow:      ", fb.total_inflow * ucf)
	balance_line(p, "Consumer Demand:   ", fb.consumer_demand * ucf)
	balance_line(p, "Demand Deficit:    ", fb.deficit_demand * ucf)
	balance_line(p, "Emitter Flow:      ", fb.emitter_demand * ucf)
	balance_line(p, "Leakage Flow:      ", fb.leakage_demand * ucf)
	balance_line(p, "Total Outflow:     ", fb.total_outflow * ucf)
	balance_line(p, "Storage Flow:      ", fb.storage_demand * ucf)
	balance_line(p, "Flow Ratio:        ", fb.ratio)
	writeline(p, "================================\n")
}

mass_line :: proc "contextless" (p: ^Project, label: string, x: f64) {
	l: Line
	puts(&l, label)
	putf(&l, "%12.5e", x)
	writeline(p, line_str(&l))
}

writemassbalance :: proc "contextless" (p: ^Project) {
	q := &p.q
	units := [?]string{"", " (mg)", " (ug)", " (hrs)"}
	k := 0
	if q.kind == .TRACE {
		k = 1
	} else if q.kind == .AGE {
		k = 3
	} else if match(p.chem_units, "mg") {
		k = 1
	} else if match(p.chem_units, "ug") {
		k = 2
	}
	l: Line
	puts(&l, "Water Quality Mass Balance")
	puts(&l, units[k])
	writeline(p, line_str(&l))
	writeline(p, "================================")
	mass_line(p, "Initial Mass:      ", q.balance.initial)
	mass_line(p, "Mass Inflow:       ", q.balance.inflow)
	mass_line(p, "Mass Outflow:      ", q.balance.outflow)
	mass_line(p, "Mass Reacted:      ", q.balance.reacted)
	mass_line(p, "Final Mass:        ", q.balance.final)
	line_reset(&l)
	puts(&l, "Mass Ratio:         ")
	putf(&l, "%-.5f", q.balance.ratio)
	writeline(p, line_str(&l))
	line_reset(&l)
	puts(&l, "Total Segments:     ")
	puti(&l, "%d", q.balance.seg_count)
	writeline(p, line_str(&l))
	writeline(p, "================================\n")
}

writerelerr :: proc "contextless" (p: ^Project, iter: int, relerr: f64) {
	l: Line
	if iter == 0 {
		time_prefix(&l, p)
		puts(&l, "Balancing the network:\n")
	} else {
		puts(&l, "            Trial ")
		puti(&l, "%2d", iter)
		puts(&l, ": relative flow change = ")
		putf(&l, "%-.6f", relerr)
	}
	writeline(p, line_str(&l))
}

// writehydbal: the largest flow and head imbalances of a converged trial.
writehydbal :: proc "contextless" (p: ^Project, qchange, herror: f64, qlink, qnode, hlink: int) {
	l: Line
	if qlink >= 1 {
		puts(&l, "                      maximum  flow change = ")
		putf(&l, "%.4f", qchange)
		puts(&l, " for Link ")
		puts(&l, p.link_id[qlink])
		writeline(p, line_str(&l))
	} else if qnode >= 1 {
		puts(&l, "                      maximum  flow change = ")
		putf(&l, "%.4f", qchange)
		puts(&l, " for Node ")
		puts(&l, p.node_id[qnode])
		writeline(p, line_str(&l))
	}
	if hlink >= 1 {
		line_reset(&l)
		puts(&l, "                      maximum  head error  = ")
		putf(&l, "%.4f", herror)
		puts(&l, " for Link ")
		puts(&l, p.link_id[hlink])
		puts(&l, "\n")
		writeline(p, line_str(&l))
	}
}

writebadvalve :: proc "contextless" (p: ^Project, k: int) {
	l: Line
	time_prefix(&l, p)
	puts(&l, "Valve ")
	puts(&l, p.link_id[k])
	puts(&l, " caused ill-conditioning")
	writeline(p, line_str(&l))
}

writestatchange :: proc "contextless" (p: ^Project, k: int, s1, s2: Status) {
	net, hyd := &p.net, &p.hyd
	l: Line
	// the same status: a setting changed
	if s1 == s2 {
		setting := hyd.setting[k]
		#partial switch net.link_type[k] {
		case .PRV, .PSV, .PBV:
			setting *= p.ucf[.PRESSURE]
		case .FCV:
			setting *= p.ucf[.FLOW]
		}
		puts(&l, "            ")
		puts(&l, LINK_TEXT[net.link_type[k]])
		puts(&l, " ")
		puts(&l, p.link_id[k])
		puts(&l, " setting changed to ")
		putf(&l, "%-.2f", setting)
		writeline(p, line_str(&l))
		return
	}
	j1 := s1 == .ACTIVE ? Status.ACTIVE : s1 <= .CLOSED ? Status.CLOSED : Status.OPEN
	j2 := s2 == .ACTIVE ? Status.ACTIVE : s2 <= .CLOSED ? Status.CLOSED : Status.OPEN
	if j1 != j2 {
		puts(&l, "            ")
		puts(&l, LINK_TEXT[net.link_type[k]])
		puts(&l, " ")
		puts(&l, p.link_id[k])
		puts(&l, " switched from ")
		puts(&l, STATUS_TEXT[j1])
		puts(&l, " to ")
		puts(&l, STATUS_TEXT[j2])
		writeline(p, line_str(&l))
	}
}

writecontrolaction :: proc "contextless" (p: ^Project, k, i: int) {
	net := &p.net
	l: Line
	switch net.control_type[i] {
	case .LOWLEVEL, .HILEVEL:
		n := int(net.control_node[i])
		time_prefix(&l, p)
		puts(&l, LINK_TEXT[net.link_type[k]])
		puts(&l, " ")
		puts(&l, p.link_id[k])
		puts(&l, " changed by ")
		puts(&l, NODE_TEXT[node_type_of(net, n)])
		puts(&l, " ")
		puts(&l, p.node_id[n])
		puts(&l, " control")
	case .TIMER, .TIMEOFDAY:
		time_prefix(&l, p)
		puts(&l, LINK_TEXT[net.link_type[k]])
		puts(&l, " ")
		puts(&l, p.link_id[k])
		puts(&l, " changed by timer control")
	}
	writeline(p, line_str(&l))
}

writeruleaction :: proc "contextless" (p: ^Project, k: int, rule_id: string) {
	l: Line
	time_prefix(&l, p)
	puts(&l, LINK_TEXT[p.net.link_type[k]])
	puts(&l, " ")
	puts(&l, p.link_id[k])
	puts(&l, " changed by rule ")
	puts(&l, rule_id)
	writeline(p, line_str(&l))
}

// writehydwarn: the warnings of a solved period, in EPANET's order; the
// code of the last one found is the period's warning code.
writehyderr :: proc "contextless" (p: ^Project, errnode: int) {
	if p.rpt.messages {
		l: Line
		time_prefix(&l, p)
		puts(&l, "System ill-conditioned at node ")
		puts(&l, p.node_id[errnode])
		writeline(p, line_str(&l))
	}
	writehydstat(p, 0, 0)
	disconnected(p)
}

// disconnected counts the junctions with demand that no open path joins
// to a tank, and names the first of them and a closed link in the way.
disconnected :: proc "contextless" (p: ^Project) -> int {
	net, hyd, r := &p.net, &p.hyd, &p.rpt
	nn := net.nnodes + 1
	nodelist := ([^]i32)(libc.calloc(c.size_t(nn), size_of(i32)))
	marked := ([^]u8)(libc.calloc(c.size_t(nn), 1))
	if nodelist == nil || marked == nil {
		libc.free(nodelist)
		libc.free(marked)
		return 0
	}
	defer libc.free(nodelist)
	defer libc.free(marked)

	for i in 1 ..= net.ntanks {
		j := net.njuncs + i
		nodelist[i] = i32(j)
		marked[j] = 1
	}
	mcount := net.ntanks
	for i in 1 ..= net.njuncs {
		if hyd.node_demand[i] < 0 {
			mcount += 1
			nodelist[mcount] = i32(i)
			marked[i] = 1
		}
	}
	marknodes(p, mcount, nodelist, marked)
	j := 0
	count := 0
	l: Line
	abuf: [16]u8
	for i in 1 ..= net.njuncs {
		if marked[i] == 0 && hyd.node_demand[i] != 0 {
			count += 1
			if count <= MAXCOUNT && r.messages {
				line_reset(&l)
				puts(&l, "WARNING: Node ")
				puts(&l, p.node_id[i])
				puts(&l, " disconnected at ")
				puts(&l, clocktime(&abuf, p.times.htime))
				puts(&l, " hrs")
				writeline(p, line_str(&l))
			}
			j = i
		}
	}
	if count > 0 && r.messages {
		if count > MAXCOUNT {
			line_reset(&l)
			puts(&l, "WARNING: ")
			puti(&l, "%d", count - MAXCOUNT)
			puts(&l, " additional nodes disconnected at ")
			puts(&l, clocktime(&abuf, p.times.htime))
			puts(&l, " hrs")
			writeline(p, line_str(&l))
		}
		getclosedlink(p, j, marked, nodelist)
	}
	return count
}

// marknodes marks every node reachable from the listed ones through open
// links, in the direction a check valve or pressure valve allows.
marknodes :: proc "contextless" (p: ^Project, m0: int, nodelist: [^]i32, marked: [^]u8) {
	net, hyd := &p.net, &p.hyd
	m := m0
	n := 1
	for n <= m {
		i := int(nodelist[n])
		for a in net.adj_first[i] ..< net.adj_first[i + 1] {
			k := int(net.adj_link[a])
			j := int(net.adj_node[a])
			if marked[j] != 0 do continue
			#partial switch net.link_type[k] {
			case .CVPIPE, .PRV, .PSV:
				if j == int(net.n1[k]) do continue
			}
			if hyd.status[k] > .CLOSED {
				marked[j] = 1
				m += 1
				nodelist[m] = i32(j)
			}
		}
		n += 1
	}
}

// getclosedlink walks out from junction i to the first marked node and
// names the link that reaches it: a closed one, which cut i off.
getclosedlink :: proc "contextless" (p: ^Project, i0: int, marked: [^]u8, stack: [^]i32) {
	net := &p.net
	top := 0
	marked[i0] = 2
	stack[0] = i32(i0)
	for top >= 0 {
		i := int(stack[top])
		top -= 1
		for a in net.adj_first[i] ..< net.adj_first[i + 1] {
			k := int(net.adj_link[a])
			j := int(net.adj_node[a])
			if marked[j] == 2 do continue
			if marked[j] == 1 {
				l: Line
				puts(&l, "WARNING: System disconnected because of Link ")
				puts(&l, p.link_id[k])
				writeline(p, line_str(&l))
				return
			}
			marked[j] = 2
			top += 1
			stack[top] = i32(j)
		}
	}
}

// ── the results report ────────────────────────────────────────────────

writeenergy :: proc "contextless" (p: ^Project) {
	net, hyd, r := &p.net, &p.hyd, &p.rpt
	if net.npumps == 0 do return
	writeline(p, " ")
	writeheader(p, .ENERHDR, false)
	csum := 0.0
	l: Line
	for j in 1 ..= net.npumps {
		e := &hyd.energy[j]
		csum += e.total_cost
		if r.line_num == r.page_size do writeheader(p, .ENERHDR, true)
		line_reset(&l)
		puts_left(&l, p.link_id[net.pump_link[j]], 8)
		puts(&l, "  ")
		putf(&l, "%6.2f", e.time_on_line)
		puts(&l, " ")
		putf(&l, "%6.2f", e.efficiency)
		puts(&l, " ")
		putf(&l, "%9.2f", e.kwhrs_per_flow)
		puts(&l, " ")
		putf(&l, "%9.2f", e.kwhrs)
		puts(&l, " ")
		putf(&l, "%9.2f", e.max_kwatts)
		puts(&l, " ")
		putf(&l, "%9.2f", e.total_cost)
		writeline(p, line_str(&l))
	}
	fill(&l, '-', 63)
	writeline(p, line_str(&l))
	line_reset(&l)
	puts_right(&l, "", 38)
	puts(&l, " Demand Charge: ")
	putf(&l, "%9.2f", hyd.emax * p.dcost)
	writeline(p, line_str(&l))
	line_reset(&l)
	puts_right(&l, "", 38)
	puts(&l, " Total Cost:    ")
	putf(&l, "%9.2f", csum + hyd.emax * p.dcost)
	writeline(p, line_str(&l))
	writeline(p, " ")
}

// writereport writes the energy and results tables: to the report file,
// or to the secondary one named in [REPORT] FILE.
writereport :: proc "contextless" (p: ^Project) -> int {
	r := &p.rpt
	errcode := 0
	r.fprinterr = false
	if r.rptflag && len(r.rpt2_fname) == 0 && r.file != nil {
		if r.energy do writeenergy(p)
		errcode = writeresults(p)
	} else if len(r.rpt2_fname) > 0 {
		if strcomp(r.rpt2_fname, p.inp_fname) || strcomp(r.rpt2_fname, r.rpt1_fname) {
			if r.energy do writeenergy(p)
			errcode = writeresults(p)
		} else {
			tfile := r.file
			tflag := r.rptflag
			buf: [1024]u8
			n := min(len(r.rpt2_fname), 1023)
			copy(buf[:n], r.rpt2_fname)
			buf[n] = 0
			r.file = libc.fopen(cstring(raw_data(buf[:])), "wt")
			if r.file == nil {
				r.file = tfile
				r.rptflag = tflag
				errcode = 303
			} else {
				r.rptflag = true
				writelogo(p)
				if r.summary do writesummary(p)
				if r.energy do writeenergy(p)
				errcode = writeresults(p)
				libc.fclose(r.file)
				r.file = tfile
				r.rptflag = tflag
			}
		}
	}
	if r.fprinterr do errmsg(p, 309)
	return errcode
}

// strcomp: equal, case blind (EPANET's).
strcomp :: proc "contextless" (a, b: string) -> bool {
	if len(a) != len(b) do return false
	for i in 0 ..< len(a) do if upper(a[i]) != upper(b[i]) do return false
	return true
}

// writeresults reads every reporting period back from the output file and
// writes the node and link tables.
writeresults :: proc "contextless" (p: ^Project) -> int {
	net, r, t := &p.net, &p.rpt, &p.times
	if r.nodes == 0 && r.links == 0 do return 0
	nnv, nlv := 0, 0
	for j in Field.ELEV ..= Field.QUALITY do if r.fields[j].enabled do nnv += 1
	for j in Field.LENGTH ..= Field.FRICTION do if r.fields[j].enabled do nlv += 1
	if nnv == 0 && nlv == 0 do return 0

	out := p.out.out_file
	if out == nil {
		buf: [1024]u8
		n := min(len(p.out.out_fname), 1023)
		copy(buf[:n], p.out.out_fname)
		buf[n] = 0
		out = libc.fopen(cstring(raw_data(buf[:])), "rb")
	}
	if out == nil do return 106

	// m columns of n values: enough for the node and the link variables
	m := max(int(Field.QUALITY) - int(Field.DEMAND) + 1, int(Field.FRICTION) - int(Field.FLOW) + 1)
	n := max(net.nnodes + 1, net.nlinks + 1)
	x: [8][^]f32
	errcode := 0
	for j in 0 ..< m {
		x[j] = ([^]f32)(libc.calloc(c.size_t(n), size_of(f32)))
		if x[j] == nil do errcode = 101
	}
	if errcode == 0 {
		libc.fseek(out, c.long(p.out.out_offset2), .SET)
		t.htime = t.rstart
		for _ in 1 ..= r.nperiods {
			for j in 0 ..= int(Field.QUALITY) - int(Field.DEMAND) {
				libc.fread(x[j][1:], size_of(f32), c.size_t(net.nnodes), out)
			}
			if nnv > 0 && r.nodes > 0 do writenodetable(p, x)
			for j in 0 ..= int(Field.FRICTION) - int(Field.FLOW) {
				libc.fread(x[j][1:], size_of(f32), c.size_t(net.nlinks), out)
			}
			if nlv > 0 && r.links > 0 do writelinktable(p, x)
			t.htime += t.rstep
		}
	}
	libc.fclose(out)
	for j in 0 ..< m do libc.free(x[j])
	return errcode
}

// put_value: a result cell, %10.2e when huge, else at the field's precision.
put_value :: proc "contextless" (l: ^Line, f: ^Report_Field, y: f64) {
	if abs(y) > 1e6 {
		putf(l, "%10.2e", y)
	} else {
		putfp(l, f.precision, y)
	}
}

checklimits :: proc "contextless" (r: ^Report_Options, y: ^[Field]f64, j1, j2: Field) -> bool {
	for j in j1 ..= j2 {
		if y[j] > r.fields[j].lo || y[j] < r.fields[j].hi do return false
	}
	return true
}

writenodetable :: proc "contextless" (p: ^Project, x: [8][^]f32) {
	net, r := &p.net, &p.rpt
	writeheader(p, .NODEHDR, false)
	l: Line
	y: [Field]f64
	for i in 1 ..= net.nnodes {
		y[.ELEV] = net.el[i] * p.ucf[.ELEV]
		for j in Field.DEMAND ..= Field.QUALITY do y[j] = f64(x[int(j) - int(Field.DEMAND)][i])
		if (r.nodes == 1 || p.node_rpt[i]) && checklimits(r, &y, .ELEV, .QUALITY) {
			if r.line_num == r.page_size do writeheader(p, .NODEHDR, true)
			line_reset(&l)
			puts_left(&l, p.node_id[i], 15)
			for j in Field.ELEV ..= Field.QUALITY {
				if r.fields[j].enabled do put_value(&l, &r.fields[j], y[j])
			}
			if i > net.njuncs {
				puts(&l, "  ")
				puts(&l, NODE_TEXT[node_type_of(net, i)])
			}
			writeline(p, line_str(&l))
		}
	}
	writeline(p, " ")
}

writelinktable :: proc "contextless" (p: ^Project, x: [8][^]f32) {
	net, r := &p.net, &p.rpt
	writeheader(p, .LINKHDR, false)
	l: Line
	y: [Field]f64
	for i in 1 ..= net.nlinks {
		y[.LENGTH] = net.len[i] * p.ucf[.LENGTH]
		y[.DIAM] = net.diam[i] * p.ucf[.DIAM]
		for j in Field.FLOW ..= Field.FRICTION do y[j] = f64(x[int(j) - int(Field.FLOW)][i])
		if (r.links == 1 || p.link_rpt[i]) && checklimits(r, &y, .DIAM, .FRICTION) {
			if r.line_num == r.page_size do writeheader(p, .LINKHDR, true)
			line_reset(&l)
			puts_left(&l, p.link_id[i], 15)
			for j in Field.LENGTH ..= Field.FRICTION {
				if !r.fields[j].enabled do continue
				if j == .STATUS {
					k: Status
					if y[j] <= f64(Status.CLOSED) {
						k = .CLOSED
					} else if y[j] == f64(Status.ACTIVE) {
						k = .ACTIVE
					} else {
						k = .OPEN
					}
					puts_right(&l, STATUS_TEXT[k], 10)
				} else {
					put_value(&l, &r.fields[j], y[j])
				}
			}
			if net.link_type[i] > .PIPE {
				puts(&l, "  ")
				puts(&l, LINK_TEXT[net.link_type[i]])
			}
			writeline(p, line_str(&l))
		}
	}
	writeline(p, " ")
}

// writeheader: a table's heading, on a fresh page when fewer than 11
// lines are left on this one.
writeheader :: proc "contextless" (p: ^Project, kind: Header_Kind, contin: bool) {
	r, t := &p.rpt, &p.times
	if r.rptflag && r.line_num + 11 > r.page_size {
		for r.line_num < r.page_size do writeline(p, " ")
	}
	writeline(p, " ")
	s, s1, s2, s3: Line
	abuf: [16]u8
	switch kind {
	case .STATHDR:
		puts(&s, "Hydraulic Status:")
		if contin do puts(&s, " (continued)")
		writeline(p, line_str(&s))
		fill(&s, '-', 70)
		writeline(p, line_str(&s))
	case .ENERHDR:
		per := p.units == .SI ? " /m3" : "/Mgal"
		puts(&s, "Energy Usage:")
		if contin do puts(&s, " (continued)")
		writeline(p, line_str(&s))
		fill(&s, '-', 63)
		writeline(p, line_str(&s))
		writeline(p, "           Usage   Avg.     Kw-hr      Avg.      Peak      Cost")
		line_reset(&s)
		puts(&s, "Pump      Factor Effic.     ")
		puts(&s, per)
		puts(&s, "        Kw        Kw      /day")
		writeline(p, line_str(&s))
		fill(&s, '-', 63)
		writeline(p, line_str(&s))
	case .NODEHDR, .LINKHDR:
		what := kind == .NODEHDR ? "Node" : "Link"
		if r.tstat == .RANGE {
			puts(&s, "DIFFERENTIAL ")
			puts(&s, what)
			puts(&s, " Results:")
		} else if r.tstat != .SERIES {
			puts(&s, TSTAT_TEXT[r.tstat])
			puts(&s, " ")
			puts(&s, what)
			puts(&s, " Results:")
		} else if t.dur == 0 {
			puts(&s, what)
			puts(&s, " Results:")
		} else {
			puts(&s, what)
			puts(&s, " Results at ")
			puts(&s, clocktime(&abuf, t.htime))
			puts(&s, " hrs:")
		}
		if contin do puts(&s, " (continued)")
		writeline(p, line_str(&s))
		n := 15
		puts_right(&s2, "", 15)
		puts_left(&s3, what, 15)
		if kind == .NODEHDR {
			for i in Field.ELEV ..< Field.QUALITY {
				if r.fields[i].enabled {
					n += 10
					puts_right(&s2, r.fields[i].name, 10)
					puts_right(&s3, r.fields[i].units, 10)
				}
			}
			if r.fields[.QUALITY].enabled {
				n += 10
				puts_right(&s2, p.chem_name, 10)
				puts_right(&s3, p.chem_units, 10)
			}
		} else {
			for i in Field.LENGTH ..= Field.FRICTION {
				if r.fields[i].enabled {
					n += 10
					puts_right(&s2, r.fields[i].name, 10)
					puts_right(&s3, r.fields[i].units, 10)
				}
			}
		}
		fill(&s1, '-', n)
		writeline(p, line_str(&s1))
		writeline(p, line_str(&s2))
		writeline(p, line_str(&s3))
		writeline(p, line_str(&s1))
	}
}
