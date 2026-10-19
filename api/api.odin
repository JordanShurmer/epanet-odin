package api

// api.odin — EPANET's toolkit (epanet.c) over the Odin project: the
// EN_* functions with EPANET's names, C calling convention, argument
// shapes and error codes, so a C program written against epanet2_2.h
// links this library instead of libepanet2. This file is the running half
// of the toolkit — projects, files, the hydraulic and quality runs, the
// report, and every getter; edit.odin is the editing half (EN_init,
// EN_set*, EN_add*, EN_delete*).
//
// Built as its own static library (`odin build api -build-mode:static`),
// the engine package inside it.

import "base:runtime"
import "core:c"
import "core:c/libc"
import "core:strings"
import posix "core:sys/posix"

import ep "../epanet"

Project :: ep.Project
Field :: ep.Field

MAXID :: ep.MAXID
MAXMSG :: 255
MAXLINE :: ep.MAXLINE
TITLELEN :: ep.TITLELEN

// the toolkit's codes (epanet2_enums.h)
EN_NODECOUNT :: 0
EN_SAVE :: 1
EN_INITFLOW :: 10

// ── helpers ───────────────────────────────────────────────────────────

// put_str: s into a C buffer of at least max+1 bytes, NUL ended.
put_str :: proc "contextless" (dst: [^]u8, s: string, max: int) {
	n := min(len(s), max)
	copy(dst[:n], s)
	dst[n] = 0
}

// keep: a C string the project holds on to (from its arena).
keep :: proc(p: ^Project, s: cstring) -> string {
	return strings.clone(string(s), ep.arena_allocator(&p.arena))
}

cpath :: proc "contextless" (buf: ^[1024]u8, s: string) -> cstring {
	n := min(len(s), 1023)
	copy(buf[:n], s)
	buf[n] = 0
	return cstring(raw_data(buf[:]))
}

// tmp_name: an unused file name beginning "en" in the temporary directory
// ($TMPDIR, else /tmp), or "". (EPANET makes its scratch files in the
// working directory, where a crash leaves them lying about.)
tmp_name :: proc(p: ^Project) -> string {
	dir := string(libc.getenv("TMPDIR"))
	if len(dir) == 0 do dir = "/tmp"
	buf: [1024]u8
	n := min(len(dir), 1000)
	copy(buf[:n], dir[:n])
	copy(buf[n:], "/enXXXXXX\x00")
	fd := posix.mkstemp(cstring(&buf[0]))
	if fd < 0 do return ""
	posix.close(fd)
	libc.remove(cstring(&buf[0]))
	return strings.clone(string(cstring(&buf[0])), ep.arena_allocator(&p.arena))
}

// sync_flags: the engine reads a few of the project's flags from its
// own structs.
sync_flags :: proc "contextless" (p: ^Project) {
	p.hyd.status_report = p.rpt.status == 2
	p.hyd.status_report_any = p.rpt.status != 0
	p.hyd.saveflag = p.out.saveflag
}

// project_reset forgets the network, keeping the arena and the scratch
// file names (EPANET's freedata; the arena is reused by the next read).
project_reset :: proc(p: ^Project) {
	arena := p.arena
	hyd, out, stat := p.tmp_hyd_fname, p.tmp_out_fname, p.tmp_stat_fname
	p^ = {}
	p.arena = arena
	p.tmp_hyd_fname, p.tmp_out_fname, p.tmp_stat_fname = hyd, out, stat
}

// ── projects and files ────────────────────────────────────────────────

@(export, link_name = "EN_createproject")
EN_createproject :: proc "c" (pp: ^^Project) -> c.int {
	context = runtime.default_context()
	p := ep.project_new()
	if p == nil do return -1
	p.tmp_hyd_fname = tmp_name(p)
	p.tmp_out_fname = tmp_name(p)
	p.tmp_stat_fname = tmp_name(p)
	pp^ = p
	return 0
}

@(export, link_name = "EN_deleteproject")
EN_deleteproject :: proc "c" (p: ^Project) -> c.int {
	context = runtime.default_context()
	if p == nil do return -1
	if p.openflag do EN_close(p)
	buf: [1024]u8
	libc.remove(cpath(&buf, p.tmp_hyd_fname))
	libc.remove(cpath(&buf, p.tmp_out_fname))
	libc.remove(cpath(&buf, p.tmp_stat_fname))
	ep.project_free(p)
	return 0
}

@(export, link_name = "EN_runproject")
EN_runproject :: proc "c" (p: ^Project, inp, rpt, out: cstring, viewprog: rawptr) -> c.int {
	context = runtime.default_context()
	errcode := EN_open(p, inp, rpt, out)
	if errcode <= 100 && p.out.hydflag != .USE do errcode = EN_solveH(p)
	if errcode <= 100 do errcode = EN_solveQ(p)
	if errcode <= 100 do errcode = EN_report(p)
	EN_close(p)
	if p.warnflag != 0 do errcode = max(errcode, c.int(p.warnflag))
	return errcode
}

// openfiles names the three files and opens the report, with the logo.
openfiles :: proc(p: ^Project, f1, f2, f3: cstring) -> int {
	p.rpt.file = nil
	p.out.out_file, p.out.hyd_file, p.out.tmp_out_file = nil, nil, nil
	p.inp_fname = keep(p, f1)
	p.rpt.rpt1_fname = keep(p, f2)
	p.out.out_fname = keep(p, f3)
	if len(p.out.out_fname) > 0 {
		p.out.outflag = .SAVE
	} else {
		p.out.outflag = .SCRATCH
		p.out.out_fname = p.tmp_out_fname
	}
	if len(p.inp_fname) > 0 && (ep.strcomp(p.inp_fname, p.rpt.rpt1_fname) || ep.strcomp(p.inp_fname, string(f3))) do return 301
	if len(f3) > 0 && ep.strcomp(p.rpt.rpt1_fname, string(f3)) do return 301
	if len(p.inp_fname) > 0 {
		buf: [1024]u8
		f := libc.fopen(cpath(&buf, p.inp_fname), "rt")
		if f == nil do return 302
		libc.fclose(f)
	}
	if len(p.rpt.rpt1_fname) == 0 {
		p.rpt.file = libc.stdout
	} else {
		buf: [1024]u8
		p.rpt.file = libc.fopen(cpath(&buf, p.rpt.rpt1_fname), "wt")
		if p.rpt.file == nil do return 303
	}
	ep.writelogo(p)
	return 0
}

openproject :: proc(p: ^Project, inp, rpt, out: cstring, allow_errors: bool) -> c.int {
	project_reset(p)
	p.rpt.messages = true
	p.rpt.rptflag = true
	errcode := openfiles(p, inp, rpt, out)
	if errcode > 0 {
		ep.errmsg(p, errcode)
		return c.int(errcode)
	}
	errcode = ep.read_inp(p, p.inp_fname)
	opened := allow_errors ? (errcode == 0 || errcode == 200) : errcode == 0
	if opened {
		if p.out.hydflag == .USE {
			if hyderr := ep.openhydfile(p); hyderr > 0 {
				ep.errmsg(p, hyderr)
				p.out.hydflag = .SCRATCH
			}
		}
		if p.rpt.summary do ep.writesummary(p)
		p.openflag = true
	}
	ep.errmsg(p, errcode)
	sync_flags(p)
	return c.int(errcode)
}

@(export, link_name = "EN_open")
EN_open :: proc "c" (p: ^Project, inp, rpt, out: cstring) -> c.int {
	context = runtime.default_context()
	return openproject(p, inp, rpt, out, false)
}

@(export, link_name = "EN_openX")
EN_openX :: proc "c" (p: ^Project, inp, rpt, out: cstring) -> c.int {
	context = runtime.default_context()
	return openproject(p, inp, rpt, out, true)
}

@(export, link_name = "EN_gettitle")
EN_gettitle :: proc "c" (p: ^Project, l1, l2, l3: [^]u8) -> c.int {
	if !p.openflag do return 102
	put_str(l1, p.title[0], TITLELEN)
	put_str(l2, p.title[1], TITLELEN)
	put_str(l3, p.title[2], TITLELEN)
	return 0
}

@(export, link_name = "EN_getcount")
EN_getcount :: proc "c" (p: ^Project, object: c.int, count: ^c.int) -> c.int {
	count^ = 0
	if !p.openflag do return 102
	net := &p.net
	switch object {
	case 0:
		count^ = c.int(net.nnodes)
	case 1:
		count^ = c.int(net.ntanks)
	case 2:
		count^ = c.int(net.nlinks)
	case 3:
		count^ = c.int(len(net.patterns) - 1)
	case 4:
		count^ = c.int(len(net.curves) - 1)
	case 5:
		count^ = c.int(net.ncontrols)
	case 6:
		count^ = c.int(net.nrules)
	case:
		return 251
	}
	return 0
}

@(export, link_name = "EN_close")
EN_close :: proc "c" (p: ^Project) -> c.int {
	context = runtime.default_context()
	if p.open_hflag do EN_closeH(p)
	if p.hyd.openqflag do ep.close_qual(p)
	if p.net.adj_first != nil do ep.free_adjlists(&p.net) // quality's, when hydraulics had closed
	ep.closeoutfile(p)
	if p.rpt.file != nil && p.rpt.file != libc.stdout do libc.fclose(p.rpt.file)
	p.rpt.file = nil
	if p.out.hyd_file != nil do libc.fclose(p.out.hyd_file)
	p.out.hyd_file = nil
	project_reset(p)
	return 0
}

// ── hydraulics ────────────────────────────────────────────────────────

@(export, link_name = "EN_solveH")
EN_solveH :: proc "c" (p: ^Project) -> c.int {
	context = runtime.default_context()
	errcode := EN_openH(p)
	if errcode == 0 {
		errcode = EN_initH(p, EN_SAVE)
		if errcode == 0 {
			// a warning (a code under 100) does not stop the run
			t, tstep: c.long
			for {
				tstep = 0
				if errcode <= 100 do errcode = EN_runH(p, &t)
				if errcode <= 100 do errcode = EN_nextH(p, &tstep)
				if tstep <= 0 do break
			}
		}
	}
	EN_closeH(p)
	return max(errcode, c.int(p.warnflag))
}

@(export, link_name = "EN_saveH")
EN_saveH :: proc "c" (p: ^Project) -> c.int {
	context = runtime.default_context()
	if !p.out.save_hflag do return 104
	kind := p.q.kind
	p.q.kind = .NONE
	errcode := EN_solveQ(p)
	p.q.kind = kind
	if errcode != 0 do ep.errmsg(p, int(errcode))
	return errcode
}

@(export, link_name = "EN_openH")
EN_openH :: proc "c" (p: ^Project) -> c.int {
	context = runtime.default_context()
	p.open_hflag = false
	p.out.save_hflag = false
	if !p.openflag do return 102
	if p.out.hydflag == .USE do return 107
	errcode := ep.open_hyd(p)
	if errcode == 0 {
		p.open_hflag = true
		ep.writetime(p, "Analysis begun ")
	} else {
		ep.errmsg(p, errcode)
	}
	return c.int(errcode)
}

@(export, link_name = "EN_initH")
EN_initH :: proc "c" (p: ^Project, init_flag: c.int) -> c.int {
	context = runtime.default_context()
	p.out.save_hflag = false
	p.warnflag = 0
	fflag := int(init_flag) / EN_INITFLOW
	sflag := int(init_flag) - fflag * EN_INITFLOW
	if !p.open_hflag do return 103
	p.out.saveflag = false
	if sflag > 0 {
		if errcode := ep.openhydfile(p); errcode != 0 {
			ep.errmsg(p, errcode)
			return c.int(errcode)
		}
		p.out.saveflag = true
	}
	ep.open_leakage(p)
	sync_flags(p)
	ep.init_hyd(&p.net, &p.hyd, &p.times, fflag)
	if p.out.saveflag do libc.fseek(p.out.hyd_file, libc.long(p.out.hyd_offset), .SET)
	if p.rpt.status > 0 do ep.writeheader(p, .STATHDR, false)
	return 0
}

@(export, link_name = "EN_runH")
EN_runH :: proc "c" (p: ^Project, current_time: ^c.long) -> c.int {
	context = runtime.default_context()
	current_time^ = 0
	if !p.open_hflag do return 103
	t, errcode := ep.run_hyd(p)
	current_time^ = c.long(t)
	if errcode != 0 do ep.errmsg(p, errcode)
	return c.int(errcode)
}

@(export, link_name = "EN_nextH")
EN_nextH :: proc "c" (p: ^Project, tstep: ^c.long) -> c.int {
	context = runtime.default_context()
	tstep^ = 0
	if !p.open_hflag do return 103
	ts, errcode := ep.next_hyd(p)
	tstep^ = c.long(ts)
	if errcode != 0 {
		ep.errmsg(p, errcode)
	} else if p.out.saveflag && ts == 0 {
		p.out.save_hflag = true
	}
	return c.int(errcode)
}

@(export, link_name = "EN_closeH")
EN_closeH :: proc "c" (p: ^Project) -> c.int {
	context = runtime.default_context()
	if !p.openflag do return 102
	if p.open_hflag {
		p.hyd.has_leakage = false
		ep.close_hyd(p)
	}
	p.open_hflag = false
	return 0
}

@(export, link_name = "EN_savehydfile")
EN_savehydfile :: proc "c" (p: ^Project, filename: cstring) -> c.int {
	context = runtime.default_context()
	if p.out.hyd_file == nil || !p.out.save_hflag do return 104
	f := libc.fopen(filename, "w+b")
	if f == nil do return 305
	libc.fseek(p.out.hyd_file, 0, .SET)
	for {
		ch := libc.fgetc(p.out.hyd_file)
		if ch == libc.EOF do break
		libc.fputc(ch, f)
	}
	libc.fclose(f)
	return 0
}

@(export, link_name = "EN_usehydfile")
EN_usehydfile :: proc "c" (p: ^Project, filename: cstring) -> c.int {
	context = runtime.default_context()
	if !p.openflag do return 102
	if p.open_hflag do return 108
	p.out.hyd_fname = keep(p, filename)
	p.out.hydflag = .USE
	p.out.save_hflag = true
	errcode := ep.openhydfile(p)
	if errcode != 0 {
		p.out.hyd_fname = ""
		p.out.hydflag = .SCRATCH
		p.out.save_hflag = false
	}
	return c.int(errcode)
}

// ── water quality ─────────────────────────────────────────────────────

@(export, link_name = "EN_solveQ")
EN_solveQ :: proc "c" (p: ^Project) -> c.int {
	context = runtime.default_context()
	errcode := EN_openQ(p)
	if errcode == 0 {
		errcode = EN_initQ(p, EN_SAVE)
		if errcode == 0 {
			t, tstep: c.long
			for {
				tstep = 0
				if errcode <= 100 do errcode = EN_runQ(p, &t)
				if errcode <= 100 do errcode = EN_nextQ(p, &tstep)
				if tstep <= 0 do break
			}
		}
	}
	EN_closeQ(p)
	return errcode
}

@(export, link_name = "EN_openQ")
EN_openQ :: proc "c" (p: ^Project) -> c.int {
	context = runtime.default_context()
	p.hyd.openqflag = false
	p.out.save_qflag = false
	if !p.openflag do return 102
	if !p.open_hflag && !p.out.save_hflag do return 104
	errcode := ep.open_qual(p)
	if errcode == 0 {
		p.hyd.openqflag = true
	} else {
		ep.errmsg(p, errcode)
	}
	return c.int(errcode)
}

@(export, link_name = "EN_initQ")
EN_initQ :: proc "c" (p: ^Project, save_flag: c.int) -> c.int {
	context = runtime.default_context()
	if !p.hyd.openqflag do return 105
	ep.initqual(p)
	p.out.save_qflag = false
	p.out.saveflag = false
	errcode := 0
	if save_flag != 0 {
		errcode = ep.openoutfile(p)
		if errcode == 0 do p.out.saveflag = true
	}
	sync_flags(p)
	return c.int(errcode)
}

@(export, link_name = "EN_runQ")
EN_runQ :: proc "c" (p: ^Project, current_time: ^c.long) -> c.int {
	context = runtime.default_context()
	current_time^ = 0
	if !p.hyd.openqflag do return 105
	t, errcode := ep.runqual(p)
	current_time^ = c.long(t)
	if errcode != 0 do ep.errmsg(p, errcode)
	return c.int(errcode)
}

@(export, link_name = "EN_nextQ")
EN_nextQ :: proc "c" (p: ^Project, tstep: ^c.long) -> c.int {
	context = runtime.default_context()
	tstep^ = 0
	if !p.hyd.openqflag do return 105
	ts, errcode := ep.nextqual(p)
	tstep^ = c.long(ts)
	if errcode == 0 && p.out.saveflag && ts == 0 do p.out.save_qflag = true
	if errcode != 0 do ep.errmsg(p, errcode)
	return c.int(errcode)
}

@(export, link_name = "EN_stepQ")
EN_stepQ :: proc "c" (p: ^Project, time_left: ^c.long) -> c.int {
	context = runtime.default_context()
	time_left^ = 0
	if !p.hyd.openqflag do return 105
	tl, errcode := ep.stepqual(p)
	time_left^ = c.long(tl)
	if errcode == 0 && p.out.saveflag && tl == 0 do p.out.save_qflag = true
	if errcode != 0 do ep.errmsg(p, errcode)
	return c.int(errcode)
}

@(export, link_name = "EN_closeQ")
EN_closeQ :: proc "c" (p: ^Project) -> c.int {
	context = runtime.default_context()
	if !p.openflag do return 102
	ep.close_qual(p)
	p.hyd.openqflag = false
	ep.closeoutfile(p)
	ep.writetime(p, "Analysis ended ")
	return 0
}

// ── the report ────────────────────────────────────────────────────────

@(export, link_name = "EN_writeline")
EN_writeline :: proc "c" (p: ^Project, line: cstring) -> c.int {
	if !p.openflag do return 102
	ep.writeline(p, string(line))
	return 0
}

@(export, link_name = "EN_report")
EN_report :: proc "c" (p: ^Project) -> c.int {
	context = runtime.default_context()
	if !p.out.save_qflag do return 106
	errcode := ep.writereport(p)
	if errcode != 0 do ep.errmsg(p, errcode)
	return c.int(errcode)
}

@(export, link_name = "EN_copyreport")
EN_copyreport :: proc "c" (p: ^Project, filename: cstring) -> c.int {
	context = runtime.default_context()
	r := &p.rpt
	if r.file == nil do return 0
	tfile := libc.fopen(filename, "w")
	if tfile == nil do return 303
	buf: [1024]u8
	libc.fclose(r.file)
	r.file = libc.fopen(cpath(&buf, r.rpt1_fname), "r")
	if r.file != nil {
		for {
			ch := libc.fgetc(r.file)
			if ch == libc.EOF do break
			libc.fputc(ch, tfile)
		}
		libc.fclose(r.file)
	}
	libc.fclose(tfile)
	r.file = libc.fopen(cpath(&buf, r.rpt1_fname), "a")
	if r.file == nil do return 303
	return 0
}

@(export, link_name = "EN_clearreport")
EN_clearreport :: proc "c" (p: ^Project) -> c.int {
	return c.int(ep.clearreport(p))
}

@(export, link_name = "EN_resetreport")
EN_resetreport :: proc "c" (p: ^Project) -> c.int {
	context = runtime.default_context()
	if !p.openflag do return 102
	ep.init_report(p)
	for i in 1 ..= p.net.nnodes do p.node_rpt[i] = false
	for i in 1 ..= p.net.nlinks do p.link_rpt[i] = false
	return 0
}

@(export, link_name = "EN_setstatusreport")
EN_setstatusreport :: proc "c" (p: ^Project, level: c.int) -> c.int {
	if level < 0 || level > 2 do return 251
	p.rpt.status = int(level)
	sync_flags(p)
	return 0
}

@(export, link_name = "EN_getversion")
EN_getversion :: proc "c" (version: ^c.int) -> c.int {
	version^ = ep.CODEVERSION
	return 0
}

WARNINGS := [?]string {
	"WARNING: System hydraulically unbalanced.",
	"WARNING: System may be hydraulically unstable.",
	"WARNING: System disconnected.",
	"WARNING: Pumps cannot deliver enough flow or head.",
	"WARNING: Valves cannot deliver enough flow.",
	"WARNING: System has negative pressures.",
}

@(export, link_name = "EN_geterror")
EN_geterror :: proc "c" (errcode: c.int, msg: [^]u8, max_len: c.int) -> c.int {
	if errcode >= 1 && errcode <= 6 {
		put_str(msg, WARNINGS[errcode - 1], int(max_len) - 1)
	} else {
		l: ep.Line
		ep.puts(&l, "Error ")
		ep.puti(&l, "%d", int(errcode))
		ep.puts(&l, ": ")
		if (errcode >= 202 && errcode <= 222) || (errcode >= 240 && errcode <= 261) do ep.puts(&l, "function call contains ")
		ep.puts(&l, ep.error_message(int(errcode)))
		put_str(msg, ep.line_str(&l), int(max_len) - 1)
	}
	if msg[0] == 0 do return 251
	return 0
}

@(export, link_name = "EN_getstatistic")
EN_getstatistic :: proc "c" (p: ^Project, kind: c.int, value: ^f64) -> c.int {
	hyd := &p.hyd
	switch kind {
	case 0:
		value^ = f64(hyd.iterations)
	case 1:
		value^ = hyd.relative_error
	case 2:
		value^ = hyd.max_head_error * p.ucf[.HEAD]
	case 3:
		value^ = hyd.max_flow_change * p.ucf[.FLOW]
	case 4:
		value^ = p.q.balance.ratio
	case 5:
		value^ = f64(hyd.deficient_nodes)
	case 6:
		value^ = hyd.demand_reduction
	case 7:
		value^ = hyd.leakage_loss
	case:
		value^ = 0
		return 251
	}
	return 0
}

@(export, link_name = "EN_getresultindex")
EN_getresultindex :: proc "c" (p: ^Project, kind, index: c.int, value: ^c.int) -> c.int {
	value^ = 0
	if !p.openflag do return 102
	if kind == 0 {
		if index <= 0 || int(index) > p.net.nnodes do return 203
		value^ = index
	} else if kind == 1 {
		if index <= 0 || int(index) > p.net.nlinks do return 204
		value^ = index
	} else {
		return 251
	}
	return 0
}

@(export, link_name = "EN_getoption")
EN_getoption :: proc "c" (p: ^Project, option: c.int, value: ^f64) -> c.int {
	hyd, q := &p.hyd, &p.q
	value^ = 0
	if !p.openflag do return 102
	v := 0.0
	switch option {
	case 0:
		v = f64(hyd.max_iter)
	case 1:
		v = hyd.hacc
	case 2:
		v = q.ctol * p.ucf[.QUALITY]
	case 3:
		if hyd.qexp > 0 do v = 1.0 / hyd.qexp
	case 4:
		v = hyd.dmult
	case 5:
		v = hyd.head_error_limit * p.ucf[.HEAD]
	case 6:
		v = hyd.flow_change_limit * p.ucf[.FLOW]
	case 7:
		v = f64(hyd.formflag)
	case 8:
		v = hyd.epump
	case 9:
		v = hyd.ecost
	case 10:
		v = f64(hyd.epat)
	case 11:
		v = p.dcost
	case 12:
		v = hyd.spgrav
	case 13:
		v = hyd.viscos / ep.VISCOS
	case 14:
		v = f64(hyd.extra_iter)
	case 15:
		v = f64(hyd.check_freq)
	case 16:
		v = f64(hyd.max_check)
	case 17:
		v = hyd.damp_limit
	case 18:
		v = q.diffus / ep.DIFFUS
	case 19:
		v = q.bulk_order
	case 20:
		v = q.wall_order
	case 21:
		v = q.tank_order
	case 22:
		v = q.climit * p.ucf[.QUALITY]
	case 23:
		v = f64(p.net.def_pat)
	case 24:
		v = hyd.emit_backflow ? 1 : 0
	case 25:
		v = f64(p.pressure_units)
	case 26:
		v = f64(p.rpt.status)
	case:
		return 251
	}
	value^ = v
	return 0
}

@(export, link_name = "EN_getflowunits")
EN_getflowunits :: proc "c" (p: ^Project, units: ^c.int) -> c.int {
	units^ = -1
	if !p.openflag do return 102
	units^ = c.int(p.flow_units)
	return 0
}

@(export, link_name = "EN_gettimeparam")
EN_gettimeparam :: proc "c" (p: ^Project, param: c.int, value: ^c.long) -> c.int {
	t := &p.times
	value^ = 0
	if !p.openflag do return 102
	switch param {
	case 0:
		value^ = c.long(t.dur)
	case 1:
		value^ = c.long(t.hstep)
	case 2:
		value^ = c.long(t.qstep)
	case 3:
		value^ = c.long(t.pstep)
	case 4:
		value^ = c.long(t.pstart)
	case 5:
		value^ = c.long(t.rstep)
	case 6:
		value^ = c.long(t.rstart)
	case 7:
		value^ = c.long(t.rulestep)
	case 8:
		value^ = c.long(p.rpt.tstat)
	case 9:
		value^ = c.long(p.rpt.nperiods)
	case 10:
		value^ = c.long(t.tstart)
	case 11:
		value^ = c.long(t.htime)
	case 12:
		value^ = c.long(t.qtime) // (EPANET falls through to the halt flag, which changes nothing)
	case 13:
	case 14:
		ts := t.hstep
		ep.tank_timestep(&p.net, &p.hyd, &ts)
		value^ = c.long(ts)
	case 15:
		ts := t.hstep
		value^ = c.long(ep.tank_timestep(&p.net, &p.hyd, &ts))
	case:
		return 251
	}
	return 0
}

@(export, link_name = "EN_timetonextevent")
EN_timetonextevent :: proc "c" (p: ^Project, event_type: ^c.int, duration: ^c.long, element: ^c.int) -> c.int {
	hstep := p.times.hstep
	tank_step, control_step := hstep, hstep
	itank := ep.tank_timestep(&p.net, &p.hyd, &tank_step)
	icontrol := ep.control_timestep(&p.net, &p.hyd, &p.times, &control_step)
	if control_step < tank_step {
		event_type^ = 4
		duration^ = c.long(control_step)
		element^ = c.int(icontrol)
	} else if tank_step < hstep {
		event_type^ = 3
		duration^ = c.long(tank_step)
		element^ = c.int(itank)
	} else {
		event_type^ = 1
		duration^ = c.long(hstep)
		element^ = 0
	}
	return 0
}

@(export, link_name = "EN_getqualinfo")
EN_getqualinfo :: proc "c" (p: ^Project, qual_type: ^c.int, chem_name, chem_units: [^]u8, trace_node: ^c.int) -> c.int {
	EN_getqualtype(p, qual_type, trace_node)
	switch p.q.kind {
	case .CHEM:
		put_str(chem_name, p.chem_name, MAXID)
		put_str(chem_units, p.chem_units, MAXID)
	case .TRACE:
		put_str(chem_name, "TRACE", MAXID)
		put_str(chem_units, "% from", MAXID)
	case .AGE:
		put_str(chem_name, "AGE", MAXID)
		put_str(chem_units, "hrs", MAXID)
	case .NONE:
		put_str(chem_name, "", MAXID)
		put_str(chem_units, "", MAXID)
	}
	return 0
}

@(export, link_name = "EN_getqualtype")
EN_getqualtype :: proc "c" (p: ^Project, qual_type: ^c.int, trace_node: ^c.int) -> c.int {
	trace_node^ = 0
	if !p.openflag do return 102
	qual_type^ = c.int(p.q.kind)
	if p.q.kind == .TRACE do trace_node^ = c.int(p.q.trace_node)
	return 0
}

// ── nodes ─────────────────────────────────────────────────────────────

@(export, link_name = "EN_getnodeindex")
EN_getnodeindex :: proc "c" (p: ^Project, id: cstring, index: ^c.int) -> c.int {
	context = runtime.default_context()
	index^ = 0
	if !p.openflag do return 102
	index^ = c.int(ep.findnode(p, string(id)))
	return index^ == 0 ? 203 : 0
}

@(export, link_name = "EN_getnodeid")
EN_getnodeid :: proc "c" (p: ^Project, index: c.int, id: [^]u8) -> c.int {
	id[0] = 0
	if !p.openflag do return 102
	if index < 1 || int(index) > p.net.nnodes do return 203
	put_str(id, p.node_id[index], MAXID)
	return 0
}

@(export, link_name = "EN_getnodetype")
EN_getnodetype :: proc "c" (p: ^Project, index: c.int, node_type: ^c.int) -> c.int {
	node_type^ = -1
	if !p.openflag do return 102
	if index < 1 || int(index) > p.net.nnodes do return 203
	node_type^ = c.int(ep.node_type_of(&p.net, int(index)))
	return 0
}

// in_controls: is the node (object 0) or link (1) named by a control or
// a rule?
in_controls :: proc "contextless" (p: ^Project, object: int, index: int) -> bool {
	net := &p.net
	for i in 1 ..= net.ncontrols {
		if object == 0 && int(net.control_node[i]) == index do return true
		if object == 1 && int(net.control_link[i]) == index do return true
	}
	rule_object := object == 0 ? ep.Rule_Object.NODE : ep.Rule_Object.LINK
	for i in 1 ..= net.nrules {
		for k in net.rule_premise_first[i] ..< net.rule_premise_first[i + 1] {
			if net.premise_object[k] == rule_object && int(net.premise_index[k]) == index do return true
		}
		if object == 1 {
			for k in net.rule_then_first[i] ..< net.rule_then_first[i + 1] {
				if int(net.action_link[k]) == index do return true
			}
		}
	}
	return false
}

@(export, link_name = "EN_getnodevalue")
EN_getnodevalue :: proc "c" (p: ^Project, index: c.int, property: c.int, value: ^f64) -> c.int {
	net, hyd, q := &p.net, &p.hyd, &p.q
	value^ = 0
	if !p.openflag do return 102
	i := int(index)
	if i <= 0 || i > net.nnodes do return 203
	nj := net.njuncs
	t := i - nj // the tank, when i > nj
	v := 0.0
	switch property {
	case 0:
		v = net.el[i] * p.ucf[.ELEV]
	case 1:
		if i <= nj && net.demand_first[i] < net.demand_first[i + 1] do v = net.demand_base[net.demand_first[i]] * p.ucf[.FLOW]
	case 2:
		if i <= nj {
			if net.demand_first[i] < net.demand_first[i + 1] do v = f64(net.demand_pat[net.demand_first[i]])
		} else {
			v = f64(net.tank_pat[t])
		}
	case 3:
		if net.ke[i] > 0 {
			ecf := p.units == .US ? ep.PSI_PER_FT * hyd.spgrav : ep.M_PER_FT
			v = p.ucf[.FLOW] / libc.pow(ecf * net.ke[i], 1.0 / hyd.qexp)
		}
	case 4:
		v = net.c0[i] * p.ucf[.QUALITY]
	case 5, 6, 7, 13:
		if !net.has_source[i] do return 240
		switch property {
		case 5:
			v = net.source_c0[i]
		case 13:
			v = q.source_mass != nil ? q.source_mass[i] * 60.0 : 0
		case 6:
			v = f64(net.source_pat[i])
		case 7:
			v = f64(net.source_type[i])
		}
	case 8:
		if i <= nj do return 0
		v = (net.tank_h0[t] - net.el[i]) * p.ucf[.ELEV]
	case 9:
		v = hyd.node_demand[i] * p.ucf[.FLOW]
	case 10:
		v = hyd.head[i] * p.ucf[.HEAD]
	case 11:
		v = (hyd.head[i] - net.el[i]) * p.ucf[.PRESSURE]
	case 12:
		v = q.node_qual[i] * p.ucf[.QUALITY]
	case 14:
		if i > nj do v = net.tank_v0[t] * p.ucf[.VOLUME]
	case 15:
		if i > nj do v = f64(net.tank_mix[t])
	case 16:
		if i > nj do v = net.tank_v1frac[t] * net.tank_vmax[t] * p.ucf[.VOLUME]
	case 17:
		if i > nj do v = libc.sqrt(4.0 / ep.PI * net.tank_area[t]) * p.ucf[.ELEV]
	case 18:
		if i > nj do v = net.tank_vmin[t] * p.ucf[.VOLUME]
	case 19:
		if i > nj do v = f64(net.tank_vcurve[t])
	case 20:
		if i > nj do v = (net.tank_hmin[t] - net.el[i]) * p.ucf[.ELEV]
	case 21:
		if i > nj do v = (net.tank_hmax[t] - net.el[i]) * p.ucf[.ELEV]
	case 22:
		v = 1
		if i > nj do v = net.tank_v1frac[t]
	case 23:
		if i > nj do v = net.tank_kb[t] * ep.SEC_PER_DAY
	case 24:
		if i <= nj do return 0
		v = ep.tank_volume(net, hyd, t, hyd.head[i]) * p.ucf[.VOLUME]
	case 25:
		if i > nj do v = net.tank_vmax[t] * p.ucf[.VOLUME]
	case 26:
		if net.node_type[i] != .TANK do return 0
		v = net.tank_overflow[t] ? 1 : 0
	case 27:
		if i > nj do return 0
		if hyd.full_demand[i] <= 0 do return 0
		v = max((hyd.full_demand[i] - hyd.demand_flow[i]) * p.ucf[.FLOW], 0)
	case 28:
		v = in_controls(p, 0, i) ? 1 : 0
	case 29:
		v = hyd.emitter_flow[i] * p.ucf[.FLOW]
	case 30:
		v = hyd.leak_flow[i] * p.ucf[.FLOW]
	case 31:
		v = hyd.demand_flow[i] * p.ucf[.FLOW]
	case 32:
		v = hyd.full_demand[i] * p.ucf[.FLOW]
	case:
		return 251
	}
	value^ = v
	return 0
}

@(export, link_name = "EN_getnodevalues")
EN_getnodevalues :: proc "c" (p: ^Project, property: c.int, values: [^]f64) -> c.int {
	for i in 1 ..= p.net.nnodes {
		if errcode := EN_getnodevalue(p, c.int(i), property, &values[i - 1]); errcode != 0 do return errcode
	}
	return 0
}

@(export, link_name = "EN_getcoord")
EN_getcoord :: proc "c" (p: ^Project, index: c.int, x, y: ^f64) -> c.int {
	if !p.openflag do return 102
	if index < 1 || int(index) > p.net.nnodes do return 203
	if p.node_x[index] == ep.MISSING || p.node_y[index] == ep.MISSING do return 254
	x^ = p.node_x[index]
	y^ = p.node_y[index]
	return 0
}

@(export, link_name = "EN_getdemandmodel")
EN_getdemandmodel :: proc "c" (p: ^Project, model: ^c.int, pmin, preq, pexp: ^f64) -> c.int {
	model^ = c.int(p.hyd.demand_model)
	pmin^ = p.hyd.pmin * p.ucf[.PRESSURE]
	preq^ = p.hyd.preq * p.ucf[.PRESSURE]
	pexp^ = p.hyd.pexp
	return 0
}

// demand_slot: node i's k-th demand (1-based), or -1.
demand_slot :: proc "contextless" (p: ^Project, i, k: int) -> int {
	net := &p.net
	first, last := int(net.demand_first[i]), int(net.demand_first[i + 1])
	if k < 1 || first + k - 1 >= last do return -1
	return first + k - 1
}

@(export, link_name = "EN_getnumdemands")
EN_getnumdemands :: proc "c" (p: ^Project, node: c.int, n: ^c.int) -> c.int {
	if !p.openflag do return 102
	if node <= 0 || int(node) > p.net.nnodes do return 203
	n^ = c.int(p.net.demand_first[node + 1] - p.net.demand_first[node])
	return 0
}

@(export, link_name = "EN_getdemandindex")
EN_getdemandindex :: proc "c" (p: ^Project, node: c.int, name: cstring, index: ^c.int) -> c.int {
	index^ = 0
	if !p.openflag do return 102
	if node <= 0 || int(node) > p.net.nnodes do return 203
	if name == nil do return 253
	s := string(name)
	net := &p.net
	for k in net.demand_first[node] ..< net.demand_first[node + 1] {
		if p.demand_name[k] == s {
			index^ = c.int(k - net.demand_first[node] + 1)
			return 0
		}
	}
	return 253
}

@(export, link_name = "EN_getbasedemand")
EN_getbasedemand :: proc "c" (p: ^Project, node, demand: c.int, base: ^f64) -> c.int {
	base^ = 0
	if !p.openflag do return 102
	if node <= 0 || int(node) > p.net.nnodes do return 203
	k := demand_slot(p, int(node), int(demand))
	if k < 0 do return 253
	base^ = p.net.demand_base[k] * p.ucf[.FLOW]
	return 0
}

@(export, link_name = "EN_getdemandname")
EN_getdemandname :: proc "c" (p: ^Project, node, demand: c.int, name: [^]u8) -> c.int {
	name[0] = 0
	if !p.openflag do return 102
	if node <= 0 || int(node) > p.net.njuncs do return 203
	k := demand_slot(p, int(node), int(demand))
	if k < 0 do return 253
	put_str(name, p.demand_name[k], MAXID)
	return 0
}

@(export, link_name = "EN_getdemandpattern")
EN_getdemandpattern :: proc "c" (p: ^Project, node, demand: c.int, pat: ^c.int) -> c.int {
	pat^ = 0
	if !p.openflag do return 102
	if node <= 0 || int(node) > p.net.nnodes do return 203
	k := demand_slot(p, int(node), int(demand))
	if k < 0 do return 253
	pat^ = c.int(p.net.demand_pat[k])
	return 0
}

// ── links ─────────────────────────────────────────────────────────────

@(export, link_name = "EN_getlinkindex")
EN_getlinkindex :: proc "c" (p: ^Project, id: cstring, index: ^c.int) -> c.int {
	context = runtime.default_context()
	index^ = 0
	if !p.openflag do return 102
	index^ = c.int(ep.findlink(p, string(id)))
	return index^ == 0 ? 204 : 0
}

@(export, link_name = "EN_getlinkid")
EN_getlinkid :: proc "c" (p: ^Project, index: c.int, id: [^]u8) -> c.int {
	id[0] = 0
	if !p.openflag do return 102
	if index < 1 || int(index) > p.net.nlinks do return 204
	put_str(id, p.link_id[index], MAXID)
	return 0
}

@(export, link_name = "EN_getlinktype")
EN_getlinktype :: proc "c" (p: ^Project, index: c.int, link_type: ^c.int) -> c.int {
	link_type^ = -1
	if !p.openflag do return 102
	if index < 1 || int(index) > p.net.nlinks do return 204
	link_type^ = c.int(p.net.link_type[index])
	return 0
}

@(export, link_name = "EN_getlinknodes")
EN_getlinknodes :: proc "c" (p: ^Project, index: c.int, node1, node2: ^c.int) -> c.int {
	node1^, node2^ = 0, 0
	if !p.openflag do return 102
	if index < 1 || int(index) > p.net.nlinks do return 204
	node1^ = c.int(p.net.n1[index])
	node2^ = c.int(p.net.n2[index])
	return 0
}

@(export, link_name = "EN_getlinkvalue")
EN_getlinkvalue :: proc "c" (p: ^Project, index: c.int, property: c.int, value: ^f64) -> c.int {
	net, hyd := &p.net, &p.hyd
	value^ = 0
	if !p.openflag do return 102
	k := int(index)
	if k <= 0 || k > net.nlinks do return 204
	lt := net.link_type[k]
	m := int(net.link_pump[k])
	v := 0.0
	switch property {
	case 0:
		if lt != .PUMP do v = net.diam[k] * p.ucf[.DIAM]
	case 1:
		v = net.len[k] * p.ucf[.ELEV]
	case 2:
		if lt <= .PIPE {
			v = hyd.formflag == .DW ? net.kc[k] * (1000.0 * p.ucf[.ELEV]) : net.kc[k]
		}
	case 3:
		if lt != .PUMP {
			d2 := net.diam[k] * net.diam[k]
			v = net.km[k] * (d2 * d2 / 0.02517)
		}
	case 4:
		v = net.init_status[k] <= .CLOSED ? 0 : 1
		if lt > .PUMP && net.init_status[k] > .OPEN do v = 2
	case 5:
		v = net.init_setting[k]
		#partial switch lt {
		case .CVPIPE, .PIPE:
			if hyd.formflag == .DW do v = v * (1000.0 * p.ucf[.ELEV])
		case .PRV, .PSV, .PBV:
			v *= p.ucf[.PRESSURE]
		case .FCV:
			v *= p.ucf[.FLOW]
		}
	case 6:
		v = net.link_kb[k] * ep.SEC_PER_DAY
	case 7:
		v = net.link_kw[k] * ep.SEC_PER_DAY
	case 8:
		if hyd.status[k] > .CLOSED do v = hyd.flow[k] * p.ucf[.FLOW]
	case 9:
		if lt != .PUMP && hyd.status[k] > .CLOSED {
			qq := abs(hyd.flow[k])
			a := ep.PI * (net.diam[k] * net.diam[k]) / 4.0
			v = qq / a * p.ucf[.VELOCITY]
		}
	case 10:
		if hyd.status[k] > .CLOSED {
			h := hyd.head[net.n1[k]] - hyd.head[net.n2[k]]
			if lt != .PUMP do h = abs(h)
			v = h * p.ucf[.HEADLOSS]
		}
	case 11:
		v = hyd.status[k] <= .CLOSED ? 0 : 1
		if lt > .PUMP && hyd.status[k] > .OPEN do v = 2
	case 12:
		if lt == .PIPE || lt == .CVPIPE do return EN_getlinkvalue(p, index, 2, value)
		v = hyd.setting[k] == ep.MISSING ? 0 : hyd.setting[k]
		#partial switch lt {
		case .PRV, .PSV, .PBV:
			v *= p.ucf[.PRESSURE]
		case .FCV:
			v *= p.ucf[.FLOW]
		}
	case 13:
		v, _ = ep.get_energy(net, hyd, k)
	case 14:
		if p.q.segs != nil do v = ep.avg_qual(net, &p.q, k) * p.ucf[.LINKQUAL]
	case 15:
		if lt == .PUMP do v = f64(net.pump_upat[m])
	case 16:
		v = f64(hyd.status[k])
		if lt == .PUMP && hyd.status[k] >= .OPEN {
			if hyd.flow[k] > hyd.setting[k] * p.pump_qmax[m] do v = f64(ep.Status.XFLOW)
			if hyd.flow[k] < 0 do v = f64(ep.Status.XHEAD)
		}
	case 17:
		_, v = ep.get_energy(net, hyd, k)
	case 18:
		if lt == .PUMP && net.pump_type[m] == .CONST_HP do v = net.km[k]
	case 19:
		if lt == .PUMP do v = f64(net.pump_hcurve[m])
	case 20:
		if lt == .PUMP do v = f64(net.pump_ecurve[m])
	case 21:
		if lt == .PUMP do v = net.pump_ecost[m]
	case 22:
		if lt == .PUMP do v = f64(net.pump_epat[m])
	case 23:
		v = in_controls(p, 1, k) ? 1 : 0
	case 24:
		if lt == .GPV do v = net.kc[k]
	case 25:
		if lt == .PCV do v = f64(net.valve_curve[net.link_valve[k]])
	case 26:
		v = net.leak_area[k] / p.ucf[.LENGTH]
	case 27:
		v = net.leak_expan[k] / p.ucf[.LENGTH]
	case 28:
		v = ep.find_link_leakage(p, k) * p.ucf[.FLOW]
	case 29:
		if lt > .PUMP do v = f64(lt)
	case:
		return 251
	}
	value^ = v
	return 0
}

@(export, link_name = "EN_getlinkvalues")
EN_getlinkvalues :: proc "c" (p: ^Project, property: c.int, values: [^]f64) -> c.int {
	for i in 1 ..= p.net.nlinks {
		if errcode := EN_getlinkvalue(p, c.int(i), property, &values[i - 1]); errcode != 0 do return errcode
	}
	return 0
}

@(export, link_name = "EN_getvertexcount")
EN_getvertexcount :: proc "c" (p: ^Project, index: c.int, count: ^c.int) -> c.int {
	count^ = 0
	if !p.openflag do return 102
	if index <= 0 || int(index) > p.net.nlinks do return 204
	count^ = c.int(len(p.vertex_x[index]))
	return 0
}

@(export, link_name = "EN_getpumptype")
EN_getpumptype :: proc "c" (p: ^Project, link: c.int, pump_type: ^c.int) -> c.int {
	pump_type^ = -1
	if !p.openflag do return 102
	if link < 1 || int(link) > p.net.nlinks do return 204
	if p.net.link_type[link] != .PUMP do return 216
	pump_type^ = c.int(p.net.pump_type[p.net.link_pump[link]])
	return 0
}

@(export, link_name = "EN_getheadcurveindex")
EN_getheadcurveindex :: proc "c" (p: ^Project, link: c.int, curve: ^c.int) -> c.int {
	curve^ = 0
	if !p.openflag do return 102
	if link < 1 || int(link) > p.net.nlinks do return 204
	if p.net.link_type[link] != .PUMP do return 216
	curve^ = c.int(p.net.pump_hcurve[p.net.link_pump[link]])
	return 0
}

// ── patterns and curves ───────────────────────────────────────────────

@(export, link_name = "EN_getpatternindex")
EN_getpatternindex :: proc "c" (p: ^Project, id: cstring, index: ^c.int) -> c.int {
	index^ = 0
	if !p.openflag do return 102
	s := string(id)
	for i in 1 ..< len(p.pattern_id) {
		if p.pattern_id[i] == s {
			index^ = c.int(i)
			return 0
		}
	}
	return 205
}

@(export, link_name = "EN_getpatternid")
EN_getpatternid :: proc "c" (p: ^Project, index: c.int, id: [^]u8) -> c.int {
	id[0] = 0
	if !p.openflag do return 102
	if index < 1 || int(index) >= len(p.pattern_id) do return 205
	put_str(id, p.pattern_id[index], MAXID)
	return 0
}

@(export, link_name = "EN_getpatternlen")
EN_getpatternlen :: proc "c" (p: ^Project, index: c.int, n: ^c.int) -> c.int {
	if !p.openflag do return 102
	if index < 1 || int(index) >= len(p.net.patterns) do return 205
	n^ = c.int(len(p.net.patterns[index].f))
	return 0
}

@(export, link_name = "EN_getpatternvalue")
EN_getpatternvalue :: proc "c" (p: ^Project, index, period: c.int, value: ^f64) -> c.int {
	value^ = 0
	if !p.openflag do return 102
	if index < 1 || int(index) >= len(p.net.patterns) do return 205
	f := p.net.patterns[index].f
	if period < 1 || int(period) > len(f) do return 251
	value^ = f[period - 1]
	return 0
}

@(export, link_name = "EN_getaveragepatternvalue")
EN_getaveragepatternvalue :: proc "c" (p: ^Project, index: c.int, value: ^f64) -> c.int {
	value^ = 0
	if !p.openflag do return 102
	if index < 0 || int(index) >= len(p.net.patterns) do return 205
	f := p.net.patterns[index].f
	for x in f do value^ += x
	value^ /= f64(len(f))
	return 0
}

@(export, link_name = "EN_getcurveindex")
EN_getcurveindex :: proc "c" (p: ^Project, id: cstring, index: ^c.int) -> c.int {
	context = runtime.default_context()
	index^ = 0
	if !p.openflag do return 102
	index^ = c.int(ep.findcurve(p, string(id)))
	return index^ == 0 ? 206 : 0
}

@(export, link_name = "EN_getcurveid")
EN_getcurveid :: proc "c" (p: ^Project, index: c.int, id: [^]u8) -> c.int {
	id[0] = 0
	if !p.openflag do return 102
	if index < 1 || int(index) >= len(p.curve_id) do return 206
	put_str(id, p.curve_id[index], MAXID)
	return 0
}

@(export, link_name = "EN_getcurvelen")
EN_getcurvelen :: proc "c" (p: ^Project, index: c.int, n: ^c.int) -> c.int {
	if !p.openflag do return 102
	if index < 1 || int(index) >= len(p.net.curves) do return 206
	n^ = c.int(len(p.net.curves[index].x))
	return 0
}

@(export, link_name = "EN_getcurvetype")
EN_getcurvetype :: proc "c" (p: ^Project, index: c.int, kind: ^c.int) -> c.int {
	if !p.openflag do return 102
	if index < 1 || int(index) >= len(p.net.curves) do return 206
	kind^ = c.int(p.curve_type[index])
	return 0
}

@(export, link_name = "EN_getcurvevalue")
EN_getcurvevalue :: proc "c" (p: ^Project, curve, point: c.int, x, y: ^f64) -> c.int {
	x^, y^ = 0, 0
	if !p.openflag do return 102
	if curve < 1 || int(curve) >= len(p.net.curves) do return 206
	cv := p.net.curves[curve]
	if point < 1 || int(point) > len(cv.x) do return 251
	x^ = cv.x[point - 1]
	y^ = cv.y[point - 1]
	return 0
}

@(export, link_name = "EN_getcurve")
EN_getcurve :: proc "c" (p: ^Project, index: c.int, id: [^]u8, n: ^c.int, xs, ys: [^]f64) -> c.int {
	if !p.openflag do return 102
	if index <= 0 || int(index) >= len(p.net.curves) do return 206
	if xs == nil || ys == nil do return 206
	cv := p.net.curves[index]
	put_str(id, p.curve_id[index], MAXID)
	n^ = c.int(len(cv.x))
	for i in 0 ..< len(cv.x) {
		xs[i] = cv.x[i]
		ys[i] = cv.y[i]
	}
	return 0
}

// ── controls and rules ────────────────────────────────────────────────

@(export, link_name = "EN_getcontrol")
EN_getcontrol :: proc "c" (p: ^Project, index: c.int, kind, link: ^c.int, setting: ^f64, node: ^c.int, level: ^f64) -> c.int {
	net := &p.net
	kind^, link^, node^ = 0, 0, 0
	if !p.openflag do return 102
	if index <= 0 || int(index) > net.ncontrols do return 241
	i := int(index)
	kind^ = c.int(net.control_type[i])
	link^ = c.int(net.control_link[i])
	s := net.control_setting[i]
	if s != ep.MISSING {
		#partial switch net.link_type[net.control_link[i]] {
		case .PRV, .PSV, .PBV:
			s *= p.ucf[.PRESSURE]
		case .FCV:
			s *= p.ucf[.FLOW]
		}
	} else if net.control_status[i] == .OPEN {
		s = 1.e10
	} else {
		s = -1.e10
	}
	node^ = c.int(net.control_node[i])
	lvl: f64
	if n := int(net.control_node[i]); n > 0 {
		if n > net.njuncs {
			lvl = (net.control_grade[i] - net.el[n]) * p.ucf[.ELEV]
		} else {
			lvl = (net.control_grade[i] - net.el[n]) * p.ucf[.PRESSURE]
		}
	} else {
		lvl = f64(net.control_time[i])
	}
	setting^ = s
	level^ = lvl
	return 0
}

@(export, link_name = "EN_getcontrolenabled")
EN_getcontrolenabled :: proc "c" (p: ^Project, index: c.int, enabled: ^c.int) -> c.int {
	if !p.openflag do return 102
	if index <= 0 || int(index) > p.net.ncontrols do return 241
	enabled^ = c.int(p.net.control_enabled[index])
	return 0
}

@(export, link_name = "EN_getrule")
EN_getrule :: proc "c" (p: ^Project, index: c.int, npremises, nthen, nelse: ^c.int, priority: ^f64) -> c.int {
	net := &p.net
	if index < 1 || int(index) > net.nrules do return 257
	i := int(index)
	priority^ = net.rule_priority[i]
	npremises^ = c.int(net.rule_premise_first[i + 1] - net.rule_premise_first[i])
	nthen^ = c.int(net.rule_else_first[i] - net.rule_then_first[i])
	nelse^ = c.int(net.rule_then_first[i + 1] - net.rule_else_first[i])
	return 0
}

@(export, link_name = "EN_getruleID")
EN_getruleID :: proc "c" (p: ^Project, index: c.int, id: [^]u8) -> c.int {
	id[0] = 0
	if !p.openflag do return 102
	if index < 1 || int(index) > p.net.nrules do return 257
	put_str(id, p.rule_label[index], MAXID)
	return 0
}

@(export, link_name = "EN_getpremise")
EN_getpremise :: proc "c" (p: ^Project, rule, premise: c.int, logop, object, obj_index, variable, relop, status: ^c.int, value: ^f64) -> c.int {
	net := &p.net
	if rule < 1 || int(rule) > net.nrules do return 257
	k := int(net.rule_premise_first[rule]) + int(premise) - 1
	if premise < 1 || k >= int(net.rule_premise_first[rule + 1]) do return 258
	logop^ = c.int(net.premise_logop[k])
	object^ = c.int(net.premise_object[k])
	obj_index^ = c.int(net.premise_index[k])
	variable^ = c.int(net.premise_variable[k])
	relop^ = c.int(net.premise_relop[k])
	status^ = c.int(net.premise_status[k])
	value^ = net.premise_value[k]
	return 0
}

get_action :: proc "contextless" (p: ^Project, from, to: i32, n: c.int, link, status: ^c.int, setting: ^f64) -> c.int {
	net := &p.net
	k := int(from) + int(n) - 1
	if n < 1 || k >= int(to) do return 258
	link^ = c.int(net.action_link[k])
	status^ = c.int(net.action_status[k])
	setting^ = net.action_setting[k]
	return 0
}

@(export, link_name = "EN_getthenaction")
EN_getthenaction :: proc "c" (p: ^Project, rule, action: c.int, link, status: ^c.int, setting: ^f64) -> c.int {
	net := &p.net
	if rule < 1 || int(rule) > net.nrules do return 257
	return get_action(p, net.rule_then_first[rule], net.rule_else_first[rule], action, link, status, setting)
}

@(export, link_name = "EN_getelseaction")
EN_getelseaction :: proc "c" (p: ^Project, rule, action: c.int, link, status: ^c.int, setting: ^f64) -> c.int {
	net := &p.net
	if rule < 1 || int(rule) > net.nrules do return 257
	return get_action(p, net.rule_else_first[rule], net.rule_then_first[rule + 1], action, link, status, setting)
}

@(export, link_name = "EN_getruleenabled")
EN_getruleenabled :: proc "c" (p: ^Project, index: c.int, enabled: ^c.int) -> c.int {
	if !p.openflag do return 102
	if index <= 0 || int(index) > p.net.nrules do return 241
	enabled^ = c.int(p.net.rule_enabled[index])
	return 0
}
