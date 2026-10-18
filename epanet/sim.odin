package epanet

// sim.odin — the engine's face for programs (API.md): a network as
// columns the caller edits at any time and steps through time, with its
// results for the step in columns beside them. A node is its index in
// nodes, a link its index in links, a result the same index in out. No
// names, no files, no handle.
//
// Inside, a Sim owns the engine's own project (the same struct the
// toolkit runs, built from the columns by project_from_model the way the
// reader builds one from a file, so a network stepped here and the same
// network run from its .inp give the same bytes). The project is rebuilt
// when the structure changes (`rewire`); values are copied in before
// every step and the results copied out after it. What no tank or
// reservoir reaches is left out of the project rather than refused.

import "base:runtime"
import "core:strconv"
import "core:strings"

Node_Kind :: enum u8 {
	NONE, // an empty row
	JUNCTION,
	RESERVOIR,
	TANK,
}

Link_Kind :: enum u8 {
	NONE, // an empty row
	PIPE, PUMP, PRV, PSV, PBV, FCV, TCV, GPV, PCV,
}

// Nodes are the node columns, in the caller's units; row i is node i.
Nodes :: struct {
	count:      int,
	kind:       []Node_Kind,
	elevation:  []f64,
	demand:     []f64, // a junction's base demand (the first category of a model's junction; the others ride inside)
	emitter:    []f64, // a leak's coefficient, 0 = none
	head:       []f64, // a reservoir's
	level:      []f64, // a tank's: the engine's as time passes, and the caller's to set
	min_level:  []f64,
	max_level:  []f64,
	diameter:   []f64,
	min_volume: []f64, // 0 = the volume at the minimum level
}

// Links are the link columns; row k is link k.
Links :: struct {
	count:       int,
	kind:        []Link_Kind,
	from, to:    []i32,
	status:      []Status, // OPEN, CLOSED; ACTIVE for a valve holding its setting
	setting:     []f64, // a valve's setting, a pump's speed (1)
	length:      []f64, // a pipe's
	diameter:    []f64, // a pipe's, a valve's
	roughness:   []f64, // a pipe's
	minor_loss:  []f64,
	check_valve: []bool, // a pipe's
	pump_q:      []f64, // a pump's design point: EPANET fits its curve (shut-off at 4/3 h, twice q at none); read on rewire
	pump_h:      []f64,
	pump_power:  []f64, // or a constant-power pump, when > 0
}

Chemical_Kind :: enum u8 {
	CHEM, // a constituent, decaying or not
	AGE, // water age, hours
	TRACE, // percent of the water from one node
}

// Chemical is one constituent carried over the hydraulics. Every
// chemical rides the same solve, each with its own segments, sources
// and decay. A Sim made from a Model holds the model's own quality as
// chemical 0 (its per-pipe coefficients and the rest of its quality
// options ride inside); the fields here are read on rewire.
Chemical :: struct {
	kind:    Chemical_Kind,
	trace:   int, // .TRACE: the node traced
	decay:   f64, // bulk coefficient, per day; negative decays
	wall:    f64, // wall coefficient, per day
	init:    []f64, // initial quality per node; nil = zero
	sources: []Source,
}

Source :: struct {
	node:     int,
	kind:     Source_Type,
	strength: f64,
	pattern:  int, // a pattern of the Sim's Model, from 1; 0 = none
}

// Sim_Options: what the columns are in and how the solver runs. A zero
// is EPANET's default; a Sim made from a Model carries the model's.
Sim_Options :: struct {
	flow_units:          Flow_Units, // CFS; .LPS and up make the rest metres and millimetres
	pressure_units:      Pressure_Units, // PSI, or metres with metric flow units
	headloss:            Headloss_Formula, // HW
	demand_model:        Demand_Model, // DDA; .PDA with the two pressures below
	min_pressure:        f64,
	required_pressure:   f64,
	pressure_exponent:   f64, // 0.5
	emitter_exponent:    f64, // 0.5
	trials:              int, // 200
	accuracy:            f64, // 0.001
	continue_unbalanced: bool, // EPANET's UNBALANCED CONTINUE, with extra_trials more; off = STOP
	extra_trials:        int,
	hydraulic_step:      i32, // 3600 s; the most a step advances
	quality_step:        i32, // a tenth of the hydraulic step
	specific_gravity:    f64, // 1
	viscosity:           f64, // water's; relative when > 1e-3
	demand_multiplier:   f64, // 1
}

// Node_Out is the last step's results per node, in the caller's units.
Node_Out :: struct {
	solved:       []bool, // false: no path to a reservoir or tank, so left out and zero
	pressure:     []f64,
	head:         []f64,
	demand:       []f64, // consumer demand delivered
	wanted:       []f64, // consumer demand asked for (PDA: the share delivered is demand / wanted)
	outflow:      []f64, // EPANET's node demand: everything leaving the node; at a tank, the net inflow (negative = out)
	emitter_flow: []f64,
	leak_flow:    []f64,
	quality:      [][]f64, // [chemical][node]
}

// Link_Out is the last step's results per link.
Link_Out :: struct {
	flow:     []f64,
	velocity: []f64,
	headloss: []f64,
	energy:   []f64, // a pump's kW
	setting:  []f64, // a pump's speed, a valve's setting; a pipe's roughness
	status:   []Status,
	quality:  [][]f64, // [chemical][link]
}

Sim :: struct {
	nodes:     Nodes, // written by the caller; read by every step
	links:     Links,
	chemicals: []Chemical,
	options:   Sim_Options,
	t:         i32, // the clock, seconds
	rewire:    bool, // set when the structure changed: a row added or removed, a kind or an end changed by hand
	out:       Node_Out, // written by the step
	link_out:  Link_Out,
	warn:      Warning, // the last step's
	fault:     int, // the node or link an error was about, or -1
	at_report: bool, // the last step's results fell on one of the model's reporting times
	balance:   []Mass_Balance, // per chemical, closed after every step

	// the engine's own: readable, not for writing
	model:        ^Model, // the Model this Sim came from; nil for a bare one
	node_entity:  []i32, // the model's entity each row came from, -1 for none
	link_entity:  []i32,
	node_engine:  []i32, // the engine's 1-based index per row, 0 = left out
	link_engine:  []i32,
	engine:       ^Project, // the project the step runs; nil until the first step, or when nothing reaches a junction
	built:        bool, // the plan is made for the rows as they are
	chems:        []Chem_State, // per chemical, in the project's arena
	prev_status:  []Status, // what the step last saw: a change is applied, the rest left to the engine
	prev_setting: []f64,
	prev_level:   []f64,
	allocator:    runtime.Allocator,
	node_cap:     int,
	link_cap:     int,
	owns_chemicals: bool, // sim_from_model and sim_copy allocate them
}

// Chem_State is one chemical's engine state: its quality solver and the
// network's per-chemical arrays, swapped in for its transport.
Chem_State :: struct {
	q:           Quality,
	ucf:         f64, // the engine's quality unit to the caller's
	c0:          []f64,
	has_source:  []b32,
	source_type: []Source_Type,
	source_c0:   []f64,
	source_pat:  []i32,
	link_kb:     []f64,
	link_kw:     []f64,
	tank_kb:     []f64,
}

BARE_DURATION :: i64(1) << 40 // a bare Sim has no end

// ── making and freeing ────────────────────────────────────────────────

// sim_make makes an empty Sim with room for node_cap nodes and link_cap
// links. Rows past the room move the columns (so a program that keeps
// views of them sizes it once).
sim_make :: proc(node_cap, link_cap: int, opts: Sim_Options, allocator := context.allocator) -> (sim: Sim) {
	sim.allocator = allocator
	sim.options = opts
	sim.fault = -1
	sim.rewire = true
	sim_node_room(&sim, max(node_cap, 1))
	sim_link_room(&sim, max(link_cap, 1))
	return
}

// sim_node_room / sim_link_room: the columns, with room for n rows.
sim_node_room :: proc(sim: ^Sim, n: int) {
	if n <= sim.node_cap do return
	a := sim.allocator
	regrow(&sim.nodes.kind, n, a)
	regrow(&sim.nodes.elevation, n, a)
	regrow(&sim.nodes.demand, n, a)
	regrow(&sim.nodes.emitter, n, a)
	regrow(&sim.nodes.head, n, a)
	regrow(&sim.nodes.level, n, a)
	regrow(&sim.nodes.min_level, n, a)
	regrow(&sim.nodes.max_level, n, a)
	regrow(&sim.nodes.diameter, n, a)
	regrow(&sim.nodes.min_volume, n, a)
	regrow(&sim.out.solved, n, a)
	regrow(&sim.out.pressure, n, a)
	regrow(&sim.out.head, n, a)
	regrow(&sim.out.demand, n, a)
	regrow(&sim.out.wanted, n, a)
	regrow(&sim.out.outflow, n, a)
	regrow(&sim.out.emitter_flow, n, a)
	regrow(&sim.out.leak_flow, n, a)
	for &col in sim.out.quality do regrow(&col, n, a)
	regrow(&sim.node_entity, n, a)
	regrow(&sim.node_engine, n, a)
	regrow(&sim.prev_level, n, a)
	for i in sim.node_cap ..< n do sim.node_entity[i] = -1
	sim.node_cap = n
}

sim_link_room :: proc(sim: ^Sim, n: int) {
	if n <= sim.link_cap do return
	a := sim.allocator
	regrow(&sim.links.kind, n, a)
	regrow(&sim.links.from, n, a)
	regrow(&sim.links.to, n, a)
	regrow(&sim.links.status, n, a)
	regrow(&sim.links.setting, n, a)
	regrow(&sim.links.length, n, a)
	regrow(&sim.links.diameter, n, a)
	regrow(&sim.links.roughness, n, a)
	regrow(&sim.links.minor_loss, n, a)
	regrow(&sim.links.check_valve, n, a)
	regrow(&sim.links.pump_q, n, a)
	regrow(&sim.links.pump_h, n, a)
	regrow(&sim.links.pump_power, n, a)
	regrow(&sim.link_out.flow, n, a)
	regrow(&sim.link_out.velocity, n, a)
	regrow(&sim.link_out.headloss, n, a)
	regrow(&sim.link_out.energy, n, a)
	regrow(&sim.link_out.setting, n, a)
	regrow(&sim.link_out.status, n, a)
	for &col in sim.link_out.quality do regrow(&col, n, a)
	regrow(&sim.link_entity, n, a)
	regrow(&sim.link_engine, n, a)
	regrow(&sim.prev_status, n, a)
	regrow(&sim.prev_setting, n, a)
	for k in sim.link_cap ..< n do sim.link_entity[k] = -1
	sim.link_cap = n
}

// regrow gives a column room for n, keeping what it held.
regrow :: proc(col: ^[]$E, n: int, allocator: runtime.Allocator) {
	if len(col^) >= n do return
	t := make([]E, n, allocator)
	copy(t, col^)
	delete(col^, allocator)
	col^ = t
}

// sim_delete gives everything back.
sim_delete :: proc(sim: ^Sim) {
	a := sim.allocator
	free_engine(sim)
	delete(sim.nodes.kind, a); delete(sim.nodes.elevation, a); delete(sim.nodes.demand, a)
	delete(sim.nodes.emitter, a); delete(sim.nodes.head, a); delete(sim.nodes.level, a)
	delete(sim.nodes.min_level, a); delete(sim.nodes.max_level, a); delete(sim.nodes.diameter, a)
	delete(sim.nodes.min_volume, a)
	delete(sim.links.kind, a); delete(sim.links.from, a); delete(sim.links.to, a)
	delete(sim.links.status, a); delete(sim.links.setting, a); delete(sim.links.length, a)
	delete(sim.links.diameter, a); delete(sim.links.roughness, a); delete(sim.links.minor_loss, a)
	delete(sim.links.check_valve, a); delete(sim.links.pump_q, a); delete(sim.links.pump_h, a)
	delete(sim.links.pump_power, a)
	delete(sim.out.solved, a); delete(sim.out.pressure, a); delete(sim.out.head, a)
	delete(sim.out.demand, a); delete(sim.out.wanted, a); delete(sim.out.outflow, a)
	delete(sim.out.emitter_flow, a); delete(sim.out.leak_flow, a)
	for col in sim.out.quality do delete(col, a)
	delete(sim.out.quality, a)
	delete(sim.link_out.flow, a); delete(sim.link_out.velocity, a); delete(sim.link_out.headloss, a)
	delete(sim.link_out.energy, a); delete(sim.link_out.setting, a); delete(sim.link_out.status, a)
	for col in sim.link_out.quality do delete(col, a)
	delete(sim.link_out.quality, a)
	delete(sim.balance, a)
	delete(sim.node_entity, a); delete(sim.link_entity, a)
	delete(sim.node_engine, a); delete(sim.link_engine, a)
	delete(sim.prev_status, a); delete(sim.prev_setting, a); delete(sim.prev_level, a)
	if sim.owns_chemicals {
		for ch in sim.chemicals {
			delete(ch.init, a)
			delete(ch.sources, a)
		}
		delete(sim.chemicals, a)
	}
	sim^ = {}
}

// sim_copy is the Sim again, for a what-if or a look ahead: the columns,
// the clock and the chemicals as they are; the engine is rebuilt on the
// copy's first step, with the tanks at their levels and each chemical
// started from the node qualities of the last step.
sim_copy :: proc(sim: ^Sim, allocator := context.allocator) -> (c: Sim) {
	c = sim_make(sim.node_cap, sim.link_cap, sim.options, allocator)
	c.model = sim.model
	c.t = sim.t
	c.nodes.count, c.links.count = sim.nodes.count, sim.links.count
	copy(c.nodes.kind, sim.nodes.kind); copy(c.nodes.elevation, sim.nodes.elevation)
	copy(c.nodes.demand, sim.nodes.demand); copy(c.nodes.emitter, sim.nodes.emitter)
	copy(c.nodes.head, sim.nodes.head); copy(c.nodes.level, sim.nodes.level)
	copy(c.nodes.min_level, sim.nodes.min_level); copy(c.nodes.max_level, sim.nodes.max_level)
	copy(c.nodes.diameter, sim.nodes.diameter); copy(c.nodes.min_volume, sim.nodes.min_volume)
	copy(c.links.kind, sim.links.kind); copy(c.links.from, sim.links.from); copy(c.links.to, sim.links.to)
	copy(c.links.status, sim.links.status); copy(c.links.setting, sim.links.setting)
	copy(c.links.length, sim.links.length); copy(c.links.diameter, sim.links.diameter)
	copy(c.links.roughness, sim.links.roughness); copy(c.links.minor_loss, sim.links.minor_loss)
	copy(c.links.check_valve, sim.links.check_valve); copy(c.links.pump_q, sim.links.pump_q)
	copy(c.links.pump_h, sim.links.pump_h); copy(c.links.pump_power, sim.links.pump_power)
	copy(c.node_entity, sim.node_entity); copy(c.link_entity, sim.link_entity)
	c.chemicals = make([]Chemical, len(sim.chemicals), allocator)
	for ch, ci in sim.chemicals {
		cc := ch
		cc.init = make([]f64, sim.node_cap, allocator)
		if sim.engine != nil && ci < len(sim.out.quality) {
			copy(cc.init, sim.out.quality[ci][:sim.nodes.count])
		} else {
			copy(cc.init, ch.init)
		}
		cc.sources = make([]Source, len(ch.sources), allocator)
		copy(cc.sources, ch.sources)
		c.chemicals[ci] = cc
	}
	c.owns_chemicals = true
	return
}

// ── rows ──────────────────────────────────────────────────────────────

// node_add adds a row, zeroed, and returns its index; fill its columns.
node_add :: proc(sim: ^Sim, kind: Node_Kind) -> int {
	i := sim.nodes.count
	sim_node_room(sim, i + 1)
	clear_node(sim, i)
	sim.nodes.kind[i] = kind
	sim.nodes.count = i + 1
	sim.rewire = true
	return i
}

clear_node :: proc(sim: ^Sim, i: int) {
	n := &sim.nodes
	n.kind[i] = .NONE
	n.elevation[i], n.demand[i], n.emitter[i], n.head[i] = 0, 0, 0, 0
	n.level[i], n.min_level[i], n.max_level[i], n.diameter[i], n.min_volume[i] = 0, 0, 0, 0, 0
	sim.node_entity[i] = -1
	sim.node_engine[i] = 0
}

// node_remove takes row i out: the last row takes its place and the
// links that held it follow; the links that touched node i are emptied.
node_remove :: proc(sim: ^Sim, i: int) {
	n := &sim.nodes
	last := n.count - 1
	for k in 0 ..< sim.links.count {
		if int(sim.links.from[k]) == i || int(sim.links.to[k]) == i do clear_link(sim, k)
	}
	if i != last {
		n.kind[i] = n.kind[last]
		n.elevation[i], n.demand[i], n.emitter[i], n.head[i] = n.elevation[last], n.demand[last], n.emitter[last], n.head[last]
		n.level[i], n.min_level[i], n.max_level[i] = n.level[last], n.min_level[last], n.max_level[last]
		n.diameter[i], n.min_volume[i] = n.diameter[last], n.min_volume[last]
		sim.node_entity[i] = sim.node_entity[last]
		for k in 0 ..< sim.links.count {
			if int(sim.links.from[k]) == last do sim.links.from[k] = i32(i)
			if int(sim.links.to[k]) == last do sim.links.to[k] = i32(i)
		}
		for &ch in sim.chemicals {
			if ch.trace == last do ch.trace = i
			for &s in ch.sources do if s.node == last do s.node = i
			if len(ch.init) > last do ch.init[i] = ch.init[last]
		}
	}
	clear_node(sim, last)
	n.count = last
	sim.rewire = true
}

// link_add adds a link from node `from` to node `to`, zeroed, and
// returns its index. A pipe comes open, a pump open at speed 1, a valve
// active at setting 0.
link_add :: proc(sim: ^Sim, kind: Link_Kind, from, to: int) -> int {
	k := sim.links.count
	sim_link_room(sim, k + 1)
	clear_link(sim, k)
	l := &sim.links
	l.kind[k] = kind
	l.from[k], l.to[k] = i32(from), i32(to)
	switch kind {
	case .PIPE:
		l.status[k] = .OPEN
	case .PUMP:
		l.status[k] = .OPEN
		l.setting[k] = 1
	case .PRV, .PSV, .PBV, .FCV, .TCV, .GPV, .PCV:
		l.status[k] = .ACTIVE
	case .NONE:
	}
	l.count = k + 1
	sim.rewire = true
	return k
}

clear_link :: proc(sim: ^Sim, k: int) {
	l := &sim.links
	l.kind[k] = .NONE
	l.from[k], l.to[k] = 0, 0
	l.status[k] = .CLOSED
	l.setting[k], l.length[k], l.diameter[k], l.roughness[k], l.minor_loss[k] = 0, 0, 0, 0, 0
	l.check_valve[k] = false
	l.pump_q[k], l.pump_h[k], l.pump_power[k] = 0, 0, 0
	sim.link_entity[k] = -1
	sim.link_engine[k] = 0
}

// link_remove takes row k out: the last row takes its place.
link_remove :: proc(sim: ^Sim, k: int) {
	l := &sim.links
	last := l.count - 1
	if k != last {
		l.kind[k] = l.kind[last]
		l.from[k], l.to[k] = l.from[last], l.to[last]
		l.status[k], l.setting[k] = l.status[last], l.setting[last]
		l.length[k], l.diameter[k], l.roughness[k], l.minor_loss[k] = l.length[last], l.diameter[last], l.roughness[last], l.minor_loss[last]
		l.check_valve[k] = l.check_valve[last]
		l.pump_q[k], l.pump_h[k], l.pump_power[k] = l.pump_q[last], l.pump_h[last], l.pump_power[last]
		sim.link_entity[k] = sim.link_entity[last]
	}
	clear_link(sim, last)
	l.count = last
	sim.rewire = true
}

// ── from a Model ──────────────────────────────────────────────────────

// Ids are the names a Model's components had, by row.
Ids :: struct {
	node, link:             []string,
	node_index, link_index: map[string]int,
}

// sim_from_model is the one conversion: entities to columns (the nodes
// in the model's order, the links in theirs), the model's patterns,
// curves, controls and rules kept inside to play each step, its quality
// as chemical 0, and the names handed back beside it. The Model must
// outlive the Sim.
sim_from_model :: proc(model: ^Model, allocator := context.allocator) -> (sim: Sim, ids: Ids, err: Error) {
	nn, nl := 0, 0
	for e in model.entities {
		if e.kind <= .TANK {
			nn += 1
		} else {
			nl += 1
		}
	}
	opts: Sim_Options
	o := &model.options
	opts.flow_units = o.flow_units
	opts.pressure_units = o.pressure_units == .DEFAULTUNIT ? .PSI : o.pressure_units
	opts.headloss, opts.demand_model = o.headloss, o.demand_model
	opts.min_pressure, opts.required_pressure, opts.pressure_exponent = o.min_pressure, o.required_pressure, o.pressure_exponent
	opts.emitter_exponent, opts.trials, opts.accuracy = o.emitter_exponent, o.trials, o.accuracy
	opts.continue_unbalanced = o.extra_trials >= 0
	opts.extra_trials = max(o.extra_trials, 0)
	opts.hydraulic_step = i32(model.times.hydraulic_step)
	opts.quality_step = i32(model.times.quality_step)
	opts.specific_gravity, opts.viscosity, opts.demand_multiplier = o.specific_gravity, o.viscosity, o.demand_multiplier
	sim = sim_make(nn, nl, opts, allocator)
	sim.model = model
	ids.node = make([]string, nn, allocator)
	ids.link = make([]string, nl, allocator)
	ids.node_index = make(map[string]int, allocator)
	ids.link_index = make(map[string]int, allocator)

	for &e, ei in model.entities {
		if e.kind > .TANK do continue
		i := node_add(&sim, Node_Kind(int(e.kind) + 1))
		if e.kind == .TANK && e.diameter == 0 do sim.nodes.kind[i] = .RESERVOIR
		if e.kind == .RESERVOIR && e.diameter > 0 do sim.nodes.kind[i] = .TANK
		sim.node_entity[i] = i32(ei)
		ids.node[i] = e.id
		ids.node_index[e.id] = i
		n := &sim.nodes
		n.elevation[i] = e.elevation
		n.head[i] = e.elevation
		if len(e.demands) > 0 do n.demand[i] = e.demands[0].base
		n.emitter[i] = e.emitter
		n.level[i], n.min_level[i], n.max_level[i] = e.init_level, e.min_level, e.max_level
		n.diameter[i], n.min_volume[i] = e.diameter, e.min_volume
	}
	for &e, ei in model.entities {
		if e.kind < .PIPE do continue
		from, ok1 := ids.node_index[e.from]
		to, ok2 := ids.node_index[e.to]
		if !ok1 || !ok2 {
			sim.fault = ei
			return sim, ids, .Undefined_Node
		}
		kind: Link_Kind
		switch e.kind {
		case .PIPE:
			kind = .PIPE
		case .PUMP:
			kind = .PUMP
		case .VALVE:
			vt := e.valve
			if vt < .PRV do vt = .PRV
			kind = Link_Kind(int(vt) - int(Link_Type.PRV) + int(Link_Kind.PRV))
		case .JUNCTION, .RESERVOIR, .TANK:
		}
		k := link_add(&sim, kind, from, to)
		sim.link_entity[k] = i32(ei)
		ids.link[k] = e.id
		ids.link_index[e.id] = k
		l := &sim.links
		if e.status != .XHEAD do l.status[k] = e.status
		l.length[k], l.diameter[k], l.roughness[k], l.minor_loss[k] = e.length, e.diameter, e.roughness, e.minor_loss
		l.check_valve[k] = e.check_valve
		switch e.kind {
		case .PUMP:
			l.setting[k] = e.speed == 0 && e.status != .CLOSED ? 1 : e.speed
			l.pump_power[k] = e.power
		case .VALVE:
			l.setting[k] = e.setting
			if e.valve == .GPV && len(e.loss_curve) > 0 && e.status == .XHEAD do l.status[k] = .OPEN
		case .PIPE, .JUNCTION, .RESERVOIR, .TANK:
		}
	}

	if o.quality != .NONE {
		ch: Chemical
		switch o.quality {
		case .CHEM:
			ch.kind = .CHEM
		case .AGE:
			ch.kind = .AGE
		case .TRACE:
			ch.kind = .TRACE
			ch.trace = ids.node_index[o.trace_node] or_else 0
		case .NONE:
		}
		ch.decay, ch.wall = o.bulk_coeff, o.wall_coeff
		ch.init = make([]f64, sim.node_cap, allocator)
		nsrc := 0
		for i in 0 ..< nn {
			e := &model.entities[sim.node_entity[i]]
			ch.init[i] = e.init_quality
			if e.has_source do nsrc += 1
		}
		ch.sources = make([]Source, nsrc, allocator)
		si := 0
		for i in 0 ..< nn {
			e := &model.entities[sim.node_entity[i]]
			if !e.has_source do continue
			pat := 0
			for mp, pi in model.patterns do if mp.id == e.source.pattern do pat = pi + 1
			ch.sources[si] = {i, e.source.kind, e.source.strength, pat}
			si += 1
		}
		sim.chemicals = make([]Chemical, 1, allocator)
		sim.chemicals[0] = ch
	}
	sim.owns_chemicals = true
	sim.rewire = true
	return
}

// ── the plan: reach, the effective model, the engine ──────────────────

// rebuild makes the engine's project from the columns (and the model's
// extras, when there is one): what a tank or reservoir reaches, the
// engine's own numbering, the matrix shape, the solvers opened at the
// clock. Returns the error, with sim.fault on the row.
rebuild :: proc(sim: ^Sim) -> Error {
	sim.rewire = false
	sim.built = true
	sim.fault = -1
	free_engine(sim)
	nn, nl := sim.nodes.count, sim.links.count
	a := sim.allocator
	nchem := len(sim.chemicals)
	if len(sim.out.quality) != nchem {
		for col in sim.out.quality do delete(col, a)
		delete(sim.out.quality, a)
		for col in sim.link_out.quality do delete(col, a)
		delete(sim.link_out.quality, a)
		delete(sim.balance, a)
		sim.out.quality = make([][]f64, nchem, a)
		sim.link_out.quality = make([][]f64, nchem, a)
		for ci in 0 ..< nchem {
			sim.out.quality[ci] = make([]f64, sim.node_cap, a)
			sim.link_out.quality[ci] = make([]f64, sim.link_cap, a)
		}
		sim.balance = make([]Mass_Balance, nchem, a)
	}
	for i in 0 ..< nn do sim.node_engine[i] = 0
	for k in 0 ..< nl do sim.link_engine[k] = 0

	// reach: a breadth-first walk from every tank and reservoir over
	// every link, whatever its status
	scratch: Arena
	if !arena_init(&scratch) do return .Out_Of_Memory
	defer arena_destroy(&scratch)
	context.allocator = arena_allocator(&scratch)
	reached := make([]bool, nn)
	degree := make([]int, nn + 1)
	for k in 0 ..< nl {
		if !link_rows_ok(sim, k) do continue
		degree[sim.links.from[k]] += 1
		degree[sim.links.to[k]] += 1
	}
	first := make([]int, nn + 1)
	for i in 0 ..< nn do first[i + 1] = first[i] + degree[i]
	adj := make([]int, first[nn])
	fill := make([]int, nn)
	copy(fill, first[:nn])
	for k in 0 ..< nl {
		if !link_rows_ok(sim, k) do continue
		f, t := sim.links.from[k], sim.links.to[k]
		adj[fill[f]] = int(t)
		fill[f] += 1
		adj[fill[t]] = int(f)
		fill[t] += 1
	}
	queue := make([]int, nn)
	head, tail := 0, 0
	for i in 0 ..< nn {
		if sim.nodes.kind[i] == .TANK || sim.nodes.kind[i] == .RESERVOIR {
			reached[i] = true
			queue[tail] = i
			tail += 1
		}
	}
	for head < tail {
		i := queue[head]
		head += 1
		for j in first[i] ..< first[i + 1] {
			if !reached[adj[j]] {
				reached[adj[j]] = true
				queue[tail] = adj[j]
				tail += 1
			}
		}
	}
	njunc := 0
	for i in 0 ..< nn do if reached[i] && sim.nodes.kind[i] == .JUNCTION do njunc += 1
	for i in 0 ..< nn do sim.out.solved[i] = reached[i]
	if njunc == 0 {
		// nothing to solve: every step moves the clock only
		return nil
	}

	// the effective model: the rows as entities, the model's extras
	eff: Model
	if sim.model != nil {
		eff = sim.model^
		eff.aux, eff.problems, eff.arena = nil, nil, nil
	} else {
		eff.options = DEFAULT_OPTIONS
		eff.times = DEFAULT_TIMES
		eff.report = default_report()
	}
	apply_sim_options(&eff.options, &eff.times, sim.options, sim.model == nil)
	if sim.model == nil do eff.times.duration = BARE_DURATION
	entities := make([dynamic]Entity)
	ent_row := make([dynamic]int) // the row each effective entity is, nodes then links
	node_ids := make([]string, nn)
	for i in 0 ..< nn {
		if !reached[i] do continue
		e := Entity{x = MISSING, y = MISSING}
		if sim.node_entity[i] >= 0 do e = sim.model.entities[sim.node_entity[i]]
		if len(e.id) == 0 do e.id = row_id("~n", i)
		node_ids[i] = e.id
		n := &sim.nodes
		switch n.kind[i] {
		case .JUNCTION:
			e.kind = .JUNCTION
			e.elevation = n.elevation[i]
			if len(e.demands) == 0 {
				d := make([]Demand, 1)
				e.demands = d
			} else {
				d := make([]Demand, len(e.demands))
				copy(d, e.demands)
				e.demands = d
			}
			e.demands[0].base = n.demand[i]
			e.emitter = n.emitter[i]
		case .RESERVOIR:
			e.kind = .RESERVOIR
			e.elevation = n.head[i]
			e.diameter, e.init_level, e.min_level, e.max_level, e.min_volume = 0, 0, 0, 0, 0
		case .TANK:
			e.kind = .TANK
			e.elevation = n.elevation[i]
			e.init_level, e.min_level, e.max_level = n.level[i], n.min_level[i], n.max_level[i]
			e.diameter, e.min_volume = n.diameter[i], n.min_volume[i]
			if sim.node_entity[i] < 0 do e.bulk_coeff = MISSING
		case .NONE:
		}
		e.has_source = false
		e.init_quality = 0
		append(&entities, e)
		append(&ent_row, i)
	}
	nent_nodes := len(entities)
	curves := make([dynamic]Model_Curve)
	append(&curves, ..eff.curves)
	for k in 0 ..< nl {
		if !link_rows_ok(sim, k) do continue
		if !reached[sim.links.from[k]] || !reached[sim.links.to[k]] do continue
		e: Entity
		if sim.link_entity[k] >= 0 do e = sim.model.entities[sim.link_entity[k]]
		if len(e.id) == 0 do e.id = row_id("~l", k)
		if sim.link_entity[k] < 0 do e.vertices = nil
		l := &sim.links
		e.from, e.to = node_ids[l.from[k]], node_ids[l.to[k]]
		e.status = l.status[k]
		e.diameter, e.minor_loss = l.diameter[k], l.minor_loss[k]
		switch l.kind[k] {
		case .PIPE:
			e.kind = .PIPE
			e.length, e.roughness = l.length[k], l.roughness[k]
			e.check_valve = l.check_valve[k]
			if sim.link_entity[k] < 0 do e.bulk_coeff, e.wall_coeff = MISSING, MISSING
		case .PUMP:
			e.kind = .PUMP
			e.speed = l.setting[k]
			e.power = l.pump_power[k]
			if len(e.head_curve) == 0 && e.power == 0 {
				if l.pump_q[k] <= 0 || l.pump_h[k] <= 0 {
					sim.fault = k
					return .No_Pump_Curve
				}
				cid := row_id("~p", k)
				x := make([]f64, 1)
				y := make([]f64, 1)
				x[0], y[0] = l.pump_q[k], l.pump_h[k]
				append(&curves, Model_Curve{id = cid, kind = .PUMP_CURVE, x = x, y = y})
				e.head_curve = cid
			}
		case .PRV, .PSV, .PBV, .FCV, .TCV, .GPV, .PCV:
			e.kind = .VALVE
			e.valve = Link_Type(int(l.kind[k]) - int(Link_Kind.PRV) + int(Link_Type.PRV))
			e.setting = l.setting[k]
		case .NONE:
		}
		append(&entities, e)
		append(&ent_row, k)
	}
	eff.entities = entities[:]
	eff.curves = curves[:]
	// controls on what is not there are dropped; rules stay the model's
	if sim.model != nil {
		kept := make([dynamic]Control)
		for ctl in eff.controls {
			ok := false
			for &e in eff.entities[nent_nodes:] do if e.id == ctl.link do ok = true
			if ok && (ctl.kind == .LOWLEVEL || ctl.kind == .HILEVEL) {
				ok = false
				for &e in eff.entities[:nent_nodes] do if e.id == ctl.node do ok = true
			}
			if ok do append(&kept, ctl)
		}
		eff.controls = kept[:]
	}
	// chemical 0 is the project's own quality
	if nchem > 0 {
		ch := &sim.chemicals[0]
		switch ch.kind {
		case .CHEM:
			eff.options.quality = .CHEM
		case .AGE:
			eff.options.quality = .AGE
		case .TRACE:
			eff.options.quality = .TRACE
			eff.options.trace_node = reached[ch.trace] ? node_ids[ch.trace] : ""
		}
		eff.options.bulk_coeff, eff.options.wall_coeff = ch.decay, ch.wall
		for &e, j in eff.entities[:nent_nodes] {
			row := ent_row[j]
			if len(ch.init) > row do e.init_quality = ch.init[row]
		}
		for s in ch.sources {
			for &e, j in eff.entities[:nent_nodes] {
				if ent_row[j] != s.node do continue
				e.has_source = true
				e.source = {s.kind, s.strength, s.pattern > 0 && s.pattern <= len(eff.patterns) ? eff.patterns[s.pattern - 1].id : ""}
			}
		}
	} else {
		eff.options.quality = .NONE
	}

	// (the project struct itself comes from the Sim's allocator; its
	// tables from its own arena)
	context.allocator = sim.allocator
	b := project_from_model(&eff)
	if b.err != nil {
		if b.p != nil do project_free(b.p)
		if b.at >= 0 && b.at < len(ent_row) do sim.fault = ent_row[b.at]
		return b.err
	}
	p := b.p
	sim.engine = p
	context.allocator = arena_allocator(&p.arena)
	for j in 0 ..< nent_nodes do sim.node_engine[ent_row[j]] = b.node_index[j]
	for j in nent_nodes ..< len(ent_row) do sim.link_engine[ent_row[j]] = b.link_index[j]

	if errcode := open_hyd(p); errcode != 0 {
		free_engine(sim)
		return Error(errcode)
	}
	open_leakage(p)
	init_hyd(&p.net, &p.hyd, &p.times, 0)
	p.open_hflag = true
	p.hyd.openqflag = true
	t := &p.times
	t.htime = i64(sim.t)
	t.qtime = i64(sim.t)
	t.rtime = t.rstart
	for t.rtime < t.htime do t.rtime += t.rstep

	// the chemicals: chemical 0 over the project's own arrays, the others
	// over their own, every one with its own solver state
	sim.chems = make([]Chem_State, nchem)
	for ci in 0 ..< nchem {
		cs := &sim.chems[ci]
		net := &p.net
		if ci == 0 {
			cs.q = p.q
			cs.ucf = p.ucf[.QUALITY]
			cs.c0, cs.has_source, cs.source_type, cs.source_c0, cs.source_pat = net.c0, net.has_source, net.source_type, net.source_c0, net.source_pat
			cs.link_kb, cs.link_kw, cs.tank_kb = net.link_kb, net.link_kw, net.tank_kb
		} else {
			ch := &sim.chemicals[ci]
			cs.q = p.q // the options; the arrays are replaced below
			cs.q.node_qual = make([]f64, net.nnodes + 1)
			cs.q.tank_c = make([]f64, net.ntanks + 1)
			cs.q.balance = {}
			switch ch.kind {
			case .CHEM:
				cs.q.kind = .CHEM
				cs.ucf = 1 / L_PER_FT3
			case .AGE:
				cs.q.kind = .AGE
				cs.ucf = 1
			case .TRACE:
				cs.q.kind = .TRACE
				cs.ucf = 1
			}
			cs.q.trace_node = ch.trace >= 0 && ch.trace < nn ? int(sim.node_engine[ch.trace]) : 0
			cs.q.ctol = (cs.q.kind == .AGE ? AGETOL : CHEMTOL) / cs.ucf
			cs.q.climit = 0
			cs.q.bulk_order, cs.q.wall_order, cs.q.tank_order = 1, 1, 1
			cs.c0 = make([]f64, net.nnodes + 1)
			cs.has_source = make([]b32, net.nnodes + 1)
			cs.source_type = make([]Source_Type, net.nnodes + 1)
			cs.source_c0 = make([]f64, net.nnodes + 1)
			cs.source_pat = make([]i32, net.nnodes + 1)
			cs.link_kb = make([]f64, net.nlinks + 1)
			cs.link_kw = make([]f64, net.nlinks + 1)
			cs.tank_kb = make([]f64, net.ntanks + 1)
			for row in 0 ..< nn {
				i := sim.node_engine[row]
				if i == 0 do continue
				if len(ch.init) > row do cs.c0[i] = ch.init[row] / cs.ucf
			}
			for s in ch.sources {
				if s.node < 0 || s.node >= nn do continue
				i := sim.node_engine[s.node]
				if i == 0 do continue
				cs.has_source[i] = true
				cs.source_type[i] = s.kind
				cs.source_c0[i] = s.strength
				cs.source_pat[i] = s.pattern > 0 && s.pattern < len(net.patterns) ? i32(s.pattern) : 0
			}
			for k in 1 ..= net.nlinks {
				if net.link_type[k] > .PIPE do continue
				cs.link_kb[k] = ch.decay / SEC_PER_DAY
				cs.link_kw[k] = ch.wall / SEC_PER_DAY
			}
			for tk in 1 ..= net.ntanks do cs.tank_kb[tk] = ch.decay / SEC_PER_DAY
		}
		cs.q.out_of_memory = false
		cs.q.flow_dir = make([]i32, net.nlinks + 1)
		cs.q.pipe_rate = make([]f64, net.nlinks + 1)
		cs.q.link_rc = make([]f64, net.nlinks + 1)
		cs.q.sorted = make([]i32, net.nlinks + net.ntanks + 1)
		cs.q.source_mass = make([]f64, net.nnodes + 1)
		cs.q.segs = segments_make(net.nlinks + net.ntanks)
		swap_chemical(p, cs)
		init_qual(net, &p.hyd, &cs.q)
	}
	if nchem > 0 do swap_chemical(p, &sim.chems[0])

	for k in 0 ..< nl {
		sim.prev_status[k] = sim.links.status[k]
		sim.prev_setting[k] = sim.links.setting[k]
	}
	for i in 0 ..< nn do sim.prev_level[i] = sim.nodes.level[i]
	return nil
}

// free_engine gives the project back, under the allocator that made it.
free_engine :: proc(sim: ^Sim) {
	if sim.engine == nil do return
	context.allocator = sim.allocator
	project_free(sim.engine)
	sim.engine = nil
	sim.chems = nil
}

link_rows_ok :: proc "contextless" (sim: ^Sim, k: int) -> bool {
	if sim.links.kind[k] == .NONE do return false
	f, t := int(sim.links.from[k]), int(sim.links.to[k])
	if f < 0 || f >= sim.nodes.count || t < 0 || t >= sim.nodes.count || f == t do return false
	return sim.nodes.kind[f] != .NONE && sim.nodes.kind[t] != .NONE
}

row_id :: proc(prefix: string, i: int) -> string {
	buf: [24]u8
	return strings.concatenate({prefix, strconv.write_int(buf[:], i64(i), 10)})
}

// apply_sim_options puts the Sim's options over a Model's (or, for a bare
// Sim, over EPANET's defaults): a zero leaves what was there.
apply_sim_options :: proc(o: ^Options, t: ^Model_Times, so: Sim_Options, bare: bool) {
	o.flow_units = so.flow_units
	if bare {
		o.pressure_units = so.pressure_units == .PSI ? .DEFAULTUNIT : so.pressure_units
	} else if so.pressure_units != .PSI {
		o.pressure_units = so.pressure_units
	}
	o.headloss = so.headloss
	o.demand_model = so.demand_model
	if so.min_pressure != 0 do o.min_pressure = so.min_pressure
	if so.required_pressure != 0 do o.required_pressure = so.required_pressure
	if so.pressure_exponent != 0 do o.pressure_exponent = so.pressure_exponent
	if so.emitter_exponent != 0 do o.emitter_exponent = so.emitter_exponent
	if so.trials != 0 do o.trials = so.trials
	if so.accuracy != 0 do o.accuracy = so.accuracy
	if so.continue_unbalanced do o.extra_trials = so.extra_trials
	if so.specific_gravity != 0 do o.specific_gravity = so.specific_gravity
	if so.viscosity != 0 do o.viscosity = so.viscosity
	if so.demand_multiplier != 0 do o.demand_multiplier = so.demand_multiplier
	if so.hydraulic_step != 0 do t.hydraulic_step = i64(so.hydraulic_step)
	if bare {
		// no patterns and no report: one step is the step
		t.pattern_step = t.hydraulic_step
		t.report_step = t.hydraulic_step
	}
	if so.quality_step != 0 do t.quality_step = i64(so.quality_step)
}

// swap_chemical puts one chemical's arrays into the network.
swap_chemical :: proc "contextless" (p: ^Project, cs: ^Chem_State) {
	net := &p.net
	net.c0, net.has_source, net.source_type, net.source_c0, net.source_pat = cs.c0, cs.has_source, cs.source_type, cs.source_c0, cs.source_pat
	net.link_kb, net.link_kw, net.tank_kb = cs.link_kb, cs.link_kw, cs.tank_kb
	net.ucf_quality = cs.ucf
}

// ── values in, results out ────────────────────────────────────────────

// copy_in puts every column into the engine, in its units: the values
// every step, and of the state (a link's status and setting, a tank's
// level) what changed since the step last looked.
copy_in :: proc "contextless" (sim: ^Sim) {
	p := sim.engine
	net, hyd := &p.net, &p.hyd
	u := &p.ucf
	n := &sim.nodes
	ecf := p.units == .US ? PSI_PER_FT * hyd.spgrav : M_PER_FT
	kcf := c_pow(u[.FLOW], hyd.qexp) / ecf
	for row in 0 ..< n.count {
		i := int(sim.node_engine[row])
		if i == 0 do continue
		switch n.kind[row] {
		case .JUNCTION:
			net.el[i] = n.elevation[row] / u[.ELEV]
			net.demand_base[net.demand_first[i]] = n.demand[row] / u[.DEMAND]
			if n.emitter[row] > 0 {
				net.ke[i] = kcf / c_pow(n.emitter[row], hyd.qexp)
				if hyd.emitter_flow[i] == 0 do hyd.emitter_flow[i] = 1
			} else {
				net.ke[i] = 0
			}
		case .RESERVOIR:
			tk := i - net.njuncs
			el := n.head[row] / u[.ELEV]
			net.el[i] = el
			net.tank_h0[tk], net.tank_hmin[tk], net.tank_hmax[tk] = el, el, el
			hyd.head[i] = el
		case .TANK:
			tk := i - net.njuncs
			el := n.elevation[row] / u[.ELEV]
			net.el[i] = el
			net.tank_hmin[tk] = el + n.min_level[row] / u[.ELEV]
			net.tank_hmax[tk] = el + n.max_level[row] / u[.ELEV]
			net.tank_h0[tk] = el + n.level[row] / u[.ELEV]
			if net.tank_vcurve[tk] == 0 {
				d := n.diameter[row] / u[.ELEV]
				net.tank_area[tk] = PI * (d * d) / 4
				area := PI * (n.diameter[row] * n.diameter[row]) / 4
				vmin := area * n.min_level[row]
				if n.min_volume[row] > 0 do vmin = n.min_volume[row]
				net.tank_vmin[tk] = vmin / u[.VOLUME]
				net.tank_v0[tk] = (vmin + area * (n.level[row] - n.min_level[row])) / u[.VOLUME]
				net.tank_vmax[tk] = (vmin + area * (n.max_level[row] - n.min_level[row])) / u[.VOLUME]
			}
			if n.level[row] != sim.prev_level[row] {
				hyd.head[i] = net.tank_h0[tk]
				hyd.tank_volume[tk] = tank_volume(net, hyd, tk, hyd.head[i])
				sim.prev_level[row] = n.level[row]
			}
		case .NONE:
		}
	}
	l := &sim.links
	for row in 0 ..< l.count {
		k := int(sim.link_engine[row])
		if k == 0 do continue
		lt := net.link_type[k]
		if lt != .PUMP {
			net.diam[k] = l.diameter[row] / u[.DIAM]
			d2 := net.diam[k] * net.diam[k]
			net.km[k] = 0.02517 * l.minor_loss[row] / d2 / d2
		}
		if lt <= .PIPE {
			net.len[k] = l.length[row] / u[.LENGTH]
			net.kc[k] = l.roughness[row]
			if hyd.formflag == .DW do net.kc[k] /= 1000 * u[.ELEV]
		} else if lt == .PUMP {
			pm := net.link_pump[k]
			if net.pump_type[pm] == .CONST_HP && l.pump_power[row] > 0 {
				net.km[k] = l.pump_power[row] / u[.POWER]
				net.pump_r[pm] = -8.814 * net.km[k] / u[.POWER]
			}
		}
		resist_coeff(net, hyd, k)
		if l.status[row] != sim.prev_status[row] {
			sim.prev_status[row] = l.status[row]
			#partial switch l.status[row] {
			case .OPEN:
				set_link_status(net, hyd, k, 1)
			case .CLOSED:
				set_link_status(net, hyd, k, 0)
			case .ACTIVE:
				if lt > .PUMP && lt != .GPV do set_link_setting(net, hyd, k, setting_in(p, k, l.setting[row]))
			}
		}
		if l.setting[row] != sim.prev_setting[row] {
			sim.prev_setting[row] = l.setting[row]
			if lt == .PUMP || (lt > .PUMP && lt != .GPV) do set_link_setting(net, hyd, k, setting_in(p, k, l.setting[row]))
		}
	}
}

// setting_in: a valve's setting in the engine's units (a pump's speed
// as it is).
setting_in :: proc "contextless" (p: ^Project, k: int, v: f64) -> f64 {
	#partial switch p.net.link_type[k] {
	case .PRV, .PSV, .PBV:
		return v / p.ucf[.PRESSURE]
	case .FCV:
		return v / p.ucf[.FLOW]
	}
	return v
}

// copy_out reads the results into the out columns, in the caller's units.
copy_out :: proc "contextless" (sim: ^Sim) {
	p := sim.engine
	net, hyd := &p.net, &p.hyd
	u := &p.ucf
	o := &sim.out
	for row in 0 ..< sim.nodes.count {
		i := int(sim.node_engine[row])
		if i == 0 {
			o.solved[row] = false
			o.pressure[row], o.head[row], o.demand[row], o.wanted[row], o.outflow[row] = 0, 0, 0, 0, 0
			o.emitter_flow[row], o.leak_flow[row] = 0, 0
			for col in o.quality do col[row] = 0
			continue
		}
		o.solved[row] = true
		o.head[row] = hyd.head[i] * u[.HEAD]
		o.pressure[row] = (hyd.head[i] - net.el[i]) * u[.PRESSURE]
		o.outflow[row] = hyd.node_demand[i] * u[.FLOW]
		o.demand[row] = hyd.demand_flow[i] * u[.FLOW]
		o.wanted[row] = hyd.full_demand[i] * u[.FLOW]
		o.emitter_flow[row] = hyd.emitter_flow[i] * u[.FLOW]
		o.leak_flow[row] = hyd.leak_flow[i] * u[.FLOW]
		for &cs, ci in sim.chems do o.quality[ci][row] = cs.q.node_qual[i] * cs.ucf
	}
	lo := &sim.link_out
	for row in 0 ..< sim.links.count {
		k := int(sim.link_engine[row])
		if k == 0 {
			lo.flow[row], lo.velocity[row], lo.headloss[row], lo.energy[row], lo.setting[row] = 0, 0, 0, 0, 0
			lo.status[row] = .CLOSED
			for col in lo.quality do col[row] = 0
			continue
		}
		lt := net.link_type[k]
		open := hyd.status[k] > .CLOSED
		lo.flow[row] = open ? hyd.flow[k] * u[.FLOW] : 0
		lo.velocity[row] = 0
		if lt != .PUMP && open {
			area := PI * (net.diam[k] * net.diam[k]) / 4.0
			lo.velocity[row] = abs(hyd.flow[k]) / area * u[.VELOCITY]
		}
		lo.headloss[row] = 0
		if open {
			h := hyd.head[net.n1[k]] - hyd.head[net.n2[k]]
			if lt != .PUMP do h = abs(h)
			lo.headloss[row] = h * u[.HEADLOSS]
		}
		lo.status[row] = hyd.status[k]
		if lt <= .PIPE {
			lo.setting[row] = hyd.formflag == .DW ? net.kc[k] * (1000.0 * u[.ELEV]) : net.kc[k]
		} else {
			v := hyd.setting[k] == MISSING ? 0 : hyd.setting[k]
			#partial switch lt {
			case .PRV, .PSV, .PBV:
				v *= u[.PRESSURE]
			case .FCV:
				v *= u[.FLOW]
			}
			lo.setting[row] = v
		}
		lo.energy[row], _ = get_energy(net, hyd, k)
		for &cs, ci in sim.chems do lo.quality[ci][row] = avg_qual(net, &cs.q, k) * cs.ucf
	}
	for &cs, ci in sim.chems do sim.balance[ci] = cs.q.balance
}

// levels_out puts the tanks' levels, as the step left them, in the level
// column: the state at sim.t, where a copy or the next step starts.
levels_out :: proc "contextless" (sim: ^Sim) {
	p := sim.engine
	net, hyd := &p.net, &p.hyd
	for row in 0 ..< sim.nodes.count {
		if sim.nodes.kind[row] != .TANK do continue
		i := int(sim.node_engine[row])
		if i == 0 do continue
		sim.nodes.level[row] = (hyd.head[i] - net.el[i]) * p.ucf[.ELEV]
		sim.prev_level[row] = sim.nodes.level[row]
	}
}

// ── stepping ──────────────────────────────────────────────────────────

// sim_step solves at sim.t with the tanks where they are, writes out,
// then moves the tanks and the clock on by dt: the hydraulic step, or
// less when a tank fills or empties, a control fires or the model's
// times say so. dt == 0 with no error is the end of a model's duration.
sim_step :: proc(sim: ^Sim) -> (dt: i32, warn: Warning, err: Error) {
	if err = ready(sim); err != nil do return
	if sim.engine == nil {
		sim.warn = .Nothing_To_Solve
		step := sim.options.hydraulic_step == 0 ? 3600 : sim.options.hydraulic_step
		sim.t += step
		return step, .Nothing_To_Solve, nil
	}
	p := sim.engine
	context.allocator = arena_allocator(&p.arena)
	net, hyd, t := &p.net, &p.hyd, &p.times
	copy_in(sim)
	_, errcode := run_hyd(net, hyd, &p.m, t, p)
	if errcode > 6 {
		sim.warn = .None
		return 0, .None, Error(errcode)
	}
	warn = Warning(errcode)
	sim.warn = warn
	sim.at_report = false
	if t.htime >= t.rtime {
		sim.at_report = true
		t.rtime += t.rstep
	}
	if t.qtime < t.dur {
		for &cs in sim.chems {
			swap_chemical(p, &cs)
			if sortcode := new_hydraulics(net, hyd, &cs.q); sortcode != 0 do return 0, warn, Error(sortcode)
		}
	}
	copy_out(sim)
	hydstep, _ := next_hyd(net, hyd, t, p)
	levels_out(sim)
	qstep: i64 = 0
	if t.htime <= t.dur do qstep = t.htime - t.qtime
	for ci in 0 ..< len(sim.chems) {
		cs := &sim.chems[ci]
		if cs.q.kind != .NONE && qstep > 0 {
			swap_chemical(p, cs)
			done: i64 = 0
			for !cs.q.out_of_memory && done < qstep {
				d := min(t.qstep, qstep - done)
				done += d
				transport(net, hyd, t, &cs.q, d)
			}
			if cs.q.out_of_memory do return 0, warn, .Out_Of_Memory
		}
		eval_mass_balance(net, &cs.q)
		sim.balance[ci] = cs.q.balance
	}
	t.qtime += qstep
	sim.t = i32(t.htime)
	return i32(hydstep), warn, nil
}

// sim_solve solves at sim.t again without moving: after an edit mid-step.
sim_solve :: proc(sim: ^Sim) -> (warn: Warning, err: Error) {
	if err = ready(sim); err != nil do return
	if sim.engine == nil {
		sim.warn = .Nothing_To_Solve
		return .Nothing_To_Solve, nil
	}
	p := sim.engine
	context.allocator = arena_allocator(&p.arena)
	copy_in(sim)
	_, errcode := run_hyd(&p.net, &p.hyd, &p.m, &p.times, p)
	if errcode > 6 {
		sim.warn = .None
		return .None, Error(errcode)
	}
	warn = Warning(errcode)
	sim.warn = warn
	copy_out(sim)
	return warn, nil
}

// ready rebuilds the engine when the structure changed.
ready :: proc(sim: ^Sim) -> Error {
	if sim.rewire || !sim.built do return rebuild(sim)
	return nil
}
