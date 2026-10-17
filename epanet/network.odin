package epanet

// network.odin — the model and the solver's state, one array per field.
//
// EPANET keeps a struct per node, link, pump and valve. Here each field is
// its own slice, indexed the way EPANET indexes (1-based; slot 0 unused),
// so a loop over links touches only the fields it reads. Curves are the
// one nested thing: a pump or valve points at one by index.
//
// The enums carry EPANET's values, since the bridge passes them as ints.

Link_Type :: enum i32 {
	CVPIPE, // pipe with check valve
	PIPE,
	PUMP,
	PRV, // pressure reducing valve
	PSV, // pressure sustaining valve
	PBV, // pressure breaker valve
	FCV, // flow control valve
	TCV, // throttle control valve
	GPV, // general purpose valve
	PCV, // positional control valve
}

Status :: enum i32 {
	XHEAD, // pump cannot deliver head (closed)
	TEMPCLOSED,
	CLOSED,
	OPEN,
	ACTIVE, // valve active (partially open)
	XFLOW, // pump exceeds maximum flow
	XFCV, // FCV cannot supply flow
	XPRESSURE, // valve cannot supply pressure
	FILLING,
	EMPTYING,
	OVERFLOWING,
}

Pump_Type :: enum i32 {
	CONST_HP,
	POWER_FUNC,
	CUSTOM,
	NOCURVE,
}

Headloss_Formula :: enum i32 {
	HW, // Hazen-Williams
	DW, // Darcy-Weisbach
	CM, // Chezy-Manning
}

Demand_Model :: enum i32 {
	DDA, // demand driven
	PDA, // pressure driven
}

Node_Type :: enum i32 {
	JUNCTION,
	RESERVOIR,
	TANK,
}

Qual_Type :: enum i32 {
	NONE,
	CHEM, // a chemical
	AGE, // water age
	TRACE, // percent of flow from one node
}

Source_Type :: enum i32 {
	CONCEN, // inflow concentration
	MASS, // mass inflow booster
	SETPOINT, // setpoint booster
	FLOWPACED, // flow paced booster
}

Mix_Model :: enum i32 {
	MIX1, // complete mix
	MIX2, // two compartments
	FIFO,
	LIFO,
}

// A rule premise: IF/AND/OR <object> <variable> <relop> <value or status>.
Rule_Object :: enum i32 {
	JUNC, RESERV, TANK, PIPE, PUMP, VALVE, NODE, LINK, SYSTEM,
}
Rule_Variable :: enum i32 {
	DEMAND, HEAD, GRADE, LEVEL, PRESSURE, FLOW, STATUS, SETTING, POWER, TIME, CLOCKTIME, FILLTIME, DRAINTIME,
}
Rule_Op :: enum i32 {
	EQ, NE, LE, GE, LT, GT, IS, NOT, BELOW, ABOVE,
}
Rule_Logic :: enum i32 {
	RULE, IF, AND, OR, THEN, ELSE, PRIORITY, DISABLED, ERROR,
}
Rule_Status :: enum i32 {
	IS_NUMBER, IS_OPEN, IS_CLOSED, IS_ACTIVE,
}

Control_Type :: enum i32 {
	LOWLEVEL, // act when grade falls below a level
	HILEVEL, // act when grade rises above a level
	TIMER,
	TIMEOFDAY,
}

MISSING : f64 : -1e10 // a setting that is not set
TINY : f64 : 1e-6
BIG : f64 : 1e10
MINPDIFF : f64 : 0.1 // least PDA pressure range (psi or m)
QZERO : f64 : 1e-6 // as good as no flow (cfs)
Q_STAGNANT : f64 : 0.005 / 448.831 // 0.005 gpm in cfs: no flow, for quality
L_PER_FT3 : f64 : 28.317
KW_PER_HP : f64 : 0.7457
SEC_PER_DAY :: 86400
CBIG : f64 : 1e8 // a huge resistance: a closed link
CSMALL : f64 : 1e-6 // a tiny resistance: an open valve

// Curve is a table of points, 0-based, x ascending.
Curve :: struct {
	x, y: []f64,
}

// Pattern is a cycle of multipliers, one per pattern time step.
Pattern :: struct {
	f: []f64,
}

// Pump_Energy is one pump's running energy statistics.
Pump_Energy :: struct {
	time_on_line:   f64, // hours
	efficiency:     f64, // time-weighted
	kwhrs_per_flow: f64,
	kwhrs:          f64,
	max_kwatts:     f64,
	total_cost:     f64,
	current_power:  f64, // kW
	current_effic:  f64,
}

// Flow_Balance is the run's account of water in and out, laid out as
// EPANET's.
Flow_Balance :: struct {
	total_inflow, total_outflow:     f64,
	consumer_demand, emitter_demand: f64,
	leakage_demand, deficit_demand:  f64,
	storage_demand, ratio:           f64,
}

// Times is the simulation clock, in seconds, laid out as EPANET's.
Times :: struct {
	tstart:   i64, // starting time of day
	hstep:    i64, // nominal hydraulic step
	pstep:    i64, // pattern step
	pstart:   i64, // starting pattern time
	rstep:    i64, // reporting step
	rstart:   i64,
	rtime:    i64, // next reporting time
	htime:    i64, // current hydraulic time
	hydstep:  i64, // the step actually taken
	qstep:    i64,
	qtime:    i64,
	rulestep: i64, // rule evaluation step
	dur:      i64, // duration
}

// Network is the model as the hydraulic solver reads it.
Network :: struct {
	nnodes, njuncs, nlinks:                  int,
	ntanks, npumps, nvalves, ncontrols:      int,

	// nodes: elevation, emitter coefficient, leak coefficients (junctions)
	el, ke:                                  []f64,
	leak_cfa, leak_cva:                      []f64,
	node_type:                               []Node_Type,
	c0:                                      []f64, // initial quality
	// a node's quality source, if has_source
	has_source:                              []b32,
	source_type:                             []Source_Type,
	source_c0:                               []f64,
	source_pat:                              []i32,

	// adjacency: node i's links are adj_link[adj_first[i] ..< adj_first[i+1]],
	// adj_node the node at the other end, in EPANET's list order
	adj_first, adj_link, adj_node:           []i32,

	// demands: node i's are demand_base[demand_first[i] ..< demand_first[i+1]]
	demand_first:                            []i32,
	demand_base:                             []f64,
	demand_pat:                              []i32,
	def_pat:                                 int, // the pattern a demand without one uses

	// links
	link_type:                               []Link_Type,
	n1, n2:                                  []i32,
	diam, len, km, kc, r:                    []f64, // diameter, length, minor loss, roughness/setting, resistance
	link_kb, link_kw:                        []f64, // bulk and wall reaction coefficients
	link_pump, link_valve:                   []i32, // the pump or valve a link is, 0 for none
	init_status:                             []Status,
	init_setting:                            []f64,
	leak_area, leak_expan:                   []f64, // pipe leak area and its growth with head

	// tanks and reservoirs: tank i is node njuncs + i; a reservoir has no area
	tank_node:                               []i32,
	tank_area, tank_hmin, tank_hmax:         []f64,
	tank_vmin, tank_vmax:                    []f64,
	tank_pat, tank_vcurve:                   []i32, // a reservoir's head pattern; a tank's volume curve
	tank_overflow:                           []b32,
	tank_h0, tank_v0, tank_v1frac, tank_kb:  []f64, // initial level and volume, mixing-zone fraction, bulk coefficient
	tank_mix:                                []Mix_Model,

	// pumps
	pump_link:                               []i32,
	pump_type:                               []Pump_Type,
	pump_hcurve, pump_ecurve:                []i32,
	pump_h0, pump_r, pump_n:                 []f64, // head curve: h = h0 - r·q^n
	pump_hmax:                               []f64, // shutoff head
	pump_q0:                                 []f64, // initial flow
	pump_upat, pump_epat:                    []i32, // utilization and energy-price patterns
	pump_ecost:                              []f64, // the pump's own energy price, 0 = the global one

	// valves
	valve_link, valve_curve:                 []i32,
	curves:                                  []Curve,
	patterns:                                []Pattern, // [0] is a single 1.0, for demands without one

	// simple controls: on a junction's pressure (checked inside the
	// solver), on a tank's level or the clock (between time steps)
	control_link, control_node:              []i32,
	control_type:                            []Control_Type,
	control_grade, control_setting:          []f64,
	control_status:                          []Status,
	control_time:                            []i64,
	control_enabled:                         []b32,

	// rules: rule i's premises are premise_*[rule_premise_first[i] ..<
	// rule_premise_first[i+1]], its THEN actions action_*[rule_then_first[i]
	// ..< rule_else_first[i]] and its ELSE actions on to rule_then_first[i+1]
	nrules:                                  int,
	rule_priority:                           []f64,
	rule_enabled:                            []b32,
	rule_premise_first:                      []i32,
	rule_then_first, rule_else_first:        []i32,
	premise_logop:                           []Rule_Logic,
	premise_object:                          []Rule_Object,
	premise_index:                           []i32,
	premise_variable:                        []Rule_Variable,
	premise_relop:                           []Rule_Op,
	premise_status:                          []Rule_Status,
	premise_value:                           []f64,
	action_link:                             []i32,
	action_status:                           []Rule_Status,
	action_setting:                          []f64,

	// unit conversion: curves are stored in user units
	ucf_flow, ucf_head, ucf_volume:          f64,
	ucf_quality, ucf_elev:                   f64,
	ucf_demand, ucf_pressure:                f64,
}

// Hydraulics is the solver's settings and state over nodes and links.
Hydraulics :: struct {
	formflag:                  Headloss_Formula,
	demand_model:              Demand_Model,
	emit_backflow:             bool,
	has_leakage:               bool,
	hexp, qexp, pexp:          f64, // head loss, emitter and demand exponents
	pmin, preq:                f64, // PDA pressure range
	rqtol:                     f64, // resistance below which head loss is linear
	viscos:                    f64,
	htol, qtol:                f64, // head and flow tolerances for status checks
	hacc:                      f64, // relative flow change that counts as converged
	head_error_limit:          f64, // 0 = not checked
	flow_change_limit:         f64, // 0 = not checked
	damp_limit:                f64, // relax to 60 % once the error is under this; 0 = never
	max_iter, extra_iter:      int, // trials, and extra trials with statuses frozen
	check_freq, max_check:     int, // status checks every check_freq trials up to max_check
	relax:                     f64, // the relaxation factor in force
	// what the last solve reported
	relative_error:            f64, // total flow change over total flow
	max_head_error:            f64,
	max_flow_change:           f64,
	iterations:                int,
	deficient_nodes:           int, // PDA: junctions short of their demand
	demand_reduction:          f64, // PDA: % of demand not met at those
	status_report:             bool, // the full status report is on (hooks get called)
	status_report_any:         bool, // any status report is on
	dmult:                     f64, // demand multiplier
	spgrav, epump:             f64, // specific gravity; global pump efficiency (%)
	ecost:                     f64, // energy price
	epat:                      int, // energy price pattern
	dsystem:                   f64, // total demand this period
	emax:                      f64, // peak power so far
	leakage_loss:              f64, // % of inflow lost to leaks this period
	haltflag:                  bool, // stop: the system would not balance
	saveflag, openqflag:       bool, // results go to the hydraulics file; quality is open
	flow_balance:              ^Flow_Balance,

	// nodes
	head:                      []f64,
	node_demand:               []f64, // total outflow; at a tank, net inflow
	demand_flow, full_demand:  []f64,
	emitter_flow, leak_flow:   []f64,
	leak_qfa, leak_qva:        []f64, // the two halves of leak_flow
	xflow:                     []f64, // inflow − outflow at the node

	// links
	flow, setting:             []f64,
	status:                    []Status,
	old_status:                []Status, // links then tanks, as of the last report
	p, y:                      []f64, // 1/gradient and loss/gradient per link

	// tanks and pumps
	tank_volume:               []f64,
	energy:                    []Pump_Energy,
}
