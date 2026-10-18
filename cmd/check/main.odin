package check

// check — the Odin API's own proofs: two roads to one answer.
//
//   check            every check, one `ok` or `bad` line each; exit 1 on a bad
//   check --reference    the network below with two chemicals, stepped for a
//                        day: every hour mark, as wasm/check.mjs prints it
//
// The roads: a network laid with node_add and link_add and stepped by
// hand against the same network as a Model through simulate (the same
// bytes); two chemicals on one Sim against two single-chemical runs (the
// same bytes); a loose junction left out, a Sim copied mid-run, and a
// Sim edited mid-run (within a tolerance, since a rebuilt engine starts
// its flows afresh). test.sh runs it and counts the lines.

import "core:fmt"
import "core:os"

import "../../epanet"

bad_count := 0

ok :: proc(name: string) {
	fmt.printf("ok %s\n", name)
}

bad :: proc(name: string, detail: string, args: ..any) {
	bad_count += 1
	fmt.printf("bad %s: ", name)
	fmt.printf(detail, ..args)
	fmt.println()
}

// ── the network, as a Model and as columns ────────────────────────────

MISSING :: epanet.MISSING

// the_model lays the test network as rows: a reservoir, four junctions
// (one with an emitter), a tank, a pump with a one-point curve and five
// pipes. GPM, Hazen-Williams, 24 hours by the hour.
the_model :: proc(quality: epanet.Qual_Type, decay, wall: f64) -> (m: epanet.Model) {
	m.options = epanet.DEFAULT_OPTIONS
	m.times = epanet.DEFAULT_TIMES
	m.report = epanet.default_report()
	m.times.duration = 24 * 3600
	m.options.quality = quality
	m.options.bulk_coeff, m.options.wall_coeff = decay, wall
	pipe :: proc(id, from, to: string, length, diam, rough: f64) -> epanet.Entity {
		return {id = id, kind = .PIPE, from = from, to = to, length = length, diameter = diam, roughness = rough,
			bulk_coeff = MISSING, wall_coeff = MISSING, x = MISSING, y = MISSING}
	}
	m.entities = make([]epanet.Entity, 12)
	m.entities[0] = {id = "R1", kind = .RESERVOIR, elevation = 700, x = MISSING, y = MISSING, bulk_coeff = MISSING}
	m.entities[1] = {id = "J1", kind = .JUNCTION, elevation = 710, x = MISSING, y = MISSING}
	m.entities[2] = {id = "J2", kind = .JUNCTION, elevation = 700, x = MISSING, y = MISSING}
	m.entities[3] = {id = "J3", kind = .JUNCTION, elevation = 695, x = MISSING, y = MISSING}
	m.entities[4] = {id = "J4", kind = .JUNCTION, elevation = 690, emitter = 2, x = MISSING, y = MISSING}
	m.entities[5] = {id = "T1", kind = .TANK, elevation = 850, init_level = 120, min_level = 100, max_level = 150, diameter = 50.5,
		x = MISSING, y = MISSING, bulk_coeff = MISSING}
	m.entities[6] = {id = "P1", kind = .PUMP, from = "R1", to = "J1", head_curve = "HC", speed = 1, x = MISSING, y = MISSING}
	m.entities[7] = pipe("p1", "J1", "J2", 5280, 14, 100)
	m.entities[8] = pipe("p2", "J2", "J3", 5280, 12, 100)
	m.entities[9] = pipe("p3", "J3", "J4", 5280, 10, 100)
	m.entities[10] = pipe("p4", "J2", "J4", 5280, 8, 100)
	m.entities[11] = pipe("p5", "J3", "T1", 3000, 12, 100)
	demands := [?]f64{0, 150, 200, 150, 100}
	for i in 1 ..= 4 {
		d := make([]epanet.Demand, 1)
		d[0] = {base = demands[i]}
		m.entities[i].demands = d
	}
	if quality == .CHEM {
		for &e in m.entities[:6] do e.init_quality = 0.5
		m.entities[0].has_source = true
		m.entities[0].source = {kind = .CONCEN, strength = 1}
	}
	m.curves = make([]epanet.Model_Curve, 1)
	x := make([]f64, 1)
	y := make([]f64, 1)
	x[0], y[0] = 1500, 250
	m.curves[0] = {id = "HC", kind = .PUMP_CURVE, x = x, y = y}
	return
}

// the_sim lays the same network as columns.
the_sim :: proc() -> (sim: epanet.Sim) {
	sim = epanet.sim_make(16, 16, {flow_units = .GPM, headloss = .HW})
	r1 := epanet.node_add(&sim, .RESERVOIR)
	sim.nodes.head[r1] = 700
	j := [5]int{}
	els := [?]f64{0, 710, 700, 695, 690}
	demands := [?]f64{0, 150, 200, 150, 100}
	for i in 1 ..= 4 {
		j[i] = epanet.node_add(&sim, .JUNCTION)
		sim.nodes.elevation[j[i]] = els[i]
		sim.nodes.demand[j[i]] = demands[i]
	}
	sim.nodes.emitter[j[4]] = 2
	t1 := epanet.node_add(&sim, .TANK)
	sim.nodes.elevation[t1] = 850
	sim.nodes.level[t1], sim.nodes.min_level[t1], sim.nodes.max_level[t1], sim.nodes.diameter[t1] = 120, 100, 150, 50.5
	p1 := epanet.link_add(&sim, .PUMP, r1, j[1])
	sim.links.pump_q[p1], sim.links.pump_h[p1] = 1500, 250
	pipe :: proc(sim: ^epanet.Sim, from, to: int, length, diam, rough: f64) {
		k := epanet.link_add(sim, .PIPE, from, to)
		sim.links.length[k], sim.links.diameter[k], sim.links.roughness[k] = length, diam, rough
	}
	pipe(&sim, j[1], j[2], 5280, 14, 100)
	pipe(&sim, j[2], j[3], 5280, 12, 100)
	pipe(&sim, j[3], j[4], 5280, 10, 100)
	pipe(&sim, j[2], j[4], 5280, 8, 100)
	pipe(&sim, j[3], t1, 3000, 12, 100)
	return
}

// ── the checks ────────────────────────────────────────────────────────

// bare_equals_model: the columns stepped by hand give the Model's run,
// bit for bit, hour by hour.
bare_equals_model :: proc() {
	name := "bare Sim = Model through simulate"
	m := the_model(.NONE, 0, 0)
	r, _, err := epanet.simulate(&m)
	if err != nil {
		bad(name, "simulate: %s", epanet.error_text(err))
		return
	}
	defer epanet.delete_results(&r)
	sim := the_sim()
	defer epanet.sim_delete(&sim)
	if len(r.periods) != 25 {
		bad(name, "%d periods, not 25", len(r.periods))
		return
	}
	hours := 0
	for at := i32(0); at < 24 * 3600 + 1; at = sim.t {
		_, _, serr := epanet.sim_step(&sim)
		if serr != nil {
			bad(name, "step at %d: %s (fault %d)", at, epanet.error_text(serr), sim.fault)
			return
		}
		if !sim.at_report do continue // a tank filled or emptied mid-hour: the hour mark comes next
		hour := int(at / 3600)
		hours += 1
		for i in 0 ..< sim.nodes.count {
			if sim.out.pressure[i] != r.node.pressure[hour][i] || sim.out.head[i] != r.node.head[hour][i] || sim.out.outflow[i] != r.node.demand[hour][i] {
				bad(name, "hour %d node %d: pressure %.17g vs %.17g", hour, i, sim.out.pressure[i], r.node.pressure[hour][i])
				return
			}
		}
		for k in 0 ..< sim.links.count {
			if sim.link_out.flow[k] != r.link.flow[hour][k] || sim.link_out.headloss[k] != r.link.headloss[hour][k] || sim.link_out.status[k] != r.link.status[hour][k] {
				bad(name, "hour %d link %d: flow %.17g vs %.17g", hour, k, sim.link_out.flow[k], r.link.flow[hour][k])
				return
			}
		}
	}
	if hours != 25 {
		bad(name, "%d hour marks, not 25", hours)
		return
	}
	if !sim.out.solved[1] || sim.out.pressure[1] <= 0 {
		bad(name, "J1 unsolved or without pressure")
		return
	}
	ok(name)
}

// two_chemicals: a decaying chemical and water age on one Sim give what
// two single-chemical Models give, bit for bit.
two_chemicals :: proc() {
	name := "two chemicals on one Sim = two single-chemical runs"
	chem := the_model(.CHEM, -0.5, -1)
	age := the_model(.AGE, 0, 0)
	rc, _, err1 := epanet.simulate(&chem)
	ra, _, err2 := epanet.simulate(&age)
	if err1 != nil || err2 != nil {
		bad(name, "simulate: %s / %s", epanet.error_text(err1), epanet.error_text(err2))
		return
	}
	defer epanet.delete_results(&rc)
	defer epanet.delete_results(&ra)
	sim := the_sim()
	defer epanet.sim_delete(&sim)
	init := make([]f64, sim.nodes.count)
	for &v in init do v = 0.5
	sources := make([]epanet.Source, 1)
	sources[0] = {node = 0, kind = .CONCEN, strength = 1}
	chems := make([]epanet.Chemical, 2)
	chems[0] = {kind = .CHEM, decay = -0.5, wall = -1, init = init, sources = sources}
	chems[1] = {kind = .AGE}
	sim.chemicals = chems
	for at := i32(0); at < 24 * 3600 + 1; at = sim.t {
		if _, _, serr := epanet.sim_step(&sim); serr != nil {
			bad(name, "step at %d: %s", at, epanet.error_text(serr))
			return
		}
		if !sim.at_report do continue
		hour := int(at / 3600)
		for i in 0 ..< sim.nodes.count {
			if sim.out.quality[0][i] != rc.node.quality[hour][i] {
				bad(name, "hour %d node %d: chemical %.17g vs %.17g", hour, i, sim.out.quality[0][i], rc.node.quality[hour][i])
				return
			}
			if sim.out.quality[1][i] != ra.node.quality[hour][i] {
				bad(name, "hour %d node %d: age %.17g vs %.17g", hour, i, sim.out.quality[1][i], ra.node.quality[hour][i])
				return
			}
		}
		for k in 0 ..< sim.links.count {
			if sim.link_out.quality[0][k] != rc.link.quality[hour][k] || sim.link_out.quality[1][k] != ra.link.quality[hour][k] {
				bad(name, "hour %d link %d: %.17g vs %.17g", hour, k, sim.link_out.quality[0][k], rc.link.quality[hour][k])
				return
			}
		}
	}
	if sim.out.quality[1][4] <= 0 || sim.out.quality[0][4] >= 1 {
		bad(name, "J4 age %g, chemical %g: nothing moved", sim.out.quality[1][4], sim.out.quality[0][4])
		return
	}
	if sim.balance[0].ratio == 0 || sim.balance[1].ratio == 0 {
		bad(name, "no mass balance")
		return
	}
	ok(name)
}

near :: proc(a, b, tol: f64) -> bool {
	return abs(a - b) <= tol * max(abs(a), abs(b), 1)
}

// loose_node_left_out: a junction no link touches is left out and the
// rest solves as its twin without it does; a part no source reaches,
// the same.
loose_node_left_out :: proc() {
	name := "a loose junction is left out, not refused"
	sim := the_sim()
	twin := the_sim()
	defer epanet.sim_delete(&sim)
	defer epanet.sim_delete(&twin)
	if _, _, err := epanet.sim_step(&sim); err != nil {
		bad(name, "step: %s", epanet.error_text(err))
		return
	}
	epanet.sim_step(&twin)
	epanet.sim_step(&twin)
	before := twin.out.pressure[:twin.nodes.count]
	loose := epanet.node_add(&sim, .JUNCTION)
	sim.nodes.elevation[loose] = 650
	sim.nodes.demand[loose] = 50
	island := epanet.node_add(&sim, .JUNCTION)
	island2 := epanet.node_add(&sim, .JUNCTION)
	epanet.link_add(&sim, .PIPE, island, island2)
	sim.links.length[sim.links.count - 1], sim.links.diameter[sim.links.count - 1], sim.links.roughness[sim.links.count - 1] = 100, 6, 100
	_, warn, err := epanet.sim_step(&sim)
	if err != nil {
		bad(name, "step with a loose node: %s", epanet.error_text(err))
		return
	}
	if warn != .None {
		bad(name, "warning %v", warn)
		return
	}
	if sim.out.solved[loose] || sim.out.solved[island] || sim.out.pressure[loose] != 0 {
		bad(name, "the loose node was solved")
		return
	}
	for i in 0 ..< len(before) {
		if !sim.out.solved[i] || !near(sim.out.pressure[i], before[i], 1e-3) {
			bad(name, "node %d moved: %.17g vs %.17g", i, sim.out.pressure[i], before[i])
			return
		}
	}
	ok(name)
}

// nothing_to_solve: a network with no tank steps the clock and says so.
nothing_to_solve :: proc() {
	name := "no source: nothing to solve, the clock moves"
	sim := epanet.sim_make(4, 4, {flow_units = .GPM})
	defer epanet.sim_delete(&sim)
	a := epanet.node_add(&sim, .JUNCTION)
	b := epanet.node_add(&sim, .JUNCTION)
	epanet.link_add(&sim, .PIPE, a, b)
	dt, warn, err := epanet.sim_step(&sim)
	if err != nil || warn != .Nothing_To_Solve || dt != 3600 || sim.t != 3600 || sim.out.solved[a] {
		bad(name, "dt %d warn %v err %v t %d", dt, warn, err, sim.t)
		return
	}
	ok(name)
}

// copied_mid_run: a copy at hour 6 reaches hour 12 where the original
// does, within the solver's accuracy (its flows start afresh, and a
// solve stops at a relative flow change of 1e-3).
copied_mid_run :: proc() {
	name := "a Sim copied mid-run goes on as the original"
	sim := the_sim()
	defer epanet.sim_delete(&sim)
	for _ in 0 ..< 6 do epanet.sim_step(&sim)
	cp := epanet.sim_copy(&sim)
	defer epanet.sim_delete(&cp)
	if cp.t != sim.t || cp.nodes.level[5] != sim.nodes.level[5] {
		bad(name, "the copy is not at the same time and level")
		return
	}
	for _ in 0 ..< 6 {
		epanet.sim_step(&sim)
		if _, _, err := epanet.sim_step(&cp); err != nil {
			bad(name, "the copy's step: %s", epanet.error_text(err))
			return
		}
	}
	if cp.t != sim.t {
		bad(name, "the clocks differ: %d vs %d", cp.t, sim.t)
		return
	}
	for i in 0 ..< sim.nodes.count {
		if !near(cp.out.pressure[i], sim.out.pressure[i], 1e-3) || !near(cp.nodes.level[i], sim.nodes.level[i], 1e-3) {
			bad(name, "node %d: %.17g vs %.17g (level %g vs %g)", i, cp.out.pressure[i], sim.out.pressure[i], cp.nodes.level[i], sim.nodes.level[i])
			return
		}
	}
	ok(name)
}

// edited_mid_run: a demand doubled is seen by the next step; a pipe
// closed is seen; a pipe laid rewires and the rest holds.
edited_mid_run :: proc() {
	name := "values and a closed pipe are seen by the next step; a pipe laid rewires"
	sim := the_sim()
	defer epanet.sim_delete(&sim)
	epanet.sim_step(&sim)
	p0 := sim.out.pressure[4]
	sim.nodes.demand[4] *= 4
	epanet.sim_solve(&sim)
	if !(sim.out.pressure[4] < p0) {
		bad(name, "a demand four times as big did not drop J4's pressure (%g vs %g)", sim.out.pressure[4], p0)
		return
	}
	if !near(sim.out.demand[4], 400, 1e-9) {
		bad(name, "J4's delivered demand is %g, not 400", sim.out.demand[4])
		return
	}
	sim.nodes.demand[4] /= 4
	sim.links.status[4] = .CLOSED // p4, J2-J4
	epanet.sim_solve(&sim)
	if sim.link_out.flow[4] != 0 || sim.link_out.status[4] != .CLOSED {
		bad(name, "the closed pipe still flows (%g, %v)", sim.link_out.flow[4], sim.link_out.status[4])
		return
	}
	sim.links.status[4] = .OPEN
	epanet.sim_solve(&sim)
	if sim.link_out.flow[4] == 0 {
		bad(name, "the reopened pipe does not flow")
		return
	}
	k := epanet.link_add(&sim, .PIPE, 1, 4) // J1-J4
	sim.links.length[k], sim.links.diameter[k], sim.links.roughness[k] = 5280, 12, 100
	if !sim.rewire {
		bad(name, "link_add did not ask for a rewire")
		return
	}
	if _, _, err := epanet.sim_step(&sim); err != nil {
		bad(name, "step after the pipe laid: %s", epanet.error_text(err))
		return
	}
	if sim.link_out.flow[k] == 0 || !sim.out.solved[4] {
		bad(name, "the new pipe carries nothing")
		return
	}
	ok(name)
}

// pump_without_curve: a pump with no design point and no power is an
// error that names its row.
pump_without_curve :: proc() {
	name := "a pump with no curve is an error naming the link"
	sim := the_sim()
	defer epanet.sim_delete(&sim)
	sim.links.pump_q[0] = 0
	_, _, err := epanet.sim_step(&sim)
	if err != .No_Pump_Curve || sim.fault != 0 {
		bad(name, "err %v fault %d", err, sim.fault)
		return
	}
	ok(name)
}

// model_written_and_read: the Model written as .inp and loaded again
// runs to the same bytes.
model_written_and_read :: proc() {
	name := "a Model written as .inp and read back runs the same"
	m := the_model(.CHEM, -0.5, -1)
	path := "build/check.inp"
	if err := epanet.write_inp(&m, path); err != nil {
		bad(name, "write_inp: %s", epanet.error_text(err))
		return
	}
	m2, lerr := epanet.load(path)
	if lerr != nil {
		bad(name, "load: %s", epanet.error_text(lerr))
		return
	}
	defer epanet.delete_model(&m2)
	if len(m2.entities) != 12 || len(m2.curves) != 1 || m2.options.quality != .CHEM {
		bad(name, "%d entities, %d curves, quality %v", len(m2.entities), len(m2.curves), m2.options.quality)
		return
	}
	r1, _, e1 := epanet.simulate(&m)
	r2, _, e2 := epanet.simulate(&m2)
	if e1 != nil || e2 != nil {
		bad(name, "simulate: %v / %v", e1, e2)
		return
	}
	defer epanet.delete_results(&r1)
	defer epanet.delete_results(&r2)
	if len(r1.periods) != len(r2.periods) {
		bad(name, "%d periods vs %d", len(r1.periods), len(r2.periods))
		return
	}
	// (the file lists junctions first, so the rows differ: compare by
	// name; and EPANET's writer keeps four decimals, which the tank's
	// minimum volume, and so its mixing, feels)
	for hour in 0 ..< len(r1.periods) {
		for id, i in r1.ids.node {
			j := r2.ids.node_index[id]
			if !near(r1.node.pressure[hour][i], r2.node.pressure[hour][j], 1e-12) || !near(r1.node.quality[hour][i], r2.node.quality[hour][j], 1e-6) {
				bad(name, "hour %d node %s: %.17g vs %.17g", hour, id, r1.node.pressure[hour][i], r2.node.pressure[hour][j])
				return
			}
		}
	}
	ok(name)
}

// reference prints the bare road with two chemicals, hour by hour, in
// the lines wasm/check.mjs prints: the wasm build is held to these.
reference :: proc() {
	sim := the_sim()
	defer epanet.sim_delete(&sim)
	init := make([]f64, sim.nodes.count)
	for &x in init do x = 0.5
	sources := make([]epanet.Source, 1)
	sources[0] = {node = 0, kind = .CONCEN, strength = 1}
	chems := make([]epanet.Chemical, 2)
	chems[0] = {kind = .CHEM, decay = -0.5, wall = -1, init = init, sources = sources}
	chems[1] = {kind = .AGE}
	sim.chemicals = chems
	for at := i32(0); at < 24 * 3600 + 1; at = sim.t {
		if _, _, err := epanet.sim_step(&sim); err != nil {
			fmt.eprintf("reference: step at %d: %s\n", at, epanet.error_text(err))
			os.exit(2)
		}
		if !sim.at_report do continue
		h := int(at / 3600)
		o, lo := &sim.out, &sim.link_out
		for i in 0 ..< sim.nodes.count {
			fmt.printf("%d node %d %.17g %.17g %.17g %.17g %.17g\n", h, i, o.pressure[i], o.head[i], o.outflow[i], o.quality[0][i], o.quality[1][i])
		}
		for k in 0 ..< sim.links.count {
			fmt.printf("%d link %d %.17g %.17g %.17g %.17g\n", h, k, lo.flow[k], lo.headloss[k], lo.quality[0][k], lo.quality[1][k])
		}
	}
	fmt.printf("massbalance %.17g %.17g\n", sim.balance[0].ratio, sim.balance[1].ratio)
}

main :: proc() {
	if len(os.args) == 2 && os.args[1] == "--reference" {
		reference()
		return
	}
	bare_equals_model()
	two_chemicals()
	loose_node_left_out()
	nothing_to_solve()
	copied_mid_run()
	edited_mid_run()
	pump_without_curve()
	model_written_and_read()
	os.exit(bad_count > 0 ? 1 : 0)
}
