package epanet

// text.odin — what the engine says and the line it says it on, shared by
// every build: the names of things, a line being built (EPANET's
// fixed-width report line), the clock as h:mm:ss, and the one report
// routine the step itself needs, writehydwarn, which decides the run's
// warning code and only then writes. The report file proper is
// report.odin, which the wasm build leaves out (report_wasm.odin stubs
// what the step calls there).

NODE_TEXT := [?]string{"Junction", "Reservoir", "Tank"}
LINK_TEXT := [Link_Type]string {
	.CVPIPE = "CV", .PIPE = "Pipe", .PUMP = "Pump", .PRV = "PRV", .PSV = "PSV",
	.PBV = "PBV", .FCV = "FCV", .TCV = "TCV", .GPV = "GPV", .PCV = "PCV",
}
STATUS_TEXT := [Status]string {
	.XHEAD = "closed because cannot deliver head", .TEMPCLOSED = "temporarily closed",
	.CLOSED = "closed", .OPEN = "open", .ACTIVE = "active",
	.XFLOW = "open but exceeds maximum flow", .XFCV = "open but cannot deliver flow",
	.XPRESSURE = "open but cannot deliver pressure",
	.FILLING = "filling", .EMPTYING = "emptying", .OVERFLOWING = "overflowing",
}
FORMULA_TEXT := [Headloss_Formula]string{.HW = "Hazen-Williams", .DW = "Darcy-Weisbach", .CM = "Chezy-Manning"}
DEMAND_MODEL_TEXT := [Demand_Model]string{.DDA = "DDA", .PDA = "PDA"}
TSTAT_TEXT := [Time_Stat]string{.SERIES = "NONE", .AVG = "AVERAGE", .MIN = "MINIMUM", .MAX = "MAXIMUM", .RANGE = "RANGE"}

// the rule words the Model's rule text and the .inp writer share
INP_RULE_VARIABLE := [Rule_Variable]string {
	.DEMAND = "DEMAND", .HEAD = "HEAD", .GRADE = "GRADE", .LEVEL = "LEVEL", .PRESSURE = "PRESSURE",
	.FLOW = "FLOW", .STATUS = "STATUS", .SETTING = "SETTING", .POWER = "POWER", .TIME = "TIME",
	.CLOCKTIME = "CLOCKTIME", .FILLTIME = "FILLTIME", .DRAINTIME = "DRAINTIME",
}
INP_RULE_OPERATOR := [Rule_Op]string {
	.EQ = "=", .NE = "<>", .LE = "<=", .GE = ">=", .LT = "<", .GT = ">",
	.IS = "IS", .NOT = "NOT", .BELOW = "BELOW", .ABOVE = "ABOVE",
}
INP_RULE_VALUE := [Rule_Status]string{.IS_NUMBER = "XXXX", .IS_OPEN = "OPEN", .IS_CLOSED = "CLOSED", .IS_ACTIVE = "ACTIVE"}

rule_object_text :: proc "contextless" (p: ^Project, object: Rule_Object, index: i32) -> string {
	net := &p.net
	#partial switch object {
	case .NODE:
		switch node_type_of(net, int(index)) {
		case 0:
			return "JUNCTION"
		case 1:
			return "RESERVOIR"
		case 2:
			return "TANK"
		}
		return "NODE"
	case .LINK:
		#partial switch net.link_type[index] {
		case .CVPIPE, .PIPE:
			return "PIPE"
		case .PUMP:
			return "PUMP"
		}
		return "VALVE"
	}
	return "SYSTEM"
}


// ── a line being built ────────────────────────────────────────────────

Line :: struct {
	buf: [MAXLINE + 1]u8,
	n:   int,
}

line_str :: #force_inline proc "contextless" (l: ^Line) -> string {
	return string(l.buf[:l.n])
}

line_reset :: #force_inline proc "contextless" (l: ^Line) {
	l.n = 0
	l.buf[0] = 0
}

// puts appends s, at most max bytes of it when max >= 0 (%.70s).
puts :: proc "contextless" (l: ^Line, s: string, max := -1) {
	n := len(s)
	if max >= 0 && n > max do n = max
	if l.n + n > MAXLINE do n = MAXLINE - l.n
	copy(l.buf[l.n:l.n + n], s[:n])
	l.n += n
	l.buf[l.n] = 0
}

// puts_right / puts_left: s in a field of width w (%10s / %-15s).
puts_right :: proc "contextless" (l: ^Line, s: string, w: int) {
	for _ in len(s) ..< w do puts(l, " ")
	puts(l, s)
}
puts_left :: proc "contextless" (l: ^Line, s: string, w: int, max := -1) {
	n := len(s)
	if max >= 0 && n > max do n = max
	puts(l, s, max)
	for _ in n ..< w do puts(l, " ")
}

// fill: n+1 of ch (EPANET's fillstr writes one more than asked).
fill :: proc "contextless" (l: ^Line, ch: u8, n: int) {
	line_reset(l)
	for _ in 0 ..= n do puts(l, string([]u8{ch}))
}

// clocktime: seconds as h:mm:ss (%01d:%02d:%02d), in the caller's buffer.
clocktime :: proc "contextless" (buf: ^[16]u8, seconds: i64) -> string {
	h := seconds / 3600
	m := seconds % 3600 / 60
	s := seconds - 3600 * h - 60 * m
	n := put_int(buf[:], 0, h, 1)
	buf[n] = ':'
	n = put_int(buf[:], n + 1, m, 2)
	buf[n] = ':'
	n = put_int(buf[:], n + 1, s, 2)
	return string(buf[:n])
}

// put_int writes x at buf[at:], zero-padded to width w (a minus sign
// counts), and returns where it ended.
put_int :: proc "contextless" (buf: []u8, at: int, x: i64, w: int) -> int {
	digits: [20]u8
	nd := 0
	v := x < 0 ? -x : x
	for {
		digits[nd] = u8('0' + v % 10)
		nd += 1
		v /= 10
		if v == 0 do break
	}
	n := at
	if x < 0 && n < len(buf) {
		buf[n] = '-'
		n += 1
	}
	for _ in nd + (x < 0 ? 1 : 0) ..< w {
		if n < len(buf) {
			buf[n] = '0'
			n += 1
		}
	}
	for i := nd - 1; i >= 0; i -= 1 {
		if n < len(buf) {
			buf[n] = digits[i]
			n += 1
		}
	}
	return n
}

node_type_of :: proc "contextless" (net: ^Network, i: int) -> int {
	if i <= net.njuncs do return 0
	if net.tank_area[i - net.njuncs] == 0 do return 1
	return 2
}

// ── the run's warning ─────────────────────────────────────────────────

// writehydwarn names what the solve left short (the trials, negative
// pressures, valves and pumps that could not deliver, a system that did
// not balance) and returns the warning code; the messages go to the
// report when there is one.
writehydwarn :: proc "contextless" (p: ^Project, iter: int, relerr: f64) -> int {
	net, hyd, r := &p.net, &p.hyd, &p.rpt
	l: Line
	abuf: [16]u8
	flag := 0
	if iter > hyd.max_iter && relerr <= hyd.hacc {
		if r.messages {
			puts(&l, "WARNING: Maximum trials exceeded at ")
			puts(&l, clocktime(&abuf, p.times.htime))
			puts(&l, " hrs. System may be unstable.")
			writeline(p, line_str(&l))
		}
		flag = 2
	}
	if hyd.demand_model == .DDA {
		hyd.deficient_nodes = 0
		for i in 1 ..= net.njuncs {
			if hyd.head[i] < net.el[i] && hyd.node_demand[i] > 0 do hyd.deficient_nodes += 1
		}
		if hyd.deficient_nodes > 0 {
			if r.messages {
				line_reset(&l)
				puts(&l, "WARNING: Negative pressures at ")
				puts(&l, clocktime(&abuf, p.times.htime))
				puts(&l, " hrs.")
				writeline(p, line_str(&l))
			}
			flag = 6
		}
	}
	for i in 1 ..= net.nvalves {
		j := int(net.valve_link[i])
		if hyd.status[j] >= .XFCV {
			if r.messages {
				line_reset(&l)
				puts(&l, "WARNING: ")
				puts(&l, LINK_TEXT[net.link_type[j]])
				puts(&l, " ")
				puts(&l, p.link_id[j])
				puts(&l, " ")
				puts(&l, STATUS_TEXT[hyd.status[j]])
				puts(&l, " at ")
				puts(&l, clocktime(&abuf, p.times.htime))
				puts(&l, " hrs.")
				writeline(p, line_str(&l))
			}
			flag = 5
		}
	}
	for i in 1 ..= net.npumps {
		j := int(net.pump_link[i])
		s := hyd.status[j]
		if s >= .OPEN {
			if hyd.flow[j] > hyd.setting[j] * p.pump_qmax[i] do s = .XFLOW
			if hyd.flow[j] < 0 do s = .XHEAD
		}
		if s == .XHEAD || s == .XFLOW {
			if r.messages {
				line_reset(&l)
				puts(&l, "WARNING: Pump ")
				puts(&l, p.link_id[j])
				puts(&l, " ")
				puts(&l, STATUS_TEXT[s])
				puts(&l, " at ")
				puts(&l, clocktime(&abuf, p.times.htime))
				puts(&l, " hrs.")
				writeline(p, line_str(&l))
			}
			flag = 4
		}
	}
	if iter > hyd.max_iter && relerr > hyd.hacc {
		if r.messages {
			line_reset(&l)
			puts(&l, "WARNING: System unbalanced at ")
			puts(&l, clocktime(&abuf, p.times.htime))
			puts(&l, " hrs.")
			if hyd.extra_iter == -1 do puts(&l, " EXECUTION HALTED.")
			writeline(p, line_str(&l))
		}
		flag = 1
	}
	if flag > 0 {
		disconnected(p)
		p.warnflag = flag
		if r.messages do writeline(p, " ")
	}
	return flag
}

