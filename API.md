# The Odin API

A second face for the engine, beside the toolkit (`api/`, EPANET's `EN_*`
for C programs). This one is for Odin programs: tables in, tables out, one
proc per step of the job, errors as values. It is what the `epanet` package
exports; the `EN_*` library keeps working over the same engine.

Rung numbers are the [ponytail](https://github.com/DietrichGebert/ponytail)
ladder (bywater-mill's `PONYTAIL.md`): where a choice stopped.

## What it is for

bywater-mill, the first user, does three things with EPANET, all through
`EN_*` calls today:

- builds a project from its own tables on every run (`water/convert.go`):
  add a node, set its data, add a link, set its data, one call each;
- solves and reads results back one value per call (`RunSimulation`,
  `timeline.go`: a `GetNodeValue` per node per property per frame);
- re-solves in a loop with one number changed (fire flow: a demand).

The toolkit's shape, a handle plus an index plus a property code plus an
out-parameter, is C's. In Odin the same work is two tables and a loop.

## The shape

```
   your tables ──► Model ──simulate──► Results
                     │  ▲
                 load│  │write_inp              sim_begin(model) ─► Sim ─► sim_step ─► read_frame
                     ▼  │
                  .inp file
```

| | What it is | Units |
|---|---|---|
| **`Model`** | the network as written: one `Entity` per component, ids as strings, references by id. The `.inp` file as data. | the modeller's |
| **`Results`** | what came out: every reporting period, every node and link. | the modeller's |
| **`Sim`** | a run in progress, for a program that steps or changes a number between solves. The engine's arrays, readable. | internal (ft, cfs, s) |

A program keeps a `Model`, edits it, simulates, reads. There is no handle
to a half-built network and no `add_node`: an edit is an edit to a table,
and the next `simulate` sees it. (rung 1: EPANET's `EN_addnode` and
`EN_deletenode` are a few hundred lines of index fix-ups for a thing a
rebuild does in one call, and bywater-mill rebuilds per run already.)

There is no Project. EPANET's `Project` is the toolkit's handle: the
network, the run state, the open files, the report's line count and the
parser's flags in one struct, because a C API needs one pointer. The Odin
face carries none of that. Inside the package today's `Project` splits the
same way: the engine's part becomes `Sim`; the files, the report state and
the `EN_*` semantics move to `api/`, whose handle is a `Sim` plus those.
The report writers take a `Sim` and a `^Report` that is nil when no one
asked for a report.

## Model

```odin
Model :: struct {
	title:    [3]string,
	entities: []Entity,   // every node and link, in the order written
	patterns: []Pattern,  // series: a cycle of multipliers
	curves:   []Curve,    // series: x against y
	controls: []Control,  // statements
	rules:    []Rule,
	options:  Options,
	times:    Times,
	problems: []Problem,  // what load could not read; empty when the file was clean
}
```

**One fat struct for every component.** A junction, a reservoir, a tank, a
pipe, a pump and a valve are one `Entity` with a `kind`; unused fields
stay zero. It is the `.inp` file's row and bywater-mill's `Entity`, so a
program's own table maps one to one. Patterns and curves are series and
controls and rules are statements: those keep their own small shapes.

```odin
Kind :: enum { JUNCTION, RESERVOIR, TANK, PIPE, PUMP, VALVE }
Valve_Type :: enum { PRV, PSV, PBV, FCV, TCV, GPV, PCV }

Entity :: struct {
	id:       string,
	kind:     Kind,
	// where it is (what the map wants; the engine ignores it)
	x, y:     f64,       // MISSING when the file had none
	vertices: [][2]f64,  // a link's bends
	// a node
	elevation:    f64,
	demands:      []Demand, // a junction's; the first is the one [JUNCTIONS] gives
	emitter:      f64,
	head_pattern: string,   // a reservoir's
	init_level, min_level, max_level, min_volume: f64, // a tank's
	volume_curve: string,
	overflow:     bool,
	mixing:       Mix_Model,
	mixing_fraction: f64,   // 1 when not given
	init_quality: f64,
	source:       Source,   // kind == .NONE when there is none
	// a link
	from, to:     string,
	length, roughness, minor_loss: f64,
	diameter:     f64,      // a pipe's, a valve's; a tank's too
	bulk_coeff, wall_coeff: f64, // a pipe's; bulk_coeff a tank's too. MISSING = the global one
	leak_area, leak_expansion: f64,
	check_valve:  bool,     // a pipe with a CV
	power:        f64,      // a constant-power pump; 0 = none
	head_curve:   string,
	speed:        f64,      // 1 when not given
	speed_pattern, energy_pattern, efficiency_curve: string,
	energy_price: f64,
	valve:        Valve_Type,
	setting:      f64,
	loss_curve:   string,   // a GPV's head loss curve, a PCV's position curve
	status:       Status,   // OPEN, CLOSED, or ACTIVE for a valve with a setting
	comment, tag: string,
}

Demand :: struct { base: f64, pattern, name: string }
Source :: struct { kind: Source_Kind, strength: f64, pattern: string }
Source_Kind :: enum { NONE, CONCEN, MASS, SETPOINT, FLOWPACED }

Pattern :: struct { id: string, factors: []f64, comment: string }
Curve   :: struct { id: string, kind: Curve_Type, x, y: []f64, comment: string }

Control :: struct {
	link:    string,
	status:  Status,       // OPEN / CLOSED, or ACTIVE when `setting` applies
	setting: f64,
	kind:    Control_Type, // LOWLEVEL, HILEVEL, TIMER, TIMEOFDAY
	node:    string,       // the level's node
	level:   f64,          // or
	time:    i64,          // seconds
	enabled: bool,
}

// A rule stays text: EPANET's grammar, one clause per line. The parser
// reads it; a struct of premises and actions would be a second grammar
// to keep in step. (rung 1)
Rule :: struct { text: string }
```

Options are one struct with typed fields, EPANET's names, EPANET's
defaults as a constant to start from. `MISSING` (`-1e10`) means "not
given" where EPANET means that.

```odin
Options :: struct {
	flow_units:       Flow_Units,       // .GPM
	pressure_units:   Pressure_Units,   // .DEFAULTUNIT: psi for US, m for SI
	headloss:         Headloss_Formula, // .HW
	trials:           int,              // 200
	accuracy:         f64,              // 0.001
	head_error, flow_change, damp_limit: f64,
	check_freq, max_check: int,         // 2, 10
	unbalanced:       Unbalanced,       // {.STOP} or {.CONTINUE, extra_trials}
	demand_model:     Demand_Model,     // .DDA
	min_pressure, required_pressure, pressure_exponent: f64,
	demand_multiplier: f64,             // 1
	default_pattern:  string,           // "1"
	emitter_exponent: f64,              // 2 (EPANET keeps 1/x)
	emitter_backflow: bool,             // true
	viscosity, diffusivity: f64,        // 1 = water, chlorine
	specific_gravity: f64,              // 1
	quality:          Quality_Spec,     // kind, chemical name and units, trace node, tolerance
	reactions:        Reactions_Spec,   // orders, global bulk and wall, limiting potential, roughness correlation
	energy:           Energy_Spec,      // global efficiency, price, price pattern, demand charge
	report:           Report_Spec,      // [REPORT], kept for write_inp; the Odin face writes no report
}
DEFAULT_OPTIONS :: Options{ flow_units = .GPM, headloss = .HW, trials = 200, accuracy = 0.001, … }

Times :: struct {
	duration, hydraulic_step, quality_step, pattern_step, pattern_start,
	report_step, report_start, rule_step, start_clocktime: i64, // seconds
	statistic: Time_Stat,
}
DEFAULT_TIMES :: Times{ hydraulic_step = 3600, pattern_step = 3600, report_step = 3600 }
```

### Procs on a Model

```odin
// The file as a Model. A file with bad lines still comes back, with
// problems filled and err == .Input_Errors (EPANET's 200); the engine
// refuses it, a program can show it.
load         :: proc(path: string, allocator := context.allocator) -> (model: Model, err: Error)
parse        :: proc(text: string, allocator := context.allocator) -> (model: Model, err: Error)
write_inp    :: proc(model: Model, path: string) -> Error   // the file back, every section
delete_model :: proc(model: Model)                           // what load allocated
Problem :: struct { line: int, code: Error, text: string }
```

`load` is the parser that exists (`parse.odin`), its second half turned
from "token to array slot" into "token to Entity field".

## Results

```odin
simulate :: proc(model: Model, opts := Sim_Options{}, allocator := context.allocator) -> (r: Results, warn: Warning, err: Error)
delete_results :: proc(r: Results)

Sim_Options :: struct {
	skip_quality: bool, // hydraulics only, whatever model.options.quality says
}

Results :: struct {
	periods:  []i64,        // reporting times, seconds (report start, every report step)
	units:    Units,        // the texts: "gpm", "psi", "ft" …
	node:     Node_Table,   // one slice per period, each over every node
	link:     Link_Table,
	warnings: []Warning,    // one per period
	energy:   []Pump_Usage, // one per pump: the energy table's row
	mass_balance: Mass_Balance,
}
Node_Table :: struct { demand, head, pressure, quality: [][]f64 }
Link_Table :: struct { flow, velocity, headloss, quality, status, setting, reaction, friction: [][]f64 }
```

`r.node.pressure[k][i]` is node i's pressure at `r.periods[k]`, node i
being the i-th node of `model.entities` counting nodes only; link k the
k-th link the same way. Each `[][]f64` is one flat allocation with a slice
header per period, so a column is contiguous and a program that wants the
block has it (`raw_data(r.node.pressure[0])`, `len(periods) × nodes`).
The four node and eight link variables are the ones EPANET's output file
holds; `simulate` is the run EPANET makes, with the table kept in memory
instead of written to a file.

## Sim

For the timeline, which wants every hydraulic event, and fire flow, which
changes a number between solves. A run in progress is a value the caller
owns; `simulate` is built from these and does nothing a program cannot.

```odin
Sim :: struct {
	net:   Network,     // the model as solved: one array per field, 1-based, internal units
	hyd:   Hydraulics,  // the hydraulic state: head, flow, status, setting, the solver's settings
	q:     Quality,     // the quality state
	times: Times_State, // the clock
	m:     Smatrix,     // the solver's matrix
	ids:   Ids,         // node and link ids, and the maps back to indexes
	ucf:   [Field]f64,  // internal units to the model's
	…
}

sim_begin :: proc(model: Model, opts := Sim_Options{}, allocator := context.allocator) -> (sim: Sim, err: Error)
sim_step  :: proc(sim: ^Sim) -> (t: i64, warn: Warning, done: bool, err: Error)
sim_end   :: proc(sim: ^Sim)

node_index :: proc(sim: ^Sim, id: string) -> (index: int, found: bool)
link_index :: proc(sim: ^Sim, id: string) -> (index: int, found: bool)
```

`sim_begin` converts and indexes the model (the parser's tail: units,
tanks, the pump curves, the validation) and opens the solvers.
`sim_step` solves the period at the current clock, advances to the next
hydraulic event (a control, a tank filling, a pattern step) and reports
the time it solved for; `done` once the clock has passed the duration.
`Network`, `Hydraulics` and `Quality` are the structs the engine runs on;
they are open to read (`sim.hyd.head[i]`, feet). Two promises about
indexes, so a program keeps its own maps: node i is the i-th junction of
`model.entities`, then the tanks and reservoirs in their order (EPANET's
layout); link k is the k-th link. 1-based, as everywhere in the package.

Between steps the state in the model's units, into slices the caller
owns (sized once; no allocation per step):

```odin
Frame :: struct {
	time: i64,
	node: Node_Row,  // demand, head, pressure, quality, tank_level: []f64
	link: Link_Row,  // flow, velocity, headloss, quality, status, setting: []f64
}
frame_make   :: proc(sim: ^Sim, allocator := context.allocator) -> Frame
read_frame   :: proc(sim: ^Sim, f: ^Frame)
frame_delete :: proc(f: Frame)
```

### Knobs

The loop cases change a number, not the structure: a demand for fire
flow, a pipe closed for a what-if. These write the engine's arrays in
place, taking the model's units, with no new `sim_begin`. Anything else is
an edit to the `Model`.

```odin
set_base_demand       :: proc(sim: ^Sim, node: int, demand: f64, category := 1)
set_demand_multiplier :: proc(sim: ^Sim, m: f64)
set_link_status       :: proc(sim: ^Sim, link: int, status: Status)
set_link_setting      :: proc(sim: ^Sim, link: int, setting: f64)
set_tank_level        :: proc(sim: ^Sim, node: int, level: f64)
set_pattern           :: proc(sim: ^Sim, pattern: int, factors: []f64)
```

(rung 2: `set_link_status`, `set_link_setting` and the pattern tables are
in `hydraul.odin`; these add the unit conversion.)

## Errors and warnings

```odin
Error :: enum i32 {
	None = 0,
	Out_Of_Memory = 101, No_Network = 102, Hydraulics_Not_Open = 103,
	No_Hydraulics = 104, Quality_Not_Open = 105, No_Results = 106,
	Unsolvable = 110, Input_Errors = 200, Syntax = 201, Bad_Number = 202,
	… every EPANET code, by its EPANET name …
}
Warning :: enum i32 { None, Unbalanced = 1, Unstable, Disconnected, Pumps, Valves, Negative_Pressure }

error_message :: proc(err: Error) -> string   // EPANET's text (errors.odin, already there)
```

EPANET's numbers stay the values, so a code read from a report, a C
program or the toolkit means the same thing. `err != nil` is the test.

## What the toolkit maps to

| `EN_*` | here |
|---|---|
| `EN_createproject`, `EN_open`, `EN_close`, `EN_deleteproject` | `load`, `delete_model` |
| `EN_init` + `EN_add*` + `EN_set*data` | fill a `Model` |
| `EN_set*value`, `EN_setoption`, `EN_settimeparam` | edit the `Model`; or a knob on a `Sim` |
| `EN_solveH`, `EN_solveQ` | `simulate` |
| `EN_openH` … `EN_nextQ` | `sim_begin`, `sim_step`, `sim_end` |
| `EN_getnodevalue`, `EN_getlinkvalue` (results) | `Results`, `Frame` |
| `EN_getnodevalue`, `EN_getlinkvalue` (data) | the `Model` the program holds |
| `EN_getcount`, `EN_get*index`, `EN_get*id` | `len(model.entities)`, `node_index`, `entity.id` |
| `EN_saveinpfile` | `write_inp` |
| `EN_geterror` | `error_message` |
| `EN_report`, `EN_savehydfile`, `EN_setreportcallback` | nothing: the numbers come back as data (rung 1) |

## Examples

Load, run, read:

```odin
import "epanet"

model, err := epanet.load("net1.inp")
if err != nil { fmt.eprintln(epanet.error_message(err)); return }
defer epanet.delete_model(model)

r, warn, run_err := epanet.simulate(model)
if run_err != nil { return }
defer epanet.delete_results(r)
for t, k in r.periods {
	fmt.printfln("%2d:00  %s  %6.2f %s", t / 3600, model.entities[0].id, r.node.pressure[k][0], r.units.pressure)
}
```

A model of your own (bywater-mill's `buildProject`, one append per entity):

```odin
entities: [dynamic]epanet.Entity
for ent in system.entities {
	switch ent.kind {
	case .JUNCTION:
		append(&entities, epanet.Entity{id = ent.name, kind = .JUNCTION, elevation = ent.elevation,
			demands = {{base = ent.base_demand, pattern = ent.pattern}}})
	case .PIPE:
		append(&entities, epanet.Entity{id = ent.name, kind = .PIPE, from = from_name, to = to_name,
			length = ent.length, diameter = ent.diameter, roughness = ent.roughness, status = .OPEN})
	…
	}
}
model := epanet.Model{entities = entities[:], options = epanet.DEFAULT_OPTIONS, times = epanet.DEFAULT_TIMES}
model.options.flow_units = .GPM
model.times.duration = 24 * 3600
r, warn, err := epanet.simulate(model)
```

Fire flow: one demand at a time, one `Sim`:

```odin
sim, err := epanet.sim_begin(model, {skip_quality = true})
defer epanet.sim_end(&sim)
frame := epanet.frame_make(&sim)
defer epanet.frame_delete(frame)
for node in hydrants {
	epanet.set_base_demand(&sim, node, 1500)           // gpm, the model's units
	_, warn, _, step_err := epanet.sim_step(&sim)
	epanet.read_frame(&sim, &frame)
	available[node] = frame.node.pressure[node - 1]
	epanet.set_base_demand(&sim, node, 0)
}
```

The timeline, every event, reporting frames kept:

```odin
sim, _ := epanet.sim_begin(model)
frame := epanet.frame_make(&sim)
for {
	t, warn, done, err := epanet.sim_step(&sim)
	if err != nil do break
	if t % report_step == 0 {
		epanet.read_frame(&sim, &frame)
		film_append(&film, t, frame.node.pressure, frame.link.flow)
	}
	if done do break
}
epanet.sim_end(&sim)
```

(The surface and these examples type-check as a stub package.)

## Decisions

- **A Model and a Sim, no Project.** The data a program holds is one
  table of entities in its own units; the run is a value that exists while
  it runs. The toolkit's handle, with its files and flags, stays in `api/`
  where C programs need it.
- **One fat `Entity`.** A junction and a pump are rows of one table with
  a kind; `diameter` serves a tank and a pipe, `bulk_coeff` a tank and a
  pipe. No union, no case per kind in the caller's code.
- **Edits are table edits.** No incremental editor, no index fix-ups, no
  half-built states. The cost is a conversion per `simulate`, a parse's
  worth of work. The knobs cover the loops.
- **Results as `[][]f64` over one block.** Indexable without arithmetic,
  contiguous for anyone who wants the block, no per-period allocation.
- **Rules stay text.** One grammar.
- **EPANET's error numbers as the enum's values.** One meaning everywhere.
- **No files, no callbacks.** The numbers come back as data. If anyone
  wants EPANET's paper, a report written from a `Model` and a `Results` is
  one proc later, from data, not from a run in flight.
- **One `Sim` per `Model` at a time is not required.** A `Sim` copies
  what it needs from the model; two sims over one model are two runs.

## Not in it

- An incremental editor (`EN_add*`/`EN_delete*` with index fix-ups): the
  toolkit's, when the editing phase ports it. (rung 1)
- Report and progress callbacks, the hydraulics file, the output file.
  (rung 1)
- Threads inside a run. A `Sim` per thread is the model; nothing in the
  package is global but read-only tables.

## Where it goes, in order

Each step is checked the way the port has been: the same bytes as EPANET.

1. **`model.odin`** — `Model`, `Entity` and the rest of the types,
   `DEFAULT_OPTIONS`, `DEFAULT_TIMES`, `Error`, `Warning`. The engine's
   struct becomes `Sim`; the report and file state leave it for `api/`.
   `errors.odin` gives `error_message`.
2. **`load` and `sim_begin`** — the parser's second half writes a Model;
   `sim_begin` is the parser's tail over it. `cmd/dumpnet` dumps a `Sim`
   and keeps proving the pair against EPANET's reader, byte for byte, on
   every fixture.
3. **`simulate`, `sim_step`, `Frame`** — over `open_hyd`, `init_hyd`,
   `run_hyd`, `next_hyd`, `initqual`, `runqual`, `nextqual`, all there. A
   new driver, `cmd/run`, prints what `harness/run.c` prints and must
   match `run-c` on every fixture.
4. **`write_inp`** — the file from a Model, every section (`inpfile.c`).
   Checked by a round trip: `load` → `write_inp` → `load` dumps the same.
5. **The knobs.** Fire flow and the timeline in bywater-mill move over;
   their smoke tests are the check.
