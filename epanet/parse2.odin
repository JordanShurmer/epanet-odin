package epanet

// parse2.odin — the rest of the section readers (EPANET's input3.c) and
// the rule statements (the parsing half of rules.c).

import "core:strings"

// ── demands, controls, sources ────────────────────────────────────────

demanddata :: proc(ps: ^Parser) -> int {
	p := ps.p
	net := &p.net
	n := ps.ntok
	if n < 2 do return 201
	y, ok := getfloat(ps.tok[1])
	if !ok do return set_error(ps, 1, 202)
	j := findnode(p, ps.tok[0])
	if j == 0 do return set_error(ps, 0, 203)
	if j > net.njuncs do return 0
	pat := 0
	if n >= 3 {
		pat = findpattern(p, ps.tok[2])
		if pat < 0 do return set_error(ps, 2, 205)
	}
	// The first category here replaces the one [JUNCTIONS] made; the
	// node's demand slot is the marker.
	name := kept(ps.comment, MAXID)
	if len(ps.demands[j]) > 0 && p.hyd.node_demand[j] != MISSING {
		ps.demands[j][0] = {y, i32(pat), len(name) > 0 ? name : ps.demands[j][0].name}
		p.hyd.node_demand[j] = MISSING
	} else {
		append(&ps.demands[j], Demand{y, i32(pat), name})
	}
	return 0
}

controldata :: proc(ps: ^Parser) -> int {
	p := ps.p
	net := &p.net
	n := ps.ntok
	if n < 6 do return 201
	enabled := true
	if match(ps.tok[n - 1], "DISABLED") {
		enabled = false
		n -= 1
	}
	k := findlink(p, ps.tok[1])
	if k == 0 do return set_error(ps, 1, 204)
	lt := net.link_type[k]
	if lt == .CVPIPE do return set_error(ps, 1, 207)

	setting := MISSING
	status := Status.ACTIVE
	if match(ps.tok[2], "OPEN") {
		status = .OPEN
		if lt == .PUMP do setting = 1
		if lt == .GPV do setting = net.kc[k]
	} else if match(ps.tok[2], "CLOSED") {
		status = .CLOSED
		if lt == .PUMP do setting = 0
		if lt == .GPV do setting = net.kc[k]
	} else if lt == .GPV {
		return set_error(ps, 1, 207)
	} else {
		x, ok := getfloat(ps.tok[2])
		if !ok do return set_error(ps, 2, 202)
		setting = x
	}
	if lt == .PUMP || lt == .PIPE {
		if setting != MISSING {
			if setting < 0 do return set_error(ps, 2, 211)
			status = setting == 0 ? .CLOSED : .OPEN
		}
	}

	i := 0
	ctype: Control_Type
	if match(ps.tok[4], "TIME") {
		ctype = .TIMER
	} else if match(ps.tok[4], "CLOCKTIME") {
		ctype = .TIMEOFDAY
	} else {
		if n < 8 do return 201
		i = findnode(p, ps.tok[5])
		if i == 0 do return set_error(ps, 5, 203)
		if match(ps.tok[6], "BELOW") {
			ctype = .LOWLEVEL
		} else if match(ps.tok[6], "ABOVE") {
			ctype = .HILEVEL
		} else {
			return set_error(ps, 6, 213)
		}
	}
	time, level := 0.0, 0.0
	switch ctype {
	case .TIMER, .TIMEOFDAY:
		if n == 6 do time = hour(ps.tok[5], "")
		if n >= 7 do time = hour(ps.tok[5], ps.tok[6])
		if time < 0 do return set_error(ps, 5, 213)
	case .LOWLEVEL, .HILEVEL:
		x, ok := getfloat(ps.tok[7])
		if !ok do return set_error(ps, 7, 202)
		level = x
	}
	net.ncontrols += 1
	if net.ncontrols > p.max_controls do return 200
	c := net.ncontrols
	net.control_link[c] = i32(k)
	net.control_node[c] = i32(i)
	net.control_type[c] = ctype
	net.control_status[c] = status
	net.control_setting[c] = setting
	net.control_time[c] = i64(3600 * time)
	if ctype == .TIMEOFDAY do net.control_time[c] %= SEC_PER_DAY
	net.control_grade[c] = level
	net.control_enabled[c] = b32(enabled)
	return 0
}

sourcedata :: proc(ps: ^Parser) -> int {
	p := ps.p
	net := &p.net
	n := ps.ntok
	if n < 2 do return 201
	j := findnode(p, ps.tok[0])
	if j == 0 do return set_error(ps, 0, 203)
	// The old format had no type: then token 1 is the quality.
	i := 2
	t := Source_Type.CONCEN
	switch {
	case match(ps.tok[1], "CONCEN"):
		t = .CONCEN
	case match(ps.tok[1], "MASS"):
		t = .MASS
	case match(ps.tok[1], "SETPOINT"):
		t = .SETPOINT
	case match(ps.tok[1], "FLOWPACED"):
		t = .FLOWPACED
	case:
		i = 1
	}
	c0, ok := getfloat(ps.tok[i])
	if !ok do return set_error(ps, i, i == 1 ? 213 : 202)
	pat := 0
	if n > i + 1 && len(ps.tok[i + 1]) > 0 && ps.tok[i + 1] != "*" {
		pat = findpattern(p, ps.tok[i + 1])
		if pat < 0 do return set_error(ps, i + 1, 205)
	}
	net.has_source[j] = true
	net.source_c0[j] = c0
	net.source_pat[j] = i32(pat)
	net.source_type[j] = t
	return 0
}

emitterdata :: proc(ps: ^Parser) -> int {
	p := ps.p
	if ps.ntok < 2 do return 201
	j := findnode(p, ps.tok[0])
	if j == 0 do return set_error(ps, 0, 203)
	if j > p.net.njuncs do return 0
	k, ok := getfloat(ps.tok[1])
	if !ok do return set_error(ps, 1, 202)
	if k < 0 do return set_error(ps, 1, 209)
	p.net.ke[j] = k
	return 0
}

leakagedata :: proc(ps: ^Parser) -> int {
	p := ps.p
	if ps.ntok < 3 do return 201
	j := findlink(p, ps.tok[0])
	if j == 0 do return set_error(ps, 0, 203)
	if p.net.link_type[j] > .PIPE do return 0
	c1, ok1 := getfloat(ps.tok[1])
	if !ok1 do return set_error(ps, 1, 202)
	if c1 < 0 do return set_error(ps, 1, 209)
	c2, ok2 := getfloat(ps.tok[2])
	if !ok2 do return set_error(ps, 2, 202)
	if c2 < 0 do return set_error(ps, 1, 209)
	p.net.leak_area[j] = c1
	p.net.leak_expan[j] = c2
	return 0
}

// ── ranges: "id1 id2 value" covers every id between, by number when
// both ids are numbers, else by text ──────────────────────────────────

in_range :: proc(id, lo, hi: string, i1, i2: i64) -> bool {
	if i1 > 0 && i2 > 0 {
		i := atol(id)
		return i >= i1 && i <= i2
	}
	return lo <= id && hi >= id
}

qualdata :: proc(ps: ^Parser) -> int {
	p := ps.p
	net := &p.net
	if net.nnodes == 0 do return set_error(ps, 0, 203)
	n := ps.ntok
	if n < 2 do return 0
	if n == 2 {
		j := findnode(p, ps.tok[0])
		if j == 0 do return set_error(ps, 0, 203)
		c0, ok := getfloat(ps.tok[1])
		if !ok do return set_error(ps, 1, 202)
		if c0 < 0 do return set_error(ps, 1, 209)
		net.c0[j] = c0
		return 0
	}
	c0, ok := getfloat(ps.tok[2])
	if !ok do return set_error(ps, 2, 202)
	if c0 < 0 do return set_error(ps, 2, 209)
	i1, i2 := atol(ps.tok[0]), atol(ps.tok[1])
	for j in 1 ..= net.nnodes {
		if in_range(p.node_id[j], ps.tok[0], ps.tok[1], i1, i2) do net.c0[j] = c0
	}
	return 0
}

reactdata :: proc(ps: ^Parser) -> int {
	p := ps.p
	net := &p.net
	q := &p.q
	n := ps.ntok
	if n < 3 do return 0
	if match(ps.tok[0], "ORDER") {
		y, ok := getfloat(ps.tok[n - 1])
		if !ok do return set_error(ps, n - 1, 202)
		if match(ps.tok[1], "BULK") {
			q.bulk_order = y
		} else if match(ps.tok[1], "TANK") {
			q.tank_order = y
		} else if match(ps.tok[1], "WALL") {
			if y == 0 {
				q.wall_order = 0
			} else if y == 1 {
				q.wall_order = 1
			} else {
				return set_error(ps, n - 1, 213)
			}
		} else {
			return set_error(ps, 1, 213)
		}
		return 0
	}
	if match(ps.tok[0], "ROUG") {
		y, ok := getfloat(ps.tok[n - 1])
		if !ok do return set_error(ps, n - 1, 202)
		p.rfactor = y
		return 0
	}
	if match(ps.tok[0], "LIMIT") {
		y, ok := getfloat(ps.tok[n - 1])
		if !ok do return set_error(ps, n - 1, 202)
		q.climit = y
		return 0
	}
	if match(ps.tok[0], "GLOB") {
		y, ok := getfloat(ps.tok[n - 1])
		if !ok do return set_error(ps, n - 1, 202)
		if match(ps.tok[1], "BULK") {
			p.kbulk = y
		} else if match(ps.tok[1], "WALL") {
			p.kwall = y
		} else {
			return set_error(ps, 1, 213)
		}
		return 0
	}
	item: int
	switch {
	case match(ps.tok[0], "BULK"):
		item = 1
	case match(ps.tok[0], "WALL"):
		item = 2
	case match(ps.tok[0], "TANK"):
		item = 3
	case:
		return set_error(ps, 0, 213)
	}
	y, ok := getfloat(ps.tok[n - 1])
	if !ok do return set_error(ps, n - 1, 202)
	if item == 3 {
		if n == 3 {
			j := findnode(p, ps.tok[1])
			if j <= net.njuncs || j - net.njuncs > net.ntanks do return 0 // (as in mixingdata)
			net.tank_kb[j - net.njuncs] = y
			return 0
		}
		i1, i2 := atol(ps.tok[1]), atol(ps.tok[2])
		for j in net.njuncs + 1 ..= net.nnodes {
			if j - net.njuncs > net.ntanks do break
			if in_range(p.node_id[j], ps.tok[1], ps.tok[2], i1, i2) do net.tank_kb[j - net.njuncs] = y
		}
		return 0
	}
	if net.nlinks == 0 do return 0
	if n == 3 {
		j := findlink(p, ps.tok[1])
		if j == 0 do return 0
		if item == 1 do net.link_kb[j] = y
		if item == 2 do net.link_kw[j] = y
		return 0
	}
	i1, i2 := atol(ps.tok[1]), atol(ps.tok[2])
	for j in 1 ..= net.nlinks {
		if in_range(p.link_id[j], ps.tok[1], ps.tok[2], i1, i2) {
			if item == 1 do net.link_kb[j] = y
			if item == 2 do net.link_kw[j] = y
		}
	}
	return 0
}

MIX_NAMES := [?]string{"MIXED", "2COMP", "FIFO", "LIFO"}

mixingdata :: proc(ps: ^Parser) -> int {
	p := ps.p
	net := &p.net
	if net.nnodes == 0 do return set_error(ps, 0, 203)
	n := ps.ntok
	if n < 2 do return 0
	j := findnode(p, ps.tok[0])
	if j == 0 do return set_error(ps, 0, 203)
	if j <= net.njuncs do return 0
	m := findmatch(ps.tok[1], MIX_NAMES[:])
	if m < 0 do return set_error(ps, 1, 213)
	v := 1.0
	if Mix_Model(m) == .MIX2 && n == 3 {
		x, ok := getfloat(ps.tok[2])
		if !ok do return set_error(ps, 2, 202)
		v = x
	}
	if v == 0 do v = 1
	// Until the tanks are re-indexed this is EPANET's arithmetic, which
	// is off (and out of bounds) when junction lines failed; the guard is
	// where EPANET reads past its table.
	i := j - net.njuncs
	if i > net.ntanks do return 0
	if net.tank_area[i] == 0 do return 0
	net.tank_mix[i] = Mix_Model(m)
	net.tank_v1frac[i] = v
	return 0
}

// changestatus: a link's initial status or setting from [STATUS];
// ACTIVE means a number was given.
changestatus :: proc(net: ^Network, j: int, status0: Status, y: f64) {
	status := status0
	t := net.link_type[j]
	if t == .PIPE || t == .GPV {
		if status != .ACTIVE do net.init_status[j] = status
	} else if t == .PUMP {
		if status == .ACTIVE {
			net.kc[j] = y
			status = y == 0 ? .CLOSED : .OPEN
		} else if status == .OPEN {
			net.kc[j] = 1
		} else if status == .CLOSED {
			net.kc[j] = 0
		}
		net.init_status[j] = status
		net.init_setting[j] = net.kc[j]
	} else if t >= .PRV {
		if status == .ACTIVE do net.kc[j] = y
		net.init_status[j] = status
		net.init_setting[j] = net.kc[j]
	}
}

statusdata :: proc(ps: ^Parser) -> int {
	p := ps.p
	net := &p.net
	if net.nlinks == 0 do return set_error(ps, 0, 204)
	n := ps.ntok - 1
	if n < 1 do return 201
	y := 0.0
	status := Status.ACTIVE
	if match(ps.tok[n], "OPEN") {
		status = .OPEN
	} else if match(ps.tok[n], "CLOSED") {
		status = .CLOSED
	} else {
		x, ok := getfloat(ps.tok[n])
		if !ok do return set_error(ps, n, 202)
		if x < 0 do return set_error(ps, n, 211)
		y = x
	}
	if n == 1 {
		j := findlink(p, ps.tok[0])
		if j == 0 do return set_error(ps, 0, 204)
		if net.link_type[j] == .CVPIPE do return set_error(ps, 0, 207)
		if net.link_type[j] == .GPV && status == .ACTIVE do return set_error(ps, 0, 207)
		changestatus(net, j, status, y)
		return 0
	}
	i1, i2 := atol(ps.tok[0]), atol(ps.tok[1])
	for j in 1 ..= net.nlinks {
		if in_range(p.link_id[j], ps.tok[0], ps.tok[1], i1, i2) do changestatus(net, j, status, y)
	}
	return 0
}

energydata :: proc(ps: ^Parser) -> int {
	p := ps.p
	net := &p.net
	hyd := &p.hyd
	n := ps.ntok
	if n < 3 do return 201
	if match(ps.tok[0], "DEMAN") {
		y, ok := getfloat(ps.tok[2])
		if !ok do return set_error(ps, 2, 202)
		if y < 0 do return set_error(ps, 2, 213)
		p.dcost = y
		return 0
	}
	j := 0
	if match(ps.tok[0], "GLOB") {
		j = 0
	} else if match(ps.tok[0], "PUMP") {
		if n < 4 do return 201
		k := findlink(p, ps.tok[1])
		if k == 0 do return set_error(ps, 1, 216)
		if net.link_type[k] != .PUMP do return set_error(ps, 1, 216)
		j = int(net.link_pump[k])
	} else {
		return set_error(ps, 0, 213)
	}
	if match(ps.tok[n - 2], "PRICE") {
		y, ok := getfloat(ps.tok[n - 1])
		if !ok do return set_error(ps, n - 1, 202)
		if y < 0 do return set_error(ps, n - 1, 217)
		if j == 0 {
			hyd.ecost = y
		} else {
			net.pump_ecost[j] = y
		}
		return 0
	}
	if match(ps.tok[n - 2], "PATT") {
		pat := findpattern(p, ps.tok[n - 1])
		if pat < 0 do return set_error(ps, n - 1, 205)
		if j == 0 {
			hyd.epat = pat
		} else {
			net.pump_epat[j] = i32(pat)
		}
		return 0
	}
	if match(ps.tok[n - 2], "EFFI") {
		if j == 0 {
			y, ok := getfloat(ps.tok[n - 1])
			if !ok do return set_error(ps, n - 1, 202)
			if y <= 0 do return set_error(ps, n - 1, 217)
			hyd.epump = y
		} else {
			c := findcurve(p, ps.tok[n - 1])
			if c == 0 do return set_error(ps, n - 1, 206)
			net.pump_ecurve[j] = i32(c)
			p.curve_type[c] = .EFFIC_CURVE
		}
		return 0
	}
	return 201
}

// ── report, times, options ────────────────────────────────────────────

// FIELD_NAMES in Field order, up to FRICTION; what [REPORT] may name.
FIELD_NAMES := [?]string {
	"Elevation", "Demand", "Head", "Pressure", "Quality", "Length", "Diameter",
	"Flow", "Velocity", "Headloss", "Quality", "State", "Setting", "Reaction", "F-Factor",
}

reportdata :: proc(ps: ^Parser) -> int {
	p := ps.p
	net := &p.net
	r := &p.rpt
	n := ps.ntok - 1
	if n < 1 do return 201
	if match(ps.tok[0], "PAGE") {
		y, ok := getfloat(ps.tok[n])
		if !ok do return set_error(ps, n, 202)
		if y < 0 || y > 255 do return set_error(ps, n, 213)
		r.page_size = int(y)
		return 0
	}
	if match(ps.tok[0], "STATUS") {
		if match(ps.tok[n], "NO") do r.status = 0
		if match(ps.tok[n], "YES") do r.status = 1
		if match(ps.tok[n], "FULL") do r.status = 2
		return 0
	}
	if match(ps.tok[0], "SUMM") {
		if match(ps.tok[n], "NO") do r.summary = false
		if match(ps.tok[n], "YES") do r.summary = true
		return 0
	}
	if match(ps.tok[0], "MESS") {
		if match(ps.tok[n], "NO") do r.messages = false
		if match(ps.tok[n], "YES") do r.messages = true
		return 0
	}
	if match(ps.tok[0], "ENER") {
		if match(ps.tok[n], "NO") do r.energy = false
		if match(ps.tok[n], "YES") do r.energy = true
		return 0
	}
	if match(ps.tok[0], "NODE") {
		if match(ps.tok[n], "NONE") {
			r.nodes = 0
		} else if match(ps.tok[n], "ALL") {
			r.nodes = 1
		} else {
			if net.nnodes == 0 do return set_error(ps, 1, 203)
			for i in 1 ..= n {
				j := findnode(p, ps.tok[i])
				if j == 0 do return set_error(ps, i, 203)
				p.node_rpt[j] = true
			}
			r.nodes = 2
		}
		return 0
	}
	if match(ps.tok[0], "LINK") {
		if match(ps.tok[n], "NONE") {
			r.links = 0
		} else if match(ps.tok[n], "ALL") {
			r.links = 1
		} else {
			if net.nlinks == 0 do return set_error(ps, 1, 204)
			for i in 1 ..= n {
				j := findlink(p, ps.tok[i])
				if j == 0 do return set_error(ps, i, 204)
				p.link_rpt[j] = true
			}
			r.links = 2
		}
		return 0
	}
	// A reported variable: "HEAD" must not take "HEADLOSS".
	i: int
	if strings.equal_fold(ps.tok[0], "Headloss") {
		i = int(Field.HEADLOSS)
	} else {
		i = findmatch(ps.tok[0], FIELD_NAMES[:])
	}
	if i >= 0 {
		f := &r.fields[Field(i)]
		if ps.ntok == 1 || match(ps.tok[1], "YES") {
			f.enabled = true
			return 0
		}
		if match(ps.tok[1], "NO") {
			f.enabled = false
			return 0
		}
		if ps.ntok < 3 do return 201
		which: int
		switch {
		case match(ps.tok[1], "BELOW"):
			which = 0
		case match(ps.tok[1], "ABOVE"):
			which = 1
		case match(ps.tok[1], "PREC"):
			which = 2
		case:
			return set_error(ps, 1, 213)
		}
		y, ok := getfloat(ps.tok[2])
		if !ok do return set_error(ps, 2, 202)
		switch which {
		case 0:
			f.lo = y
		case 1:
			f.hi = y
		case 2:
			f.enabled = true
			f.precision = int(y + 0.5) if y >= 0 else -int(-y + 0.5)
		}
		return 0
	}
	if match(ps.tok[0], "FILE") {
		r.rpt2_fname = strings.clone(ps.tok[1])
		return 0
	}
	return 201
}

timedata :: proc(ps: ^Parser) -> int {
	p := ps.p
	t := &p.times
	n := ps.ntok - 1
	if n < 1 do return 201
	if match(ps.tok[0], "STAT") {
		switch {
		case match(ps.tok[n], "NONE"):
			p.rpt.tstat = .SERIES
		case match(ps.tok[n], "NO"):
			p.rpt.tstat = .SERIES
		case match(ps.tok[n], "AVERAGE"):
			p.rpt.tstat = .AVG
		case match(ps.tok[n], "MINIMUM"):
			p.rpt.tstat = .MIN
		case match(ps.tok[n], "MAXIMUM"):
			p.rpt.tstat = .MAX
		case match(ps.tok[n], "RANGE"):
			p.rpt.tstat = .RANGE
		case:
			return set_error(ps, n, 213)
		}
		return 0
	}
	// "5", "5 MINUTES", "13:50", "1:50 pm"
	y, ok := getfloat(ps.tok[n])
	if !ok {
		y = hour(ps.tok[n], "")
		if y < 0 {
			y = hour(ps.tok[n - 1], ps.tok[n])
			if y < 0 do return set_error(ps, n - 1, 213)
		}
	}
	secs := i64(3600 * y + 0.5)
	switch {
	case match(ps.tok[0], "DURA"):
		t.dur = secs
	case match(ps.tok[0], "HYDR"):
		t.hstep = secs
	case match(ps.tok[0], "QUAL"):
		t.qstep = secs
	case match(ps.tok[0], "RULE"):
		t.rulestep = secs
	case match(ps.tok[0], "MINI"):
		return 0 // not used any more
	case match(ps.tok[0], "PATT"):
		if match(ps.tok[1], "TIME") {
			t.pstep = secs
		} else if match(ps.tok[1], "STAR") {
			t.pstart = secs
		} else {
			return set_error(ps, 1, 213)
		}
	case match(ps.tok[0], "REPO"):
		if match(ps.tok[1], "TIME") {
			t.rstep = secs
		} else if match(ps.tok[1], "STAR") {
			t.rstart = secs
		} else {
			return set_error(ps, 1, 213)
		}
	case match(ps.tok[0], "STAR"):
		t.tstart = secs % SEC_PER_DAY
	case:
		return set_error(ps, 0, 213)
	}
	return 0
}

optiondata :: proc(ps: ^Parser) -> int {
	n := ps.ntok - 1
	if i := optionchoice(ps, n); i >= 0 do return i
	return optionvalue(ps, n)
}

// optionchoice: the options that are a word. -1 when the keyword is none
// of them.
optionchoice :: proc(ps: ^Parser, n: int) -> int {
	p := ps.p
	hyd, q := &p.hyd, &p.q
	if n < 0 do return 201
	tok0 := ps.tok[0]
	switch {
	case match(tok0, "UNIT"):
		if n < 1 do return 0
		if !get_units_option(p, ps.tok[1]) do return set_error(ps, 1, 213)
	case match(tok0, "PRESSURE"):
		if n < 1 do return 0
		switch {
		case match(ps.tok[1], "EXP"):
			return -1
		case match(ps.tok[1], "PSI"):
			p.pressure_units = .PSI
		case match(ps.tok[1], "KPA"):
			p.pressure_units = .KPA
		case match(ps.tok[1], "METERS"):
			p.pressure_units = .METERS
		case match(ps.tok[1], "BAR"):
			p.pressure_units = .BAR
		case match(ps.tok[1], "FEET"):
			p.pressure_units = .FEET
		case:
			return set_error(ps, 1, 213)
		}
	case match(tok0, "HEADL"):
		if n < 1 do return 0
		if !get_headloss_option(p, ps.tok[1]) do return set_error(ps, 1, 213)
	case match(tok0, "HYDR"):
		if n < 2 do return 0
		if match(ps.tok[1], "USE") {
			p.out.hydflag = .USE
		} else if match(ps.tok[1], "SAVE") {
			p.out.hydflag = .SAVE
		} else {
			return set_error(ps, 1, 213)
		}
		p.out.hyd_fname = strings.clone(ps.tok[2])
	case match(tok0, "QUAL"):
		if n < 1 do return 0
		switch {
		case match(ps.tok[1], "NONE"):
			q.kind = .NONE
		case match(ps.tok[1], "CHEM"):
			q.kind = .CHEM
		case match(ps.tok[1], "AGE"):
			q.kind = .AGE
		case match(ps.tok[1], "TRACE"):
			q.kind = .TRACE
		case:
			q.kind = .CHEM
			p.chem_name = strings.clone(clip(ps.tok[1], MAXID))
			if n >= 2 do p.chem_units = strings.clone(clip(ps.tok[2], MAXID))
		}
		if q.kind == .TRACE {
			if n < 2 do return 201
			q.trace_node = findnode(p, ps.tok[2])
			if q.trace_node == 0 do return set_error(ps, 2, 212)
			p.chem_name = "% from"
			p.chem_units = strings.clone(clip(ps.tok[2], MAXID))
		}
		if q.kind == .AGE {
			p.chem_name = "AGE"
			p.chem_units = "hrs"
		}
	case match(tok0, "MAP"):
		if n < 1 do return 0
		p.map_fname = strings.clone(ps.tok[1])
	case match(tok0, "VERI"):
		// deprecated
	case match(tok0, "UNBA"):
		if n < 1 do return 0
		if match(ps.tok[1], "STOP") {
			hyd.extra_iter = -1
		} else if match(ps.tok[1], "CONT") {
			hyd.extra_iter = n >= 2 ? int(atol(ps.tok[2])) : 0
		} else {
			return set_error(ps, 1, 213)
		}
	case match(tok0, "PATT"):
		if n < 1 do return 0
		p.def_pat_id = strings.clone(clip(ps.tok[1], MAXID))
	case match(tok0, "DEMAND"):
		if n < 2 do return 0
		if !match(ps.tok[1], "MODEL") do return -1
		switch {
		case match(ps.tok[2], "DDA"):
			hyd.demand_model = .DDA
		case match(ps.tok[2], "PDA"):
			hyd.demand_model = .PDA
		case:
			return set_error(ps, 2, 213)
		}
	case match(tok0, "BACK"):
		if n < 2 do return 0
		if !match(ps.tok[1], "ALLOW") do return -1
		switch {
		case match(ps.tok[2], "NO"):
			hyd.emit_backflow = false
		case match(ps.tok[2], "YES"):
			hyd.emit_backflow = true
		case:
			return set_error(ps, 2, 213)
		}
	case:
		return -1
	}
	return 0
}

// clip: at most n bytes of s (strncpy into a MAXID buffer).
clip :: #force_inline proc "contextless" (s: string, n: int) -> string {
	return len(s) > n ? s[:n] : s
}

// optionvalue: the options that are a number.
optionvalue :: proc(ps: ^Parser, n: int) -> int {
	p := ps.p
	hyd, q := &p.hyd, &p.q
	tok0 := ps.tok[0]
	if match(tok0, "SEGM") do return 0
	nvalue := 1
	if match(tok0, "SPEC") || match(tok0, "EMIT") || match(tok0, "DEMAND") ||
	   match(tok0, "MINI") || match(tok0, "REQ") || match(tok0, "PRESSURE") ||
	   match(tok0, "PREC") {
		nvalue = 2
	}
	if n < nvalue do return 0
	y, ok := getfloat(ps.tok[nvalue])
	if !ok do return set_error(ps, nvalue, 202)

	switch {
	case match(tok0, "TOLER"):
		if y < 0 do return set_error(ps, nvalue, 213)
		q.ctol = y
		return 0
	case match(tok0, "DIFF"):
		if y < 0 do return set_error(ps, nvalue, 213)
		q.diffus = y
		return 0
	case match(tok0, "DAMPLIMIT"):
		hyd.damp_limit = y
		return 0
	case match(tok0, "FLOWCHANGE"):
		if y < 0 do return set_error(ps, nvalue, 213)
		hyd.flow_change_limit = y
		return 0
	case match(tok0, "HEADERROR"):
		if y < 0 do return set_error(ps, nvalue, 213)
		hyd.head_error_limit = y
		return 0
	case match(tok0, "MINI"):
		if y < 0 do return set_error(ps, nvalue, 213)
		if hyd.preq == MINPDIFF {
			hyd.preq = y + MINPDIFF
		} else if hyd.preq - y < MINPDIFF {
			return set_error(ps, nvalue, 208)
		}
		hyd.pmin = y
		return 0
	case match(tok0, "REQ"):
		if y < 0 do return set_error(ps, nvalue, 213)
		if y - hyd.pmin < MINPDIFF do return set_error(ps, nvalue, 208)
		hyd.preq = y
		return 0
	case match(tok0, "PRESSURE"):
		if y < 0 do return set_error(ps, nvalue, 213)
		hyd.pexp = y
		return 0
	}
	if y <= 0 do return set_error(ps, nvalue, 213)
	switch {
	case match(tok0, "VISC"):
		hyd.viscos = y
	case match(tok0, "SPEC"):
		hyd.spgrav = y
	case match(tok0, "TRIAL"):
		hyd.max_iter = int(y)
	case match(tok0, "ACCU"):
		hyd.hacc = min(max(y, 1e-5), 1e-1)
	case match(tok0, "HTOL"):
		hyd.htol = y
	case match(tok0, "QTOL"):
		hyd.qtol = y
	case match(tok0, "RQTOL"):
		if y >= 1 do return 213
		hyd.rqtol = y
	case match(tok0, "CHECKFREQ"):
		hyd.check_freq = int(y)
	case match(tok0, "MAXCHECK"):
		hyd.max_check = int(y)
	case match(tok0, "EMIT"):
		hyd.qexp = 1 / y
	case match(tok0, "DEMAND"):
		hyd.dmult = y
	case:
		return 201
	}
	return 0
}

// ── rules ─────────────────────────────────────────────────────────────
// A rule's premises are appended as they are read, then its THEN actions,
// then its ELSE actions; the *_first arrays mark where each rule's runs
// begin. A rule that fails is cut off by truncating the arrays back.

RULE_WORDS := [?]string{"RULE", "IF", "AND", "OR", "THEN", "ELSE", "PRIO", "DISABLED"}
RULE_VARIABLES := [?]string {
	"DEMAND", "HEAD", "GRADE", "LEVEL", "PRESSURE", "FLOW", "STATUS", "SETTING",
	"POWER", "TIME", "CLOCKTIME", "FILLTIME", "DRAINTIME",
}
RULE_OBJECTS := [?]string{"Junc", "Reser", "Tank", "Pipe", "Pump", "Valve", "NODE", "LINK", "SYSTEM"}
// "<=" and ">=" sit before "<" and ">" so a prefix match finds them first.
RULE_OPERATORS := [?]string{"=", "<>", "<=", ">=", "<", ">", "IS", "NOT", "BELOW", "ABOVE"}
RULE_VALUES := [?]string{"XXXX", "OPEN", "CLOSED", "ACTIVE"}

ruledata :: proc(ps: ^Parser) -> int {
	net := &ps.p.net
	// Once a rule has failed, the rest of the section is skipped.
	if ps.rule_state == .ERROR do return 0
	err := 0
	key := findmatch(ps.tok[0], RULE_WORDS[:])
	if key < 0 {
		err = 201
	} else do switch Rule_Logic(key) {
	case .RULE:
		if ps.ntok != 2 {
			err = 201
			break
		}
		net.nrules += 1
		newrule(ps)
		ps.rule_state = .RULE
		ps.rule_errcode = 0
	case .IF:
		if ps.rule_state != .RULE {
			err = 221
			break
		}
		ps.rule_state = .IF
		err = newpremise(ps, .AND)
	case .AND:
		if ps.rule_state == .IF {
			err = newpremise(ps, .AND)
		} else if ps.rule_state == .THEN || ps.rule_state == .ELSE {
			err = newaction(ps)
		} else {
			err = 221
		}
	case .OR:
		if ps.rule_state == .IF {
			err = newpremise(ps, .OR)
		} else {
			err = 221
		}
	case .THEN:
		if ps.rule_state != .IF {
			err = 221
			break
		}
		ps.rule_state = .THEN
		err = newaction(ps)
	case .ELSE:
		if ps.rule_state != .THEN {
			err = 221
			break
		}
		ps.rule_state = .ELSE
		err = newaction(ps)
	case .PRIORITY:
		if ps.rule_state != .THEN && ps.rule_state != .ELSE {
			err = 221
			break
		}
		ps.rule_state = .PRIORITY
		err = newpriority(ps)
	case .DISABLED:
		if ps.rule_state != .THEN && ps.rule_state != .ELSE && ps.rule_state != .PRIORITY {
			err = 221
			break
		}
		ps.rule_enabled[net.nrules] = false
	case .ERROR:
		err = 201
	}
	if err != 0 {
		ps.rule_state = .ERROR
		ps.rule_errcode = err
		err = 200
	}
	return err
}

newrule :: proc(ps: ^Parser) {
	append(&ps.rule_label, strings.clone(clip(ps.tok[1], MAXID)))
	append(&ps.rule_priority, 0)
	append(&ps.rule_enabled, true)
	append(&ps.rule_premise_first, i32(len(ps.premise_logop)))
	append(&ps.rule_then_first, i32(len(ps.action_link)))
	append(&ps.rule_else_first, i32(len(ps.action_link)))
}

// delete_last_rule drops the rule being read (EPANET deletes the last
// rule when a statement of it fails — the previous rule when the RULE
// line itself failed).
delete_last_rule :: proc(ps: ^Parser) {
	net := &ps.p.net
	r := net.nrules
	if r < 1 do return
	np := int(ps.rule_premise_first[r])
	na := int(ps.rule_then_first[r])
	resize(&ps.premise_logop, np)
	resize(&ps.premise_object, np)
	resize(&ps.premise_index, np)
	resize(&ps.premise_variable, np)
	resize(&ps.premise_relop, np)
	resize(&ps.premise_status, np)
	resize(&ps.premise_value, np)
	resize(&ps.action_link, na)
	resize(&ps.action_status, na)
	resize(&ps.action_setting, na)
	resize(&ps.rule_label, r)
	resize(&ps.rule_priority, r)
	resize(&ps.rule_enabled, r)
	resize(&ps.rule_premise_first, r)
	resize(&ps.rule_then_first, r)
	resize(&ps.rule_else_first, r)
	net.nrules -= 1
}

// newpremise: IF/AND/OR <object> <id> <variable> <op> <value>, or
// IF/AND/OR SYSTEM <variable> <op> <value> (units).
newpremise :: proc(ps: ^Parser, logop: Rule_Logic) -> int {
	p := ps.p
	net := &p.net
	if ps.ntok != 5 && ps.ntok != 6 do return 201
	obj := findmatch(ps.tok[1], RULE_OBJECTS[:])
	j, vi: int
	if obj == int(Rule_Object.SYSTEM) {
		j = 0
		vi = findmatch(ps.tok[2], RULE_VARIABLES[:])
		if vi != int(Rule_Variable.DEMAND) && vi != int(Rule_Variable.TIME) && vi != int(Rule_Variable.CLOCKTIME) do return 201
	} else {
		vi = findmatch(ps.tok[3], RULE_VARIABLES[:])
		if vi < 0 do return 201
		if obj < 0 do return 201
		switch Rule_Object(obj) {
		case .NODE, .JUNC, .RESERV, .TANK:
			obj = int(Rule_Object.NODE)
		case .LINK, .PIPE, .PUMP, .VALVE:
			obj = int(Rule_Object.LINK)
		case .SYSTEM:
			return 201
		}
		if Rule_Object(obj) == .NODE {
			j = findnode(p, ps.tok[2])
			if j == 0 do return 203
			#partial switch Rule_Variable(vi) {
			case .DEMAND, .HEAD, .GRADE, .LEVEL, .PRESSURE:
			case .FILLTIME, .DRAINTIME:
				if j <= net.njuncs do return 201
			case:
				return 201
			}
		} else {
			j = findlink(p, ps.tok[2])
			if j == 0 do return 204
			#partial switch Rule_Variable(vi) {
			case .FLOW, .STATUS, .SETTING:
			case:
				return 201
			}
		}
	}
	v := Rule_Variable(vi)
	m := Rule_Object(obj) == .SYSTEM ? 3 : 4
	k := findmatch(ps.tok[m], RULE_OPERATORS[:])
	if k < 0 do return 201
	r: Rule_Op
	#partial switch Rule_Op(k) {
	case .IS:
		r = .EQ
	case .NOT:
		r = .NE
	case .BELOW:
		r = .LT
	case .ABOVE:
		r = .GT
	case:
		r = Rule_Op(k)
	}
	s := Rule_Status.IS_NUMBER
	x := MISSING
	if v == .TIME || v == .CLOCKTIME {
		if ps.ntok == 6 {
			x = hour(ps.tok[4], ps.tok[5]) * 3600
		} else {
			x = hour(ps.tok[4], "") * 3600
		}
		if x < 0 do return 202
	} else if sv := findmatch(ps.tok[ps.ntok - 1], RULE_VALUES[:]); sv > int(Rule_Status.IS_NUMBER) {
		s = Rule_Status(sv)
	} else {
		tok := ps.tok[ps.ntok - 1]
		if (v == .FILLTIME || v == .DRAINTIME) && strings.index_byte(tok, ':') >= 0 {
			// h:m:s, as EPANET's own .inp writer puts it (and its own parser refuses)
			x = hour(tok, "") * 3600
			if x < 0 do return 202
		} else {
			y, ok := getfloat(tok)
			if !ok do return 202
			x = y
			if v == .FILLTIME || v == .DRAINTIME do x *= 3600
		}
	}
	append(&ps.premise_logop, logop)
	append(&ps.premise_object, Rule_Object(obj))
	append(&ps.premise_index, i32(j))
	append(&ps.premise_variable, v)
	append(&ps.premise_relop, r)
	append(&ps.premise_status, s)
	append(&ps.premise_value, x)
	return 0
}

// newaction: THEN/ELSE/AND LINK <id> <variable> IS <value>.
newaction :: proc(ps: ^Parser) -> int {
	p := ps.p
	net := &p.net
	if ps.ntok != 6 do return 201
	j := findlink(p, ps.tok[2])
	if j == 0 do return 204
	if net.link_type[j] == .CVPIPE do return 207
	s := -1
	x := MISSING
	if sv := findmatch(ps.tok[5], RULE_VALUES[:]); sv > int(Rule_Status.IS_NUMBER) {
		s = sv
	} else {
		y, ok := getfloat(ps.tok[5])
		if !ok do return 202
		if y < 0 do return 202
		x = y
	}
	if x != MISSING && net.link_type[j] == .GPV do return 202
	if x != MISSING && net.link_type[j] == .PIPE {
		s = int(x == 0 ? Rule_Status.IS_CLOSED : Rule_Status.IS_OPEN)
		x = MISSING
	}
	append(&ps.action_link, i32(j))
	append(&ps.action_status, Rule_Status(s))
	append(&ps.action_setting, x)
	// the THEN run ends where the ELSE run begins
	if ps.rule_state == .THEN do ps.rule_else_first[net.nrules] = i32(len(ps.action_link))
	return 0
}

newpriority :: proc(ps: ^Parser) -> int {
	x, ok := getfloat(ps.tok[1])
	if !ok do return 202
	ps.rule_priority[ps.p.net.nrules] = x
	return 0
}
