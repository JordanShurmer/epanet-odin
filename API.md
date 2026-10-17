# The Odin API

A second face for the engine, beside the toolkit (`api/`, EPANET's `EN_*`
for C programs). This one is for Odin programs: tables in, tables out, one
proc per step of the job, errors as values. It is what the `epanet` package
exports; the `EN_*` library keeps working over the same `Project`.

Rung numbers in the margins are the [ponytail](https://github.com/DietrichGebert/ponytail)
ladder (bywater-mill's `PONYTAIL.md`): where each choice stopped.

## What it is for

bywater-mill, the first user, does three things with EPANET, all through
`EN_*` calls today:

- builds a project from its own tables on every run (`water/convert.go`):
  add a node, set its data, add a link, set its data, one call each;
- solves and reads results back one value per call (`RunSimulation`,
  `timeline.go`: a `GetNodeValue` per node per property per frame);
- re-solves in a loop with one number changed (fire flow: a demand).

The toolkit's shape, a handle plus an index plus a property code plus an
out-parameter, is C's. In Odin the same work is three tables and three
procs.

## The shape

Three structs, each plain data. Nothing hides behind a method.

| | What it is | Units | Who writes it |
|---|---|---|---|
| **`Spec`** | the network as written: ids, kinds, values, references by id. The `.inp` file as a struct. | the user's | the program, or `load` |
| **`Project`** | the network as solved: indexes, one array per field, the run state. Already in the package. | internal (ft, cfs, s) | `build` |
| **`Results`** | what came out: every reporting period, every node and link. | the user's | `simulate` |

```
   your tables ──► Spec ──build──► Project ──simulate──► Results
                    ▲                 │   ▲
                load │        run_step│   │read_frame
                    │                 ▼   │
                 .inp file         (the engine's arrays)
```

A program keeps a `Spec` as its model, edits it, builds, runs, reads.
There is no `add_node` on a `Project`: an edit is an edit to the `Spec`
and a rebuild. (rung 1: EPANET's `EN_addnode`/`EN_deletenode` are a few
hundred lines of index fix-ups; a rebuild is one call and bywater-mill
rebuilds from scratch per run already.)

## Spec

```odin
Spec :: struct {
	title:    [3]string,
	nodes:    []Node,
	links:    []Link,
	patterns: []Pattern,
	curves:   []Curve,
	controls: []Control,
	rules:    []Rule,
	options:  Options,
	times:    Times_Spec,
	report:   Report_Spec,
	problems: []Problem, // what load could not read; empty when the file was clean
}
```

**One fat struct per kind of thing**, as the `.inp` has one line per thing
and bywater-mill has one `Entity`. Unused fields stay zero. (CLAUDE.md:
fat structs over polymorphism.)

```odin
Node_Kind :: enum { JUNCTION, RESERVOIR, TANK }

Node :: struct {
	id:        string,
	kind:      Node_Kind,
	elevation: f64,
	x, y:      f64, // MISSING when the file had none
	// junction
	demands:   []Demand, // the first is the one [JUNCTIONS] gives
	emitter:   f64,
	// reservoir
	head_pattern: string,
	// tank
	init_level, min_level, max_level, diameter, min_volume: f64,
	volume_curve: string,
	overflow:     bool,
	mixing:       Mix_Model,
	mixing_fraction: f64, // 1 when not given
	bulk_coeff:   f64,    // MISSING = the global one
	// quality
	init_quality: f64,
	source:       Source, // kind == .NONE when there is none
	comment, tag: string,
}

Demand :: struct { base: f64, pattern, name: string }
Source :: struct { kind: Source_Kind, strength: f64, pattern: string }
Source_Kind :: enum { NONE, CONCEN, MASS, SETPOINT, FLOWPACED }

Link :: struct {
	id:       string,
	kind:     Link_Type, // the engine's enum: CVPIPE, PIPE, PUMP, PRV … PCV
	from, to: string,
	// pipe
	length, diameter, roughness, minor_loss: f64,
	bulk_coeff, wall_coeff: f64, // MISSING = the global one
	leak_area, leak_expansion: f64,
	// pump
	power:        f64,   // constant-power pump, 0 = none
	head_curve:   string,
	speed:        f64,   // 1 when not given
	speed_pattern, energy_pattern, efficiency_curve: string,
	energy_price: f64,
	// valve
	setting:      f64,
	loss_curve:   string, // GPV's head loss curve, PCV's position curve
	// any
	status:   Status, // OPEN, CLOSED, or ACTIVE for a valve with a setting
	vertices: [][2]f64,
	comment, tag: string,
}

Pattern :: struct { id: string, factors: []f64, comment: string }
Curve   :: struct { id: string, kind: Curve_Type, x, y: []f64, comment: string }

Control :: struct {
	link:    string,
	status:  Status,  // OPEN / CLOSED, or ACTIVE when `setting` applies
	setting: f64,
	kind:    Control_Type, // LOWLEVEL, HILEVEL, TIMER, TIMEOFDAY
	node:    string,  // the level's node
	level:   f64,     // or
	time:    i64,     // seconds
	enabled: bool,
}

// A rule stays text: EPANET's grammar, one clause per line. The parser
// already reads it; a struct of premises and actions would be a second
// grammar to keep in step. (rung 1)
Rule :: struct { text: string }
```

Options are one struct with typed fields, EPANET's names, EPANET's
defaults as a constant to start from:

```odin
Options :: struct {
	flow_units:       Flow_Units,       // .GPM
	pressure_units:   Pressure_Units,   // .DEFAULTUNIT: psi for US, m for SI
	headloss:         Headloss_Formula, // .HW
	trials:           int,              // 200
	accuracy:         f64,              // 0.001
	head_error, flow_change, damp_limit: f64,
	check_freq, max_check:  int,        // 2, 10
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
	hydraulics_file:  Hyd_File_Spec,    // {.SCRATCH} / {.SAVE, name} / {.USE, name}
}

DEFAULT_OPTIONS :: Options{ flow_units = .GPM, headloss = .HW, trials = 200, accuracy = 0.001, … }

Times_Spec :: struct {
	duration, hydraulic_step, quality_step, pattern_step, pattern_start,
	report_step, report_start, rule_step, start_clocktime: i64, // seconds
	statistic: Time_Stat,
}
DEFAULT_TIMES :: Times_Spec{ hydraulic_step = 3600, pattern_step = 3600, report_step = 3600 }
```

`Report_Spec` is `[REPORT]`: page size, status, summary, energy, which
nodes and links, each field's precision and limits. It only matters when
a report file is asked for.

### Procs on a Spec

```odin
// The file as a Spec. A file with bad lines still comes back, with
// problems filled and err == .Input_Errors (EPANET's 200); the engine
// refuses it, a program can show it.
load       :: proc(path: string, allocator := context.allocator) -> (spec: Spec, err: Error)
parse      :: proc(text: string, allocator := context.allocator) -> (spec: Spec, err: Error)
write_inp  :: proc(spec: Spec, path: string) -> Error   // the file back, every section
delete_spec :: proc(spec: Spec)                          // what load allocated
Problem :: struct { line: int, code: Error, text: string }
```

`load` is the parser that exists (`parse.odin`), its second half turned
from "token to array slot" into "token to Spec field". The dump comparison
against EPANET's reader keeps proving it: `build(load(f))` must dump the
same as today's `parse_inp(f)`.

## Project

The struct the package already has. `build` makes one; `destroy` frees it
(its arena goes with it).

```odin
build   :: proc(spec: Spec) -> (p: ^Project, err: Error)
destroy :: proc(p: ^Project)
```

`build` is the parser's tail (`finish_tables`, `adjust_data`,
`init_tanks`, `init_units`, `convert_units`) and the validator, over a
Spec instead of tokens. Two promises about indexes, so a program can keep
its own maps instead of asking:

- **node i** is the i-th junction of `spec.nodes` while i ≤ the junction
  count, then the tanks and reservoirs in their order (EPANET's layout);
  **link k** is `spec.links[k-1]`. Both 1-based, as everywhere in the
  package.
- `node_index(p, id)` and `link_index(p, id)` answer `(index, found)`.

A `Project`'s arrays are open to read: `p.net.el[i]`, `p.hyd.head[i]`,
`p.hyd.flow[k]`, internal units. That is the data-oriented door; the
procs below are the ergonomic one.

### Knobs that do not change the structure

The loop cases: fire flow changes one demand and solves again; a what-if
closes a pipe. These write the arrays in place, in the user's units, with
no rebuild. Anything else is a Spec edit.

```odin
set_base_demand  :: proc(p: ^Project, node: int, demand: f64, category := 1)
set_demand_multiplier :: proc(p: ^Project, m: f64)
set_link_status  :: proc(p: ^Project, link: int, status: Status)
set_link_setting :: proc(p: ^Project, link: int, setting: f64)
set_tank_level   :: proc(p: ^Project, node: int, level: f64)
set_pattern      :: proc(p: ^Project, pattern: int, factors: []f64)
set_times        :: proc(p: ^Project, t: Times_Spec)
```

(rung 2: `set_link_status`, `set_link_setting` and the pattern tables are
in `hydraul.odin` already; these add the unit conversion.)

## Running

### All at once

```odin
Run_Options :: struct {
	quality: bool,   // true: water quality as the Spec asks (NONE runs nothing)
	files:   Files,  // empty strings: no report, no output, no hydraulics file
}
Files :: struct { report, output, hydraulics: string }

simulate :: proc(p: ^Project, opts := Run_Options{quality = true},
                 allocator := context.allocator) -> (r: Results, warn: Warning, err: Error)
delete_results :: proc(r: Results)
```

```odin
Results :: struct {
	periods:  []i64,        // reporting times, seconds (report start, every report step)
	units:    Units,        // the texts: "gpm", "psi", "ft" …
	node:     Node_Table,   // one slice per period, each over every node (0-based)
	link:     Link_Table,
	warnings: []Warning,    // one per period
	energy:   []Pump_Usage, // one per pump, the energy table's row
	mass_balance: Mass_Balance,
}
Node_Table :: struct { demand, head, pressure, quality: [][]f64 }
Link_Table :: struct { flow, velocity, headloss, quality, status, setting, reaction, friction: [][]f64 }
```

`r.node.pressure[k][i]` is node i+1's pressure at `r.periods[k]`. Each
`[][]f64` is one flat allocation with a slice header per period, so a
column is contiguous and a program that wants the raw block has it
(`raw_data(r.node.pressure[0])`, `len(periods) × nnodes`). The eight link
and four node variables are the output file's; `simulate` is the run EPANET
makes, with the table kept in memory instead of (or as well as) written
to the file.

### Step by step

For the timeline, which wants every hydraulic event, and fire flow, which
changes a number between solves.

```odin
Run :: struct { p: ^Project, … }   // an open run; one per Project at a time

run_begin :: proc(p: ^Project, opts := Run_Options{quality = true}) -> (r: Run, err: Error)
run_step  :: proc(r: ^Run) -> (t: i64, warn: Warning, done: bool, err: Error)
run_end   :: proc(r: ^Run)
```

`run_step` solves the period at the current clock, advances to the next
hydraulic event (a control, a tank filling, a pattern step) and reports the
time it solved for; `done` once the clock has passed the duration. Between
steps the engine's state is readable:

```odin
// Frame is what the engine knows after a solve, in the user's units,
// into slices the caller owns (sized by frame_make; no allocation per step).
Frame :: struct {
	time: i64,
	node: Node_Row,  // demand, head, pressure, quality, tank_level: []f64
	link: Link_Row,  // flow, velocity, headloss, quality, status, setting: []f64
}
frame_make  :: proc(p: ^Project, allocator := context.allocator) -> Frame
read_frame  :: proc(r: ^Run, f: ^Frame)
frame_delete :: proc(f: Frame)
```

`simulate` is `run_begin`, a loop of `run_step` + `read_frame` at the
reporting times, `run_end`; nothing in it that a program cannot do itself.

### Errors and warnings

```odin
Error :: enum i32 {
	None = 0,
	Out_Of_Memory = 101, No_Network = 102, Hydraulics_Not_Open = 103,
	No_Hydraulics = 104, Quality_Not_Open = 105, No_Results = 106,
	Unsolvable = 110, Input_Errors = 200, Syntax = 201, Bad_Number = 202,
	… every EPANET code, by its EPANET name, through 310 and the 25x function-call codes …
}
Warning :: enum i32 { None, Unbalanced = 1, Unstable, Disconnected, Pumps, Valves, Negative_Pressure }

error_message :: proc(err: Error) -> string   // EPANET's text (errors.odin, already there)
```

EPANET's numbers stay the values, so a code read from a report, a C
program or the toolkit means the same thing. `err != nil` is the test
(`.None` is the zero value).

## Reading a Spec out of a Project

```odin
spec_of :: proc(p: ^Project, allocator := context.allocator) -> Spec
```

For a program that only has the `Project` (the toolkit built it, or it
wants the converted values back in its own units). Mostly `convert_units`
run backwards; the arena holds the names.

## What the toolkit maps to

| `EN_*` | here |
|---|---|
| `EN_createproject`, `EN_open`, `EN_close`, `EN_deleteproject` | `load`, `build`, `destroy` |
| `EN_init` + `EN_add*` + `EN_set*data` | fill a `Spec`, `build` |
| `EN_set*value`, `EN_setoption`, `EN_settimeparam` | edit the `Spec`, rebuild; or a knob |
| `EN_solveH`, `EN_solveQ`, `EN_runH`/`EN_nextH`/`EN_runQ`/`EN_nextQ` | `simulate`; `run_begin`/`run_step`/`run_end` |
| `EN_getnodevalue`, `EN_getlinkvalue` (results) | `Results`, `Frame` |
| `EN_getnodevalue`, `EN_getlinkvalue` (data) | the `Spec` the program holds; `spec_of` |
| `EN_getcount`, `EN_get*index`, `EN_get*id` | `len(spec.nodes)`, `node_index`, `spec.nodes[i].id` |
| `EN_report`, `EN_savehydfile` | `Run_Options.files` |
| `EN_saveinpfile` | `write_inp` |
| `EN_geterror` | `error_message` |
| `EN_setreportcallback` | nothing: the report is a file or not at all (rung 1) |

## Examples

Load, run, read:

```odin
import "epanet"

spec, err := epanet.load("net1.inp")
if err != nil { fmt.eprintln(epanet.error_message(err)); return }
defer epanet.delete_spec(spec)

p, build_err := epanet.build(spec)
if build_err != nil { return }
defer epanet.destroy(p)

r, warn, run_err := epanet.simulate(p)
defer epanet.delete_results(r)
for t, k in r.periods {
	fmt.printfln("%2d:00  %s  %6.2f %s", t / 3600, spec.nodes[0].id, r.node.pressure[k][0], r.units.pressure)
}
```

A model of your own, built and solved (bywater-mill's `buildProject`):

```odin
nodes: [dynamic]epanet.Node
links: [dynamic]epanet.Link
for ent in system.entities {
	switch ent.kind {
	case .JUNCTION:
		append(&nodes, epanet.Node{id = ent.name, kind = .JUNCTION, elevation = ent.elevation,
			demands = {{base = ent.base_demand, pattern = ent.pattern}}})
	case .PIPE:
		append(&links, epanet.Link{id = ent.name, kind = .PIPE, from = from_name, to = to_name,
			length = ent.length, diameter = ent.diameter, roughness = ent.roughness, status = .OPEN})
	…
	}
}
spec := epanet.Spec{nodes = nodes[:], links = links[:], options = epanet.DEFAULT_OPTIONS, times = epanet.DEFAULT_TIMES}
spec.options.flow_units = .GPM
spec.times.duration = 24 * 3600
p, err := epanet.build(spec)
```

(The surface and these examples type-check as a stub package; Odin does
not redeclare a name with `:=`, hence `build_err` and `run_err`.)

Fire flow: one demand at a time, the same project:

```odin
run, err := epanet.run_begin(p, {quality = false})
defer epanet.run_end(&run)
frame := epanet.frame_make(p)
defer epanet.frame_delete(frame)
for node in hydrants {
	epanet.set_base_demand(p, node, 1500)           // gpm, the Spec's units
	_, warn, _, err := epanet.run_step(&run)
	epanet.read_frame(&run, &frame)
	available[node] = frame.node.pressure[node - 1]
	epanet.set_base_demand(p, node, 0)
}
```

The timeline, every event, reporting frames kept:

```odin
run, _ := epanet.run_begin(p, {})
frame := epanet.frame_make(p)
for {
	t, warn, done, err := epanet.run_step(&run)
	if err != nil do break
	if t % report_step == 0 {
		epanet.read_frame(&run, &frame)
		film_append(&film, t, frame.node.pressure, frame.link.flow)
	}
	if done do break
}
epanet.run_end(&run)
```

## Decisions

- **Spec, not an editable Project.** Edits are table edits and a rebuild;
  no index fix-ups, no "add then set" protocol, no half-built states. The
  cost is a rebuild per edit, which is a parse's worth of work and what the
  first user does anyway. If a program edits in a loop and the rebuild
  shows up, the knobs grow. (rung 7, after rung 1 cut the alternative)
- **Fat structs, user units, ids as strings in the Spec.** The `.inp`
  file's model, so `load` and `write_inp` are a transcription and a
  program's own tables map one to one. Conversion happens once, in
  `build`, as it does in EPANET.
- **Results as `[][]f64` over one block.** Indexable without arithmetic,
  contiguous for anyone who wants the block, no per-period allocation.
- **Rules stay text.** One grammar.
- **EPANET's error numbers as the enum's values.** One meaning everywhere.
- **No callbacks.** Progress is the caller's loop; the report is a file.
- **No report by default.** The numbers come back as data; the report
  file is there for whoever wants EPANET's paper.
- **One `Run` per `Project`.** The engine's state is in the `Project`;
  two runs over one would share it. A program that wants two runs at once
  builds twice (the Spec is the shared part, and is read-only to `build`).

## Not in it

- An incremental `Project` editor (`EN_add*`/`EN_delete*` with index
  fix-ups): the toolkit's, when the editing phase ports it; the Spec is
  the Odin way. (rung 1)
- Progress and report callbacks. (rung 1)
- Threads inside a run. A `Project` per thread is the model; nothing in
  the package is global but read-only tables.

## Where it goes, in order

Each step is checked the way the port has been: the same bytes as EPANET.

1. **`spec.odin`** — the types, `DEFAULT_OPTIONS`, `DEFAULT_TIMES`,
   `Error`, `Warning`. `errors.odin` gives `error_message`.
2. **`load` and `build`** — the parser's second half writes a Spec;
   `build` is the parser's tail over it. `parse_inp` becomes
   `build(load(path))` and `cmd/dumpnet` keeps proving the pair against
   EPANET's reader, byte for byte, on every fixture.
3. **`simulate`, `run_*`, `Frame`** — over `open_hyd`, `init_hyd`,
   `run_hyd`, `next_hyd`, `initqual`, `runqual`, `nextqual`, all there. A
   new driver, `cmd/run`, prints what `harness/run.c` prints and must
   match `run-c` on every fixture; with `files` set, the three files too.
4. **`write_inp`** — the file from a Spec, every section (`inpfile.c`).
   Checked by a round trip: `load` → `write_inp` → `load` → `build` dumps
   the same.
5. **The knobs and `spec_of`.** Fire flow and the timeline in
   bywater-mill move over; their smoke tests are the check.
