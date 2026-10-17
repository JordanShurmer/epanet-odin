# The Odin API

A second face for the engine, beside the toolkit (`api/`, EPANET's `EN_*`
for C programs). This one is for Odin programs and for anything that can
call Odin, a game in WebAssembly included: columns in, columns out, one
proc per step of the job, errors as values. It is what the `epanet`
package exports; the `EN_*` library keeps working over the same engine.

Rung numbers are the [ponytail](https://github.com/DietrichGebert/ponytail)
ladder (bywater-mill's `PONYTAIL.md`): where a choice stopped.

## Who it is for

Three users, read before a line was designed:

**Waterworks** (aule-dev-web, `web/waterworks/`), a game whose water is
EPANET's. It keeps its network as columns of typed arrays (`net.js`: a
node is a node whether house, spring or tank, the kind says which, the
unused fields stay zero) and, every time the network changes, writes the
columns out as an `.inp` text, has EPANET's wasm build parse it back, looks
its indexes up by name, runs the rest of the day step by step reading one
value per wasm call per node per property per step, and blends between
steps each frame. For three minerals in the spring it solves the
hydraulics three more times, once per chemical. It works out reachability
itself, because EPANET refuses a node no pipe touches and cannot solve a
part with no source. All of that is the engine's job to carry, not the
game's.

**bywater-mill**, which builds a project from its own tables on every run
through `EN_add*`/`EN_set*`, solves, reads results one value per call,
steps a timeline frame by frame, and re-solves in a loop for fire flow.

**The file world**: `.inp` files read, written, round-tripped, and EPANET's
numbers matched byte for byte, which is how every phase of this port is
checked.

| | wants | does not want |
|---|---|---|
| a game | columns it already has, edited any time, a step at a time, no text, no names, solve what can be solved, several chemicals at once, wasm | files, a parse, a handle, an error for a loose node |
| bywater-mill | its tables in, results as tables out, a step loop, one number changed between solves | one call per value |
| files | the `.inp` as data, every section, round trips | — |

## The shape

```
                          ┌──────────── sim_from_model ─────────────┐
 .inp ──load──► Model ────┤                                         ▼
       ◄─write_inp─       │   your columns ──sim_make──► Sim ──sim_step──► sim.out (this step)
                          │                              ▲ │
                          └──────────simulate────────────┘ └── Results (every period)
```

| | What it is | Shape | Units |
|---|---|---|---|
| **`Sim`** | the engine's face: a network as columns, editable at any time, stepped through time; its results for the step in columns beside them. | columns | the caller's |
| **`Model`** | the network as written: one `Entity` per component, ids as strings, patterns, curves, controls, rules, options. The `.inp` file as data. | rows | the modeller's |
| **`Results`** | a whole run: every reporting period, every node and link. | tables | the modeller's |

Rows for people, columns for the machine. A file is rows, a table someone
edits by hand is rows, so `Model` is rows. The engine runs over columns
and a game keeps columns, so `Sim` is columns; `sim_from_model` is the one
place the two meet.

There is no Project. EPANET's `Project` is the toolkit's handle: the
network, the run state, the open files, the report's line count and the
parser's flags in one struct, because a C API needs one pointer. Inside
the package today's `Project` splits the same way: the engine's part
becomes `Sim`; the files, the report state and the `EN_*` semantics move
to `api/`, whose handle is a `Sim` plus those. The report writers take a
`Sim` and a `^Report` that is nil when no one asked for a report.

## Sim

### The columns

```odin
Sim :: struct {
	nodes: Nodes,         // written by the caller; read by every step
	links: Links,
	chemicals: []Chemical,
	options: Sim_Options,
	t: i32,               // the clock, seconds
	rewire: bool,         // set when the structure changed: a node or link added or removed, a kind or an end changed
	out: Node_Out,        // written by the step; the caller's units, the caller's indexes
	link_out: Link_Out,
	warn: Warning,        // the last step's
	fault: int,           // the node or link an error was about, or -1
	// the engine's own: the network in internal units with junctions first, the solver
	// state, the matrix, the map from the caller's indexes to its own. Readable; not for writing.
	…
}

Node_Kind :: enum u8 { NONE, JUNCTION, RESERVOIR, TANK }   // NONE: an empty row
Nodes :: struct {
	count:     int,
	kind:      []Node_Kind,
	elevation: []f64,
	demand:    []f64,   // a junction's base demand; the caller changes it whenever it likes
	emitter:   []f64,   // a leak's coefficient, 0 = none
	head:      []f64,   // a reservoir's
	level, min_level, max_level, diameter, min_volume: []f64, // a tank's; level is the engine's as time passes, and the caller's to set
}

Link_Kind :: enum u8 { NONE, PIPE, PUMP, PRV, PSV, PBV, FCV, TCV, GPV, PCV }
Links :: struct {
	count:     int,
	kind:      []Link_Kind,
	from, to:  []i32,
	status:    []Status,   // OPEN, CLOSED; ACTIVE for a valve holding its setting
	setting:   []f64,      // a valve's setting, a pump's speed (1)
	length, diameter, roughness, minor_loss: []f64, // a pipe's; diameter a valve's too
	check_valve: []bool,   // a pipe's
	pump_q, pump_h: []f64, // a pump's design point: EPANET fits its curve (shut-off at 4/3 h, twice q at none)
	pump_power: []f64,     // or a constant-power pump, when > 0
}

Chemical :: struct {
	decay:   f64,          // bulk, first order, per day; negative decays
	sources: []Source,     // where it comes in
}
Source :: struct { node: int, kind: Source_Kind, strength: f64 }

Sim_Options :: struct {
	flow_units:     Flow_Units,       // what every column is in; .LPS makes the rest metres and millimetres
	headloss:       Headloss_Formula, // .HW
	demand_model:   Demand_Model,     // .DDA; .PDA with the two pressures below
	min_pressure, required_pressure, pressure_exponent: f64,
	emitter_exponent: f64,            // 2 (EPANET keeps 1/x)
	trials:         int,              // 200
	accuracy:       f64,              // 0.001
	unbalanced:     Unbalanced,       // {.STOP} or {.CONTINUE, extra_trials}
	hydraulic_step: i32,              // 3600 s; the most a step advances
	quality_step:   i32,              // 0: a tenth of the hydraulic step
}

Node_Out :: struct {
	solved:    []bool, // false: no path to a reservoir or tank, so left out and zero
	pressure, head: []f64,
	demand:    []f64,  // delivered
	wanted:    []f64,  // asked for (PDA: the share delivered is demand / wanted)
	emitter_flow: []f64,
	quality:   [][]f64, // [chemical][node]
}
Link_Out :: struct {
	flow, velocity, headloss: []f64,
	energy:  []f64,     // a pump's kW
	status:  []Status,
	quality: [][]f64,   // [chemical][link]
}
```

Every column is a slice over one block the `Sim` owns, sized once at
`sim_make`. A node is its index in `nodes`; a link, in `links`; a result,
the same index in `out`. There is no name anywhere in a `Sim`: a program
that has names keeps its own map, as every game and every database does.

### The procs

```odin
sim_make   :: proc(node_cap, link_cap: int, opts: Sim_Options, allocator := context.allocator) -> Sim
sim_delete :: proc(sim: ^Sim)
sim_copy   :: proc(sim: ^Sim, allocator := context.allocator) -> Sim   // the whole state: a what-if, a look ahead

node_add    :: proc(sim: ^Sim, kind: Node_Kind) -> int   // a row, zeroed; fill its columns
node_remove :: proc(sim: ^Sim, i: int)                   // the last row takes its place; links follow
link_add    :: proc(sim: ^Sim, kind: Link_Kind, from, to: int) -> int
link_remove :: proc(sim: ^Sim, k: int)

// Solve at sim.t with the tanks where they are, write out, move the tanks and
// the clock on by dt: the hydraulic step, or less when a tank fills, empties
// or a chemical front says so. dt == 0 means nothing moved (an error).
sim_step  :: proc(sim: ^Sim) -> (dt: i32, warn: Warning, err: Error)
// Solve at sim.t again without moving: after an edit mid-step.
sim_solve :: proc(sim: ^Sim) -> (warn: Warning, err: Error)
```

**Values are read every step.** `sim_step` converts every column into the
engine's units each time (an O(n) copy, nothing beside a solve), so a
demand or a status changed in place is simply seen. The caller never says
"I changed a value".

**Structure is read when told.** `node_add`, `link_add`, `node_remove`
and `link_remove` set `sim.rewire`; a caller that changes a `kind`, a
`from` or a `to` by hand sets it too. The next step rebuilds the plan:
which nodes a source reaches, the engine's own numbering (junctions first,
tanks and reservoirs after, as EPANET's solver needs), the sparse matrix
shape. That is a parse's worth of work for a big network and nothing for a
game's.

**What cannot be solved is left out, not refused.** A node no link
touches, or a part of the network no reservoir or tank is joined to, is
not sent to the solver: `out.solved[i]` is false and its results are zero.
With nothing reachable the step solves nothing, moves the clock, and warns
`.Nothing_To_Solve`. EPANET's errors 223, 224 and 233 do not exist here.
(This is the one place the Odin face means something other than EPANET:
Waterworks had to compute it in JavaScript; a program that wants EPANET's
refusal has the toolkit.)

**Chemicals ride the same hydraulics.** After each hydraulic step the
transport runs once per chemical over that step, each with its own
segments, sources and decay. One solve, N chemicals. (Waterworks solves
the hydraulics once per mineral, because an EPANET project carries one.)

**No patterns, controls or rules in a bare Sim.** The caller is the
controller: it sets the demands for the hour and closes the pipe itself
before the step. A `Sim` made from a `Model` keeps the model's patterns,
controls and rules inside and plays them each step, which is how
`simulate` reproduces EPANET's run. (rung 1 for the game: Waterworks has
its own clock and its own day curve.)

**Nothing allocates in a step.** The `Sim` sized itself at `sim_make`; a
step runs in the loop of a game at a frame's pace. A pure function of the
struct: the same columns give the same numbers, bit for bit, which is what
a replay or a lockstep multiplayer wants; one `Sim` per thread, nothing in
the package is global but read-only tables.

**Times are `i32` seconds.** A day is 86 400; the type crosses to
JavaScript as a number, where an `i64` does not.

### Errors and warnings

```odin
Error :: enum i32 {
	None = 0,
	Out_Of_Memory = 101, Unsolvable = 110, … every EPANET code, by its EPANET name …
}
Warning :: enum i32 {
	None, Unbalanced = 1, Unstable, Disconnected, Pumps, Valves, Negative_Pressure,
	Nothing_To_Solve = 7,
}
error_message :: proc(err: Error) -> string   // EPANET's text (errors.odin, already there)
```

EPANET's numbers stay the values, so a code read from a report, a C
program or the toolkit means the same thing. `err != nil` is the test.
`sim.fault` names the node or link an error is about (a valve on a
reservoir, a pump with no curve), so a game can point at it.

## Model

The network as written: what `load` reads, `write_inp` writes, and a
program edits by hand. One fat struct for every component: a junction, a
reservoir, a tank, a pipe, a pump and a valve are one `Entity` with a
`kind`; unused fields stay zero. It is the `.inp` file's row and
bywater-mill's `Entity`, so a program's own table maps one to one.
Patterns and curves are series and controls and rules are statements:
those keep their own small shapes.

```odin
Model :: struct {
	title:    [3]string,
	entities: []Entity,
	patterns: []Pattern,
	curves:   []Curve,
	controls: []Control,
	rules:    []Rule,
	options:  Options,
	times:    Times,
	problems: []Problem,  // what load could not read; empty when the file was clean
}

Kind :: enum { JUNCTION, RESERVOIR, TANK, PIPE, PUMP, VALVE }

Entity :: struct {
	id:       string,
	kind:     Kind,
	x, y:     f64,       // MISSING when the file had none
	vertices: [][2]f64,  // a link's bends
	// a node
	elevation:    f64,
	demands:      []Demand,
	emitter:      f64,
	head_pattern: string,   // a reservoir's
	init_level, min_level, max_level, min_volume: f64, // a tank's
	volume_curve: string,
	overflow:     bool,
	mixing:       Mix_Model,
	mixing_fraction: f64,   // 1 when not given
	init_quality: f64,
	source:       Source_Spec, // kind == .NONE when there is none
	// a link
	from, to:     string,
	length, roughness, minor_loss: f64,
	diameter:     f64,      // a pipe's, a valve's; a tank's too
	bulk_coeff, wall_coeff: f64, // MISSING = the global one
	leak_area, leak_expansion: f64,
	check_valve:  bool,
	power:        f64,      // a constant-power pump; 0 = none
	head_curve:   string,
	speed:        f64,      // 1 when not given
	speed_pattern, energy_pattern, efficiency_curve: string,
	energy_price: f64,
	valve:        Valve_Type,
	setting:      f64,
	loss_curve:   string,   // a GPV's head loss curve, a PCV's position curve
	status:       Status,
	comment, tag: string,
}
Demand :: struct { base: f64, pattern, name: string }
Source_Spec :: struct { kind: Source_Kind, strength: f64, pattern: string }
Pattern :: struct { id: string, factors: []f64, comment: string }
Curve   :: struct { id: string, kind: Curve_Type, x, y: []f64, comment: string }
Control :: struct { link: string, status: Status, setting: f64, kind: Control_Type, node: string, level: f64, time: i64, enabled: bool }
Rule    :: struct { text: string }  // EPANET's grammar, one clause per line: one grammar, not two (rung 1)
Options :: struct { … EPANET's options by name, typed; DEFAULT_OPTIONS to start from … }
Times   :: struct { duration, hydraulic_step, quality_step, pattern_step, pattern_start, report_step, report_start, rule_step, start_clocktime: i64, statistic: Time_Stat }

load         :: proc(path: string, allocator := context.allocator) -> (model: Model, err: Error)
parse        :: proc(text: string, allocator := context.allocator) -> (model: Model, err: Error)
write_inp    :: proc(model: Model, path: string) -> Error
delete_model :: proc(model: Model)
```

A file with bad lines still comes back, `problems` filled and
`err == .Input_Errors` (EPANET's 200): a program can show them.

### Model to Sim

```odin
sim_from_model :: proc(model: Model, allocator := context.allocator) -> (sim: Sim, ids: Ids, err: Error)
Ids :: struct { node, link: []string, node_index, link_index: map[string]int }
```

The one conversion: entities to columns (the nodes in the model's order,
the links in theirs), the patterns, controls and rules kept inside the
`Sim` to play each step, the names handed back beside it for whoever
wants them. A program that only has a `Sim` and wants a file writes a
`Model` from the columns; that is `model_from_sim`, when someone needs it.

## Results

```odin
simulate :: proc(model: Model, allocator := context.allocator) -> (r: Results, warn: Warning, err: Error)
delete_results :: proc(r: Results)

Results :: struct {
	periods:  []i32,        // reporting times (report start, every report step)
	units:    Units,        // the texts: "gpm", "psi", "ft" …
	node:     Node_Table,   // [period][node]
	link:     Link_Table,   // [period][link]
	warnings: []Warning,    // one per period
	energy:   []Pump_Usage, // one per pump: the energy table's row
	mass_balance: Mass_Balance,
}
Node_Table :: struct { demand, head, pressure, quality: [][]f64 }
Link_Table :: struct { flow, velocity, headloss, quality, status, setting, reaction, friction: [][]f64 }
```

`simulate` is `sim_from_model`, a loop of `sim_step` with `sim.out` copied
at the reporting times, `sim_delete`; nothing a program cannot do itself.
Each `[][]f64` is one flat allocation with a slice header per period, so a
column is contiguous and a program that wants the block has it. The four
node and eight link variables are the ones EPANET's output file holds.

## WebAssembly

Odin builds the package for `wasm32`. The game's side is small: a handful
of exported procs that take a `^Sim` and plain numbers, and one that
hands back the addresses of the columns, so JavaScript makes a
`Float64Array` view over each column in the wasm memory, writes a demand,
calls `step`, reads a pressure. No text, no file system, no name, no
`malloc` for an out-parameter, no copy: the columns the game draws from
are the engine's. The solve runs where the game puts it, a worker or the
main thread; a step on a game's network is well under a frame.

## Examples

**Waterworks, as it would be.** `net.js` keeps its columns; the engine's
are the same ones. The input-file writer, the name lookups, the reach
check, the per-value reads and the extra solves per mineral go.

```odin
sim := epanet.sim_make(256, 256, {flow_units = .LPS, headloss = .HW, demand_model = .PDA,
	required_pressure = 20, pressure_exponent = 0.5, emitter_exponent = 2, hydraulic_step = 900})
spring := epanet.node_add(&sim, .RESERVOIR); sim.nodes.head[spring] = 204
house  := epanet.node_add(&sim, .JUNCTION);  sim.nodes.elevation[house] = 140; sim.nodes.demand[house] = 0.3
main   := epanet.link_add(&sim, .PIPE, spring, house)
sim.links.length[main], sim.links.diameter[main], sim.links.roughness[main] = 312, 100, 140
sim.chemicals = {{decay = -8, sources = {{node = spring, kind = .CONCEN, strength = 2}}}}

// each game quarter hour
sim.nodes.demand[house] = base_demand * day_curve[hour]      // the game is the controller
dt, warn, err := epanet.sim_step(&sim)
pressure := sim.out.pressure[house]                           // m
served   := sim.out.demand[house] / sim.out.wanted[house]     // the share, for the window to light
colour   := sim.link_out.quality[0][main]                     // sparkstone, mg/L in the main

// a burst: an emitter opens; the step after sees it
sim.nodes.emitter[house] = 0.25
// a pipe laid: a row more; the next step rewires
k := epanet.link_add(&sim, .PIPE, house, new_house)
```

Blending between steps is the game's, as now: keep the previous `out`
and interpolate to the current. Looking at the rest of the day, as the
game does today, is `sim_copy` and stepping the copy to midnight.

**bywater-mill**, a run from its own tables and the results per entity:

```odin
model := epanet.Model{entities = entities[:], options = epanet.DEFAULT_OPTIONS, times = epanet.DEFAULT_TIMES}
model.times.duration = 24 * 3600
r, warn, err := epanet.simulate(model)
pressure_of_entity := r.node.pressure[k][node_of_entity[e]]
```

Fire flow, one demand at a time on one `Sim`:

```odin
sim, ids, err := epanet.sim_from_model(model)
defer epanet.sim_delete(&sim)
for hydrant in hydrants {
	sim.nodes.demand[hydrant] += 1500
	epanet.sim_solve(&sim)
	available[hydrant] = sim.out.pressure[hydrant]
	sim.nodes.demand[hydrant] -= 1500
}
```

The timeline, every event:

```odin
for sim.t < duration {
	dt, warn, err := epanet.sim_step(&sim)
	if err != nil do break
	if sim.t % report_step == 0 do film_append(&film, sim.t, sim.out.pressure, sim.link_out.flow)
}
```

A thousand what-ifs, one per thread, each from the same start:

```odin
base, _, _ := epanet.sim_from_model(model)
for variant, i in variants {   // each on its own thread
	sim := epanet.sim_copy(&base)
	sim.links.diameter[variant.link] = variant.diameter
	epanet.sim_solve(&sim)
	score[i] = sim.out.pressure[watched]
	epanet.sim_delete(&sim)
}
```

(The surface and these examples type-check as a stub package.)

## Decisions

- **Columns are the API.** The `Sim` is the engine's own shape handed
  out: no handle, no property codes, no getter per value. A game that
  already keeps columns keeps them; the engine's results are columns
  beside them. (rung 2: `Network` and `Hydraulics` are already one array
  per field.)
- **A `Sim` is editable and stepped; a `Model` is rows for files.** Two
  faces because they serve two jobs: the solver and a game want columns
  and a clock; a file and a person want rows with names. One conversion
  between them.
- **Values re-read every step, structure on `rewire`.** No "I changed X"
  protocol for values; one flag for shape. The cost of the re-read is a
  copy, which nothing notices beside a solve.
- **Left out, not refused.** The engine solves what a source reaches and
  says what it left. A game's valley with a dangling pipe is a normal
  state, not an error.
- **N chemicals, one hydraulics.** The transport is per chemical over the
  same step; EPANET's one-species-per-project is a limit of its project,
  not of its method.
- **The caller is the controller in a bare `Sim`.** Patterns, controls
  and rules are a file's way of saying what a program says in code; they
  play only inside a `Sim` made from a `Model`.
- **No Project, no files, no callbacks, no names in a `Sim`.** The
  numbers come back as data; EPANET's paper, when anyone wants it, is one
  proc written from a `Model` and a `Results`.
- **EPANET's error numbers as the enum's values.** One meaning
  everywhere, plus the one warning EPANET never gives because it refuses
  instead.

## Not in it

- An incremental editor by name (`EN_add*`/`EN_delete*` with index
  fix-ups): the toolkit's, when the editing phase ports it; a `Sim` edits
  columns by index, a `Model` by row. (rung 1)
- Report and progress callbacks, the hydraulics file, the output file.
  (rung 1)
- Threads inside a step. One `Sim` per thread; `sim_copy` is how a run
  forks.

## Where it goes, in order

Each step is checked the way the port has been: the same bytes as EPANET,
and, for what EPANET cannot do, two roads to one answer.

1. **`sim.odin`** — `Sim`, its columns, `sim_make`/`sim_delete`/`sim_copy`,
   the row procs, the plan (reach, the engine's numbering, the matrix
   shape) over `open.odin`, `sim_step` and `sim_solve` over `init_hyd`,
   `run_hyd`, `next_hyd` and the quality transport, N chemicals. The
   engine's struct becomes `Sim`; the report and file state leave it for
   `api/`. `Error`, `Warning`; `errors.odin` gives `error_message`.
2. **`model.odin`, `load`, `sim_from_model`** — the parser's second half
   writes a `Model`; `sim_from_model` is the parser's tail over it.
   `cmd/dumpnet` dumps the `Sim` and keeps proving the pair against
   EPANET's reader, byte for byte, on every fixture.
3. **`simulate`** — a new driver, `cmd/run`, prints what `harness/run.c`
   prints and must match `run-c` on every fixture: the `Sim`'s step loop
   reproduces EPANET's run, events, patterns, controls and rules included.
4. **The bare road** — a fixture built with `node_add`/`link_add` and
   stepped must give the same numbers as the same network through `.inp`
   and `simulate`: Waterworks' `check.mjs` network, laid both ways.
   Then N chemicals against N single-chemical EPANET runs.
5. **`write_inp`**, checked by a round trip: `load` → `write_inp` → `load`
   dumps the same.
6. **wasm** — the package built for `wasm32`, the column addresses
   exported, Waterworks' `solver.js` and `net.js#inp` replaced; its
   `check.mjs` is the test, and its day must read the same as before.
