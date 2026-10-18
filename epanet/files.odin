#+build !wasm32
package epanet

// files.odin — what reads or writes a file: the .inp reader's file entry
// (parse_inp, read_inp), the Model's (load, write_inp), and the quality
// run read back from the hydraulics file (initqual, runqual, nextqual,
// stepqual). The wasm build has none of it: a Model comes in as text
// (parse) and a Sim as columns.

import "core:c/libc"
import "core:os"

// parse_inp reads the file into a new project. Returns the project and
// EPANET's error code: 0, 200 when lines had errors, or a fatal code.
parse_inp :: proc(path: string) -> (p: ^Project, errcode: int) {
	p = project_new()
	if p == nil do return nil, 101
	errcode = read_inp(p, path)
	if errcode == 302 {
		project_free(p)
		return nil, errcode
	}
	return
}

// read_inp reads the file into an existing project, from its arena.
read_inp :: proc(p: ^Project, path: string) -> (errcode: int) {
	context.allocator = arena_allocator(&p.arena)
	data, rerr := os.read_entire_file_from_path(path, context.allocator)
	if rerr != nil do return 302
	errcode = read_text(p, string(data))
	if errcode == 0 || errcode == 200 do finish_project(p)
	return
}

// load reads an .inp file. A file with bad lines still comes back, its
// problems listed and err == .Input_Errors. Everything the Model holds
// comes from one arena; delete_model gives it back.
load :: proc(path: string, allocator := context.allocator) -> (m: Model, err: Error) {
	data, rerr := os.read_entire_file_from_path(path, context.temp_allocator)
	if rerr != nil do return m, .Cannot_Open_Input
	return parse(string(data), allocator)
}

// write_inp writes the Model as an .inp file, in EPANET's own layout.
write_inp :: proc(m: ^Model, path: string) -> Error {
	b := project_from_model(m)
	if b.p == nil do return b.err
	defer project_free(b.p)
	if b.err != nil do return b.err
	return Error(save_inp(b.p, path))
}

// ── the quality run over the hydraulics file ──────────────────────────

// initqual starts the quality run at time zero.
initqual :: proc(p: ^Project) -> int {
	t := &p.times
	if !p.open_hflag do libc.fseek(p.out.hyd_file, libc.long(p.out.hyd_offset), .SET)
	t.qtime = 0
	t.htime = 0
	t.rtime = t.rstart
	p.rpt.nperiods = 0
	init_qual(&p.net, &p.hyd, &p.q)
	return 0
}

// runqual brings the hydraulics for the next period in (from the file
// when the hydraulic solver is closed) and saves the period's results.
runqual :: proc(p: ^Project) -> (t: i64, errcode: int) {
	q, tm := &p.q, &p.times
	t = tm.qtime
	hydtime, hydstep: i64
	if tm.qtime == tm.htime {
		if !p.open_hflag {
			if !readhyd(p, &hydtime) do return t, 307
			if !readhydstep(p, &hydstep) do return t, 307
			tm.htime = hydtime
		}
		if tm.htime >= tm.rtime {
			if p.out.saveflag {
				errcode = saveoutput(p)
				p.rpt.nperiods += 1
			}
			tm.rtime += tm.rstep
		}
		if errcode != 0 do return
		if q.kind != .NONE && tm.qtime < tm.dur {
			errcode = new_hydraulics(&p.net, &p.hyd, q)
		}
		if !p.open_hflag do tm.htime = hydtime + hydstep
	}
	return
}

// nextqual moves quality through the period to the next hydraulic time.
nextqual :: proc(p: ^Project) -> (tstep: i64, errcode: int) {
	q, tm := &p.q, &p.times
	hydstep: i64 = 0
	if tm.htime <= tm.dur do hydstep = tm.htime - tm.qtime
	if q.kind != .NONE && hydstep > 0 {
		qtime: i64 = 0
		for !q.out_of_memory && qtime < hydstep {
			dt := min(tm.qstep, hydstep - qtime)
			qtime += dt
			transport(&p.net, &p.hyd, tm, q, dt)
		}
		if q.out_of_memory do errcode = 101
	}
	eval_mass_balance(&p.net, q)
	if errcode == 0 do tstep = hydstep
	tm.qtime += hydstep
	if errcode == 0 && tstep == 0 {
		if q.kind != .NONE && p.rpt.status != 0 do writemassbalance(p)
		if p.out.saveflag do errcode = savefinaloutput(p)
	}
	return
}

// stepqual moves quality one quality time step, reading hydraulics as
// it needs them.
stepqual :: proc(p: ^Project) -> (tleft: i64, errcode: int) {
	q, tm := &p.q, &p.times
	tstep := tm.qstep
	for {
		dt := tstep
		hstep := tm.htime - tm.qtime
		if hstep < dt {
			dt = hstep
			if q.kind != .NONE do transport(&p.net, &p.hyd, tm, q, dt)
			tm.qtime += dt
			if p.open_hflag do break
			t: i64
			t, errcode = runqual(p)
			tm.qtime = t
		} else {
			if q.kind != .NONE do transport(&p.net, &p.hyd, tm, q, dt)
			tm.qtime += dt
		}
		tstep -= dt
		if q.out_of_memory do errcode = 101
		if errcode != 0 || tstep <= 0 do break
	}
	eval_mass_balance(&p.net, q)
	tleft = tm.dur - tm.qtime
	if errcode == 0 && tleft == 0 {
		if q.kind != .NONE && p.rpt.status != 0 do writemassbalance(p)
		if p.out.saveflag do errcode = savefinaloutput(p)
	}
	return
}
