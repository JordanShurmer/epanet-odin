package epanet_wasm

// wasm/epanet.odin — the engine for JavaScript (API.md, WebAssembly): a
// handful of exported procs that take a ^Sim and plain numbers, and one
// that hands back the addresses of the columns, so a Float64Array view
// over the wasm memory is the engine's own column. No text, no file
// system, no name, no copy: the columns the game draws from are the
// engine's.
//
//   odin build wasm -target:freestanding_wasm32 -out:epanet.wasm -no-entry-point -o:speed
//
// epanet.js wraps it; check.mjs is its test. The module imports pow and
// exp (env.pow, env.exp) from the host, which epanet.js supplies from
// Math. Every export runs on the wasm heap, with a scratch arena for the
// engine's temporaries that is emptied when the call returns.

import "base:runtime"
import "core:mem"

import ep "../epanet"

// Columns is where every column lives: addresses into the wasm memory,
// which JavaScript reads as a table of 32-bit numbers in this order
// (epanet.js names them). The addresses move when rows outgrow the
// room, so a program reads the table again after node_add and link_add.
Columns :: struct {
	node_count, link_count, node_cap, link_cap: i32,
	// nodes, written by the caller
	node_kind:                                 [^]u8,
	elevation, demand, emitter, head:          [^]f64,
	level, min_level, max_level:               [^]f64,
	diameter, min_volume:                      [^]f64,
	// links, written by the caller
	link_kind:                                 [^]u8,
	from, to:                                  [^]i32,
	status:                                    [^]ep.Status,
	setting, length, link_diameter:            [^]f64,
	roughness, minor_loss:                     [^]f64,
	check_valve:                               [^]bool,
	pump_q, pump_h, pump_power:                [^]f64,
	// nodes, written by the step
	solved:                                    [^]bool,
	pressure, out_head, out_demand, wanted:    [^]f64,
	outflow, emitter_flow, leak_flow:          [^]f64,
	// links, written by the step
	flow, velocity, headloss, energy:          [^]f64,
	out_setting:                               [^]f64,
	out_status:                                [^]ep.Status,
}

columns: Columns
scratch: mem.Dynamic_Arena
scratch_ready: bool

// wasm_context: the wasm heap for everything that lasts, a scratch
// arena for the rest.
wasm_context :: proc() -> runtime.Context {
	c := context
	c.allocator = runtime.default_wasm_allocator()
	if !scratch_ready {
		mem.dynamic_arena_init(&scratch, c.allocator, c.allocator)
		scratch_ready = true
	}
	c.temp_allocator = mem.dynamic_arena_allocator(&scratch)
	return c
}

// ── a Sim ─────────────────────────────────────────────────────────────

@(export)
sim_new :: proc "c" (node_cap, link_cap: i32) -> ^ep.Sim {
	context = runtime.default_context()
	context = wasm_context()
	defer free_all(context.temp_allocator)
	sim := new(ep.Sim)
	sim^ = ep.sim_make(int(node_cap), int(link_cap), {}, context.allocator)
	return sim
}

@(export)
sim_free :: proc "c" (sim: ^ep.Sim) {
	context = runtime.default_context()
	context = wasm_context()
	defer free_all(context.temp_allocator)
	for &ch in sim.chemicals {
		delete(ch.init)
		delete(ch.sources)
	}
	delete(sim.chemicals)
	sim.chemicals = nil
	ep.sim_delete(sim)
	free(sim)
}

// sim_option sets one of Sim_Options by number (epanet.js names them);
// read on the next rewire, which this asks for.
@(export)
sim_option :: proc "c" (sim: ^ep.Sim, key: i32, value: f64) {
	o := &sim.options
	switch key {
	case 0:
		o.flow_units = ep.Flow_Units(int(value))
	case 1:
		o.pressure_units = ep.Pressure_Units(int(value))
	case 2:
		o.headloss = ep.Headloss_Formula(int(value))
	case 3:
		o.demand_model = ep.Demand_Model(int(value))
	case 4:
		o.min_pressure = value
	case 5:
		o.required_pressure = value
	case 6:
		o.pressure_exponent = value
	case 7:
		o.emitter_exponent = value
	case 8:
		o.trials = int(value)
	case 9:
		o.accuracy = value
	case 10:
		o.continue_unbalanced = value != 0
	case 11:
		o.extra_trials = int(value)
	case 12:
		o.hydraulic_step = i32(value)
	case 13:
		o.quality_step = i32(value)
	case 14:
		o.specific_gravity = value
	case 15:
		o.viscosity = value
	case 16:
		o.demand_multiplier = value
	}
	sim.rewire = true
}

// ── rows ──────────────────────────────────────────────────────────────

@(export)
sim_node_add :: proc "c" (sim: ^ep.Sim, kind: i32) -> i32 {
	context = runtime.default_context()
	context = wasm_context()
	defer free_all(context.temp_allocator)
	return i32(ep.node_add(sim, ep.Node_Kind(kind)))
}

@(export)
sim_node_remove :: proc "c" (sim: ^ep.Sim, i: i32) {
	context = runtime.default_context()
	context = wasm_context()
	ep.node_remove(sim, int(i))
}

@(export)
sim_link_add :: proc "c" (sim: ^ep.Sim, kind, from, to: i32) -> i32 {
	context = runtime.default_context()
	context = wasm_context()
	defer free_all(context.temp_allocator)
	return i32(ep.link_add(sim, ep.Link_Kind(kind), int(from), int(to)))
}

@(export)
sim_link_remove :: proc "c" (sim: ^ep.Sim, k: i32) {
	context = runtime.default_context()
	context = wasm_context()
	ep.link_remove(sim, int(k))
}

// sim_rewire: the structure changed by hand (a kind, an end, a pump's
// design point, a chemical).
@(export)
sim_rewire :: proc "c" (sim: ^ep.Sim) {
	sim.rewire = true
}

// sim_columns: where the columns are now.
@(export)
sim_columns :: proc "c" (sim: ^ep.Sim) -> ^Columns {
	n, l, o, lo := &sim.nodes, &sim.links, &sim.out, &sim.link_out
	c := &columns
	c.node_count, c.link_count = i32(n.count), i32(l.count)
	c.node_cap, c.link_cap = i32(sim.node_cap), i32(sim.link_cap)
	c.node_kind = ([^]u8)(raw_data(n.kind))
	c.elevation, c.demand, c.emitter, c.head = raw_data(n.elevation), raw_data(n.demand), raw_data(n.emitter), raw_data(n.head)
	c.level, c.min_level, c.max_level = raw_data(n.level), raw_data(n.min_level), raw_data(n.max_level)
	c.diameter, c.min_volume = raw_data(n.diameter), raw_data(n.min_volume)
	c.link_kind = ([^]u8)(raw_data(l.kind))
	c.from, c.to = raw_data(l.from), raw_data(l.to)
	c.status = raw_data(l.status)
	c.setting, c.length, c.link_diameter = raw_data(l.setting), raw_data(l.length), raw_data(l.diameter)
	c.roughness, c.minor_loss = raw_data(l.roughness), raw_data(l.minor_loss)
	c.check_valve = raw_data(l.check_valve)
	c.pump_q, c.pump_h, c.pump_power = raw_data(l.pump_q), raw_data(l.pump_h), raw_data(l.pump_power)
	c.solved = raw_data(o.solved)
	c.pressure, c.out_head, c.out_demand, c.wanted = raw_data(o.pressure), raw_data(o.head), raw_data(o.demand), raw_data(o.wanted)
	c.outflow, c.emitter_flow, c.leak_flow = raw_data(o.outflow), raw_data(o.emitter_flow), raw_data(o.leak_flow)
	c.flow, c.velocity, c.headloss, c.energy = raw_data(lo.flow), raw_data(lo.velocity), raw_data(lo.headloss), raw_data(lo.energy)
	c.out_setting = raw_data(lo.setting)
	c.out_status = raw_data(lo.status)
	return c
}

// ── chemicals ─────────────────────────────────────────────────────────

// sim_chemicals gives the Sim n chemicals, plain and conservative, each
// with an initial-quality column the size of the node room; sim_chemical
// and sim_source fill them in. Read on the next rewire.
@(export)
sim_chemicals :: proc "c" (sim: ^ep.Sim, n: i32) -> i32 {
	context = runtime.default_context()
	context = wasm_context()
	defer free_all(context.temp_allocator)
	for &ch in sim.chemicals {
		delete(ch.init)
		delete(ch.sources)
	}
	delete(sim.chemicals)
	sim.chemicals = make([]ep.Chemical, int(n))
	for &ch in sim.chemicals do ch.init = make([]f64, sim.node_cap)
	sim.rewire = true
	return n
}

@(export)
sim_chemical :: proc "c" (sim: ^ep.Sim, i, kind: i32, decay, wall: f64, trace: i32) {
	if int(i) < 0 || int(i) >= len(sim.chemicals) do return
	ch := &sim.chemicals[i]
	ch.kind = ep.Chemical_Kind(kind)
	ch.decay, ch.wall = decay, wall
	ch.trace = int(trace)
	sim.rewire = true
}

// sim_quality_init: chemical i's initial quality per node, the caller's
// to write (the room's size; rows past the room are not read).
@(export)
sim_quality_init :: proc "c" (sim: ^ep.Sim, i: i32) -> [^]f64 {
	if int(i) < 0 || int(i) >= len(sim.chemicals) do return nil
	return raw_data(sim.chemicals[i].init)
}

@(export)
sim_source :: proc "c" (sim: ^ep.Sim, i, node, kind: i32, strength: f64) {
	context = runtime.default_context()
	context = wasm_context()
	if int(i) < 0 || int(i) >= len(sim.chemicals) do return
	ch := &sim.chemicals[i]
	more := make([]ep.Source, len(ch.sources) + 1)
	copy(more, ch.sources)
	more[len(ch.sources)] = {int(node), ep.Source_Type(kind), strength, 0}
	delete(ch.sources)
	ch.sources = more
	sim.rewire = true
}

// sim_quality / sim_link_quality: chemical i's results per node / link
// after a step; nil before the first.
@(export)
sim_quality :: proc "c" (sim: ^ep.Sim, i: i32) -> [^]f64 {
	if int(i) < 0 || int(i) >= len(sim.out.quality) do return nil
	return raw_data(sim.out.quality[i])
}

@(export)
sim_link_quality :: proc "c" (sim: ^ep.Sim, i: i32) -> [^]f64 {
	if int(i) < 0 || int(i) >= len(sim.link_out.quality) do return nil
	return raw_data(sim.link_out.quality[i])
}

// ── stepping ──────────────────────────────────────────────────────────

// sim_step: dt, or minus EPANET's error code.
@(export)
sim_step :: proc "c" (sim: ^ep.Sim) -> i32 {
	context = runtime.default_context()
	context = wasm_context()
	defer free_all(context.temp_allocator)
	dt, _, err := ep.sim_step(sim)
	if err != nil do return -i32(err)
	return dt
}

// sim_solve: 0, or minus EPANET's error code.
@(export)
sim_solve :: proc "c" (sim: ^ep.Sim) -> i32 {
	context = runtime.default_context()
	context = wasm_context()
	defer free_all(context.temp_allocator)
	_, err := ep.sim_solve(sim)
	if err != nil do return -i32(err)
	return 0
}

@(export)
sim_time :: proc "c" (sim: ^ep.Sim) -> i32 {
	return sim.t
}

@(export)
sim_warn :: proc "c" (sim: ^ep.Sim) -> i32 {
	return i32(sim.warn)
}

@(export)
sim_fault :: proc "c" (sim: ^ep.Sim) -> i32 {
	return i32(sim.fault)
}

@(export)
sim_at_report :: proc "c" (sim: ^ep.Sim) -> i32 {
	return sim.at_report ? 1 : 0
}

// sim_mass_balance: chemical i's mass balance ratio after the last step.
@(export)
sim_mass_balance :: proc "c" (sim: ^ep.Sim, i: i32) -> f64 {
	if int(i) < 0 || int(i) >= len(sim.balance) do return 0
	return sim.balance[i].ratio
}
