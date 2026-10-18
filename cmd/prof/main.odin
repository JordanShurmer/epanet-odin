package prof

// prof — the Odin engine's hot path and memory, one network at a time.
//
//   prof <file.inp>              load, build, step to the end; the figures
//   prof <file.inp> -reps 5      the run five times; the step loop's best and mean
//   prof <file.inp> -steps       + one line per step: time, trials, segments, arena
//
// What it prints: the network's size and run, the time of each stage
// (load, the engine built on the first step, the steps), and — when the
// engine is built with -define:PROF=true — the phases of a step from
// epanet/prof.odin, each with its calls, its share of the step and its
// mean. Then memory: the project's arena, the segments, what the Sim's
// allocator and the temporary allocator were asked for during the
// steps, and the process's resident set. A step that allocates is a
// smell; an arena that grows step over step is a leak into it.
//
// audit/prof.sh builds and runs it, with callgrind and memcheck beside.

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"

import "../../epanet"

// Counting is an allocator that counts what passes through to another.
Counting :: struct {
	backing:                 runtime.Allocator,
	allocs, frees, resizes:  int,
	bytes:                   int, // asked for, net of resizes
}

counting_allocator :: proc(c: ^Counting) -> runtime.Allocator {
	return {counting_proc, c}
}

counting_proc :: proc(data: rawptr, mode: runtime.Allocator_Mode, size, alignment: int, old_memory: rawptr, old_size: int, loc := #caller_location) -> ([]byte, runtime.Allocator_Error) {
	c := (^Counting)(data)
	#partial switch mode {
	case .Alloc, .Alloc_Non_Zeroed:
		c.allocs += 1
		c.bytes += size
	case .Free:
		c.frees += 1
	case .Resize, .Resize_Non_Zeroed:
		c.resizes += 1
		c.bytes += size - old_size
	}
	return c.backing.procedure(c.backing.data, mode, size, alignment, old_memory, old_size, loc)
}

// Run is what one pass through a network measured.
Run :: struct {
	load_ns, build_ns, steps_ns: i64,
	steps, trials, max_trials:   int,
	nodes, links, njuncs:        int,
	duration:                    i64,
	warnings:                    int,
	segs_cap, segs_live:         int, // the segment store's slots, and those in a chain
	nchem:                       int,
	arena_used, arena_reserved:  uint,
	arena_after_build:           uint,
	sim_allocs, temp_allocs:     Counting, // during the steps
}

Step_Line :: struct {
	t:          i32,
	ns:         i64,
	trials:     int,
	segs:       int,
	arena_used: uint,
}

main :: proc() {
	path := ""
	reps := 1
	want_steps := false
	args := os.args[1:]
	for i := 0; i < len(args); i += 1 {
		switch args[i] {
		case "-reps":
			i += 1
			if i < len(args) do reps, _ = strconv.parse_int(args[i])
		case "-steps":
			want_steps = true
		case:
			path = args[i]
		}
	}
	if path == "" {
		fmt.eprintln("usage: prof <file.inp> [-reps N] [-steps]")
		os.exit(2)
	}
	if reps < 1 do reps = 1

	// every allocation of the program is counted; the step loop's share
	// is read off before and after it
	sim_count := Counting{backing = context.allocator}
	temp_count := Counting{backing = context.temp_allocator}
	context.allocator = counting_allocator(&sim_count)
	context.temp_allocator = counting_allocator(&temp_count)

	best: Run
	mean_steps_ns: i64
	lines: [dynamic]Step_Line
	cycles0, wall0 := epanet.prof_now(), time.tick_now()
	for r in 0 ..< reps {
		epanet.prof_reset()
		run := one_run(path, &sim_count, &temp_count, want_steps && r == reps - 1 ? &lines : nil)
		mean_steps_ns += run.steps_ns
		if r == 0 || run.steps_ns < best.steps_ns do best = run
	}
	mean_steps_ns /= i64(reps)
	// the stopwatch counts cycles: this many per nanosecond, over the run
	ns_per_cycle := f64(time.tick_since(wall0)) / f64(max(epanet.prof_now() - cycles0, 1))

	r := &best
	fmt.printf("network   %s\n", path)
	fmt.printf("size      %d nodes (%d junctions), %d links, %d chemical(s)\n", r.nodes, r.njuncs, r.links, r.nchem)
	fmt.printf("run       %s, %d steps, %d trials (%.2f per step, %d at most), %d warnings\n",
		clock(r.duration), r.steps, r.trials, f64(r.trials) / f64(max(r.steps, 1)), r.max_trials, r.warnings)
	fmt.println()
	fmt.printf("load      %s\n", ms(r.load_ns))
	fmt.printf("build     %s   (the engine's project, matrix shape and solvers, on the first step)\n", ms(r.build_ns))
	if reps > 1 {
		fmt.printf("steps     %s best of %d, %s mean   (%s per step, %s per trial)\n",
			ms(r.steps_ns), reps, ms(mean_steps_ns), us(r.steps_ns / i64(max(r.steps, 1))), us(r.steps_ns / i64(max(r.trials, 1))))
	} else {
		fmt.printf("steps     %s   (%s per step, %s per trial)\n", ms(r.steps_ns), us(r.steps_ns / i64(max(r.steps, 1))), us(r.steps_ns / i64(max(r.trials, 1))))
	}

	if epanet.PROF {
		fmt.println()
		fmt.println("phase             calls       total  of step    per call")
		p := &epanet.prof
		ns: [epanet.Prof_Phase]i64
		for ph in epanet.Prof_Phase do ns[ph] = i64(f64(p.cycles[ph]) * ns_per_cycle)
		step_ns := max(ns[.step], 1)
		accounted: i64
		for ph in epanet.Prof_Phase {
			if p.calls[ph] == 0 do continue
			if ph != .step do accounted += ns[ph]
			fmt.printf("%-15s % 7d %11s % 7.1f%% %11s\n", ph, p.calls[ph], ms(ns[ph]), 100 * f64(ns[ph]) / f64(step_ns), us(ns[ph] / p.calls[ph]))
		}
		fmt.printf("%-15s % 7s %11s % 7.1f%%\n", "(unaccounted)", "", ms(ns[.step] - accounted), 100 * f64(ns[.step] - accounted) / f64(step_ns))
	} else {
		fmt.println()
		fmt.println("(build with -define:PROF=true for the phases of a step)")
	}

	fmt.println()
	fmt.printf("arena     %s used of %s reserved; %s after build, so the steps grew it by %s\n",
		kb(int(r.arena_used)), kb(int(r.arena_reserved)), kb(int(r.arena_after_build)), kb(int(r.arena_used) - int(r.arena_after_build)))
	fmt.printf("segments  %d slots, %d in chains\n", r.segs_cap, r.segs_live)
	fmt.printf("allocs    sim: %d allocs, %d resizes, %d frees, %s during the steps\n", r.sim_allocs.allocs, r.sim_allocs.resizes, r.sim_allocs.frees, kb(r.sim_allocs.bytes))
	fmt.printf("          temp: %d allocs, %d resizes, %d frees, %s during the steps\n", r.temp_allocs.allocs, r.temp_allocs.resizes, r.temp_allocs.frees, kb(r.temp_allocs.bytes))
	rss, hwm := rss_kb()
	fmt.printf("rss       %d kB now, %d kB peak\n", rss, hwm)

	if want_steps {
		fmt.println()
		fmt.println("       t        step  trials    segs      arena")
		for l in lines {
			fmt.printf("% 8s % 11s % 7d % 7d % 10s\n", clock(i64(l.t)), us(l.ns), l.trials, l.segs, kb(int(l.arena_used)))
		}
	}
}

// one_run: the whole of a run, measured.
one_run :: proc(path: string, sim_count, temp_count: ^Counting, lines: ^[dynamic]Step_Line) -> (r: Run) {
	t0 := time.tick_now()
	model, err := epanet.load(path)
	if err != nil && err != .Input_Errors do fail("load", err)
	defer epanet.delete_model(&model)
	sim, ids, ferr := epanet.sim_from_model(&model)
	if ferr != nil do fail("sim_from_model", ferr)
	defer epanet.sim_delete(&sim)
	defer epanet.delete_ids(&ids)
	r.load_ns = i64(time.tick_since(t0))
	r.duration = model.times.duration
	r.nodes, r.links = sim.nodes.count, sim.links.count
	r.nchem = len(sim.chemicals)

	// the first step builds the engine (and solves once: that solve is
	// the build's); the build's own allocations are not the steps'
	t0 = time.tick_now()
	_, _, berr := epanet.sim_step(&sim)
	if berr != nil do fail("first step", berr)
	r.build_ns = i64(time.tick_since(t0))
	if sim.engine != nil {
		r.njuncs = sim.engine.net.njuncs
		r.arena_after_build = sim.engine.arena.total_used
	}
	before_sim, before_temp := sim_count^, temp_count^
	r.steps = 1
	r.trials = trials_of(&sim)
	r.max_trials = r.trials
	t0 = time.tick_now()
	for {
		at := sim.t
		ts := time.tick_now()
		dt, warn, serr := epanet.sim_step(&sim)
		if serr != nil do fail("step", serr)
		n := trials_of(&sim)
		r.steps += 1
		r.trials += n
		r.max_trials = max(r.max_trials, n)
		if warn != nil && warn != .Nothing_To_Solve do r.warnings += 1
		if lines != nil {
			append(lines, Step_Line{at, i64(time.tick_since(ts)), n, segs_of(&sim), arena_used(&sim)})
		}
		if dt == 0 do break
	}
	r.steps_ns = i64(time.tick_since(t0))
	r.sim_allocs = {allocs = sim_count.allocs - before_sim.allocs, frees = sim_count.frees - before_sim.frees, resizes = sim_count.resizes - before_sim.resizes, bytes = sim_count.bytes - before_sim.bytes}
	r.temp_allocs = {allocs = temp_count.allocs - before_temp.allocs, frees = temp_count.frees - before_temp.frees, resizes = temp_count.resizes - before_temp.resizes, bytes = temp_count.bytes - before_temp.bytes}
	if sim.engine != nil {
		r.arena_used = sim.engine.arena.total_used
		r.arena_reserved = sim.engine.arena.total_reserved
	}
	r.segs_live = segs_of(&sim)
	for cs in sim.chems do if cs.q.segs != nil do r.segs_cap += len(cs.q.segs.at) - 1
	return
}

trials_of :: proc(sim: ^epanet.Sim) -> int {
	if sim.engine == nil do return 0
	return sim.engine.hyd.iterations
}

// segs_of: the segments in every chain, over every chemical, counted
// by walking the chains.
segs_of :: proc(sim: ^epanet.Sim) -> int {
	n := 0
	for cs in sim.chems {
		s := cs.q.segs
		if s == nil do continue
		for k in 0 ..< len(s.first) {
			for i := s.first[k]; i != 0; i = s.at[i].prev do n += 1
		}
	}
	return n
}

arena_used :: proc(sim: ^epanet.Sim) -> uint {
	if sim.engine == nil do return 0
	return sim.engine.arena.total_used
}

// rss_kb: the resident set now and at its peak, from /proc (0 elsewhere).
rss_kb :: proc() -> (rss, hwm: int) {
	data, rerr := os.read_entire_file_from_path("/proc/self/status", context.temp_allocator)
	if rerr != nil do return
	text := string(data)
	for line in strings.split_lines_iterator(&text) {
		if strings.has_prefix(line, "VmRSS:") do rss = kb_field(line)
		if strings.has_prefix(line, "VmHWM:") do hwm = kb_field(line)
	}
	return
}

kb_field :: proc(line: string) -> int {
	fields := strings.fields(line, context.temp_allocator)
	if len(fields) < 2 do return 0
	n, _ := strconv.parse_int(fields[1])
	return n
}

ms :: proc(ns: i64) -> string {
	return fmt.tprintf("%.2f ms", f64(ns) / 1e6)
}

us :: proc(ns: i64) -> string {
	return fmt.tprintf("%.1f µs", f64(ns) / 1e3)
}

kb :: proc(bytes: int) -> string {
	return fmt.tprintf("%d kB", bytes / 1024)
}

clock :: proc(seconds: i64) -> string {
	return fmt.tprintf("%d:%02d:%02d", seconds / 3600, seconds % 3600 / 60, seconds % 60)
}

fail :: proc(what: string, err: epanet.Error) {
	fmt.eprintf("prof: %s: EPANET error %d (%s)\n", what, int(err), epanet.error_text(err))
	os.exit(2)
}
