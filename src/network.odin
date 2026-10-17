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

MISSING : f64 : -1e10 // a setting that is not set
TINY : f64 : 1e-6
CBIG : f64 : 1e8 // a huge resistance: a closed link
CSMALL : f64 : 1e-6 // a tiny resistance: an open valve

// Curve is a table of points, 0-based, x ascending.
Curve :: struct {
	x, y: []f64,
}

// Network is the model as the hydraulic solver reads it.
Network :: struct {
	nnodes, njuncs, nlinks, npumps, nvalves: int,

	// nodes: elevation, emitter coefficient
	el, ke:                                  []f64,

	// links
	link_type:                               []Link_Type,
	n1, n2:                                  []i32,
	diam, km, kc, r:                         []f64, // diameter, minor loss, roughness/setting, resistance
	link_pump, link_valve:                   []i32, // the pump or valve a link is, 0 for none

	// pumps
	pump_type:                               []Pump_Type,
	pump_hcurve:                             []i32,
	pump_h0, pump_r, pump_n:                 []f64, // head curve: h = h0 - r·q^n

	// valves
	valve_link, valve_curve:                 []i32,
	curves:                                  []Curve,

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

	// nodes
	head:                      []f64,
	demand_flow, full_demand:  []f64,
	emitter_flow, xflow:       []f64, // xflow: inflow − outflow at the node

	// links
	flow, setting:             []f64,
	status:                    []Status,
	p, y:                      []f64, // 1/gradient and loss/gradient per link
}

// Matrix is the linear system the coefficients fill, plus the maps from
// the network into it (see Sparse).
Matrix :: struct {
	aii, aij, f: []f64,
	row, ndx:    []i32,
}
