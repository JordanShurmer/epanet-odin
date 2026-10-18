package epanet

// parse.odin — the .inp reader (EPANET's input1.c, input2.c, input3.c
// and the parsing half of rules.c), line by line as EPANET reads it:
// one pass to count the objects and collect the pattern and curve names,
// one pass to read them, then the fix-ups and the unit conversion in
// units.odin. Keywords match as EPANET's do: the keyword is a prefix of
// the token, case blind. Numbers go through strtod, as EPANET's do.

import "core:c"
import "core:c/libc"
import "core:mem/virtual"
import "core:os"
import "core:strings"

MAXID :: 31
MAXFNAME :: 259
MAXLINE :: 1024
MAXMSG :: 255
MAXTOKS :: 40
TITLELEN :: 79

Section :: enum {
	TITLE, JUNCTIONS, RESERVOIRS, TANKS, PIPES, PUMPS, VALVES, CONTROLS, RULES,
	DEMANDS, SOURCES, EMITTERS, PATTERNS, CURVES, QUALITY, STATUS, ROUGHNESS,
	ENERGY, REACTIONS, MIXING, REPORT, TIMES, OPTIONS, COORDS, VERTICES, LABELS,
	BACKDROP, TAGS, LEAKAGE, END,
}

// in Section order
SECTION_NAMES := [?]string {
	"[TITLE]", "[JUNCTIONS]", "[RESERVOIRS]",
	"[TANKS]", "[PIPES]", "[PUMPS]", "[VALVES]",
	"[CONTROLS]", "[RULES]", "[DEMANDS]",
	"[SOURCES]", "[EMITTERS]", "[PATTERNS]",
	"[CURVES]", "[QUALITY]", "[STATUS]",
	"[ROUGHNESS]", "[ENERGY]", "[REACTIONS]",
	"[MIXING]", "[REPORT]", "[TIMES]", "[OPTIONS]",
	"[COORDINATES]", "[VERTICES]", "[LABELS]",
	"[BACKDROP]", "[TAGS]", "[LEAKAGE]", "[END]",
}

// A demand category, kept per node while reading.
Demand :: struct {
	base: f64,
	pat:  i32,
	name: string,
}

// Parser is the reader's state between lines.
Parser :: struct {
	p:                     ^Project,
	lines:                 []string,
	tok:                   [MAXTOKS]string,
	ntok:                  int,
	errtok:                int,
	comment:               string,
	ntitle:                int,
	prev_pat, prev_curve:  int, // 0 / -1: none
	// what the first pass found
	max_pats, max_curves:  int,
	// tables that grow while reading
	pattern_f:             [dynamic][dynamic]f64,
	curve_x, curve_y:      [dynamic][dynamic]f64,
	demands:               [][dynamic]Demand,
	vx, vy:                [][dynamic]f64, // vertices per link
	// rules in progress
	rule_label:            [dynamic]string,
	rule_state:            Rule_Logic,
	rule_errcode:          int,
	rule_priority:         [dynamic]f64,
	rule_enabled:          [dynamic]b32,
	rule_premise_first:    [dynamic]i32,
	rule_then_first:       [dynamic]i32,
	rule_else_first:       [dynamic]i32,
	premise_logop:         [dynamic]Rule_Logic,
	premise_object:        [dynamic]Rule_Object,
	premise_index:         [dynamic]i32,
	premise_variable:      [dynamic]Rule_Variable,
	premise_relop:         [dynamic]Rule_Op,
	premise_status:        [dynamic]Rule_Status,
	premise_value:         [dynamic]f64,
	action_link:           [dynamic]i32,
	action_status:         [dynamic]Rule_Status,
	action_setting:        [dynamic]f64,
}

// ── words ─────────────────────────────────────────────────────────────

upper :: #force_inline proc "contextless" (c: u8) -> u8 {
	return c >= 'a' && c <= 'z' ? c - 32 : c
}

// match: sub is a prefix of str (after str's leading blanks), case blind.
match :: proc "contextless" (str, sub: string) -> bool {
	if len(sub) == 0 do return false
	i := 0
	for i < len(str) && str[i] == ' ' do i += 1
	for j in 0 ..< len(sub) {
		if i >= len(str) || upper(str[i]) != upper(sub[j]) do return false
		i += 1
	}
	return true
}

findmatch :: proc "contextless" (str: string, words: []string) -> int {
	for w, i in words do if match(str, w) do return i
	return -1
}

// getfloat: the number in s, by strtod; false when anything follows it.
getfloat :: proc(s: string) -> (f64, bool) {
	buf: [256]u8
	n := min(len(s), 255)
	copy(buf[:n], s)
	buf[n] = 0
	end: [^]u8
	y := libc.strtod(cstring(&buf[0]), (^[^]c.char)(&end))
	if end[0] > 0 do return y, false
	return y, true
}

atol :: proc(s: string) -> i64 {
	buf: [256]u8
	n := min(len(s), 255)
	copy(buf[:n], s)
	buf[n] = 0
	return i64(libc.atol(cstring(&buf[0])))
}

// hour converts a time ("5", "13:50", "1:50 pm", "30 min") to hours, or
// -1 when it is no time.
hour :: proc(time, units: string) -> f64 {
	y: [4]f64
	n := 0
	rest := time
	for n <= 3 {
		// strtok: skip empty fields
		for len(rest) > 0 && rest[0] == ':' do rest = rest[1:]
		if len(rest) == 0 do break
		end := strings.index_byte(rest, ':')
		field := rest
		if end >= 0 {
			field = rest[:end]
			rest = rest[end + 1:]
		} else {
			rest = ""
		}
		v, ok := getfloat(field)
		if !ok do return -1
		y[n] = v
		n += 1
	}
	if n == 1 {
		if len(units) == 0 do return y[0]
		if match(units, "SEC") do return y[0] / 3600
		if match(units, "MIN") do return y[0] / 60
		if match(units, "HOU") do return y[0]
		if match(units, "DAY") do return y[0] * 24
	}
	if n > 1 do y[0] = y[0] + y[1] / 60 + y[2] / 3600
	if len(units) == 0 do return y[0]
	if match(units, "AM") {
		if y[0] >= 13 do return -1
		if y[0] >= 12 do return y[0] - 12
		return y[0]
	}
	if match(units, "PM") {
		if y[0] >= 13 do return -1
		if y[0] >= 12 do return y[0]
		return y[0] + 12
	}
	return -1
}

// gettokens splits a line as EPANET does: the part before ';' is the
// line, separators are blanks, tabs and line ends, and quotes hold a
// token together. Returns the comment after the ';'.
//
// EPANET counts the bytes left in the line as it goes, and a quoted token
// is counted at its full width but stepped over one byte short, so after
// one the count runs out early and the last token of the line comes with
// its trailing separators ("1.5\n", which then reads as no number). That
// is kept, byte for byte.
gettokens :: proc(ps: ^Parser, line0: string) -> (comment: string) {
	line := line0
	ps.ntok = 0
	if c := strings.index_byte(line, ';'); c >= 0 {
		rest := line[c + 1:]
		if e := strings.index_any(rest, "\n\r"); e >= 0 do rest = rest[:e]
		comment = rest
		line = line[:c]
	}
	remaining := len(line)
	pos := 0
	// (EPANET goes on past the line's end when a quoted token held a blank;
	// what it finds there is the buffer's leftovers, and is not mirrored.)
	for remaining > 0 && pos < len(line) && ps.ntok < MAXTOKS {
		m := strcspn(line[pos:], " \t\n\r")
		if m == remaining {
			ps.tok[ps.ntok] = line[pos:]
			ps.ntok += 1
			break
		}
		remaining -= m + 1
		if m == 0 {
			pos += 1
			continue
		}
		if line[pos] == '"' {
			pos += 1
			m = strcspn(line[pos:], "\"\n\r")
		}
		ps.tok[ps.ntok] = line[pos:pos + m]
		ps.ntok += 1
		pos = min(pos + m + 1, len(line))
	}
	return
}

// strcspn: how many leading bytes of s are not in set.
strcspn :: proc "contextless" (s, set: string) -> int {
	for i in 0 ..< len(s) {
		if strings.index_byte(set, s[i]) >= 0 do return i
	}
	return len(s)
}

// ── lookups ───────────────────────────────────────────────────────────

findnode :: proc(p: ^Project, id: string) -> int {
	return int(p.nodes_by_id[id] or_else 0)
}
findlink :: proc(p: ^Project, id: string) -> int {
	return int(p.links_by_id[id] or_else 0)
}
findpattern :: proc(p: ^Project, id: string) -> int {
	if i, ok := p.patterns_by_id[id]; ok do return int(i)
	return -1
}
findcurve :: proc(p: ^Project, id: string) -> int {
	return int(p.curves_by_id[id] or_else 0)
}

set_error :: #force_inline proc(ps: ^Parser, tok, err: int) -> int {
	ps.errtok = tok
	return err
}

// ── the reader ────────────────────────────────────────────────────────

// parse_inp reads the file into a new project. Returns the project and
// EPANET's error code: 0, 200 when lines had errors, or a fatal code.
parse_inp :: proc(path: string) -> (p: ^Project, errcode: int) {
	p = project_new()
	if p == nil do return nil, 101
	errcode = read_inp(p, path)
	if errcode == 302 {
		project_free(p)
		return nil, errcode
	}
	return
}

// project_new makes an empty project with its arena.
project_new :: proc() -> ^Project {
	p := new(Project)
	if virtual.arena_init_growing(&p.arena) != nil {
		free(p)
		return nil
	}
	return p
}

// read_inp reads the file into an existing project, from its arena.
read_inp :: proc(p: ^Project, path: string) -> (errcode: int) {
	context.allocator = virtual.arena_allocator(&p.arena)
	data, rerr := os.read_entire_file_from_path(path, context.allocator)
	if rerr != nil do return 302
	ps := Parser{p = p}
	ps.lines = split_lines(string(data))
	set_defaults(p)
	init_report(p)
	errcode = netsize(&ps)
	if errcode != 0 do return
	project_alloc(p)
	errcode = readdata(&ps)
	if errcode == 0 || errcode == 200 {
		reindex_tanks(&ps)
		finish_tables(&ps)
		adjust_data(p)
		init_tanks(p)
		init_units(p)
		convert_units(p)
	}
	return
}

// split_lines as fgets with a MAXLINE buffer would: a line longer than
// MAXLINE-1 bytes comes in pieces.
split_lines :: proc(s: string) -> []string {
	out: [dynamic]string
	rest := s
	for len(rest) > 0 {
		e := strings.index_byte(rest, '\n')
		line: string
		if e >= 0 {
			line = rest[:e + 1]
			rest = rest[e + 1:]
		} else {
			line = rest
			rest = ""
		}
		for len(line) > MAXLINE - 1 {
			append(&out, line[:MAXLINE - 1])
			line = line[MAXLINE - 1:]
		}
		append(&out, line)
	}
	return out[:]
}

set_defaults :: proc(p: ^Project) {
	hyd, q, t := &p.hyd, &p.q, &p.times
	p.chem_name = "Chemical"
	p.chem_units = "mg/L"
	p.def_pat_id = "1"
	p.units = .US
	p.flow_units = .GPM
	p.pressure_units = .DEFAULTUNIT
	p.out.hydflag = .SCRATCH
	p.rpt.tstat = .SERIES
	hyd.formflag = .HW
	hyd.htol = 0.0005
	hyd.qtol = 0.0001
	hyd.hacc = 0.001
	hyd.flow_change_limit = 0
	hyd.head_error_limit = 0
	hyd.demand_model = .DDA
	hyd.pmin = 0
	hyd.preq = MINPDIFF
	hyd.pexp = 0.5
	hyd.max_iter = 200
	hyd.extra_iter = -1
	hyd.viscos = MISSING
	hyd.spgrav = 1
	hyd.epat = 0
	hyd.ecost = 0
	p.dcost = 0
	hyd.epump = 75
	hyd.emax = 0
	hyd.qexp = 2
	hyd.emit_backflow = true
	p.net.def_pat = 0
	hyd.dmult = 1
	hyd.rqtol = 1e-7
	hyd.check_freq = 2
	hyd.max_check = 10
	hyd.damp_limit = 0
	q.kind = .NONE
	q.ctol = MISSING
	q.trace_node = 0
	q.bulk_order = 1
	q.wall_order = 1
	q.tank_order = 1
	p.kbulk = 0
	p.kwall = 0
	q.climit = 0
	q.diffus = MISSING
	p.rfactor = 0
	q.balance.ratio = 0
	t.dur = 0
	t.tstart = 0
	t.pstart = 0
	t.hstep = 3600
	t.qstep = 0
	t.pstep = 3600
	t.rstep = 3600
	t.rulestep = 0
	t.rstart = 0
}

init_report :: proc(p: ^Project) {
	r := &p.rpt
	r.page_size = 0
	r.summary = true
	r.messages = true
	r.status = 0
	r.energy = false
	r.nodes = 0
	r.links = 0
	for f in Field {
		r.fields[f] = {enabled = false, precision = 2, lo = BIG * BIG, hi = -BIG * BIG}
	}
	for f, i in FIELD_NAMES do r.fields[Field(i)].name = f
	r.fields[.FRICTION].precision = 3
	for f in Field.DEMAND ..= Field.QUALITY do r.fields[f].enabled = true
	for f in Field.FLOW ..= Field.HEADLOSS do r.fields[f].enabled = true
}

// netsize is the first pass: counts, pattern and curve names, and the
// units and head loss options, which the defaults of later lines need.
netsize :: proc(ps: ^Parser) -> int {
	p := ps.p
	sect := -1
	// Pattern 0: the single 1.0 for demands without a pattern.
	add_pattern(ps, "")
	append(&ps.pattern_f[0], 1.0)

	for raw in ps.lines {
		// strtok on SEPSTR: the first token
		line := raw
		comment_at := -1
		_ = comment_at
		tok := first_token(line)
		if len(tok) == 0 do continue
		if tok[0] == ';' do continue
		if tok[0] == '[' {
			newsect := findmatch(tok, SECTION_NAMES[:])
			if newsect >= 0 {
				sect = newsect
				if Section(sect) == .END do break
			} else {
				sect = -1
			}
			continue
		}
		if sect < 0 do continue
		#partial switch Section(sect) {
		case .JUNCTIONS:
			p.max_juncs += 1
		case .RESERVOIRS, .TANKS:
			p.max_tanks += 1
		case .PIPES:
			p.max_links += 1
		case .PUMPS:
			p.max_links += 1
			p.max_pumps += 1
		case .VALVES:
			p.max_links += 1
			p.max_valves += 1
		case .CONTROLS:
			p.max_controls += 1
		case .PATTERNS:
			if err := add_pattern(ps, tok); err != 0 do return err
		case .CURVES:
			if err := add_curve(ps, tok); err != 0 do return err
		case .OPTIONS:
			if match(tok, "UNIT") {
				get_units_option(p, second_token(line))
			} else if match(tok, "HEADL") {
				get_headloss_option(p, second_token(line))
			}
		}
	}
	ps.max_pats = len(ps.pattern_f) - 1
	ps.max_curves = len(ps.curve_x) - 1
	return 0
}

// first_token / second_token as strtok(line, SEPSTR) gives them.
first_token :: proc "contextless" (line: string) -> string {
	i := 0
	for i < len(line) && strings.index_byte(" \t\n\r", line[i]) >= 0 do i += 1
	j := i
	for j < len(line) && strings.index_byte(" \t\n\r", line[j]) < 0 do j += 1
	return line[i:j]
}
second_token :: proc "contextless" (line: string) -> string {
	t := first_token(line)
	if len(t) == 0 do return ""
	rest := line[strings.index(line, t) + len(t):]
	return first_token(rest)
}

add_pattern :: proc(ps: ^Parser, id: string) -> int {
	n := len(ps.pattern_f) - 1
	if n > 0 {
		if ps.p.pattern_id[n] == id do return 0
		if findpattern(ps.p, id) > 0 do return 0
	}
	if len(id) > MAXID do return 252
	append(&ps.pattern_f, [dynamic]f64{})
	ids := make([]string, len(ps.pattern_f))
	copy(ids, ps.p.pattern_id)
	ids[len(ids) - 1] = strings.clone(id)
	ps.p.pattern_id = ids
	ps.p.patterns_by_id[ids[len(ids) - 1]] = i32(len(ids) - 1)
	ps.p.pattern_comment = grown(ps.p.pattern_comment, len(ids))
	return 0
}

// grown: s with room for n entries, the ones it had kept.
grown :: proc(s: []$E, n: int) -> []E {
	if len(s) >= n do return s
	t := make([]E, n)
	copy(t, s)
	return t
}

add_curve :: proc(ps: ^Parser, id: string) -> int {
	n := len(ps.curve_x) - 1
	if n > 0 {
		if ps.p.curve_id[n] == id do return 0
		if findcurve(ps.p, id) > 0 do return 0
	}
	if len(id) > MAXID do return 252
	if len(ps.curve_x) == 0 {
		append(&ps.curve_x, [dynamic]f64{})
		append(&ps.curve_y, [dynamic]f64{})
		ps.p.curve_id = make([]string, 1)
		ps.p.curve_type = make([]Curve_Type, 1)
	}
	append(&ps.curve_x, [dynamic]f64{})
	append(&ps.curve_y, [dynamic]f64{})
	ids := make([]string, len(ps.curve_x))
	copy(ids, ps.p.curve_id)
	ids[len(ids) - 1] = strings.clone(id)
	ps.p.curve_id = ids
	types := make([]Curve_Type, len(ps.curve_x))
	copy(types, ps.p.curve_type)
	types[len(types) - 1] = .GENERIC_CURVE
	ps.p.curve_type = types
	ps.p.curves_by_id[ids[len(ids) - 1]] = i32(len(ids) - 1)
	ps.p.curve_comment = grown(ps.p.curve_comment, len(ids))
	return 0
}

get_units_option :: proc(p: ^Project, units: string) -> bool {
	switch {
	case match(units, "CFS"):
		p.flow_units = .CFS
	case match(units, "GPM"):
		p.flow_units = .GPM
	case match(units, "AFD"):
		p.flow_units = .AFD
	case match(units, "MGD"):
		p.flow_units = .MGD
	case match(units, "IMGD"):
		p.flow_units = .IMGD
	case match(units, "LPS"):
		p.flow_units = .LPS
	case match(units, "LPM"):
		p.flow_units = .LPM
	case match(units, "CMH"):
		p.flow_units = .CMH
	case match(units, "CMD"):
		p.flow_units = .CMD
	case match(units, "MLD"):
		p.flow_units = .MLD
	case match(units, "CMS"):
		p.flow_units = .CMS
	case match(units, "SI"):
		p.flow_units = .LPS
	case:
		return false
	}
	p.units = p.flow_units >= .LPS ? .SI : .US
	return true
}

get_headloss_option :: proc(p: ^Project, formula: string) -> bool {
	switch {
	case match(formula, "H-W"):
		p.hyd.formflag = .HW
	case match(formula, "D-W"):
		p.hyd.formflag = .DW
	case match(formula, "C-M"):
		p.hyd.formflag = .CM
	case:
		return false
	}
	return true
}

// readdata is the second pass: every line to its section's reader. The
// error count turns into code 200.
readdata :: proc(ps: ^Parser) -> int {
	p := ps.p
	nn := p.max_juncs + p.max_tanks
	ps.demands = make([][dynamic]Demand, nn + 1)
	ps.vx = make([][dynamic]f64, p.max_links + 1)
	ps.vy = make([][dynamic]f64, p.max_links + 1)
	ps.prev_pat = -1
	ps.prev_curve = 0
	for i in 0 ..= nn do p.node_x[i], p.node_y[i] = MISSING, MISSING
	if len(ps.curve_x) == 0 {
		ps.p.curve_id = make([]string, 1)
		ps.p.curve_type = make([]Curve_Type, 1)
		append(&ps.curve_x, [dynamic]f64{})
		append(&ps.curve_y, [dynamic]f64{})
	}
	ps.rule_state = .PRIORITY
	append(&ps.rule_label, "")
	append(&ps.rule_priority, 0)
	append(&ps.rule_enabled, false)
	append(&ps.rule_premise_first, 1)
	append(&ps.rule_then_first, 1)
	append(&ps.rule_else_first, 1)
	append(&ps.premise_logop, Rule_Logic.RULE)
	append(&ps.premise_object, Rule_Object.JUNC)
	append(&ps.premise_index, 0)
	append(&ps.premise_variable, Rule_Variable.DEMAND)
	append(&ps.premise_relop, Rule_Op.EQ)
	append(&ps.premise_status, Rule_Status.IS_NUMBER)
	append(&ps.premise_value, 0)
	append(&ps.action_link, 0)
	append(&ps.action_status, Rule_Status.IS_NUMBER)
	append(&ps.action_setting, 0)

	sect := -1
	errsum := 0
	line_comment := ""
	for raw in ps.lines {
		ps.comment = gettokens(ps, raw)
		ps.errtok = -1
		if ps.ntok == 0 {
			if sect == int(Section.PATTERNS) || sect == int(Section.CURVES) do line_comment = ps.comment
			continue
		}
		if sect == int(Section.PATTERNS) || sect == int(Section.CURVES) do ps.comment = line_comment
		line_comment = ""
		if len(raw) >= MAXLINE do errsum += 1
		if ps.tok[0][0] == '[' {
			newsect := findmatch(ps.tok[0], SECTION_NAMES[:])
			if newsect >= 0 {
				sect = newsect
				if Section(sect) == .END do break
			} else {
				sect = -1
				errsum += 1
			}
			continue
		}
		if sect < 0 do continue
		if inperr := newline(ps, Section(sect), raw); inperr > 0 do errsum += 1
	}
	return errsum > 0 ? 200 : 0
}

newline :: proc(ps: ^Parser, sect: Section, line: string) -> int {
	p := ps.p
	switch sect {
	case .TITLE:
		if ps.ntitle < 3 {
			l := line
			if len(l) > 0 && l[len(l) - 1] == '\n' do l = l[:len(l) - 1]
			if len(l) > TITLELEN do l = l[:TITLELEN]
			p.title[ps.ntitle] = strings.clone(l)
			ps.ntitle += 1
		}
		return 0
	case .JUNCTIONS:
		return juncdata(ps)
	case .RESERVOIRS, .TANKS:
		return tankdata(ps)
	case .PIPES:
		return pipedata(ps)
	case .PUMPS:
		return pumpdata(ps)
	case .VALVES:
		return valvedata(ps)
	case .PATTERNS:
		return patterndata(ps)
	case .CURVES:
		return curvedata(ps)
	case .DEMANDS:
		return demanddata(ps)
	case .CONTROLS:
		return controldata(ps)
	case .RULES:
		if ruledata(ps) > 0 {
			delete_last_rule(ps)
			return 200
		}
		return 0
	case .SOURCES:
		return sourcedata(ps)
	case .EMITTERS:
		return emitterdata(ps)
	case .LEAKAGE:
		return leakagedata(ps)
	case .QUALITY:
		return qualdata(ps)
	case .STATUS:
		return statusdata(ps)
	case .ROUGHNESS:
		return 0
	case .ENERGY:
		return energydata(ps)
	case .REACTIONS:
		return reactdata(ps)
	case .MIXING:
		return mixingdata(ps)
	case .REPORT:
		return reportdata(ps)
	case .TIMES:
		return timedata(ps)
	case .OPTIONS:
		return optiondata(ps)
	case .TAGS:
		return tagdata(ps)
	case .COORDS:
		return coordata(ps)
	case .VERTICES:
		return vertexdata(ps)
	case .LABELS, .BACKDROP, .END:
		return 0
	}
	return 201
}

// ── network objects ───────────────────────────────────────────────────

addnode_id :: proc(ps: ^Parser, n: int, id: string) -> int {
	if findnode(ps.p, id) != 0 do return 215
	if len(id) > MAXID do return 252
	ps.p.node_id[n] = strings.clone(id)
	ps.p.nodes_by_id[ps.p.node_id[n]] = i32(n)
	return 0
}

addlink_id :: proc(ps: ^Parser, n: int, id: string) -> int {
	if findlink(ps.p, id) != 0 do return 215
	if len(id) > MAXID do return 252
	ps.p.link_id[n] = strings.clone(id)
	ps.p.links_by_id[ps.p.link_id[n]] = i32(n)
	return 0
}

juncdata :: proc(ps: ^Parser) -> int {
	p := ps.p
	net := &p.net
	if net.nnodes == p.max_juncs + p.max_tanks do return 200
	errcode := addnode_id(ps, net.njuncs + 1, ps.tok[0])
	if errcode > 0 do return set_error(ps, 0, errcode)
	net.njuncs += 1
	net.nnodes += 1
	p.node_comment[net.njuncs] = kept(ps.comment, MAXMSG)
	el, d := 0.0, 0.0
	pat := 0
	errtok := -1
	n := ps.ntok
	if n > 1 {
		if x, ok := getfloat(ps.tok[1]); !ok {
			errcode, errtok = 202, 1
		} else {
			el = x
		}
	}
	if errcode == 0 && n > 2 {
		if x, ok := getfloat(ps.tok[2]); !ok {
			errcode, errtok = 202, 2
		} else {
			d = x
		}
	}
	if errcode == 0 && n > 3 {
		pat = findpattern(p, ps.tok[3])
		if pat < 0 do errcode, errtok = 205, 3
	}
	j := net.njuncs
	net.el[j] = el
	net.c0[j] = 0
	net.has_source[j] = false
	net.ke[j] = 0
	net.node_type[j] = .JUNCTION
	append(&ps.demands[j], Demand{d, i32(pat), ""})
	p.hyd.node_demand[j] = d
	if errcode > 0 do return set_error(ps, errtok, errcode)
	return 0
}

gettokvalue :: proc(ps: ^Parser, x: f64, itok: int, errcode, errtok: ^int) -> f64 {
	if errcode^ != 0 do return x
	result, ok := getfloat(ps.tok[itok])
	if !ok {
		errcode^ = 202
	} else if result < 0 {
		errcode^ = 209
	}
	if errcode^ > 0 {
		result = x
		errtok^ = itok
	}
	return result
}

tankdata :: proc(ps: ^Parser) -> int {
	p := ps.p
	net := &p.net
	if net.ntanks == p.max_tanks || net.nnodes == p.max_juncs + p.max_tanks do return 200
	i := p.max_juncs + net.ntanks + 1
	errcode := addnode_id(ps, i, ps.tok[0])
	if errcode != 0 do return set_error(ps, 0, errcode)
	net.ntanks += 1
	net.nnodes += 1
	p.node_comment[i] = kept(ps.comment, MAXMSG)

	el, initlevel, minlevel, maxlevel, minvol, diam := 0.0, 0.0, 0.0, 0.0, 0.0, 0.0
	pattern, curve := 0, 0
	overflow := false
	errtok := -1
	n := ps.ntok
	if n < 2 do errcode = 201
	if errcode == 0 {
		if x, ok := getfloat(ps.tok[1]); !ok {
			errcode, errtok = 202, 1
		} else {
			el = x
		}
	}
	if n <= 3 {
		if n == 3 && errcode == 0 {
			pattern = findpattern(p, ps.tok[2])
			if pattern < 0 do errcode, errtok = 205, 2
		}
	} else if errcode == 0 {
		if n < 6 {
			errcode = 201
		} else {
			initlevel = gettokvalue(ps, initlevel, 2, &errcode, &errtok)
			minlevel = gettokvalue(ps, minlevel, 3, &errcode, &errtok)
			maxlevel = gettokvalue(ps, maxlevel, 4, &errcode, &errtok)
			diam = gettokvalue(ps, diam, 5, &errcode, &errtok)
			if n >= 7 do minvol = gettokvalue(ps, minvol, 6, &errcode, &errtok)
			if errcode == 0 && n >= 8 {
				if len(ps.tok[7]) > 0 && ps.tok[7][0] != '*' {
					curve = findcurve(p, ps.tok[7])
					if curve == 0 {
						errcode, errtok = 206, 7
					} else {
						p.curve_type[curve] = .VOLUME_CURVE
					}
				}
			}
			if errcode == 0 && n >= 9 {
				if match(ps.tok[8], "YES") {
					overflow = true
				} else if match(ps.tok[8], "NO") {
					overflow = false
				} else {
					errcode, errtok = 213, 8
				}
			}
		}
	}
	t := net.ntanks
	net.el[i] = el
	net.c0[i] = 0
	net.has_source[i] = false
	net.ke[i] = 0
	net.node_type[i] = diam == 0 ? .RESERVOIR : .TANK
	net.tank_node[t] = i32(i)
	net.tank_h0[t] = initlevel
	net.tank_hmin[t] = minlevel
	net.tank_hmax[t] = maxlevel
	net.tank_area[t] = diam
	net.tank_pat[t] = i32(pattern)
	net.tank_kb[t] = MISSING
	net.tank_overflow[t] = b32(overflow)
	area := PI * (diam * diam) / 4
	net.tank_vmin[t] = area * minlevel
	if minvol > 0 do net.tank_vmin[t] = minvol
	net.tank_v0[t] = net.tank_vmin[t] + area * (initlevel - minlevel)
	net.tank_vmax[t] = net.tank_vmin[t] + area * (maxlevel - minlevel)
	net.tank_vcurve[t] = i32(curve)
	net.tank_mix[t] = .MIX1
	net.tank_v1frac[t] = 1
	if errcode > 0 do return set_error(ps, errtok, errcode)
	return 0
}

pipedata :: proc(ps: ^Parser) -> int {
	p := ps.p
	net := &p.net
	if net.nlinks == p.max_links do return 200
	n := ps.ntok
	if n < 3 do return set_error(ps, -1, 0)
	j1 := findnode(p, ps.tok[1])
	if j1 == 0 do return set_error(ps, 1, 203)
	j2 := findnode(p, ps.tok[2])
	if j2 == 0 do return set_error(ps, 2, 203)
	if j1 == j2 do return set_error(ps, 0, 222)
	if errcode := addlink_id(ps, net.nlinks + 1, ps.tok[0]); errcode != 0 do return set_error(ps, 0, errcode)
	net.nlinks += 1
	k := net.nlinks
	p.link_comment[k] = kept(ps.comment, MAXMSG)
	net.n1[k], net.n2[k] = i32(j1), i32(j2)
	if p.units == .SI {
		net.len[k], net.diam[k] = 100, 254
	} else {
		net.len[k], net.diam[k] = 330, 10
	}
	switch p.hyd.formflag {
	case .HW:
		net.kc[k] = 130
	case .DW:
		net.kc[k] = 0.0005
	case .CM:
		net.kc[k] = 0.01
	}
	net.km[k] = 0
	net.link_kb[k] = MISSING
	net.link_kw[k] = MISSING
	net.leak_area[k] = 0
	net.leak_expan[k] = 0
	net.link_type[k] = .PIPE
	net.init_status[k] = .OPEN
	net.init_setting[k] = net.kc[k]
	if n > 3 {
		x, ok := getfloat(ps.tok[3])
		if !ok || x <= 0 do return set_error(ps, 3, 202)
		net.len[k] = x
	}
	if n > 4 {
		x, ok := getfloat(ps.tok[4])
		if !ok || x <= 0 do return set_error(ps, 4, 202)
		net.diam[k] = x
	}
	if n > 5 {
		x, ok := getfloat(ps.tok[5])
		if !ok || x <= 0 do return set_error(ps, 5, 202)
		net.kc[k] = x
	}
	if n > 6 {
		if match(ps.tok[6], "CV") {
			net.link_type[k] = .CVPIPE
		} else if match(ps.tok[6], "CLOSED") {
			net.init_status[k] = .CLOSED
		} else if match(ps.tok[6], "OPEN") {
			net.init_status[k] = .OPEN
		} else {
			x, ok := getfloat(ps.tok[6])
			if !ok || x < 0 do return set_error(ps, 6, 202)
			net.km[k] = x
		}
	}
	if n > 7 {
		x, ok := getfloat(ps.tok[6])
		if !ok || x < 0 do return set_error(ps, 6, 202)
		net.km[k] = x
		if match(ps.tok[7], "CV") {
			net.link_type[k] = .CVPIPE
		} else if match(ps.tok[7], "CLOSED") {
			net.init_status[k] = .CLOSED
		} else if match(ps.tok[7], "OPEN") {
			net.init_status[k] = .OPEN
		} else {
			return set_error(ps, 7, 213)
		}
	}
	return 0
}

pumpdata :: proc(ps: ^Parser) -> int {
	p := ps.p
	net := &p.net
	if net.nlinks == p.max_links || net.npumps == p.max_pumps do return 200
	n := ps.ntok
	if n < 3 do return set_error(ps, -1, 0)
	j1 := findnode(p, ps.tok[1])
	if j1 == 0 do return set_error(ps, 1, 203)
	j2 := findnode(p, ps.tok[2])
	if j2 == 0 do return set_error(ps, 2, 203)
	if j1 == j2 do return set_error(ps, 0, 222)
	if errcode := addlink_id(ps, net.nlinks + 1, ps.tok[0]); errcode != 0 do return set_error(ps, 0, errcode)
	net.nlinks += 1
	net.npumps += 1
	k, m := net.nlinks, net.npumps
	p.link_comment[k] = kept(ps.comment, MAXMSG)
	net.n1[k], net.n2[k] = i32(j1), i32(j2)
	net.diam[k] = 0
	net.len[k] = 0
	net.kc[k] = 1
	net.km[k] = 0
	net.link_kb[k] = 0
	net.link_kw[k] = 0
	net.leak_area[k] = 0
	net.leak_expan[k] = 0
	net.link_type[k] = .PUMP
	net.init_status[k] = .OPEN
	net.init_setting[k] = 1
	net.pump_link[m] = i32(k)
	net.link_pump[k] = i32(m)
	net.pump_type[m] = .NOCURVE
	net.pump_hcurve[m] = 0
	net.pump_ecurve[m] = 0
	net.pump_upat[m] = 0
	net.pump_ecost[m] = 0
	net.pump_epat[m] = 0
	if n < 4 do return 0
	for i := 4; i < n; i += 2 {
		if match(ps.tok[i - 1], "POWER") {
			y, ok := getfloat(ps.tok[i])
			if !ok || y <= 0 do return set_error(ps, i, 202)
			net.pump_type[m] = .CONST_HP
			net.km[k] = y
		} else if match(ps.tok[i - 1], "HEAD") {
			c := findcurve(p, ps.tok[i])
			if c == 0 do return set_error(ps, i, 206)
			net.pump_type[m] = .CUSTOM
			net.pump_hcurve[m] = i32(c)
		} else if match(ps.tok[i - 1], "PATT") {
			pat := findpattern(p, ps.tok[i])
			if pat < 0 do return set_error(ps, i, 205)
			net.pump_upat[m] = i32(pat)
		} else if match(ps.tok[i - 1], "SPEE") {
			y, ok := getfloat(ps.tok[i])
			if !ok || y < 0 do return set_error(ps, i, 202)
			net.kc[k] = y
		} else {
			return set_error(ps, i - 1, 201)
		}
	}
	net.init_setting[k] = net.kc[k]
	return 0
}

// valvecheck: the connections a pressure or flow control valve may not
// have, to a fixed-grade node or in series with another such valve.
valvecheck :: proc(p: ^Project, index: int, t: Link_Type, j1, j2: int) -> int {
	net := &p.net
	if t == .PRV || t == .PSV || t == .FCV {
		if j1 > net.njuncs || j2 > net.njuncs do return 219
		for k in 1 ..= net.nvalves {
			if int(net.valve_link[k]) == index do continue
			l := net.valve_link[k]
			vj1, vj2 := int(net.n1[l]), int(net.n2[l])
			vt := net.link_type[l]
			if vt == .PRV && t == .PRV {
				if vj2 == j2 || vj2 == j1 || vj1 == j2 do return 220
			}
			if vt == .PSV && t == .PSV {
				if vj1 == j1 || vj1 == j2 || vj2 == j1 do return 220
			}
			if vt == .PSV && t == .PRV && vj1 == j2 do return 220
			if vt == .PRV && t == .PSV && vj2 == j1 do return 220
			if vt == .FCV && t == .PSV && vj2 == j1 do return 220
			if vt == .FCV && t == .PRV && vj1 == j2 do return 220
			if vt == .PSV && t == .FCV && vj1 == j2 do return 220
			if vt == .PRV && t == .FCV && vj2 == j1 do return 220
		}
	}
	return 0
}

valvedata :: proc(ps: ^Parser) -> int {
	p := ps.p
	net := &p.net
	if net.nlinks == p.max_links || net.nvalves == p.max_valves do return 200
	n := ps.ntok
	if n < 5 do return set_error(ps, -1, 0)
	j1 := findnode(p, ps.tok[1])
	if j1 == 0 do return set_error(ps, 1, 203)
	j2 := findnode(p, ps.tok[2])
	if j2 == 0 do return set_error(ps, 2, 203)
	if j1 == j2 do return set_error(ps, 0, 222)
	t: Link_Type
	switch {
	case match(ps.tok[4], "PRV"):
		t = .PRV
	case match(ps.tok[4], "PSV"):
		t = .PSV
	case match(ps.tok[4], "PBV"):
		t = .PBV
	case match(ps.tok[4], "FCV"):
		t = .FCV
	case match(ps.tok[4], "TCV"):
		t = .TCV
	case match(ps.tok[4], "GPV"):
		t = .GPV
	case match(ps.tok[4], "PCV"):
		t = .PCV
	case:
		return set_error(ps, 4, 213)
	}
	if valvecheck(p, net.nlinks, t, j1, j2) != 0 {
		if j1 > net.njuncs do return set_error(ps, 1, 219)
		if j2 > net.njuncs do return set_error(ps, 2, 219)
		return set_error(ps, -1, 220)
	}
	if errcode := addlink_id(ps, net.nlinks + 1, ps.tok[0]); errcode != 0 do return set_error(ps, 0, errcode)
	net.nvalves += 1
	net.nlinks += 1
	k, v := net.nlinks, net.nvalves
	p.link_comment[k] = kept(ps.comment, MAXMSG)
	net.n1[k], net.n2[k] = i32(j1), i32(j2)
	net.diam[k] = p.units == .SI ? 254 : 10
	net.len[k] = 0
	net.kc[k] = 0
	net.km[k] = 0
	net.link_kb[k] = 0
	net.link_kw[k] = 0
	net.leak_area[k] = 0
	net.leak_expan[k] = 0
	net.link_type[k] = t
	net.init_status[k] = .ACTIVE
	net.init_setting[k] = 0
	net.valve_link[v] = i32(k)
	net.link_valve[k] = i32(v)
	net.valve_curve[v] = 0
	x, ok := getfloat(ps.tok[3])
	if !ok || x <= 0 do return set_error(ps, 3, 202)
	net.diam[k] = x
	if n > 5 {
		if t == .GPV {
			c := findcurve(p, ps.tok[5])
			if c == 0 do return set_error(ps, 5, 206)
			net.kc[k] = f64(c)
			p.curve_type[c] = .HLOSS_CURVE
			net.init_status[k] = .OPEN
		} else {
			y, ok2 := getfloat(ps.tok[5])
			if !ok2 do return set_error(ps, 5, 202)
			net.kc[k] = y
		}
	}
	if n > 6 {
		y, ok2 := getfloat(ps.tok[6])
		if !ok2 || y < 0 do return set_error(ps, 6, 202)
		net.km[k] = y
	}
	if n > 7 && t == .PCV {
		c := findcurve(p, ps.tok[7])
		if c == 0 do return set_error(ps, 7, 206)
		net.valve_curve[v] = i32(c)
		p.curve_type[c] = .VALVE_CURVE
		if net.kc[k] > 100 do net.kc[k] = 100
	}
	net.init_setting[k] = net.kc[k]
	return 0
}

patterndata :: proc(ps: ^Parser) -> int {
	p := ps.p
	n := ps.ntok - 1
	if n < 1 do return 201
	i: int
	if ps.prev_pat >= 0 && ps.tok[0] == p.pattern_id[ps.prev_pat] {
		i = ps.prev_pat
	} else {
		i = findpattern(p, ps.tok[0])
		if i <= 0 do return set_error(ps, 0, 205)
	}
	if len(p.pattern_comment[i]) == 0 && len(ps.comment) > 0 do p.pattern_comment[i] = kept(ps.comment, MAXMSG)
	f := &ps.pattern_f[i]
	n1 := len(f)
	for _ in 1 ..= n do append(f, 1.0)
	for j in 1 ..= n {
		x, ok := getfloat(ps.tok[j])
		if !ok do return set_error(ps, j, 202)
		f[n1 + j - 1] = x
	}
	ps.prev_pat = i
	return 0
}

CURVE_TYPE_NAMES := [?]string{"VOLUME", "PUMP", "EFFIC", "HEADLOSS", "GENERIC", "VALVE"}

curvedata :: proc(ps: ^Parser) -> int {
	p := ps.p
	if ps.ntok < 3 do return 201
	x, okx := getfloat(ps.tok[1])
	if !okx do return set_error(ps, 1, 202)
	y, oky := getfloat(ps.tok[2])
	if !oky do return set_error(ps, 2, 202)
	ctype := -1
	if ps.ntok > 3 do ctype = findmatch(ps.tok[3], CURVE_TYPE_NAMES[:])
	i: int
	if ps.prev_curve > 0 && ps.tok[0] == p.curve_id[ps.prev_curve] {
		i = ps.prev_curve
	} else {
		i = findcurve(p, ps.tok[0])
		if i == 0 do return set_error(ps, 0, 206)
	}
	if len(p.curve_comment[i]) == 0 && len(ps.comment) > 0 do p.curve_comment[i] = kept(ps.comment, MAXMSG)
	append(&ps.curve_x[i], x)
	append(&ps.curve_y[i], y)
	if ctype >= 0 do p.curve_type[i] = Curve_Type(ctype)
	ps.prev_curve = i
	return 0
}

coordata :: proc(ps: ^Parser) -> int {
	if ps.ntok < 3 do return 0
	j := findnode(ps.p, ps.tok[0])
	if j == 0 do return 0
	x, okx := getfloat(ps.tok[1])
	if !okx do return 0
	y, oky := getfloat(ps.tok[2])
	if !oky do return 0
	ps.p.node_x[j], ps.p.node_y[j] = x, y
	return 0
}

// vertexdata: [VERTICES] link x y, appended to the link's bends.
vertexdata :: proc(ps: ^Parser) -> int {
	if ps.ntok < 3 do return 0
	j := findlink(ps.p, ps.tok[0])
	if j == 0 do return 0
	x, okx := getfloat(ps.tok[1])
	if !okx do return 0
	y, oky := getfloat(ps.tok[2])
	if !oky do return 0
	append(&ps.vx[j], x)
	append(&ps.vy[j], y)
	return 0
}

// tagdata: [TAGS] NODE|LINK id tag.
tagdata :: proc(ps: ^Parser) -> int {
	p := ps.p
	if ps.ntok < 3 do return 201
	if match(ps.tok[0], "NODE") {
		j := findnode(p, ps.tok[1])
		if j == 0 do return set_error(ps, 0, 203)
		p.node_tag[j] = kept(ps.tok[2], MAXMSG)
	} else if match(ps.tok[0], "LINK") {
		j := findlink(p, ps.tok[1])
		if j == 0 do return set_error(ps, 0, 203)
		p.link_tag[j] = kept(ps.tok[2], MAXMSG)
	}
	return 0
}

// kept: a copy of s, at most n bytes, from the current allocator.
kept :: proc(s: string, n: int) -> string {
	if len(s) == 0 do return ""
	return strings.clone(clip(s, n))
}
