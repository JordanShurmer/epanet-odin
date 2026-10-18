package epanet

// model.odin — the network as written (API.md): one fat Entity per
// component, the patterns, curves, controls and rules, the options, times
// and report settings, every number in the file's own units. It is what
// `load` reads and `write_inp` writes, and a program's own table of
// components maps onto it one to one. project_from_model builds the
// engine's project from it the way the reader builds one from a file, so
// a Model and the file it came from run to the same bytes; dumpnet --model
// proves that on every fixture.

import "core:strconv"
import "core:strings"

// Kind is what a component is. A tank with no diameter is a reservoir to
// the engine, whatever its kind says, as it is to EPANET's reader.
Kind :: enum u8 {
	JUNCTION, RESERVOIR, TANK, PIPE, PUMP, VALVE,
}

// Entity is one component. Unused fields stay zero. A field the reader
// leaves at a default when the file has no value is noted; a Model a
// program builds gets the same default for a zero.
Entity :: struct {
	id:              string,
	kind:            Kind,
	x, y:            f64, // MISSING when the file had none
	vertices:        [][2]f64, // a link's bends
	comment, tag:    string,
	report:          bool, // named in the [REPORT] NODES or LINKS list

	// a node
	elevation:       f64, // a reservoir's head
	demands:         []Demand, // a junction's; none = one demand of zero
	emitter:         f64,
	init_quality:    f64,
	has_source:      bool,
	source:          Source_Spec,
	head_pattern:    string, // a reservoir's
	init_level:      f64, // a tank's
	min_level:       f64,
	max_level:       f64,
	min_volume:      f64, // 0 = the volume at the minimum level
	diameter:        f64, // a tank's; a pipe's and a valve's too (0 = 10 in or 254 mm)
	volume_curve:    string,
	overflow:        bool,
	mixing:          Mix_Model,
	mixing_fraction: f64, // 0 = 1
	bulk_coeff:      f64, // a tank's, a reservoir's or a pipe's; MISSING = the global one
	wall_coeff:      f64, // a pipe's; MISSING = the global one

	// a link
	from, to:        string,
	length:          f64, // 0 = 330 ft or 100 m
	roughness:       f64, // 0 = the formula's default
	minor_loss:      f64,
	leak_area:       f64,
	leak_expansion:  f64,
	check_valve:     bool,
	status:          Status, // OPEN or CLOSED, a valve's ACTIVE; unset (XHEAD) = the kind's default
	power:           f64, // a constant-power pump's; 0 = none
	head_curve:      string,
	speed:           f64, // 0 = 1
	speed_pattern:   string,
	energy_pattern:  string,
	efficiency_curve: string,
	energy_price:    f64,
	valve:           Link_Type, // PRV … PCV
	setting:         f64,
	loss_curve:      string, // a GPV's head loss curve, a PCV's position curve
}

Demand :: struct {
	base:    f64,
	pattern: string,
	name:    string,
}

Source_Spec :: struct {
	kind:     Source_Type,
	strength: f64,
	pattern:  string,
}

Model_Pattern :: struct {
	id:      string,
	factors: []f64,
	comment: string,
}

Model_Curve :: struct {
	id:      string,
	kind:    Curve_Type,
	x, y:    []f64,
	comment: string,
}

// Control is a simple control: link <status or setting> IF NODE node
// BELOW/ABOVE level, or AT TIME / AT CLOCKTIME time. A status of OPEN or
// CLOSED with no setting, or a setting with no status, as the file gives
// them.
Control :: struct {
	link:     string,
	status:   Status,
	setting:  f64, // MISSING = none; 0 with a status = none
	kind:     Control_Type,
	node:     string,
	level:    f64,
	time:     i64,
	disabled: bool,
}

// Rule is a rule-based control in EPANET's grammar, one clause per line,
// starting with its RULE line.
Rule :: struct {
	text: string,
}

// Options are the [OPTIONS], [REACTIONS] (the global part) and [ENERGY]
// (the global part) sections. Start from DEFAULT_OPTIONS.
Options :: struct {
	flow_units:            Flow_Units,
	pressure_units:        Pressure_Units,
	headloss:              Headloss_Formula,
	demand_model:          Demand_Model,
	min_pressure:          f64,
	required_pressure:     f64,
	pressure_exponent:     f64,
	emitter_exponent:      f64,
	demand_multiplier:     f64,
	specific_gravity:      f64,
	viscosity:             f64, // relative to water's when > 1e-3, else absolute; 0 = water's
	diffusivity:           f64, // relative to chlorine's when > 1e-4, else absolute; 0 = chlorine's
	trials:                int,
	accuracy:              f64,
	head_error:            f64, // 0 = not checked
	flow_change:           f64, // 0 = not checked
	damp_limit:            f64,
	check_freq:            int,
	max_check:             int,
	rq_tolerance:          f64,
	head_tolerance:        f64,
	flow_tolerance:        f64,
	extra_trials:          int, // -1 = UNBALANCED STOP; n = CONTINUE n
	backflow_allowed:      bool,
	default_pattern:       string,
	quality:               Qual_Type,
	chemical:              string, // the constituent's name and units
	chemical_units:        string,
	trace_node:            string,
	tolerance:             f64, // 0 = EPANET's
	limit:                 f64, // limiting potential
	bulk_order:            f64,
	wall_order:            f64,
	tank_order:            f64,
	bulk_coeff:            f64, // global, per day
	wall_coeff:            f64,
	roughness_correlation: f64,
	pump_efficiency:       f64, // %
	energy_price:          f64,
	energy_pattern:        string,
	demand_charge:         f64,
	map_file:              string,
	hydraulics_file:       string,
	hydraulics:            Hyd_File,
}

DEFAULT_OPTIONS :: Options {
	flow_units = .GPM, pressure_units = .DEFAULTUNIT, headloss = .HW, demand_model = .DDA,
	required_pressure = MINPDIFF, pressure_exponent = 0.5, emitter_exponent = 0.5,
	demand_multiplier = 1, specific_gravity = 1, trials = 200, accuracy = 0.001,
	check_freq = 2, max_check = 10, rq_tolerance = 1e-7, head_tolerance = 0.0005, flow_tolerance = 0.0001,
	extra_trials = -1, backflow_allowed = true, default_pattern = "1",
	chemical = "Chemical", chemical_units = "mg/L", bulk_order = 1, wall_order = 1, tank_order = 1,
	pump_efficiency = 75, hydraulics = .SCRATCH,
}

// Model_Times is the [TIMES] section, in seconds.
Model_Times :: struct {
	duration:        i64,
	hydraulic_step:  i64,
	quality_step:    i64, // 0 = a tenth of the hydraulic step
	pattern_step:    i64,
	pattern_start:   i64,
	report_step:     i64,
	report_start:    i64,
	rule_step:       i64, // 0 = a tenth of the hydraulic step
	start_clocktime: i64,
	statistic:       Time_Stat,
}

DEFAULT_TIMES :: Model_Times{hydraulic_step = 3600, pattern_step = 3600, report_step = 3600}

// Report_Spec is the [REPORT] section. default_report() is EPANET's.
Report_Spec :: struct {
	page_size: int,
	summary:   bool,
	messages:  bool,
	status:    int, // 0 no, 1 yes, 2 full
	energy:    bool,
	nodes:     int, // 0 none, 1 all, 2 those an Entity flags with report
	links:     int,
	fields:    [Field]Report_Field,
	file:      string,
}

default_report :: proc() -> (r: Report_Spec) {
	r.summary, r.messages = true, true
	for f in Field do r.fields[f] = {enabled = false, precision = 2, lo = BIG * BIG, hi = -BIG * BIG}
	for f, i in FIELD_NAMES do r.fields[Field(i)].name = f
	r.fields[.FRICTION].precision = 3
	for f in Field.DEMAND ..= Field.QUALITY do r.fields[f].enabled = true
	for f in Field.FLOW ..= Field.HEADLOSS do r.fields[f].enabled = true
	return
}

Model :: struct {
	title:    [3]string,
	entities: []Entity,
	patterns: []Model_Pattern,
	curves:   []Model_Curve,
	controls: []Control,
	rules:    []Rule,
	options:  Options,
	times:    Model_Times,
	report:   Report_Spec,
	aux:      []string, // the [LABELS] and [BACKDROP] sections, line by line, written back as they were
	problems: []Problem, // what load could not read; empty when the file was clean
	arena:    ^Arena, // what load allocated from; nil for a Model a program built
}

// ── files ─────────────────────────────────────────────────────────────

// parse reads an .inp file's text.
parse :: proc(text: string, allocator := context.allocator) -> (m: Model, err: Error) {
	context.allocator = allocator
	p := project_new()
	if p == nil do return m, .Out_Of_Memory
	errcode := read_text_in_arena(p, text)
	err = Error(errcode)
	if errcode != 0 && errcode != 200 {
		project_free(p)
		return
	}
	m.arena = new(Arena)
	if !arena_init(m.arena) {
		free(m.arena)
		m.arena = nil
		project_free(p)
		return m, .Out_Of_Memory
	}
	model_from_project_in_arena(p, &m)
	project_free(p)
	return
}

read_text_in_arena :: proc(p: ^Project, text: string) -> int {
	context.allocator = arena_allocator(&p.arena)
	return read_text(p, text)
}

model_from_project_in_arena :: proc(p: ^Project, m: ^Model) {
	context.allocator = arena_allocator(m.arena)
	model_from_project(p, m)
}

// delete_model gives back what load allocated. A Model a program built
// is the program's to free.
delete_model :: proc(m: ^Model) {
	if m.arena == nil do return
	arena_destroy(m.arena)
	free(m.arena)
	m^ = {}
}

// ── a Model from the reader's project ─────────────────────────────────

// model_from_project reads a Model out of a project as read_text leaves
// it: the tables finished, nothing converted. The Model's memory is the
// caller's allocator.
model_from_project :: proc(p: ^Project, m: ^Model) {
	net, hyd, q, t, r := &p.net, &p.hyd, &p.q, &p.times, &p.rpt
	for s, i in p.title do m.title[i] = strings.clone(s)

	m.entities = make([]Entity, net.nnodes + net.nlinks)
	for i in 1 ..= net.nnodes {
		e := &m.entities[i - 1]
		e.id = strings.clone(p.node_id[i])
		e.x, e.y = p.node_x[i], p.node_y[i]
		e.comment = strings.clone(p.node_comment[i])
		e.tag = strings.clone(p.node_tag[i])
		e.report = bool(p.node_rpt[i])
		e.elevation = net.el[i]
		e.emitter = net.ke[i]
		e.init_quality = net.c0[i]
		if net.has_source[i] {
			e.has_source = true
			e.source = {net.source_type[i], net.source_c0[i], pattern_name(p, net.source_pat[i])}
		}
		switch net.node_type[i] {
		case .JUNCTION:
			e.kind = .JUNCTION
			first, last := net.demand_first[i], net.demand_first[i + 1]
			e.demands = make([]Demand, last - first)
			for k in first ..< last {
				e.demands[k - first] = {net.demand_base[k], pattern_name(p, net.demand_pat[k]), strings.clone(p.demand_name[k])}
			}
		case .RESERVOIR, .TANK:
			// (a reservoir is a tank line with no diameter; what else the
			// line said is kept, as the reader keeps it)
			e.kind = net.node_type[i] == .TANK ? .TANK : .RESERVOIR
			j := i - net.njuncs
			e.head_pattern = pattern_name(p, net.tank_pat[j])
			e.init_level = net.tank_h0[j]
			e.min_level = net.tank_hmin[j]
			e.max_level = net.tank_hmax[j]
			e.diameter = net.tank_area[j]
			e.min_volume = net.tank_vmin[j]
			e.volume_curve = curve_name(p, net.tank_vcurve[j])
			e.overflow = bool(net.tank_overflow[j])
			e.mixing = net.tank_mix[j]
			e.mixing_fraction = net.tank_v1frac[j]
			e.bulk_coeff = net.tank_kb[j]
		}
	}
	for k in 1 ..= net.nlinks {
		e := &m.entities[net.nnodes + k - 1]
		e.id = strings.clone(p.link_id[k])
		e.from = strings.clone(p.node_id[net.n1[k]])
		e.to = strings.clone(p.node_id[net.n2[k]])
		e.comment = strings.clone(p.link_comment[k])
		e.tag = strings.clone(p.link_tag[k])
		e.report = bool(p.link_rpt[k])
		if n := len(p.vertex_x[k]); n > 0 {
			e.vertices = make([][2]f64, n)
			for x, j in p.vertex_x[k] do e.vertices[j] = {x, p.vertex_y[k][j]}
		}
		e.status = net.init_status[k]
		e.minor_loss = net.km[k]
		e.diameter = net.diam[k]
		lt := net.link_type[k]
		switch {
		case lt <= .PIPE:
			e.kind = .PIPE
			e.check_valve = lt == .CVPIPE
			e.length = net.len[k]
			e.roughness = net.kc[k]
			e.bulk_coeff = net.link_kb[k]
			e.wall_coeff = net.link_kw[k]
			e.leak_area = net.leak_area[k]
			e.leak_expansion = net.leak_expan[k]
		case lt == .PUMP:
			e.kind = .PUMP
			pm := net.link_pump[k]
			e.power = net.km[k]
			e.head_curve = curve_name(p, net.pump_hcurve[pm])
			e.speed = net.kc[k]
			e.speed_pattern = pattern_name(p, net.pump_upat[pm])
			e.energy_pattern = pattern_name(p, net.pump_epat[pm])
			e.efficiency_curve = curve_name(p, net.pump_ecurve[pm])
			e.energy_price = net.pump_ecost[pm]
		case:
			e.kind = .VALVE
			e.valve = lt
			v := net.link_valve[k]
			if lt == .GPV {
				e.loss_curve = curve_name(p, i32(net.kc[k]))
			} else {
				e.setting = net.kc[k]
				if lt == .PCV do e.loss_curve = curve_name(p, net.valve_curve[v])
			}
		}
	}

	m.patterns = make([]Model_Pattern, len(net.patterns) - 1)
	for i in 1 ..< len(net.patterns) {
		f := make([]f64, len(net.patterns[i].f))
		copy(f, net.patterns[i].f)
		m.patterns[i - 1] = {strings.clone(p.pattern_id[i]), f, strings.clone(p.pattern_comment[i])}
	}
	m.curves = make([]Model_Curve, max(len(net.curves) - 1, 0))
	for i in 1 ..< len(net.curves) {
		x := make([]f64, len(net.curves[i].x))
		y := make([]f64, len(net.curves[i].y))
		copy(x, net.curves[i].x)
		copy(y, net.curves[i].y)
		m.curves[i - 1] = {strings.clone(p.curve_id[i]), p.curve_type[i], x, y, strings.clone(p.curve_comment[i])}
	}
	m.controls = make([]Control, net.ncontrols)
	for c in 1 ..= net.ncontrols {
		k := net.control_link[c]
		ctl := &m.controls[c - 1]
		if k > 0 do ctl.link = strings.clone(p.link_id[k])
		if n := net.control_node[c]; n > 0 do ctl.node = strings.clone(p.node_id[n])
		ctl.status = net.control_status[c]
		ctl.setting = net.control_setting[c]
		ctl.kind = net.control_type[c]
		ctl.level = net.control_grade[c]
		ctl.time = net.control_time[c]
		ctl.disabled = !net.control_enabled[c]
	}
	m.rules = make([]Rule, net.nrules)
	for ri in 1 ..= net.nrules do m.rules[ri - 1] = {rule_text(p, ri)}

	o := &m.options
	o.flow_units = p.flow_units
	o.pressure_units = p.pressure_units
	o.headloss = hyd.formflag
	o.demand_model = hyd.demand_model
	o.min_pressure, o.required_pressure, o.pressure_exponent = hyd.pmin, hyd.preq, hyd.pexp
	o.emitter_exponent = 1 / hyd.qexp
	o.demand_multiplier = hyd.dmult
	o.specific_gravity = hyd.spgrav
	o.viscosity = hyd.viscos == MISSING ? 0 : hyd.viscos
	o.diffusivity = q.diffus == MISSING ? 0 : q.diffus
	o.trials = hyd.max_iter
	o.accuracy = hyd.hacc
	o.head_error, o.flow_change, o.damp_limit = hyd.head_error_limit, hyd.flow_change_limit, hyd.damp_limit
	o.check_freq, o.max_check = hyd.check_freq, hyd.max_check
	o.rq_tolerance, o.head_tolerance, o.flow_tolerance = hyd.rqtol, hyd.htol, hyd.qtol
	o.extra_trials = hyd.extra_iter
	o.backflow_allowed = hyd.emit_backflow
	o.default_pattern = strings.clone(p.def_pat_id)
	o.quality = q.kind
	o.chemical = strings.clone(p.chem_name)
	o.chemical_units = strings.clone(p.chem_units)
	if q.trace_node > 0 do o.trace_node = strings.clone(p.node_id[q.trace_node])
	o.tolerance = q.ctol == MISSING ? 0 : q.ctol
	o.limit = q.climit
	o.bulk_order, o.wall_order, o.tank_order = q.bulk_order, q.wall_order, q.tank_order
	o.bulk_coeff, o.wall_coeff, o.roughness_correlation = p.kbulk, p.kwall, p.rfactor
	o.pump_efficiency, o.energy_price, o.demand_charge = hyd.epump, hyd.ecost, p.dcost
	o.energy_pattern = pattern_name(p, i32(hyd.epat))
	o.map_file = strings.clone(p.map_fname)
	o.hydraulics_file = strings.clone(p.out.hyd_fname)
	o.hydraulics = p.out.hydflag

	m.times = {t.dur, t.hstep, t.qstep, t.pstep, t.pstart, t.rstep, t.rstart, t.rulestep, t.tstart, r.tstat}
	m.report = {r.page_size, r.summary, r.messages, r.status, r.energy, r.nodes, r.links, r.fields, strings.clone(r.rpt2_fname)}
	for f in Field {
		m.report.fields[f].name = strings.clone(r.fields[f].name)
		m.report.fields[f].units = strings.clone(r.fields[f].units)
	}
	m.aux = make([]string, len(p.aux))
	for s, i in p.aux do m.aux[i] = strings.clone(s)
	m.problems = make([]Problem, len(p.problems))
	for pr, i in p.problems do m.problems[i] = {pr.line, pr.code, strings.clone(pr.text)}
}

pattern_name :: proc(p: ^Project, i: i32) -> string {
	return i > 0 ? strings.clone(p.pattern_id[i]) : ""
}

curve_name :: proc(p: ^Project, i: i32) -> string {
	return i > 0 ? strings.clone(p.curve_id[i]) : ""
}

// rule_text writes rule r in EPANET's grammar, numbers at %.17g so the
// same rule reads back.
rule_text :: proc(p: ^Project, r: int) -> string {
	net := &p.net
	sb: strings.Builder
	strings.builder_init(&sb, context.temp_allocator)
	strings.write_string(&sb, "RULE ")
	strings.write_string(&sb, p.rule_label[r])
	for k in net.rule_premise_first[r] ..< net.rule_premise_first[r + 1] {
		strings.write_string(&sb, k == net.rule_premise_first[r] ? "\nIF " : (net.premise_logop[k] == .OR ? "\nOR " : "\nAND "))
		#partial switch net.premise_object[k] {
		case .NODE:
			strings.write_string(&sb, rule_object_text(p, .NODE, net.premise_index[k]))
			strings.write_string(&sb, " ")
			strings.write_string(&sb, p.node_id[net.premise_index[k]])
		case .LINK:
			strings.write_string(&sb, rule_object_text(p, .LINK, net.premise_index[k]))
			strings.write_string(&sb, " ")
			strings.write_string(&sb, p.link_id[net.premise_index[k]])
		case:
			strings.write_string(&sb, "SYSTEM")
		}
		strings.write_string(&sb, " ")
		strings.write_string(&sb, INP_RULE_VARIABLE[net.premise_variable[k]])
		strings.write_string(&sb, " ")
		strings.write_string(&sb, INP_RULE_OPERATOR[net.premise_relop[k]])
		strings.write_string(&sb, " ")
		if net.premise_value[k] == MISSING {
			strings.write_string(&sb, INP_RULE_VALUE[net.premise_status[k]])
		} else {
			#partial switch net.premise_variable[k] {
			case .CLOCKTIME, .DRAINTIME, .FILLTIME, .TIME:
				write_g17(&sb, net.premise_value[k] / 3600)
			case:
				write_g17(&sb, net.premise_value[k])
			}
		}
	}
	for k in net.rule_then_first[r] ..< net.rule_then_first[r + 1] {
		switch {
		case k == net.rule_then_first[r]:
			strings.write_string(&sb, "\nTHEN ")
		case k == net.rule_else_first[r]:
			strings.write_string(&sb, "\nELSE ")
		case:
			strings.write_string(&sb, "\nAND ")
		}
		link := net.action_link[k]
		strings.write_string(&sb, rule_object_text(p, .LINK, link))
		strings.write_string(&sb, " ")
		strings.write_string(&sb, p.link_id[link])
		if net.action_setting[k] == MISSING {
			strings.write_string(&sb, " STATUS IS ")
			strings.write_string(&sb, INP_RULE_VALUE[net.action_status[k]])
		} else {
			strings.write_string(&sb, " SETTING IS ")
			write_g17(&sb, net.action_setting[k])
		}
	}
	if net.rule_priority[r] > 0 {
		strings.write_string(&sb, "\nPRIORITY ")
		write_g17(&sb, net.rule_priority[r])
	}
	if !net.rule_enabled[r] do strings.write_string(&sb, "\nDISABLED")
	return strings.clone(strings.to_string(sb))
}

write_g17 :: proc(sb: ^strings.Builder, x: f64) {
	buf: [40]u8
	strings.write_string(sb, strconv.write_float(buf[:], x, 'g', 17, 64))
}

// ── the engine's project from a Model ─────────────────────────────────

// Built is what project_from_model hands back: the project in internal
// units with its solvers not yet open, where each entity went, and the
// first thing that could not be built.
Built :: struct {
	p:          ^Project,
	node_index: []i32, // per entity: the engine's node index, 0 when the entity is a link
	link_index: []i32, // per entity: the engine's link index, 0 when the entity is a node
	err:        Error,
	at:         int, // the entity (or, past them, the control or rule) the error is about; -1 = none
}

// project_from_model builds the engine's project from a Model as the
// reader would from the file: the same tables, the same defaults, the
// same order (junctions first, then tanks and reservoirs, each in the
// Model's order), then the reader's own tail puts it in internal units.
project_from_model :: proc(m: ^Model) -> (b: Built) {
	b.at = -1
	p := project_new()
	if p == nil {
		b.err = .Out_Of_Memory
		return
	}
	b.p = p
	context.allocator = arena_allocator(&p.arena)
	net, hyd, q := &p.net, &p.hyd, &p.q
	set_defaults(p)
	init_report(p)
	o := &m.options

	// options the reader needs before the lines
	p.flow_units = o.flow_units
	p.units = p.flow_units >= .LPS ? .SI : .US
	p.pressure_units = o.pressure_units
	hyd.formflag = o.headloss

	// counts
	for e in m.entities {
		switch e.kind {
		case .JUNCTION:
			p.max_juncs += 1
		case .RESERVOIR, .TANK:
			p.max_tanks += 1
		case .PIPE:
			p.max_links += 1
		case .PUMP:
			p.max_links += 1
			p.max_pumps += 1
		case .VALVE:
			p.max_links += 1
			p.max_valves += 1
		}
	}
	p.max_controls = len(m.controls)
	project_alloc(p)
	nn := p.max_juncs + p.max_tanks
	for i in 0 ..= nn do p.node_x[i], p.node_y[i] = MISSING, MISSING
	b.node_index = make([]i32, len(m.entities))
	b.link_index = make([]i32, len(m.entities))

	// patterns and curves, pattern 0 being the single 1.0
	np, nc := len(m.patterns), len(m.curves)
	p.pattern_id = make([]string, np + 1)
	p.pattern_comment = make([]string, np + 1)
	net.patterns = make([]Pattern, np + 1)
	one := make([]f64, 1)
	one[0] = 1
	net.patterns[0] = {one}
	p.patterns_by_id[""] = 0
	for pat, i in m.patterns {
		if len(pat.id) > MAXID || findpattern(p, pat.id) > 0 {
			b.err = len(pat.id) > MAXID ? .Bad_ID : .Duplicate_ID
			return
		}
		p.pattern_id[i + 1] = strings.clone(pat.id)
		p.pattern_comment[i + 1] = strings.clone(pat.comment)
		f := make([]f64, len(pat.factors))
		copy(f, pat.factors)
		net.patterns[i + 1] = {f}
		p.patterns_by_id[p.pattern_id[i + 1]] = i32(i + 1)
	}
	p.curve_id = make([]string, nc + 1)
	p.curve_comment = make([]string, nc + 1)
	p.curve_type = make([]Curve_Type, nc + 1)
	net.curves = make([]Curve, nc + 1)
	for cv, i in m.curves {
		if len(cv.id) > MAXID || findcurve(p, cv.id) > 0 {
			b.err = len(cv.id) > MAXID ? .Bad_ID : .Duplicate_ID
			return
		}
		p.curve_id[i + 1] = strings.clone(cv.id)
		p.curve_comment[i + 1] = strings.clone(cv.comment)
		p.curve_type[i + 1] = cv.kind
		x := make([]f64, len(cv.x))
		y := make([]f64, len(cv.y))
		copy(x, cv.x)
		copy(y, cv.y)
		net.curves[i + 1] = {x, y}
		p.curves_by_id[p.curve_id[i + 1]] = i32(i + 1)
	}

	// nodes
	for &e, ei in m.entities {
		if e.kind > .TANK do continue
		if len(e.id) > MAXID {
			b.err, b.at = .Bad_ID, ei
			return
		}
		if findnode(p, e.id) != 0 {
			b.err, b.at = .Duplicate_ID, ei
			return
		}
		i: int
		if e.kind == .JUNCTION {
			net.njuncs += 1
			i = net.njuncs
			net.node_type[i] = .JUNCTION
		} else {
			net.ntanks += 1
			t := net.ntanks
			i = p.max_juncs + t
			// a reservoir is a tank with no diameter, whatever its kind says
			diam, h0, hmin, hmax, minvol := e.diameter, e.init_level, e.min_level, e.max_level, e.min_volume
			net.node_type[i] = diam == 0 ? .RESERVOIR : .TANK
			net.tank_node[t] = i32(i)
			net.tank_h0[t] = h0
			net.tank_hmin[t] = hmin
			net.tank_hmax[t] = hmax
			net.tank_area[t] = diam
			net.tank_kb[t] = e.bulk_coeff
			net.tank_overflow[t] = b32(e.overflow)
			area := PI * (diam * diam) / 4
			net.tank_vmin[t] = area * hmin
			if minvol > 0 do net.tank_vmin[t] = minvol
			net.tank_v0[t] = net.tank_vmin[t] + area * (h0 - hmin)
			net.tank_vmax[t] = net.tank_vmin[t] + area * (hmax - hmin)
			net.tank_mix[t] = e.mixing
			net.tank_v1frac[t] = e.mixing_fraction == 0 ? 1 : e.mixing_fraction
			if len(e.head_pattern) > 0 {
				pat := findpattern(p, e.head_pattern)
				if pat < 0 {
					b.err, b.at = .Undefined_Pattern, ei
					return
				}
				net.tank_pat[t] = i32(pat)
			}
			if len(e.volume_curve) > 0 {
				c := findcurve(p, e.volume_curve)
				if c == 0 {
					b.err, b.at = .Undefined_Curve, ei
					return
				}
				net.tank_vcurve[t] = i32(c)
				p.curve_type[c] = .VOLUME_CURVE
			}
		}
		net.nnodes += 1
		b.node_index[ei] = i32(i)
		p.node_id[i] = strings.clone(e.id)
		p.nodes_by_id[p.node_id[i]] = i32(i)
		p.node_x[i], p.node_y[i] = e.x, e.y
		p.node_comment[i] = strings.clone(e.comment)
		p.node_tag[i] = strings.clone(e.tag)
		p.node_rpt[i] = b32(e.report)
		net.el[i] = e.elevation
		net.ke[i] = e.emitter
		net.c0[i] = e.init_quality
		if e.has_source {
			net.has_source[i] = true
			net.source_type[i] = e.source.kind
			net.source_c0[i] = e.source.strength
			if len(e.source.pattern) > 0 {
				pat := findpattern(p, e.source.pattern)
				if pat < 0 {
					b.err, b.at = .Undefined_Pattern, ei
					return
				}
				net.source_pat[i] = i32(pat)
			}
		}
	}

	// demands: every junction has at least one, as the reader gives it
	node_entity := make([]int, net.nnodes + 1, context.temp_allocator)
	for n, ei in b.node_index do if n > 0 do node_entity[n] = ei
	nd := 0
	for e in m.entities do if e.kind == .JUNCTION do nd += max(len(e.demands), 1)
	net.demand_base = make([]f64, nd + 1)
	net.demand_pat = make([]i32, nd + 1)
	p.demand_name = make([]string, nd + 1)
	slot := 1
	for i in 1 ..= net.nnodes {
		net.demand_first[i] = i32(slot)
		if i > net.njuncs do continue
		ei := node_entity[i]
		e := &m.entities[ei]
		if len(e.demands) == 0 {
			slot += 1
			continue
		}
		for d in e.demands {
			net.demand_base[slot] = d.base
			if len(d.pattern) > 0 {
				pat := findpattern(p, d.pattern)
				if pat < 0 {
					b.err, b.at = .Undefined_Pattern, ei
					return
				}
				net.demand_pat[slot] = i32(pat)
			}
			p.demand_name[slot] = strings.clone(clip(d.name, MAXID))
			slot += 1
		}
	}
	net.demand_first[net.nnodes + 1] = i32(slot)

	// links
	for &e, ei in m.entities {
		if e.kind < .PIPE do continue
		if len(e.id) > MAXID {
			b.err, b.at = .Bad_ID, ei
			return
		}
		if findlink(p, e.id) != 0 {
			b.err, b.at = .Duplicate_ID, ei
			return
		}
		j1, j2 := findnode(p, e.from), findnode(p, e.to)
		if j1 == 0 || j2 == 0 {
			b.err, b.at = .Undefined_Node, ei
			return
		}
		if j1 == j2 {
			b.err, b.at = .Same_Ends, ei
			return
		}
		k := net.nlinks + 1
		lt: Link_Type
		switch e.kind {
		case .PIPE:
			lt = e.check_valve ? .CVPIPE : .PIPE
		case .PUMP:
			lt = .PUMP
		case .VALVE:
			lt = e.valve
			if lt < .PRV do lt = .PRV
			if errcode := valvecheck(p, k, lt, j1, j2); errcode != 0 {
				b.err, b.at = Error(errcode), ei
				return
			}
		case .JUNCTION, .RESERVOIR, .TANK:
		}
		net.nlinks = k
		b.link_index[ei] = i32(k)
		p.link_id[k] = strings.clone(e.id)
		p.links_by_id[p.link_id[k]] = i32(k)
		p.link_comment[k] = strings.clone(e.comment)
		p.link_tag[k] = strings.clone(e.tag)
		p.link_rpt[k] = b32(e.report)
		if len(e.vertices) > 0 {
			p.vertex_x[k] = make([]f64, len(e.vertices))
			p.vertex_y[k] = make([]f64, len(e.vertices))
			for v, j in e.vertices do p.vertex_x[k][j], p.vertex_y[k][j] = v[0], v[1]
		}
		net.link_type[k] = lt
		net.n1[k], net.n2[k] = i32(j1), i32(j2)
		net.km[k] = e.minor_loss
		d := e.diameter
		if d == 0 do d = p.units == .SI ? 254 : 10
		status := e.status
		#partial switch lt {
		case .CVPIPE, .PIPE:
			net.len[k] = e.length
			if net.len[k] == 0 do net.len[k] = p.units == .SI ? 100 : 330
			net.diam[k] = d
			net.kc[k] = e.roughness
			if net.kc[k] == 0 {
				switch hyd.formflag {
				case .HW:
					net.kc[k] = 130
				case .DW:
					net.kc[k] = 0.0005
				case .CM:
					net.kc[k] = 0.01
				}
			}
			net.link_kb[k] = e.bulk_coeff
			net.link_kw[k] = e.wall_coeff
			net.leak_area[k] = e.leak_area
			net.leak_expan[k] = e.leak_expansion
			if status == .XHEAD do status = .OPEN
		case .PUMP:
			net.npumps += 1
			pm := net.npumps
			net.pump_link[pm] = i32(k)
			net.link_pump[k] = i32(pm)
			net.diam[k], net.len[k] = 0, 0
			net.km[k] = e.power
			net.kc[k] = e.speed
			if net.kc[k] == 0 && status != .CLOSED do net.kc[k] = 1
			net.pump_type[pm] = .NOCURVE
			if e.power > 0 do net.pump_type[pm] = .CONST_HP
			if len(e.head_curve) > 0 {
				c := findcurve(p, e.head_curve)
				if c == 0 {
					b.err, b.at = .Undefined_Curve, ei
					return
				}
				net.pump_type[pm] = .CUSTOM
				net.pump_hcurve[pm] = i32(c)
			}
			if len(e.efficiency_curve) > 0 {
				c := findcurve(p, e.efficiency_curve)
				if c == 0 {
					b.err, b.at = .Undefined_Curve, ei
					return
				}
				net.pump_ecurve[pm] = i32(c)
				p.curve_type[c] = .EFFIC_CURVE
			}
			if len(e.speed_pattern) > 0 {
				pat := findpattern(p, e.speed_pattern)
				if pat < 0 {
					b.err, b.at = .Undefined_Pattern, ei
					return
				}
				net.pump_upat[pm] = i32(pat)
			}
			if len(e.energy_pattern) > 0 {
				pat := findpattern(p, e.energy_pattern)
				if pat < 0 {
					b.err, b.at = .Undefined_Pattern, ei
					return
				}
				net.pump_epat[pm] = i32(pat)
			}
			net.pump_ecost[pm] = e.energy_price
			if status == .XHEAD do status = .OPEN
		case:
			net.nvalves += 1
			v := net.nvalves
			net.valve_link[v] = i32(k)
			net.link_valve[k] = i32(v)
			net.diam[k] = d
			net.len[k] = 0
			net.kc[k] = e.setting
			if status == .XHEAD do status = .ACTIVE
			if lt == .GPV {
				net.kc[k] = 0
				if len(e.loss_curve) > 0 {
					c := findcurve(p, e.loss_curve)
					if c == 0 {
						b.err, b.at = .Undefined_Curve, ei
						return
					}
					net.kc[k] = f64(c)
					p.curve_type[c] = .HLOSS_CURVE
					if e.status == .XHEAD do status = .OPEN
				}
			} else if lt == .PCV && len(e.loss_curve) > 0 {
				c := findcurve(p, e.loss_curve)
				if c == 0 {
					b.err, b.at = .Undefined_Curve, ei
					return
				}
				net.valve_curve[v] = i32(c)
				p.curve_type[c] = .VALVE_CURVE
				if net.kc[k] > 100 do net.kc[k] = 100
			}
		}
		net.init_status[k] = status
		net.init_setting[k] = net.kc[k]
	}

	// controls, with the reader's reading of a status and a setting
	for ctl, ci in m.controls {
		k := findlink(p, ctl.link)
		if k == 0 {
			b.err, b.at = .Undefined_Link, len(m.entities) + ci
			return
		}
		lt := net.link_type[k]
		if lt == .CVPIPE {
			b.err, b.at = .Control_On_CV, len(m.entities) + ci
			return
		}
		setting := ctl.setting
		status := ctl.status
		if status != .ACTIVE && setting == 0 do setting = MISSING
		if status == .XHEAD do status = .ACTIVE
		if setting == MISSING {
			if lt == .PUMP do setting = status == .OPEN ? 1 : 0
			if lt == .GPV do setting = net.kc[k]
		}
		if (lt == .PUMP || lt == .PIPE) && setting != MISSING do status = setting == 0 ? .CLOSED : .OPEN
		n := 0
		if ctl.kind == .LOWLEVEL || ctl.kind == .HILEVEL {
			n = findnode(p, ctl.node)
			if n == 0 {
				b.err, b.at = .Undefined_Node, len(m.entities) + ci
				return
			}
		}
		c := ci + 1
		net.ncontrols = c
		net.control_link[c] = i32(k)
		net.control_node[c] = i32(n)
		net.control_type[c] = ctl.kind
		net.control_status[c] = status
		net.control_setting[c] = setting
		net.control_time[c] = ctl.time
		if ctl.kind == .TIMEOFDAY do net.control_time[c] %= SEC_PER_DAY
		net.control_grade[c] = ctl.level
		net.control_enabled[c] = b32(!ctl.disabled)
	}

	// rules, through the reader's own rule parser
	p.rule_label = make([]string, 1)
	net.rule_priority = make([]f64, 1)
	net.rule_enabled = make([]b32, 1)
	net.rule_premise_first = make([]i32, 2)
	net.rule_then_first = make([]i32, 2)
	net.rule_else_first = make([]i32, 1)
	net.rule_premise_first[0], net.rule_premise_first[1] = 1, 1
	net.rule_then_first[0], net.rule_then_first[1] = 1, 1
	net.rule_else_first[0] = 1
	net.premise_logop = make([]Rule_Logic, 1)
	net.premise_object = make([]Rule_Object, 1)
	net.premise_index = make([]i32, 1)
	net.premise_variable = make([]Rule_Variable, 1)
	net.premise_relop = make([]Rule_Op, 1)
	net.premise_status = make([]Rule_Status, 1)
	net.premise_value = make([]f64, 1)
	net.action_link = make([]i32, 1)
	net.action_status = make([]Rule_Status, 1)
	net.action_setting = make([]f64, 1)
	for rule, ri in m.rules {
		if errcode := add_rule_text(p, rule.text); errcode != 0 {
			b.err, b.at = Error(errcode), len(m.entities) + len(m.controls) + ri
			return
		}
	}

	// the rest of the options
	hyd.demand_model = o.demand_model
	hyd.pmin, hyd.preq, hyd.pexp = o.min_pressure, o.required_pressure, o.pressure_exponent
	if hyd.preq == 0 do hyd.preq = MINPDIFF
	if hyd.pexp == 0 do hyd.pexp = 0.5
	hyd.qexp = o.emitter_exponent == 0 ? 2 : 1 / o.emitter_exponent
	hyd.dmult = o.demand_multiplier == 0 ? 1 : o.demand_multiplier
	hyd.spgrav = o.specific_gravity == 0 ? 1 : o.specific_gravity
	hyd.viscos = o.viscosity == 0 ? MISSING : o.viscosity
	q.diffus = o.diffusivity == 0 ? MISSING : o.diffusivity
	hyd.max_iter = o.trials == 0 ? 200 : o.trials
	hyd.hacc = o.accuracy == 0 ? 0.001 : o.accuracy
	hyd.head_error_limit, hyd.flow_change_limit, hyd.damp_limit = o.head_error, o.flow_change, o.damp_limit
	hyd.check_freq = o.check_freq == 0 ? 2 : o.check_freq
	hyd.max_check = o.max_check == 0 ? 10 : o.max_check
	hyd.rqtol = o.rq_tolerance == 0 ? 1e-7 : o.rq_tolerance
	hyd.htol = o.head_tolerance == 0 ? 0.0005 : o.head_tolerance
	hyd.qtol = o.flow_tolerance == 0 ? 0.0001 : o.flow_tolerance
	hyd.extra_iter = o.extra_trials
	hyd.emit_backflow = o.backflow_allowed
	p.def_pat_id = len(o.default_pattern) > 0 ? strings.clone(clip(o.default_pattern, MAXID)) : "1"
	q.kind = o.quality
	p.chem_name = len(o.chemical) > 0 ? strings.clone(clip(o.chemical, MAXID)) : "Chemical"
	p.chem_units = len(o.chemical_units) > 0 ? strings.clone(clip(o.chemical_units, MAXID)) : "mg/L"
	if q.kind == .TRACE {
		q.trace_node = findnode(p, o.trace_node)
		if q.trace_node == 0 {
			b.err = .Undefined_Trace_Node
			return
		}
		if len(o.chemical) == 0 do p.chem_name = "% from"
		if len(o.chemical_units) == 0 do p.chem_units = strings.clone(clip(o.trace_node, MAXID))
	}
	if q.kind == .AGE && len(o.chemical) == 0 do p.chem_name, p.chem_units = "AGE", "hrs"
	q.ctol = o.tolerance == 0 ? MISSING : o.tolerance
	q.climit = o.limit
	q.bulk_order, q.wall_order, q.tank_order = o.bulk_order, o.wall_order, o.tank_order
	p.kbulk, p.kwall, p.rfactor = o.bulk_coeff, o.wall_coeff, o.roughness_correlation
	hyd.epump = o.pump_efficiency == 0 ? 75 : o.pump_efficiency
	hyd.ecost, p.dcost = o.energy_price, o.demand_charge
	if len(o.energy_pattern) > 0 {
		pat := findpattern(p, o.energy_pattern)
		if pat < 0 {
			b.err = .Undefined_Pattern
			return
		}
		hyd.epat = pat
	}
	p.map_fname = strings.clone(o.map_file)
	p.out.hyd_fname = strings.clone(o.hydraulics_file)
	p.out.hydflag = o.hydraulics

	t := &p.times
	mt := &m.times
	t.dur, t.hstep, t.qstep, t.pstep, t.pstart = mt.duration, mt.hydraulic_step, mt.quality_step, mt.pattern_step, mt.pattern_start
	t.rstep, t.rstart, t.rulestep, t.tstart = mt.report_step, mt.report_start, mt.rule_step, mt.start_clocktime
	if t.hstep == 0 do t.hstep = 3600
	if t.pstep == 0 do t.pstep = 3600
	if t.rstep == 0 do t.rstep = 3600

	r := &p.rpt
	mr := &m.report
	r.tstat = mt.statistic
	r.page_size, r.summary, r.messages, r.status, r.energy = mr.page_size, mr.summary, mr.messages, mr.status, mr.energy
	r.nodes, r.links = mr.nodes, mr.links
	for f in Field {
		fld := mr.fields[f]
		r.fields[f].enabled, r.fields[f].precision, r.fields[f].lo, r.fields[f].hi = fld.enabled, fld.precision, fld.lo, fld.hi
	}
	r.rpt2_fname = strings.clone(mr.file)
	for s, i in m.title do p.title[i] = strings.clone(clip(s, TITLELEN))
	p.aux = make([]string, len(m.aux))
	for s, i in m.aux do p.aux[i] = strings.clone(s)

	finish_project(p)
	return
}
