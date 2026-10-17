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
CBIG : f64 : 1e8 // a huge resistance: a closed link
CSMALL : f64 : 1e-6 // a tiny resistance: an open valve

// Curve is a table of points, 0-based, x ascending.
Curve :: struct {
	x, y: []f64,
}

// Network is the model as the hydraulic solver reads it.
Network :: struct {
	nnodes, njuncs, nlinks:                  int,
	ntanks, npumps, nvalves, ncontrols:      int,

	// nodes: elevation, emitter coefficient, leak coefficients (junctions)
	el, ke:                                  []f64,
	leak_cfa, leak_cva:                      []f64,

	// links
	link_type:                               []Link_Type,
	n1, n2:                                  []i32,
	diam, km, kc, r:                         []f64, // diameter, minor loss, roughness/setting, resistance
	link_pump, link_valve:                   []i32, // the pump or valve a link is, 0 for none

	// tanks and reservoirs: tank i is node njuncs + i; a reservoir has no area
	tank_area, tank_hmin, tank_hmax:         []f64,
	tank_overflow:                           []b32,

	// pumps
	pump_type:                               []Pump_Type,
	pump_hcurve:                             []i32,
	pump_h0, pump_r, pump_n:                 []f64, // head curve: h = h0 - r·q^n
	pump_hmax:                               []f64, // shutoff head

	// valves
	valve_link, valve_curve:                 []i32,
	curves:                                  []Curve,

	// simple controls on junction pressure (the tank and time ones act
	// between time steps, not inside the solver)
	control_link, control_node:              []i32,
	control_type:                            []Control_Type,
	control_grade, control_setting:          []f64,
	control_status:                          []Status,

	// unit conversion: curves are stored in user units
	ucf_flow, ucf_head:                      f64,
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
	status_report:             bool, // the full status report is on (hooks get called)

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
	p, y:                      []f64, // 1/gradient and loss/gradient per link
}

// Hooks are the lines of the status report, which the solver still
// leaves to C's report writer. ctx goes back with every call.
Hooks :: struct {
	ctx:              rawptr,
	write_relerr:     proc "c" (ctx: rawptr, iter: i32, relerr: f64),
	write_statchange: proc "c" (ctx: rawptr, link: i32, old, new: Status),
	write_hyderr:     proc "c" (ctx: rawptr, node: i32),
	write_hydbal:     proc "c" (ctx: rawptr, flow_change, head_error: f64, qlink, qnode, hlink: i32),
	write_badvalve:   proc "c" (ctx: rawptr, link: i32),
}
