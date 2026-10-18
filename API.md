# The Odin API

A second face for the engine, beside the toolkit (`api/`, EPANET's `EN_*`
for C programs). This one is for Odin programs and for anything that can
call Odin, a game in WebAssembly included: columns in, columns out, one
proc per step of the job, errors as values. It is what the `epanet`
package exports (`model.odin`, `sim.odin`, `simulate.odin`); the `EN_*`
library keeps working over the same engine. Built as designed, with two
departures noted where they fall: the engine's `Project` stays inside the
`Sim` as its own, and a copy rebuilds its engine rather than cloning the
solver's state.

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

There is no Project in the API. EPANET's `Project` is the toolkit's
handle: the network, the run state, the open files, the report's line
count and the parser's flags in one struct, because a C API needs one
pointer. The design had the engine's part become `Sim` and the rest move
to `api/`; what was built keeps the `Project` whole, inside the `Sim` as
the engine it owns and rebuilds on rewire (from an effective `Model`,
through the same builder the reader's tail runs), with its file and
report state simply unused. That was the first rung that held: the
toolkit, the harness and the step all run the one engine, and nothing
had to move.

## Sim

### The columns

```odin
Sim :: struct {
	nodes:     Nodes,         // written by the caller; read by every step
	links:     Links,
	chemicals: []Chemical,    // read on rewire
	options:   Sim_Options,
	t:         i32,           // the clock, seconds
	rewire:    bool,          // set when the structure changed: a row added or removed, a kind or an end changed by hand
	out:       Node_Out,      // written by the step; the caller's units, the caller's indexes
	link_out:  Link_Out,
	warn:      Warning,       // the last step's
	fault:     int,           // the node or link an error was about, or -1
	at_report: bool,          // the last step's results fell on one of the model's reporting times
	balance:   []Mass_Balance, // per chemical
	// the engine's own: the Model this came from (nil when bare), which entity
	// each row came from, the engine's 1-based index per row (0 = left out),
	// the project and the per-chemical solver states. Readable; not for writing.
	…
}

Node_Kind :: enum u8 { NONE, JUNCTION, RESERVOIR, TANK }   // NONE: an empty row
Nodes :: struct {
	count:     int,
	kind:      []Node_Kind,
	elevation: []f64,
	demand:    []f64,   // a junction's base demand (a model junction's first category; the others ride inside)
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
	pump_q, pump_h: []f64, // a pump's design point: EPANET fits its curve (shut-off at 4/3 h, twice q at none); read on rewire
	pump_power: []f64,     // or a constant-power pump, when > 0
}

Chemical_Kind :: enum u8 { CHEM, AGE, TRACE }
Chemical :: struct {
	kind:    Chemical_Kind,
	trace:   int,          // .TRACE: the node traced
	decay:   f64,          // bulk coefficient, per day; negative decays
	wall:    f64,          // wall coefficient, per day
	init:    []f64,        // initial quality per node; nil = zero
	sources: []Source,     // where it comes in
}
Source :: struct { node: int, kind: Source_Type, strength: f64, pattern: int } // pattern: the Sim's Model's, from 1; 0 = none

Sim_Options :: struct {        // a zero is EPANET's default
	flow_units:     Flow_Units,       // CFS; .LPS and up make the rest metres and millimetres
	pressure_units: Pressure_Units,   // PSI, or metres with metric flow units
	headloss:       Headloss_Formula, // HW
	demand_model:   Demand_Model,     // DDA; .PDA with the two pressures below
	min_pressure, required_pressure, pressure_exponent: f64,
	emitter_exponent: f64,            // 0.5
	trials:         int,              // 200
	accuracy:       f64,              // 0.001
	continue_unbalanced: bool,        // EPANET's UNBALANCED CONTINUE, with extra_trials more; off = STOP
	extra_trials:   int,
	hydraulic_step: i32,              // 3600 s; the most a step advances
	quality_step:   i32,              // a tenth of the hydraulic step
	specific_gravity, viscosity, demand_multiplier: f64,
}

Node_Out :: struct {
	solved:    []bool, // false: no path to a reservoir or tank, so left out and zero
	pressure, head: []f64,
	demand:    []f64,  // consumer demand delivered
	wanted:    []f64,  // asked for (PDA: the share delivered is demand / wanted)
	outflow:   []f64,  // EPANET's node demand: everything leaving the node; at a tank, the net inflow
	emitter_flow, leak_flow: []f64,
	quality:   [][]f64, // [chemical][node]
}
Link_Out :: struct {
	flow, velocity, headloss: []f64,
	energy:  []f64,     // a pump's kW
	setting: []f64,     // a pump's speed, a valve's setting; a pipe's roughness
	status:  []Status,
	quality: [][]f64,   // [chemical][link]
}
```

Every column is a slice the `Sim` owns, sized at `sim_make` (a row past
the room moves the columns). A node is its index in `nodes`; a link, in
`links`; a result, the same index in `out`. There is no name anywhere in
a `Sim`: a program that has names keeps its own map, as every game and
every database does; `sim_from_model` hands the file's names back as
`Ids`.

### The procs

```odin
sim_make   :: proc(node_cap, link_cap: int, opts: Sim_Options, allocator := context.allocator) -> Sim
sim_delete :: proc(sim: ^Sim)
sim_copy   :: proc(sim: ^Sim, allocator := context.allocator) -> Sim   // a what-if, a look ahead

node_add    :: proc(sim: ^Sim, kind: Node_Kind) -> int   // a row, zeroed; fill its columns
node_remove :: proc(sim: ^Sim, i: int)                   // the last row takes its place; links follow; links that touched i are emptied
link_add    :: proc(sim: ^Sim, kind: Link_Kind, from, to: int) -> int
link_remove :: proc(sim: ^Sim, k: int)

// Solve at sim.t with the tanks where they are, write out, move the tanks and
// the clock on by dt: the hydraulic step, or less when a tank fills or
// empties, a control fires or the model's times say so. dt == 0 with no
// error is the end of a model's duration (a bare Sim has none).
sim_step  :: proc(sim: ^Sim) -> (dt: i32, warn: Warning, err: Error)
// Solve at sim.t again without moving: after an edit mid-step.
sim_solve :: proc(sim: ^Sim) -> (warn: Warning, err: Error)
```

**Values are read every step.** `sim_step` converts every value column
into the engine's units each time (an O(n) copy, nothing beside a solve),
so a demand, an elevation or a diameter changed in place is simply seen.
The three columns that are state as well — a link's `status` and
`setting`, a tank's `level` — are applied when they differ from what the
step last saw, and otherwise left to the engine: a pump the solver shut
off stays shut until the solver reopens it or the caller writes the
column. The caller never says "I changed a value".

**Structure is read when told.** `node_add`, `link_add`, `node_remove`
and `link_remove` set `sim.rewire`; a caller that changes a `kind`, a
`from` or a `to` by hand sets it too, and so does one that changes a
pump's design point or the `chemicals`. The next step rebuilds the plan:
which rows a source reaches, the engine's own numbering (junctions first,
tanks and reservoirs after, as EPANET's solver needs), the matrix shape,
the solvers opened at the clock with the tanks at their levels. That is a
parse's worth of work for a big network and nothing for a game's.

**What cannot be solved is left out, not refused.** A node no link
touches, or a part of the network no reservoir or tank is joined to, is
not sent to the solver: `out.solved[i]` is false and its results are zero.
With no junction reachable the step solves nothing, moves the clock, and
warns `.Nothing_To_Solve`. EPANET's errors 223, 224 and 233 do not exist
here. (This is the one place the Odin face means something other than
EPANET: Waterworks had to compute it in JavaScript; a program that wants
EPANET's refusal has the toolkit.)

**Chemicals ride the same hydraulics.** After each hydraulic step the
transport runs once per chemical over that step, each with its own
segments, sources, decay and solver state; the network's per-chemical
arrays are swapped in for its turn. One solve, N chemicals. A `Sim`
made from a `Model` holds the model's own quality as chemical 0, with the
model's per-pipe coefficients, orders and tolerance riding inside; the
chemicals a program adds after it get the plain first-order kinetics the
struct describes. (Waterworks solves the hydraulics once per mineral,
because an EPANET project carries one.)

**No patterns, controls or rules in a bare Sim.** The caller is the
controller: it sets the demands for the hour and closes the pipe itself
before the step. A `Sim` made from a `Model` keeps the model's patterns,
controls and rules inside and plays them each step, which is how
`simulate` reproduces EPANET's run. (rung 1 for the game: Waterworks has
its own clock and its own day curve.)

**A step allocates what the engine allocates.** The columns are sized
at `sim_make`; the rebuild is where the work is. Inside the step the
quality segments grow as EPANET's do (from the project's arena) and the
rules take a scratch list; nothing else. A step is a pure function of the
struct: the same columns give the same numbers, bit for bit, which is
what a replay or a lockstep multiplayer wants; one `Sim` per thread,
nothing in the package is global but read-only tables.

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
error_text :: proc(err: Error) -> string   // EPANET's text (errors.odin)
```

EPANET's numbers stay the values, so a code read from a report, a C
program or the toolkit means the same thing. `err != nil` is the test.
`sim.fault` names the node or link an error is about (a pump with no
curve and no power, a valve on a reservoir, a duplicate or undefined
name), so a game can point at it.

## Model

The network as written: what `load` reads, `write_inp` writes, and a
program edits by hand. One fat struct for every component: a junction, a
reservoir, a tank, a pipe, a pump and a valve are one `Entity` with a
`kind`; unused fields stay zero. It is the `.inp` file's row and
bywater-mill's `Entity`, so a program's own table maps one to one.
Patterns and curves are series and controls and rules are statements:
those keep their own small shapes. Every number is in the file's own
units; a zero where the reader would have supplied a default gets that
default (a pipe of no length is 330 ft or 100 m, a pump of no speed runs
at 1), and a reaction coefficient of `MISSING` is the global one, as the
reader leaves it.

```odin
Model :: struct {
	title:    [3]string,
	entities: []Entity,
	patterns: []Model_Pattern,
	curves:   []Model_Curve,
	controls: []Control,
	rules:    []Rule,
	options:  Options,     // DEFAULT_OPTIONS to start from
	times:    Model_Times, // DEFAULT_TIMES
	report:   Report_Spec, // default_report()
	aux:      []string,    // the [LABELS] and [BACKDROP] sections, line by line, written back as they were
	problems: []Problem,   // what load could not read; empty when the file was clean
	arena:    ^virtual.Arena, // what load allocated from; nil for a Model a program built
}

Kind :: enum u8 { JUNCTION, RESERVOIR, TANK, PIPE, PUMP, VALVE }

Entity :: struct {
	id:       string,
	kind:     Kind,
	x, y:     f64,       // MISSING when the file had none
	vertices: [][2]f64,  // a link's bends
	comment, tag: string,
	report:   bool,      // named in the [REPORT] NODES or LINKS list
	// a node
	elevation:    f64,   // a reservoir's head
	demands:      []Demand,
	emitter:      f64,
	init_quality: f64,
	has_source:   bool,
	source:       Source_Spec,
	head_pattern: string,   // a reservoir's
	init_level, min_level, max_level, min_volume, diameter: f64, // a tank's; diameter a pipe's and a valve's too
	volume_curve: string,
	overflow:     bool,
	mixing:       Mix_Model,
	mixing_fraction: f64,   // 0 = 1
	bulk_coeff, wall_coeff: f64, // MISSING = the global one
	// a link
	from, to:     string,
	length, roughness, minor_loss: f64,
	leak_area, leak_expansion: f64,
	check_valve:  bool,
	status:       Status,   // OPEN or CLOSED, a valve's ACTIVE; unset = the kind's default
	power:        f64,      // a constant-power pump; 0 = none
	head_curve:   string,
	speed:        f64,      // 0 = 1
	speed_pattern, energy_pattern, efficiency_curve: string,
	energy_price: f64,
	valve:        Link_Type, // PRV … PCV
	setting:      f64,
	loss_curve:   string,   // a GPV's head loss curve, a PCV's position curve
}
Demand        :: struct { base: f64, pattern, name: string }
Source_Spec   :: struct { kind: Source_Type, strength: f64, pattern: string }
Model_Pattern :: struct { id: string, factors: []f64, comment: string }
Model_Curve   :: struct { id: string, kind: Curve_Type, x, y: []f64, comment: string }
Control       :: struct { link: string, status: Status, setting: f64, kind: Control_Type, node: string, level: f64, time: i64, disabled: bool }
Rule          :: struct { text: string }  // EPANET's grammar, one clause per line, from its RULE line: one grammar, not two (rung 1)
Options       :: struct { … EPANET's [OPTIONS], the global [REACTIONS] and [ENERGY] lines, by name, typed … }
Model_Times   :: struct { duration, hydraulic_step, quality_step, pattern_step, pattern_start, report_step, report_start, rule_step, start_clocktime: i64, statistic: Time_Stat }
Report_Spec   :: struct { page_size: int, summary, messages: bool, status: int, energy: bool, nodes, links: int, fields: [Field]Report_Field, file: string }

load         :: proc(path: string, allocator := context.allocator) -> (model: Model, err: Error)
parse        :: proc(text: string, allocator := context.allocator) -> (model: Model, err: Error)
write_inp    :: proc(model: ^Model, path: string) -> Error
delete_model :: proc(model: ^Model)
```

A file with bad lines still comes back, `problems` filled (the line, the
code, the text) and `err == .Input_Errors` (EPANET's 200): a program can
show them.

### Model to Sim, and the engine from a Model

```odin
sim_from_model :: proc(model: ^Model, allocator := context.allocator) -> (sim: Sim, ids: Ids, err: Error)
Ids :: struct { node, link: []string, node_index, link_index: map[string]int }

project_from_model :: proc(model: ^Model) -> Built   // the engine's project, as the reader would build it
```

The one conversion: entities to columns (the nodes in the model's order,
the links in theirs), the patterns, controls, rules and quality options
kept inside the `Sim` to play each step, the names handed back beside it
for whoever wants them. Under it, `project_from_model` builds the
engine's project from a `Model` the way the reader builds one from a
file — the same tables, the same defaults, the same order — and then the
reader's own tail puts it in internal units; `cmd/dumpnet --model` proves
on every fixture that the file read as a `Model` and built back is the
reader's project byte for byte. A `Sim` builds its engine from an
*effective* `Model` on every rewire: its rows as entities (the model's
own entity, where a row came from one, with the columns written over it),
the model's extras, the reachable part only.

## Results

```odin
simulate :: proc(model: ^Model, allocator := context.allocator) -> (r: Results, warn: Warning, err: Error)
delete_results :: proc(r: ^Results, allocator := context.allocator)

Results :: struct {
	periods:  []i32,        // reporting times (report start, every report step)
	units:    Units,        // the texts: "gpm", "psi", "ft" …
	node:     Node_Table,   // [period][node]
	link:     Link_Table,   // [period][link]
	warnings: []Warning,    // one per period
	energy:   []Pump_Usage, // one per pump: EPANET's energy statistics
	mass_balance: []Mass_Balance, // one per chemical
	ids:      Ids,          // the names, by row
}
Node_Table :: struct { demand, head, pressure, quality: [][]f64 }
Link_Table :: struct { flow, velocity, headloss, quality, setting: [][]f64, status: [][]Status }
```

`simulate` is `sim_from_model`, a loop of `sim_step` with `sim.out` copied
at the reporting times (`sim.at_report`), `sim_delete`; nothing a program
cannot do itself. Each `[][]f64` is one flat allocation with a slice
header per period, so a column is contiguous and a program that wants the
block has it. The four node and six link variables are the ones EPANET's
output file holds, less the reaction rate and friction factor.

## WebAssembly

Odin builds the package for `wasm32` (`odin build wasm
-target:freestanding_wasm32 -no-entry-point`, 280 KB). The game's side is
small: `wasm/epanet.odin` exports a handful of procs that take a `^Sim`
and plain numbers, and one that hands back the addresses of the columns,
so JavaScript makes a `Float64Array` view over each column in the wasm
memory, writes a demand, calls `step`, reads a pressure. No text, no file
system, no name, no `malloc` for an out-parameter, no copy: the columns
the game draws from are the engine's. `wasm/epanet.js` wraps it:

```js
import { instantiate, Node, Link, Units, Headloss } from "./epanet.js";
const engine = await instantiate(await fetch("epanet.wasm").then(r => r.arrayBuffer()));
const sim = engine.sim(256, 256, { flowUnits: Units.LPS, headloss: Headloss.HW });
const spring = sim.nodeAdd(Node.RESERVOIR); sim.v.head[spring] = 204;
const house  = sim.nodeAdd(Node.JUNCTION);  sim.v.elevation[house] = 140; sim.v.demand[house] = 0.3;
const main   = sim.linkAdd(Link.PIPE, spring, house);
sim.v.length[main] = 312; sim.v.linkDiameter[main] = 100; sim.v.roughness[main] = 140;
sim.step();                 // each game quarter hour
sim.v.pressure[house];      // m
```

`sim.v` is the set of typed-array views over the engine's columns,
rebuilt after every call that can move memory. Chemicals:
`sim.setChemicals(n)`, `sim.chemical(i, {kind, decay, wall})`,
`sim.source(i, node, kind, strength)`, `sim.v.qualityInit0[node]`, then
`sim.v.quality0[node]` after a step. The solve runs where the game puts
it, a worker or the main thread; a step on a game's network is well under
a frame.

What the wasm build is not: byte-identical to the native one. The engine
takes `pow` from the host (`env.pow`, `Math.pow` in `epanet.js`), whose
last bits are not glibc's, so `wasm/check.mjs` is held to `WASM_TOL`
(1e-6) against `check --reference`, not to the byte; and for the same
reason two hosts may differ in the last bits. A lockstep game that needs
the same numbers on every machine wants `pow` written in Odin — the next
rung, when a use needs it. The engine's own files and report never
reach the wasm build: `files.odin`, `report.odin`, `output.odin`,
`inpfile.odin`, `dump.odin` and `export.odin` are native-only, and what
the step would have said to a report goes to stubs (`report_wasm.odin`).

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
sim.chemicals = {{decay = -8, sources = {{node = spring, kind = .CONCEN, strength = 2}}}}  // read on the next rewire

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
model := epanet.Model{entities = entities[:], options = epanet.DEFAULT_OPTIONS, times = epanet.DEFAULT_TIMES, report = epanet.default_report()}
model.times.duration = 24 * 3600
r, warn, err := epanet.simulate(&model)
pressure_of_entity := r.node.pressure[k][r.ids.node_index[entity_id]]
```

Fire flow, one demand at a time on one `Sim`:

```odin
sim, ids, err := epanet.sim_from_model(&model)
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
for {
	at := sim.t
	dt, warn, err := epanet.sim_step(&sim)
	if err != nil || dt == 0 do break
	if sim.at_report do film_append(&film, at, sim.out.pressure, sim.link_out.flow)
}
```

A thousand what-ifs, one per thread, each from the same start:

```odin
base, _, _ := epanet.sim_from_model(&model)
for variant, i in variants {   // each on its own thread
	sim := epanet.sim_copy(&base)
	sim.links.diameter[variant.link] = variant.diameter
	epanet.sim_solve(&sim)
	score[i] = sim.out.pressure[watched]
	epanet.sim_delete(&sim)
}
```

(The surface is what `epanet/model.odin`, `sim.odin` and `simulate.odin`
export; `cmd/check` is these examples, run.)

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
- **No Project, no files, no callbacks, no names in a `Sim`'s face.**
  The numbers come back as data; EPANET's paper, when anyone wants it, is
  the toolkit's. (Inside, the engine's `Project` is kept whole: see *The
  shape*.)
- **A copy rebuilds.** `sim_copy` takes the columns, the clock and each
  chemical's node qualities and rebuilds the engine on its first step:
  the tanks at their levels, the flows started afresh, so a copy goes on
  within the solver's accuracy (a relative flow change of 1e-3), not to
  the bit. Cloning the solver's state, the segments included, is the next
  rung, when a use needs it.
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

Each step was checked the way the port has been: the same bytes as EPANET,
and, for what EPANET cannot do, two roads to one answer.

1. **`sim.odin`** — done. `Sim`, its columns, `sim_make`/`sim_delete`/
   `sim_copy`, the row procs, the plan (reach, the engine's numbering,
   the matrix shape) over `open.odin`, `sim_step` and `sim_solve` over
   `init_hyd`, `run_hyd`, `next_hyd` and the quality transport, N
   chemicals. `Error`, `Warning`; `errors.odin` gives `error_text`.
2. **`model.odin`, `load`, `sim_from_model`** — done. The reader stops
   before converting (`read_text`), `model_from_project` reads the Model
   out of that, `project_from_model` builds the project back and runs the
   reader's tail. `cmd/dumpnet --model` proves the pair byte for byte on
   every fixture.
3. **`simulate`** — done. `cmd/run` prints what `harness/run.c` prints
   and matches it on every fixture: the `Sim`'s step loop reproduces
   EPANET's run, events, patterns, controls and rules included.
4. **The bare road** — done. `cmd/check`: a network laid with
   `node_add`/`link_add` and stepped gives the same bytes as the same
   network as a `Model` through `simulate`; two chemicals on one `Sim`
   give the same bytes as two single-chemical runs; a loose junction is
   left out; a copy goes on; an edit is seen; a pump with no curve is an
   error naming its row.
5. **`write_inp`** — done, checked by `cmd/inp` against the toolkit's
   `EN_saveinpfile` of the same file, byte for byte on every fixture, and
   by a round trip through a file that runs the same.
6. **wasm** — done. The engine's step path has no C library, no files
   and no virtual memory (`cmath*.odin`, `numbers*.odin`, `arena*.odin`
   pick per target; `text.odin` holds what every build says; the file
   world is native-only), so `odin build wasm -target:freestanding_wasm32`
   gives `epanet.wasm`, with `wasm/epanet.js` over it. `wasm/check.mjs`
   lays `cmd/check`'s network through it in Node and matches `check
   --reference` within `WASM_TOL`. Waterworks' own `solver.js` and
   `net.js#inp` are the game's to replace, with its `check.mjs` as the
   test, in its own repository. Next rung: `pow` in Odin, for the same
   bits on every host.
