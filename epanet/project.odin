package epanet

// project.odin — a project the package owns: the network, the solver
// state, the clock, the quality settings and the names, allocated from
// what the input file holds. Everything the engine runs over lives here;
// the reader (parse.odin) fills it, the converter (units.odin) puts it in
// internal units, the validator (validate.odin) checks it. Everything a
// project holds comes out of its own arena, so project_free is one call.


// Field numbers EPANET's reported variables; ucf[field] converts the
// internal value to the user's units.
Field :: enum {
	ELEV, DEMAND, HEAD, PRESSURE, QUALITY,
	LENGTH, DIAM, FLOW, VELOCITY, HEADLOSS, LINKQUAL, STATUS, SETTING, REACTRATE, FRICTION,
	POWER, TIME, VOLUME, CLOCKTIME, FILLTIME, DRAINTIME,
}

Flow_Units :: enum i32 {
	CFS, GPM, MGD, IMGD, AFD, LPS, LPM, MLD, CMH, CMD, CMS,
}

Pressure_Units :: enum i32 {
	PSI, KPA, METERS, BAR, FEET, DEFAULTUNIT,
}

Units_System :: enum i32 {
	US, SI,
}

Curve_Type :: enum i32 {
	VOLUME_CURVE, PUMP_CURVE, EFFIC_CURVE, HLOSS_CURVE, GENERIC_CURVE, VALVE_CURVE,
}

Time_Stat :: enum i32 {
	SERIES, AVG, MIN, MAX, RANGE,
}

Hyd_File :: enum i32 {
	USE, SAVE, SCRATCH,
}

// Report_Field is how one reported variable prints.
Report_Field :: struct {
	name, units: string,
	enabled:     bool,
	precision:   int,
	lo, hi:      f64, // only values outside are reported
}

// Report_Options are the [REPORT] section and the report file as it is
// being written (report.odin).
Report_Options :: struct {
	page_size:                 int,
	summary, messages, energy: bool,
	status:                    int, // 0 no, 1 yes, 2 full
	nodes, links:              int, // 0 none, 1 all, 2 those flagged
	tstat:                     Time_Stat,
	fields:                    [Field]Report_Field,
	rpt1_fname, rpt2_fname:    string,
	// the file in progress
	file:                      File,
	rptflag:                   bool, // the formatted report is wanted
	fprinterr:                 bool, // a write failed
	page_num, line_num:        int,
	nperiods:                  int, // reporting periods saved so far
	callback:                  proc "c" (user: rawptr, pr: rawptr, line: cstring), // takes every line instead of the file
	callback_user:             rawptr,
}

// Outfile is the binary output file and the hydraulics file (output.odin).
Outfile :: struct {
	hyd_fname, out_fname:                string,
	outflag, hydflag:                    Hyd_File,
	save_hflag, save_qflag, saveflag:    bool,
	hyd_offset, out_offset1, out_offset2: i64,
	out_file, hyd_file, tmp_out_file:    File,
}

Project :: struct {
	arena: Arena, // every allocation below lives here (arena.odin)
	net:   Network,
	hyd:   Hydraulics,
	m:     Smatrix,
	q:     Quality,
	times: Times,
	rpt:   Report_Options,
	out:   Outfile,
	fb:    Flow_Balance,

	title:                        [3]string,
	node_id, link_id:             []string,
	pattern_id, curve_id:         []string,
	rule_label:                   []string,
	node_x, node_y:               []f64, // MISSING when not given
	node_rpt, link_rpt:           []b32,
	node_comment, link_comment:   []string, // the ;comment on the object's line
	node_tag, link_tag:           []string, // [TAGS]
	pattern_comment:              []string,
	curve_comment:                []string,
	demand_name:                  []string, // per demand slot, beside net.demand_base
	vertex_x, vertex_y:           [][]f64, // a link's bends, nil when none
	curve_type:                   []Curve_Type,
	pump_qmax:                    []f64,
	units:                        Units_System,
	flow_units:                   Flow_Units,
	pressure_units:               Pressure_Units,
	inp_fname, map_fname:         string,
	aux:                          []string, // the [LABELS] and [BACKDROP] sections, line by line as read
	problems:                     []Problem, // the lines the reader could not take
	tmp_hyd_fname, tmp_out_fname: string, // scratch files
	tmp_stat_fname:               string,
	warnflag:                     int, // the last run's warning code
	openflag, open_hflag:         bool, // a network is loaded; the hydraulic solver is open
	chem_name, chem_units:        string,
	def_pat_id:                   string,
	kbulk, kwall, rfactor:        f64, // global reaction coefficients, per day until converted
	dcost:                        f64, // energy demand charge
	ucf:                          [Field]f64,
	nodes_by_id, links_by_id:     map[string]i32,
	patterns_by_id, curves_by_id: map[string]i32,

	// what the reader counted, which sizes the arrays
	max_juncs, max_tanks, max_links, max_pumps, max_valves, max_controls: int,
}

// project_free gives back everything the project holds.
project_free :: proc(p: ^Project) {
	arena_destroy(&p.arena)
	free(p)
}

// project_alloc sizes every table from the counts the first pass made.
// Patterns, curves and rules grow as they are read.
project_alloc :: proc(p: ^Project) {
	nn := p.max_juncs + p.max_tanks
	nl := p.max_links
	nt, np, nv, nk := p.max_tanks, p.max_pumps, p.max_valves, p.max_controls
	net, hyd, q := &p.net, &p.hyd, &p.q

	p.node_id = make([]string, nn + 1)
	p.link_id = make([]string, nl + 1)
	p.node_x = make([]f64, nn + 1)
	p.node_y = make([]f64, nn + 1)
	p.node_rpt = make([]b32, nn + 1)
	p.link_rpt = make([]b32, nl + 1)
	p.node_comment = make([]string, nn + 1)
	p.link_comment = make([]string, nl + 1)
	p.node_tag = make([]string, nn + 1)
	p.link_tag = make([]string, nl + 1)
	p.vertex_x = make([][]f64, nl + 1)
	p.vertex_y = make([][]f64, nl + 1)
	p.pump_qmax = make([]f64, np + 1)

	net.el = make([]f64, nn + 1)
	net.ke = make([]f64, nn + 1)
	net.leak_cfa = make([]f64, nn + 1)
	net.leak_cva = make([]f64, nn + 1)
	net.node_type = make([]Node_Type, nn + 1)
	net.c0 = make([]f64, nn + 1)
	net.has_source = make([]b32, nn + 1)
	net.source_type = make([]Source_Type, nn + 1)
	net.source_c0 = make([]f64, nn + 1)
	net.source_pat = make([]i32, nn + 1)
	net.demand_first = make([]i32, nn + 2)

	net.link_type = make([]Link_Type, nl + 1)
	net.n1 = make([]i32, nl + 1)
	net.n2 = make([]i32, nl + 1)
	net.diam = make([]f64, nl + 1)
	net.len = make([]f64, nl + 1)
	net.km = make([]f64, nl + 1)
	net.kc = make([]f64, nl + 1)
	net.r = make([]f64, nl + 1)
	net.link_kb = make([]f64, nl + 1)
	net.link_kw = make([]f64, nl + 1)
	net.link_pump = make([]i32, nl + 1)
	net.link_valve = make([]i32, nl + 1)
	net.init_status = make([]Status, nl + 1)
	net.init_setting = make([]f64, nl + 1)
	net.leak_area = make([]f64, nl + 1)
	net.leak_expan = make([]f64, nl + 1)

	net.tank_node = make([]i32, nt + 1)
	net.tank_area = make([]f64, nt + 1)
	net.tank_hmin = make([]f64, nt + 1)
	net.tank_hmax = make([]f64, nt + 1)
	net.tank_vmin = make([]f64, nt + 1)
	net.tank_vmax = make([]f64, nt + 1)
	net.tank_pat = make([]i32, nt + 1)
	net.tank_vcurve = make([]i32, nt + 1)
	net.tank_overflow = make([]b32, nt + 1)
	net.tank_h0 = make([]f64, nt + 1)
	net.tank_v0 = make([]f64, nt + 1)
	net.tank_v1frac = make([]f64, nt + 1)
	net.tank_kb = make([]f64, nt + 1)
	net.tank_mix = make([]Mix_Model, nt + 1)

	net.pump_link = make([]i32, np + 1)
	net.pump_type = make([]Pump_Type, np + 1)
	net.pump_hcurve = make([]i32, np + 1)
	net.pump_ecurve = make([]i32, np + 1)
	net.pump_h0 = make([]f64, np + 1)
	net.pump_r = make([]f64, np + 1)
	net.pump_n = make([]f64, np + 1)
	net.pump_hmax = make([]f64, np + 1)
	net.pump_q0 = make([]f64, np + 1)
	net.pump_upat = make([]i32, np + 1)
	net.pump_epat = make([]i32, np + 1)
	net.pump_ecost = make([]f64, np + 1)

	net.valve_link = make([]i32, nv + 1)
	net.valve_curve = make([]i32, nv + 1)

	net.control_link = make([]i32, nk + 1)
	net.control_node = make([]i32, nk + 1)
	net.control_type = make([]Control_Type, nk + 1)
	net.control_grade = make([]f64, nk + 1)
	net.control_setting = make([]f64, nk + 1)
	net.control_status = make([]Status, nk + 1)
	net.control_time = make([]i64, nk + 1)
	net.control_enabled = make([]b32, nk + 1)

	hyd.head = make([]f64, nn + 1)
	hyd.node_demand = make([]f64, nn + 1)
	hyd.demand_flow = make([]f64, nn + 1)
	hyd.full_demand = make([]f64, nn + 1)
	hyd.emitter_flow = make([]f64, nn + 1)
	hyd.leak_flow = make([]f64, nn + 1)
	hyd.leak_qfa = make([]f64, nn + 1)
	hyd.leak_qva = make([]f64, nn + 1)
	hyd.flow = make([]f64, nl + 1)
	hyd.setting = make([]f64, nl + 1)
	hyd.status = make([]Status, nl + 1)
	hyd.tank_volume = make([]f64, nt + 1)
	hyd.energy = make([]Pump_Energy, np + 1)
	hyd.flow_balance = &p.fb
	q.node_qual = make([]f64, nn + 1)
	q.tank_c = make([]f64, nt + 1)
}
