package api

// edit.odin — the editing half of the toolkit: EN_init and every EN_set*,
// EN_add* and EN_delete* of epanet.c, with EPANET's checks, error codes
// and unit conversions, over the project the engine owns (epanet/edit.odin
// moves the data). An editing call runs in the project's arena, like the
// reader, so what it adds lives as long as the project.

import "base:runtime"
import "core:c"
import "core:c/libc"
import "core:mem/virtual"
import "core:strings"

import ep "../epanet"

MISSING :: ep.MISSING
SET_OPEN :: 1.e10
SET_CLOSED :: -1.e10

// arena_context: the context an editing call runs in.
arena_context :: proc "contextless" (p: ^Project) -> runtime.Context {
	context = runtime.default_context()
	context.allocator = virtual.arena_allocator(&p.arena)
	return context
}

// name_valid: an ID is 1 to MAXID bytes, no blank or ';', not quoted.
name_valid :: proc(id: string) -> bool {
	if len(id) < 1 || len(id) > MAXID || id[0] == '"' do return false
	return !strings.contains_any(id, " ;")
}

solver_open :: proc "contextless" (p: ^Project) -> bool {
	return p.open_hflag || p.hyd.openqflag
}

// ── the project ───────────────────────────────────────────────────────

@(export, link_name = "EN_init")
EN_init :: proc "c" (p: ^Project, rpt_file, out_file: cstring, units_type, headloss_type: c.int) -> c.int {
	context = arena_context(p)
	if units_type < 0 || units_type > 10 do return 251
	if headloss_type < 0 || headloss_type > 2 do return 251
	project_reset(p)
	p.rpt.messages = true
	p.rpt.rptflag = true
	errcode := openfiles(p, "", rpt_file, out_file)
	net := &p.net
	ep.set_defaults(p)
	p.flow_units = ep.Flow_Units(units_type)
	p.hyd.formflag = ep.Headloss_Formula(headloss_type)
	ep.project_alloc(p)
	// the tables the reader finishes, empty
	p.pattern_id = make([]string, 1)
	p.pattern_comment = make([]string, 1)
	p.patterns_by_id[""] = 0
	net.patterns = make([]ep.Pattern, 1)
	one := make([]f64, 1)
	one[0] = 1.0
	net.patterns[0] = {one}
	p.curve_id = make([]string, 1)
	p.curve_comment = make([]string, 1)
	p.curve_type = make([]ep.Curve_Type, 1)
	net.curves = make([]ep.Curve, 1)
	net.demand_first[1] = 1
	net.demand_base = make([]f64, 1)
	net.demand_pat = make([]i32, 1)
	p.demand_name = make([]string, 1)
	p.rule_label = make([]string, 1)
	net.rule_priority = make([]f64, 1)
	net.rule_enabled = make([]b32, 1)
	net.rule_premise_first = make([]i32, 2)
	net.rule_then_first = make([]i32, 2)
	net.rule_else_first = make([]i32, 1)
	net.rule_premise_first[0], net.rule_premise_first[1] = 1, 1
	net.rule_then_first[0], net.rule_then_first[1] = 1, 1
	net.rule_else_first[0] = 1
	net.premise_logop = make([]ep.Rule_Logic, 1)
	net.premise_object = make([]ep.Rule_Object, 1)
	net.premise_index = make([]i32, 1)
	net.premise_variable = make([]ep.Rule_Variable, 1)
	net.premise_relop = make([]ep.Rule_Op, 1)
	net.premise_status = make([]ep.Rule_Status, 1)
	net.premise_value = make([]f64, 1)
	net.action_link = make([]i32, 1)
	net.action_status = make([]ep.Rule_Status, 1)
	net.action_setting = make([]f64, 1)
	ep.init_report(p)
	ep.adjust_data(p)
	ep.init_units(p)
	ep.init_tanks(p)
	ep.convert_units(p)
	p.openflag = true
	sync_flags(p)
	return c.int(errcode)
}

@(export, link_name = "EN_settitle")
EN_settitle :: proc "c" (p: ^Project, line1, line2, line3: cstring) -> c.int {
	context = arena_context(p)
	if !p.openflag do return 102
	p.title[0] = strings.clone(ep.clip(string(line1), TITLELEN))
	p.title[1] = strings.clone(ep.clip(string(line2), TITLELEN))
	p.title[2] = strings.clone(ep.clip(string(line3), TITLELEN))
	return 0
}

@(export, link_name = "EN_saveinpfile")
EN_saveinpfile :: proc "c" (p: ^Project, filename: cstring) -> c.int {
	context = runtime.default_context()
	if !p.openflag do return 102
	return c.int(ep.save_inp(p, string(filename)))
}

// comment_of / tag_of: the table a comment or tag lives in, or nil.
comment_of :: proc "contextless" (p: ^Project, object, index: c.int) -> ^string {
	i := int(index)
	switch object {
	case 0:
		if i < 1 || i > p.net.nnodes do return nil
		return &p.node_comment[i]
	case 1:
		if i < 1 || i > p.net.nlinks do return nil
		return &p.link_comment[i]
	case 2:
		if i < 1 || i >= len(p.pattern_id) do return nil
		return &p.pattern_comment[i]
	case 3:
		if i < 1 || i >= len(p.curve_id) do return nil
		return &p.curve_comment[i]
	}
	return nil
}

tag_of :: proc "contextless" (p: ^Project, object, index: c.int) -> ^string {
	i := int(index)
	switch object {
	case 0:
		if i < 1 || i > p.net.nnodes do return nil
		return &p.node_tag[i]
	case 1:
		if i < 1 || i > p.net.nlinks do return nil
		return &p.link_tag[i]
	}
	return nil
}

@(export, link_name = "EN_setcomment")
EN_setcomment :: proc "c" (p: ^Project, object, index: c.int, comment: cstring) -> c.int {
	context = arena_context(p)
	slot := comment_of(p, object, index)
	if slot == nil do return 251
	slot^ = ep.kept(string(comment), MAXMSG)
	return 0
}

@(export, link_name = "EN_getcomment")
EN_getcomment :: proc "c" (p: ^Project, object, index: c.int, comment: [^]u8) -> c.int {
	comment[0] = 0
	slot := comment_of(p, object, index)
	if slot == nil do return 251
	put_str(comment, slot^, MAXMSG)
	return 0
}

@(export, link_name = "EN_settag")
EN_settag :: proc "c" (p: ^Project, object, index: c.int, tag: cstring) -> c.int {
	context = arena_context(p)
	slot := tag_of(p, object, index)
	if slot == nil do return 251
	slot^ = ep.kept(string(tag), MAXMSG)
	return 0
}

@(export, link_name = "EN_gettag")
EN_gettag :: proc "c" (p: ^Project, object, index: c.int, tag: [^]u8) -> c.int {
	tag[0] = 0
	slot := tag_of(p, object, index)
	if slot == nil do return 251
	put_str(tag, slot^, MAXMSG)
	return 0
}

// ── nodes ─────────────────────────────────────────────────────────────

@(export, link_name = "EN_addnode")
EN_addnode :: proc "c" (p: ^Project, id: cstring, node_type: c.int, index: ^c.int) -> c.int {
	context = arena_context(p)
	index^ = 0
	if !p.openflag do return 102
	if solver_open(p) do return 262
	s := string(id)
	if !name_valid(s) do return 252
	if ep.findnode(p, s) != 0 do return 215
	if node_type < 0 || node_type > 2 do return 251
	index^ = c.int(ep.add_node(p, s, ep.Node_Type(node_type)))
	return 0
}

@(export, link_name = "EN_deletenode")
EN_deletenode :: proc "c" (p: ^Project, index, action_code: c.int) -> c.int {
	context = arena_context(p)
	net := &p.net
	if !p.openflag do return 102
	if solver_open(p) do return 262
	i := int(index)
	if i <= 0 || i > net.nnodes do return 203
	if action_code < 0 || action_code > 1 do return 251
	if i == p.q.trace_node do return 260
	if action_code == 1 {
		if ep.in_controls(p, .NODE, i) do return 261
		for k in 1 ..= net.nlinks {
			if int(net.n1[k]) == i || int(net.n2[k]) == i do return 259
		}
	}
	ep.delete_node(p, i)
	return 0
}

@(export, link_name = "EN_setnodeid")
EN_setnodeid :: proc "c" (p: ^Project, index: c.int, newid: cstring) -> c.int {
	context = arena_context(p)
	if index <= 0 || int(index) > p.net.nnodes do return 203
	s := string(newid)
	if !name_valid(s) do return 252
	if ep.findnode(p, s) > 0 do return 215
	delete_key(&p.nodes_by_id, p.node_id[index])
	p.node_id[index] = strings.clone(s)
	p.nodes_by_id[p.node_id[index]] = i32(index)
	return 0
}

@(export, link_name = "EN_setcoord")
EN_setcoord :: proc "c" (p: ^Project, index: c.int, x, y: f64) -> c.int {
	if !p.openflag do return 102
	if index < 1 || int(index) > p.net.nnodes do return 203
	p.node_x[index], p.node_y[index] = x, y
	return 0
}

@(export, link_name = "EN_setjuncdata")
EN_setjuncdata :: proc "c" (p: ^Project, index: c.int, elev, dmnd: f64, dmndpat: cstring) -> c.int {
	context = arena_context(p)
	net := &p.net
	if !p.openflag do return 102
	i := int(index)
	if i <= 0 || i > net.njuncs do return 203
	pat := 0
	if dmndpat != nil && len(dmndpat) > 0 {
		pat = ep.findpattern(p, string(dmndpat))
		if pat < 0 do return 205
	}
	d := dmnd / p.ucf[.FLOW]
	if first := int(net.demand_first[i]); first < int(net.demand_first[i + 1]) {
		net.demand_base[first] = d
		net.demand_pat[first] = i32(pat)
	} else {
		ep.add_demand(p, i, d, pat, "")
	}
	net.el[i] = elev / p.ucf[.ELEV]
	return 0
}

@(export, link_name = "EN_settankdata")
EN_settankdata :: proc "c" (p: ^Project, index: c.int, elev, initlvl, minlvl, maxlvl, diam, minvol: f64, volcurve: cstring) -> c.int {
	context = runtime.default_context()
	net, hyd := &p.net, &p.hyd
	u := &p.ucf
	if !p.openflag do return 102
	i := int(index)
	if i <= net.njuncs || i > net.nnodes do return 263
	j := i - net.njuncs
	if net.tank_area[j] == 0 do return 263
	if initlvl < 0 || minlvl < 0 || maxlvl < 0 do return 209
	if minlvl > initlvl || minlvl > maxlvl || initlvl > maxlvl do return 225
	if diam < 0 || minvol < 0 do return 209
	curve := 0
	area: f64
	if len(volcurve) > 0 {
		curve = ep.findcurve(p, string(volcurve))
		if curve == 0 do return 206
		cv := net.curves[curve]
		n := len(cv.x) - 1
		if minlvl < cv.x[0] || maxlvl > cv.x[n] do return 225
		area = (cv.y[n] - cv.y[0]) / (cv.x[n] - cv.x[0])
	} else {
		area = ep.PI * diam * diam / 4.0
	}
	net.el[i] = elev / u[.ELEV]
	net.tank_area[j] = area / u[.ELEV] / u[.ELEV]
	net.tank_h0[j] = (elev + initlvl) / u[.ELEV]
	net.tank_hmin[j] = (elev + minlvl) / u[.ELEV]
	net.tank_hmax[j] = (elev + maxlvl) / u[.ELEV]
	net.tank_vcurve[j] = i32(curve)
	if curve == 0 {
		if minvol > 0 {
			net.tank_vmin[j] = minvol / u[.VOLUME]
		} else {
			net.tank_vmin[j] = net.tank_area[j] * (net.tank_hmin[j] - elev / u[.ELEV])
		}
	} else {
		net.tank_vmin[j] = ep.tank_volume(net, hyd, j, net.tank_hmin[j])
	}
	net.tank_v0[j] = ep.tank_volume(net, hyd, j, net.tank_h0[j])
	net.tank_vmax[j] = ep.tank_volume(net, hyd, j, net.tank_hmax[j])
	return 0
}

@(export, link_name = "EN_setnodevalue")
EN_setnodevalue :: proc "c" (p: ^Project, index, property: c.int, value: f64) -> c.int {
	context = arena_context(p)
	net, hyd, q := &p.net, &p.hyd, &p.q
	u := &p.ucf
	value := value
	if !p.openflag do return 102
	i := int(index)
	if i <= 0 || i > net.nnodes do return 203
	nj := net.njuncs
	npats := len(net.patterns) - 1
	j := i - nj // the tank, when i > nj
	switch property {
	case 0: // elevation
		if i <= nj {
			net.el[i] = value / u[.ELEV]
		} else {
			dv := value / u[.ELEV] - net.el[i]
			net.tank_h0[j] += dv
			net.tank_hmin[j] += dv
			net.tank_hmax[j] += dv
			net.el[i] += dv
			hyd.head[i] += dv
		}
	case 1: // base demand, the primary category
		if i <= nj {
			if first := int(net.demand_first[i]); first < int(net.demand_first[i + 1]) do net.demand_base[first] = value / u[.FLOW]
		}
	case 2: // pattern
		pat := int(libc.round(value))
		if pat < 0 || pat > npats do return 205
		if i <= nj {
			if first := int(net.demand_first[i]); first < int(net.demand_first[i + 1]) do net.demand_pat[first] = i32(pat)
		} else {
			net.tank_pat[j] = i32(pat)
		}
	case 3: // emitter
		if i > nj do return 0
		if value < 0 do return 209
		if value > 0 {
			ecf := p.units == .US ? ep.PSI_PER_FT * hyd.spgrav : ep.M_PER_FT
			value = libc.pow(u[.FLOW] / value, hyd.qexp) / ecf
		}
		net.ke[i] = value
		if hyd.emitter_flow[i] == 0 do hyd.emitter_flow[i] = 1.0
	case 4: // initial quality
		if value < 0 do return 209
		net.c0[i] = value / u[.QUALITY]
		if i > nj do q.tank_c[j] = net.c0[i]
	case 5, 6, 7: // source quality, pattern, type
		if value < 0 do return 209
		if !net.has_source[i] {
			net.has_source[i] = true
			net.source_type[i] = .CONCEN
			net.source_c0[i] = 0
			net.source_pat[i] = 0
		}
		if property == 5 {
			net.source_c0[i] = value
		} else if property == 6 {
			pat := int(libc.round(value))
			if pat < 0 || pat > npats do return 205
			net.source_pat[i] = i32(pat)
		} else {
			t := int(libc.round(value))
			if t < 0 || t > 3 do return 251
			net.source_type[i] = ep.Source_Type(t)
		}
	case 8: // tank level
		if i <= nj do return 263
		if net.tank_area[j] == 0 { // a reservoir
			net.tank_h0[j] = value / u[.ELEV]
			net.tank_hmin[j] = net.tank_h0[j]
			net.tank_hmax[j] = net.tank_h0[j]
			net.el[i] = net.tank_h0[j]
			hyd.head[i] = net.tank_h0[j]
		} else {
			h := net.el[i] + value / u[.ELEV]
			if h > net.tank_hmax[j] || h < net.tank_hmin[j] do return 225
			net.tank_h0[j] = h
			net.tank_v0[j] = ep.tank_volume(net, hyd, j, h)
			hyd.tank_volume[j] = net.tank_v0[j]
			hyd.head[i] = h
		}
	case 17: // tank diameter
		if value <= 0 do return 209
		if i <= nj do return 263
		if net.tank_area[j] == 0 do return 263
		d := value / u[.ELEV]
		net.tank_area[j] = ep.PI * d * d / 4.0
		if net.tank_vcurve[j] > 0 {
			net.tank_vcurve[j] = 0
			net.tank_vmin[j] = net.tank_area[j] * (net.tank_hmin[j] - net.el[i])
		}
		net.tank_v0[j] = ep.tank_volume(net, hyd, j, net.tank_h0[j])
		net.tank_vmax[j] = ep.tank_volume(net, hyd, j, net.tank_hmax[j])
	case 18: // minimum volume
		if value < 0 do return 209
		if i <= nj do return 263
		if net.tank_area[j] == 0 do return 263
		if ci := int(net.tank_vcurve[j]); ci > 0 {
			cv := net.curves[ci]
			if value < cv.y[0] do return 225
			v := value / u[.VOLUME]
			h := ep.tank_grade(net, hyd, j, v)
			if h > net.tank_h0[j] || h > net.tank_hmax[j] do return 225
			net.tank_hmin[j] = h
			net.tank_vmin[j] = v
		} else {
			if value == 0 {
				net.tank_vmin[j] = net.tank_area[j] * (net.tank_hmin[j] - net.el[i])
			} else {
				net.tank_vmin[j] = value / u[.VOLUME]
			}
			net.tank_v0[j] = ep.tank_volume(net, hyd, j, net.tank_h0[j])
			net.tank_vmax[j] = ep.tank_volume(net, hyd, j, net.tank_hmax[j])
		}
	case 19: // volume curve
		ci := int(libc.round(value))
		if ci <= 0 || ci >= len(net.curves) do return 205
		if i <= nj do return 263
		if net.tank_area[j] == 0 do return 263
		cv := net.curves[ci]
		n := len(cv.x) - 1
		if (net.tank_hmin[j] - net.el[i]) * u[.ELEV] < cv.x[0] do return 225
		if (net.tank_hmax[j] - net.el[i]) * u[.ELEV] > cv.x[n] do return 225
		net.tank_vcurve[j] = i32(ci)
		net.tank_vmin[j] = ep.tank_volume(net, hyd, j, net.tank_hmin[j])
		net.tank_v0[j] = ep.tank_volume(net, hyd, j, net.tank_h0[j])
		net.tank_vmax[j] = ep.tank_volume(net, hyd, j, net.tank_hmax[j])
		net.tank_area[j] = (cv.y[n] - cv.y[0]) / (cv.x[n] - cv.x[0])
	case 20: // minimum level
		if value < 0 do return 209
		if i <= nj do return 263
		if net.tank_area[j] == 0 do return 263
		h := value / u[.ELEV] + net.el[i]
		if h >= net.tank_hmax[j] || h > net.tank_h0[j] do return 225
		if ci := int(net.tank_vcurve[j]); ci > 0 {
			if value < net.curves[ci].x[0] do return 225
			net.tank_vmin[j] = ep.tank_volume(net, hyd, j, h)
		}
		net.tank_hmin[j] = h
	case 21: // maximum level
		if value <= 0 do return 209
		if i <= nj do return 263
		if net.tank_area[j] == 0 do return 263
		h := value / u[.ELEV] + net.el[i]
		if h < net.tank_hmin[j] || h < net.tank_h0[j] do return 225
		if ci := int(net.tank_vcurve[j]); ci > 0 {
			cv := net.curves[ci]
			if value > cv.x[len(cv.x) - 1] do return 225
		}
		net.tank_hmax[j] = h
		net.tank_vmax[j] = ep.tank_volume(net, hyd, j, h)
	case 15: // mixing model
		m := int(libc.round(value))
		if i <= nj do return 263
		if m < 0 || m > 3 do return 251
		if net.tank_area[j] > 0 do net.tank_mix[j] = ep.Mix_Model(m)
	case 22: // mixing fraction
		if i <= nj do return 263
		if value < 0 || value > 1 do return 209
		if net.tank_area[j] > 0 do net.tank_v1frac[j] = value
	case 23: // tank bulk coefficient
		if i <= nj do return 263
		if net.tank_area[j] > 0 do net.tank_kb[j] = value / ep.SEC_PER_DAY
	case 26: // can overflow
		if net.node_type[i] != .TANK do return 263
		net.tank_overflow[j] = value != 0
	case:
		return 251
	}
	return 0
}

// ── demands ───────────────────────────────────────────────────────────

@(export, link_name = "EN_setdemandmodel")
EN_setdemandmodel :: proc "c" (p: ^Project, model: c.int, pmin, preq, pexp: f64) -> c.int {
	if model < 0 || model > 1 do return 251
	if model == 1 {
		if pexp <= 0 do return 208
		if pmin < 0 do return 208
		if preq - pmin < ep.MINPDIFF do return 208
	}
	p.hyd.demand_model = ep.Demand_Model(model)
	p.hyd.pmin = pmin / p.ucf[.PRESSURE]
	p.hyd.preq = preq / p.ucf[.PRESSURE]
	p.hyd.pexp = pexp
	return 0
}

@(export, link_name = "EN_adddemand")
EN_adddemand :: proc "c" (p: ^Project, node: c.int, base: f64, pattern, name: cstring) -> c.int {
	context = arena_context(p)
	if !p.openflag do return 102
	i := int(node)
	if i <= 0 || i > p.net.nnodes do return 203
	pat := 0
	if pattern != nil && len(pattern) > 0 {
		pat = ep.findpattern(p, string(pattern))
		if pat < 0 do return 205
	}
	if i > p.net.njuncs do return 0
	ep.add_demand(p, i, base / p.ucf[.FLOW], pat, name != nil ? string(name) : "")
	return 0
}

@(export, link_name = "EN_deletedemand")
EN_deletedemand :: proc "c" (p: ^Project, node, demand: c.int) -> c.int {
	context = arena_context(p)
	if !p.openflag do return 102
	i := int(node)
	if i <= 0 || i > p.net.nnodes do return 203
	if i <= p.net.njuncs {
		if p.net.demand_first[i] == p.net.demand_first[i + 1] do return 253
		if ep.demand_slot(p, i, int(demand)) < 0 do return 253
		ep.delete_demand(p, i, int(demand))
	}
	return 0
}

@(export, link_name = "EN_setbasedemand")
EN_setbasedemand :: proc "c" (p: ^Project, node, demand: c.int, base: f64) -> c.int {
	if !p.openflag do return 102
	if node <= 0 || int(node) > p.net.nnodes do return 203
	k := ep.demand_slot(p, int(node), int(demand))
	if k < 0 do return 253
	p.net.demand_base[k] = base / p.ucf[.FLOW]
	return 0
}

@(export, link_name = "EN_setdemandname")
EN_setdemandname :: proc "c" (p: ^Project, node, demand: c.int, name: cstring) -> c.int {
	context = arena_context(p)
	if !p.openflag do return 102
	if node <= 0 || int(node) > p.net.njuncs do return 203
	k := ep.demand_slot(p, int(node), int(demand))
	if k < 0 do return 253
	p.demand_name[k] = ep.kept(string(name), MAXID)
	return 0
}

@(export, link_name = "EN_setdemandpattern")
EN_setdemandpattern :: proc "c" (p: ^Project, node, demand, pat: c.int) -> c.int {
	if !p.openflag do return 102
	if node <= 0 || int(node) > p.net.nnodes do return 203
	if pat < 0 || int(pat) >= len(p.net.patterns) do return 205
	k := ep.demand_slot(p, int(node), int(demand))
	if k < 0 do return 253
	p.net.demand_pat[k] = pat
	return 0
}

// ── links ─────────────────────────────────────────────────────────────

@(export, link_name = "EN_addlink")
EN_addlink :: proc "c" (p: ^Project, id: cstring, link_type: c.int, from_node, to_node: cstring, index: ^c.int) -> c.int {
	context = arena_context(p)
	index^ = 0
	if !p.openflag do return 102
	if solver_open(p) do return 262
	s := string(id)
	if !name_valid(s) do return 252
	if ep.findlink(p, s) != 0 do return 215
	if link_type < 0 || link_type > 9 do return 251
	n1 := ep.findnode(p, string(from_node))
	n2 := ep.findnode(p, string(to_node))
	if n1 == 0 || n2 == 0 do return 203
	kind := ep.Link_Type(link_type)
	if kind > .PUMP {
		if errcode := ep.valvecheck(p, 0, kind, n1, n2); errcode != 0 do return c.int(errcode)
	}
	index^ = c.int(ep.add_link(p, s, kind, n1, n2))
	return 0
}

@(export, link_name = "EN_deletelink")
EN_deletelink :: proc "c" (p: ^Project, index, action_code: c.int) -> c.int {
	context = arena_context(p)
	if !p.openflag do return 102
	if solver_open(p) do return 262
	k := int(index)
	if k <= 0 || k > p.net.nlinks do return 204
	if action_code < 0 || action_code > 1 do return 251
	if action_code == 1 && ep.in_controls(p, .LINK, k) do return 261
	ep.delete_link(p, k)
	return 0
}

@(export, link_name = "EN_setlinkid")
EN_setlinkid :: proc "c" (p: ^Project, index: c.int, newid: cstring) -> c.int {
	context = arena_context(p)
	if index <= 0 || int(index) > p.net.nlinks do return 204
	s := string(newid)
	if !name_valid(s) do return 252
	if ep.findlink(p, s) > 0 do return 215
	delete_key(&p.links_by_id, p.link_id[index])
	p.link_id[index] = strings.clone(s)
	p.links_by_id[p.link_id[index]] = i32(index)
	return 0
}

@(export, link_name = "EN_setlinknodes")
EN_setlinknodes :: proc "c" (p: ^Project, index, node1, node2: c.int) -> c.int {
	context = runtime.default_context()
	net := &p.net
	if solver_open(p) do return 262
	k := int(index)
	if k <= 0 || k > net.nlinks do return 204
	if node1 < 1 || int(node1) > net.nnodes do return 203
	if node2 < 1 || int(node2) > net.nnodes do return 203
	if node1 == node2 do return 222
	if node1 == net.n1[k] && node2 == net.n2[k] do return 0
	if kind := net.link_type[k]; kind > .PUMP {
		if errcode := ep.valvecheck(p, k, kind, int(node1), int(node2)); errcode != 0 do return c.int(errcode)
	}
	net.n1[k], net.n2[k] = node1, node2
	return 0
}

@(export, link_name = "EN_setlinktype")
EN_setlinktype :: proc "c" (p: ^Project, index: ^c.int, link_type, action_code: c.int) -> c.int {
	context = arena_context(p)
	net := &p.net
	k := int(index^)
	if !p.openflag do return 102
	if solver_open(p) do return 262
	if link_type < 0 || link_type > 9 || action_code < 0 || action_code > 1 do return 251
	if k <= 0 || k > net.nlinks do return 204
	old, new := net.link_type[k], ep.Link_Type(link_type)
	if old == new do return 0
	if action_code == 1 && ep.in_controls(p, .LINK, k) do return 261
	if old <= .PIPE && new <= .PIPE {
		net.link_type[k] = new
		if new == .CVPIPE do net.init_status[k] = .OPEN
		return 0
	}
	id := p.link_id[k]
	n1, n2 := int(net.n1[k]), int(net.n2[k])
	if errcode := ep.valvecheck(p, k, new, n1, n2); errcode != 0 do return c.int(errcode)
	ep.delete_link(p, k)
	if new > .PUMP {
		if errcode := ep.valvecheck(p, 0, new, n1, n2); errcode != 0 {
			index^ = 0
			return c.int(errcode)
		}
	}
	index^ = c.int(ep.add_link(p, id, new, n1, n2))
	return 0
}

@(export, link_name = "EN_setpipedata")
EN_setpipedata :: proc "c" (p: ^Project, index: c.int, length, diam, rough, mloss: f64) -> c.int {
	net, hyd := &p.net, &p.hyd
	u := &p.ucf
	if !p.openflag do return 102
	k := int(index)
	if k <= 0 || k > net.nlinks do return 204
	if net.link_type[k] > .PIPE do return 0
	if length <= 0 || diam <= 0 || rough <= 0 || mloss < 0 do return 211
	net.len[k] = length / u[.ELEV]
	net.diam[k] = diam / u[.DIAM]
	net.kc[k] = rough
	if hyd.formflag == .DW do net.kc[k] /= 1000.0 * u[.ELEV]
	d2 := net.diam[k] * net.diam[k]
	net.km[k] = 0.02517 * mloss / d2 / d2
	if p.open_hflag {
		ep.resist_coeff(net, hyd, k)
	} else {
		net.init_setting[k] = net.kc[k]
	}
	return 0
}

@(export, link_name = "EN_setheadcurveindex")
EN_setheadcurveindex :: proc "c" (p: ^Project, link, curve: c.int) -> c.int {
	net := &p.net
	if !p.openflag do return 102
	k := int(link)
	if k < 1 || k > net.nlinks do return 204
	if net.link_type[k] != .PUMP do return 0
	if curve < 0 || int(curve) >= len(net.curves) do return 206
	net.pump_hcurve[net.link_pump[k]] = curve
	net.km[k] = 0
	return 0
}

// change_valve_type keeps the setting in the new type's units
// (project.c changevalvetype).
change_valve_type :: proc(p: ^Project, k: int, kind: ep.Link_Type) -> c.int {
	net := &p.net
	if net.link_type[k] <= .PUMP do return 264
	if errcode := ep.valvecheck(p, k, kind, int(net.n1[k]), int(net.n2[k])); errcode != 0 do return c.int(errcode)
	setting := net.init_setting[k]
	#partial switch net.link_type[k] {
	case .FCV:
		setting *= p.ucf[.FLOW]
	case .PRV, .PSV, .PBV:
		setting *= p.ucf[.PRESSURE]
	case .GPV:
		setting = 0
	}
	#partial switch kind {
	case .FCV:
		setting /= p.ucf[.FLOW]
	case .PRV, .PSV, .PBV:
		setting /= p.ucf[.PRESSURE]
	}
	if kind == .GPV do setting = 0
	if kind == .PCV do setting = min(setting, 100.0)
	net.kc[k] = setting
	net.init_setting[k] = setting
	net.link_type[k] = kind
	return 0
}

@(export, link_name = "EN_setlinkvalue")
EN_setlinkvalue :: proc "c" (p: ^Project, index, property: c.int, value: f64) -> c.int {
	context = runtime.default_context()
	net, hyd := &p.net, &p.hyd
	u := &p.ucf
	value := value
	if !p.openflag do return 102
	k := int(index)
	if k <= 0 || k > net.nlinks do return 204
	kind := net.link_type[k]
	npats := len(net.patterns) - 1
	ncurves := len(net.curves) - 1
	switch property {
	case 0: // diameter
		if kind != .PUMP {
			if value <= 0 do return 211
			value /= u[.DIAM]
			r := net.diam[k] / value
			net.km[k] *= (r * r) * (r * r)
			net.diam[k] = value
			ep.resist_coeff(net, hyd, k)
		}
	case 1: // length
		if kind <= .PIPE {
			if value <= 0 do return 211
			net.len[k] = value / u[.ELEV]
			ep.resist_coeff(net, hyd, k)
		}
	case 2: // roughness
		if kind <= .PIPE {
			if value <= 0 do return 211
			net.kc[k] = value
			if hyd.formflag == .DW do net.kc[k] /= 1000.0 * u[.ELEV]
			if p.open_hflag {
				ep.resist_coeff(net, hyd, k)
			} else {
				net.init_setting[k] = net.kc[k]
			}
		}
	case 3: // minor loss
		if kind != .PUMP {
			if value < 0 do return 211
			d2 := net.diam[k] * net.diam[k]
			net.km[k] = 0.02517 * value / d2 / d2
		}
	case 4, 11: // initial status, status
		if kind == .CVPIPE do return 207
		s := int(libc.round(value))
		if s < 0 || s > 1 do return 211
		if property == 4 {
			net.init_status[k] = s == 0 ? .CLOSED : .OPEN
		} else {
			ep.set_link_status(net, hyd, k, s)
		}
	case 5, 12: // initial setting, setting
		if kind == .PIPE || kind == .CVPIPE {
			if errcode := EN_setlinkvalue(p, index, 2, value); errcode != 0 do return errcode
			if property == 5 do net.init_setting[k] = net.kc[k]
		} else {
			#partial switch kind {
			case .PUMP:
				if value < 0 do return 211
			case .PRV, .PSV, .PBV:
				value /= u[.PRESSURE]
			case .FCV:
				value /= u[.FLOW]
			case .TCV, .PCV:
			case .GPV:
				return 207
			case:
				return 0
			}
			if property == 5 {
				net.kc[k] = value
				net.init_setting[k] = value
				if kind > .PUMP && kind != .GPV do net.init_status[k] = .ACTIVE
			} else {
				ep.set_link_setting(net, hyd, k, value)
			}
		}
	case 6: // bulk coefficient
		if kind <= .PIPE do net.link_kb[k] = value / ep.SEC_PER_DAY
	case 7: // wall coefficient
		if kind <= .PIPE do net.link_kw[k] = value / ep.SEC_PER_DAY
	case 15: // pump speed pattern
		if kind == .PUMP {
			pat := int(libc.round(value))
			if pat < 0 || pat > npats do return 205
			net.pump_upat[net.link_pump[k]] = i32(pat)
		}
	case 18: // pump power
		if kind == .PUMP {
			if value <= 0 do return 211
			m := net.link_pump[k]
			net.pump_type[m] = .CONST_HP
			net.pump_hcurve[m] = 0
			net.km[k] = value
		}
	case 19: // pump head curve
		if kind == .PUMP do return EN_setheadcurveindex(p, index, c.int(libc.round(value)))
	case 20: // pump efficiency curve
		if kind == .PUMP {
			ci := int(libc.round(value))
			if ci < 0 || ci > ncurves do return 205
			net.pump_ecurve[net.link_pump[k]] = i32(ci)
		}
	case 21: // pump energy price
		if kind == .PUMP {
			if value < 0 do return 211
			net.pump_ecost[net.link_pump[k]] = value
		}
	case 22: // pump price pattern
		if kind == .PUMP {
			pat := int(libc.round(value))
			if pat < 0 || pat > npats do return 205
			net.pump_epat[net.link_pump[k]] = i32(pat)
		}
	case 25: // PCV curve
		if kind == .PCV {
			ci := int(libc.round(value))
			if ci < 0 || ci > ncurves do return 206
			net.valve_curve[net.link_valve[k]] = i32(ci)
		}
	case 24: // GPV curve
		if kind == .GPV {
			ci := int(libc.round(value))
			if ci < 0 || ci > ncurves do return 206
			net.kc[k] = f64(ci)
			if !p.open_hflag do net.init_setting[k] = f64(ci)
		}
	case 26: // leak area
		if value < 0 do return 211
		net.leak_area[k] = value * u[.LENGTH]
	case 27: // leak expansion
		if value < 0 do return 211
		net.leak_expan[k] = value * u[.LENGTH]
	case 29: // valve type
		if solver_open(p) do return 262
		if kind <= .PUMP do return 264
		vt := int(libc.round(value))
		if vt < int(ep.Link_Type.PRV) || vt > int(ep.Link_Type.PCV) do return 213
		if ep.Link_Type(vt) == kind do return 0
		return change_valve_type(p, k, ep.Link_Type(vt))
	case:
		return 251
	}
	return 0
}

@(export, link_name = "EN_getvertex")
EN_getvertex :: proc "c" (p: ^Project, index, vertex: c.int, x, y: ^f64) -> c.int {
	x^, y^ = MISSING, MISSING
	if !p.openflag do return 102
	if index <= 0 || int(index) > p.net.nlinks do return 204
	vx := p.vertex_x[index]
	if vx == nil do return 255
	if vertex <= 0 || int(vertex) > len(vx) do return 255
	x^ = vx[vertex - 1]
	y^ = p.vertex_y[index][vertex - 1]
	return 0
}

@(export, link_name = "EN_setvertex")
EN_setvertex :: proc "c" (p: ^Project, index, vertex: c.int, x, y: f64) -> c.int {
	if !p.openflag do return 102
	if index <= 0 || int(index) > p.net.nlinks do return 204
	vx := p.vertex_x[index]
	if vx == nil do return 255
	if vertex <= 0 || int(vertex) > len(vx) do return 255
	vx[vertex - 1] = x
	p.vertex_y[index][vertex - 1] = y
	return 0
}

@(export, link_name = "EN_setvertices")
EN_setvertices :: proc "c" (p: ^Project, index: c.int, x, y: [^]f64, count: c.int) -> c.int {
	context = arena_context(p)
	if !p.openflag do return 102
	if index <= 0 || int(index) > p.net.nlinks do return 204
	n := max(int(count), 0)
	ep.set_vertices(p, int(index), x[:n], y[:n])
	return 0
}

// ── patterns ──────────────────────────────────────────────────────────

@(export, link_name = "EN_addpattern")
EN_addpattern :: proc "c" (p: ^Project, id: cstring) -> c.int {
	context = arena_context(p)
	if !p.openflag do return 102
	i: c.int
	if EN_getpatternindex(p, id, &i) == 0 do return 215
	if !name_valid(string(id)) do return 252
	ep.add_pattern_entry(p, string(id))
	return 0
}

@(export, link_name = "EN_deletepattern")
EN_deletepattern :: proc "c" (p: ^Project, index: c.int) -> c.int {
	context = arena_context(p)
	if !p.openflag do return 102
	if solver_open(p) do return 262
	if index < 1 || int(index) >= len(p.net.patterns) do return 205
	ep.delete_pattern_entry(p, int(index))
	return 0
}

@(export, link_name = "EN_setpattern")
EN_setpattern :: proc "c" (p: ^Project, index: c.int, values: [^]f64, length: c.int) -> c.int {
	context = arena_context(p)
	if !p.openflag do return 102
	if index <= 0 || int(index) >= len(p.net.patterns) do return 205
	if values == nil do return 205
	if length <= 0 do return 202
	f := make([]f64, int(length))
	copy(f, values[:length])
	p.net.patterns[index] = {f}
	return 0
}

@(export, link_name = "EN_setpatternid")
EN_setpatternid :: proc "c" (p: ^Project, index: c.int, id: cstring) -> c.int {
	context = arena_context(p)
	if !p.openflag do return 102
	n := len(p.net.patterns) - 1
	if index < 1 || int(index) > n do return 205
	s := string(id)
	if !name_valid(s) do return 252
	for i in 1 ..= n do if i != int(index) && p.pattern_id[i] == s do return 215
	delete_key(&p.patterns_by_id, p.pattern_id[index])
	p.pattern_id[index] = strings.clone(s)
	p.patterns_by_id[p.pattern_id[index]] = index
	return 0
}

@(export, link_name = "EN_setpatternvalue")
EN_setpatternvalue :: proc "c" (p: ^Project, index, period: c.int, value: f64) -> c.int {
	if !p.openflag do return 102
	if index <= 0 || int(index) >= len(p.net.patterns) do return 205
	f := p.net.patterns[index].f
	if period <= 0 || int(period) > len(f) do return 251
	f[period - 1] = value
	return 0
}

@(export, link_name = "EN_loadpatternfile")
EN_loadpatternfile :: proc "c" (p: ^Project, filename, id: cstring) -> c.int {
	context = arena_context(p)
	if !p.openflag do return 102
	file := libc.fopen(filename, "r")
	if file == nil do return 302
	i: c.int
	err := EN_getpatternindex(p, id, &i)
	if err == 205 {
		if err = EN_addpattern(p, id); err != 0 {
			libc.fclose(file)
			return err
		}
		i = c.int(len(p.net.patterns) - 1)
	}
	values := make([dynamic]f64, context.temp_allocator)
	defer free_all(context.temp_allocator)
	line: [MAXLINE + 1]u8
	for libc.fgets(&line[0], MAXLINE + 1, file) != nil {
		tok := ep.first_token(string(cstring(&line[0])))
		if len(tok) == 0 do continue
		if v, ok := ep.getfloat(tok); ok do append(&values, v)
	}
	libc.fclose(file)
	if len(values) == 0 do return 202
	return EN_setpattern(p, i, raw_data(values), c.int(len(values)))
}

// ── curves ────────────────────────────────────────────────────────────

@(export, link_name = "EN_addcurve")
EN_addcurve :: proc "c" (p: ^Project, id: cstring) -> c.int {
	context = arena_context(p)
	if !p.openflag do return 102
	i: c.int
	if EN_getcurveindex(p, id, &i) == 0 do return 215
	if !name_valid(string(id)) do return 252
	ep.add_curve_entry(p, string(id))
	return 0
}

@(export, link_name = "EN_deletecurve")
EN_deletecurve :: proc "c" (p: ^Project, index: c.int) -> c.int {
	context = arena_context(p)
	if !p.openflag do return 102
	if solver_open(p) do return 262
	if index < 1 || int(index) >= len(p.net.curves) do return 206
	ep.delete_curve_entry(p, int(index))
	return 0
}

@(export, link_name = "EN_setcurve")
EN_setcurve :: proc "c" (p: ^Project, index: c.int, xs, ys: [^]f64, n: c.int) -> c.int {
	context = arena_context(p)
	if !p.openflag do return 102
	if index <= 0 || int(index) >= len(p.net.curves) do return 206
	if xs == nil || ys == nil do return 206
	if n <= 0 do return 202
	for j in 1 ..< int(n) do if xs[j - 1] >= xs[j] do return 230
	x := make([]f64, int(n))
	y := make([]f64, int(n))
	copy(x, xs[:n])
	copy(y, ys[:n])
	p.net.curves[index] = {x, y}
	return 0
}

@(export, link_name = "EN_setcurveid")
EN_setcurveid :: proc "c" (p: ^Project, index: c.int, id: cstring) -> c.int {
	context = arena_context(p)
	if !p.openflag do return 102
	n := len(p.net.curves) - 1
	if index < 1 || int(index) > n do return 206
	s := string(id)
	if !name_valid(s) do return 252
	for i in 1 ..= n do if i != int(index) && p.curve_id[i] == s do return 215
	delete_key(&p.curves_by_id, p.curve_id[index])
	p.curve_id[index] = strings.clone(s)
	p.curves_by_id[p.curve_id[index]] = index
	return 0
}

@(export, link_name = "EN_setcurvetype")
EN_setcurvetype :: proc "c" (p: ^Project, index, kind: c.int) -> c.int {
	if !p.openflag do return 102
	if index < 1 || int(index) >= len(p.net.curves) do return 206
	if kind < 0 || kind > 5 do return 251
	p.curve_type[index] = ep.Curve_Type(kind)
	return 0
}

@(export, link_name = "EN_setcurvevalue")
EN_setcurvevalue :: proc "c" (p: ^Project, curve, point: c.int, x, y: f64) -> c.int {
	context = arena_context(p)
	if !p.openflag do return 102
	if curve <= 0 || int(curve) >= len(p.net.curves) do return 206
	cv := &p.net.curves[curve]
	if point <= 0 do return 251
	n := int(point) - 1
	x1, x2 := -1.e37, 1.e37
	if n - 1 >= 0 && n - 1 < len(cv.x) do x1 = cv.x[n - 1]
	if n + 1 < len(cv.x) do x2 = cv.x[n + 1]
	if x <= x1 || x >= x2 do return 230
	if n >= len(cv.x) {
		cv.x = ep.plus_one(cv.x)
		cv.y = ep.plus_one(cv.y)
		n = len(cv.x) - 1
	}
	cv.x[n], cv.y[n] = x, y
	return 0
}

// ── simple controls ───────────────────────────────────────────────────

// control_values checks and converts a control's properties (project.c
// setcontrol); the eight fields are returned.
control_values :: proc "contextless" (p: ^Project, kind, link: int, setting: f64, node: int, level: f64) ->
	(ctype: ep.Control_Type, status: ep.Status, s: f64, t: i64, grade: f64, nodex: int, errcode: int) {
	net := &p.net
	u := &p.ucf
	lt := net.link_type[link]
	status = .ACTIVE
	s = MISSING
	nodex = node
	if lt == .CVPIPE do return ctype, status, s, t, grade, nodex, 207
	if kind < 0 || kind > 3 do return ctype, status, s, t, grade, nodex, 251
	ctype = ep.Control_Type(kind)
	if ctype == .LOWLEVEL || ctype == .HILEVEL {
		if node < 1 || node > net.nnodes do return ctype, status, s, t, grade, nodex, 203
	} else {
		nodex = 0
	}
	if setting == SET_OPEN {
		status = .OPEN
		if lt == .PUMP do s = 1.0
		if lt == .GPV do s = net.kc[link]
	} else if setting == SET_CLOSED {
		status = .CLOSED
		if lt == .PUMP do s = 0.0
		if lt == .GPV do s = net.kc[link]
	} else {
		s = setting
		#partial switch lt {
		case .PIPE, .PUMP:
			if s < 0 do return ctype, status, s, t, grade, nodex, 202
			status = s == 0 ? .CLOSED : .OPEN
		case .PRV, .PSV, .PBV:
			s /= u[.PRESSURE]
		case .FCV:
			s /= u[.FLOW]
		case .GPV:
			if s == 0 {
				status = .CLOSED
			} else if s == 1 {
				status = .OPEN
			} else {
				return ctype, status, s, t, grade, nodex, 202
			}
			s = net.kc[link]
		}
	}
	if ctype == .LOWLEVEL || ctype == .HILEVEL {
		if nodex > net.njuncs {
			grade = net.el[nodex] + level / u[.ELEV]
		} else {
			grade = net.el[nodex] + level / u[.PRESSURE]
		}
	} else {
		t = i64(level)
		if t < 0 do return ctype, status, s, t, grade, nodex, 202
	}
	return
}

put_control :: proc "contextless" (p: ^Project, c: int, ctype: ep.Control_Type, status: ep.Status, s: f64, t: i64, grade: f64, link, node: int) {
	net := &p.net
	net.control_link[c] = i32(link)
	net.control_node[c] = i32(node)
	net.control_type[c] = ctype
	net.control_status[c] = status
	net.control_setting[c] = s
	net.control_time[c] = t
	net.control_grade[c] = grade
	net.control_enabled[c] = true
}

@(export, link_name = "EN_addcontrol")
EN_addcontrol :: proc "c" (p: ^Project, kind, link: c.int, setting: f64, node: c.int, level: f64, index: ^c.int) -> c.int {
	context = arena_context(p)
	if !p.openflag do return 102
	if link <= 0 || int(link) > p.net.nlinks do return 204
	ctype, status, s, t, grade, nodex, errcode := control_values(p, int(kind), int(link), setting, int(node), level)
	if errcode > 0 do return c.int(errcode)
	n := ep.add_control(p)
	put_control(p, n, ctype, status, s, t, grade, int(link), nodex)
	index^ = c.int(n)
	return 0
}

@(export, link_name = "EN_setcontrol")
EN_setcontrol :: proc "c" (p: ^Project, index, kind, link: c.int, setting: f64, node: c.int, level: f64) -> c.int {
	if !p.openflag do return 102
	if index <= 0 || int(index) > p.net.ncontrols do return 241
	if link == 0 {
		p.net.control_link[index] = 0
		return 0
	}
	if link < 0 || int(link) > p.net.nlinks do return 204
	ctype, status, s, t, grade, nodex, errcode := control_values(p, int(kind), int(link), setting, int(node), level)
	if errcode > 0 do return c.int(errcode)
	put_control(p, int(index), ctype, status, s, t, grade, int(link), nodex)
	return 0
}

@(export, link_name = "EN_deletecontrol")
EN_deletecontrol :: proc "c" (p: ^Project, index: c.int) -> c.int {
	context = runtime.default_context()
	if index <= 0 || int(index) > p.net.ncontrols do return 241
	ep.delete_control(p, int(index))
	return 0
}

@(export, link_name = "EN_setcontrolenabled")
EN_setcontrolenabled :: proc "c" (p: ^Project, index, enabled: c.int) -> c.int {
	if enabled != 0 && enabled != 1 do return 202
	if !p.openflag do return 102
	if index <= 0 || int(index) > p.net.ncontrols do return 241
	p.net.control_enabled[index] = enabled == 1
	return 0
}

// ── rules ─────────────────────────────────────────────────────────────

@(export, link_name = "EN_addrule")
EN_addrule :: proc "c" (p: ^Project, rule: cstring) -> c.int {
	context = arena_context(p)
	return c.int(ep.add_rule_text(p, string(rule)))
}

@(export, link_name = "EN_deleterule")
EN_deleterule :: proc "c" (p: ^Project, index: c.int) -> c.int {
	context = arena_context(p)
	if index < 1 || int(index) > p.net.nrules do return 257
	ep.delete_rule(p, int(index))
	return 0
}

@(export, link_name = "EN_setrulepriority")
EN_setrulepriority :: proc "c" (p: ^Project, index: c.int, priority: f64) -> c.int {
	if index <= 0 || int(index) > p.net.nrules do return 257
	p.net.rule_priority[index] = priority
	return 0
}

@(export, link_name = "EN_setruleenabled")
EN_setruleenabled :: proc "c" (p: ^Project, index, enabled: c.int) -> c.int {
	if enabled != 0 && enabled != 1 do return 202
	if !p.openflag do return 102
	if index <= 0 || int(index) > p.net.nrules do return 257
	p.net.rule_enabled[index] = enabled == 1
	return 0
}

// premise_at: rule r's n-th premise slot, or -1.
premise_at :: proc "contextless" (p: ^Project, r, n: c.int) -> int {
	net := &p.net
	if r < 1 || int(r) > net.nrules do return -2
	k := int(net.rule_premise_first[r]) + int(n) - 1
	if n < 1 || k >= int(net.rule_premise_first[r + 1]) do return -1
	return k
}

@(export, link_name = "EN_setpremise")
EN_setpremise :: proc "c" (p: ^Project, rule, premise, logop, object, obj_index, variable, relop, status: c.int, value: f64) -> c.int {
	k := premise_at(p, rule, premise)
	if k == -2 do return 257
	if k < 0 do return 258
	net := &p.net
	net.premise_logop[k] = ep.Rule_Logic(logop)
	net.premise_object[k] = ep.Rule_Object(object)
	net.premise_index[k] = obj_index
	net.premise_variable[k] = ep.Rule_Variable(variable)
	net.premise_relop[k] = ep.Rule_Op(relop)
	net.premise_status[k] = ep.Rule_Status(status)
	net.premise_value[k] = value
	return 0
}

@(export, link_name = "EN_setpremiseindex")
EN_setpremiseindex :: proc "c" (p: ^Project, rule, premise, obj_index: c.int) -> c.int {
	k := premise_at(p, rule, premise)
	if k == -2 do return 257
	if k < 0 do return 258
	p.net.premise_index[k] = obj_index
	return 0
}

@(export, link_name = "EN_setpremisestatus")
EN_setpremisestatus :: proc "c" (p: ^Project, rule, premise, status: c.int) -> c.int {
	k := premise_at(p, rule, premise)
	if k == -2 do return 257
	if k < 0 do return 258
	p.net.premise_status[k] = ep.Rule_Status(status)
	return 0
}

@(export, link_name = "EN_setpremisevalue")
EN_setpremisevalue :: proc "c" (p: ^Project, rule, premise: c.int, value: f64) -> c.int {
	k := premise_at(p, rule, premise)
	if k == -2 do return 257
	if k < 0 do return 258
	p.net.premise_value[k] = value
	return 0
}

set_action :: proc "contextless" (p: ^Project, from, to: i32, n, link, status: c.int, setting: f64) -> c.int {
	net := &p.net
	k := int(from) + int(n) - 1
	if n < 1 || k >= int(to) do return 258
	net.action_link[k] = link
	net.action_status[k] = ep.Rule_Status(status)
	net.action_setting[k] = setting
	return 0
}

@(export, link_name = "EN_setthenaction")
EN_setthenaction :: proc "c" (p: ^Project, rule, action, link, status: c.int, setting: f64) -> c.int {
	net := &p.net
	if rule < 1 || int(rule) > net.nrules do return 257
	return set_action(p, net.rule_then_first[rule], net.rule_else_first[rule], action, link, status, setting)
}

@(export, link_name = "EN_setelseaction")
EN_setelseaction :: proc "c" (p: ^Project, rule, action, link, status: c.int, setting: f64) -> c.int {
	net := &p.net
	if rule < 1 || int(rule) > net.nrules do return 257
	return set_action(p, net.rule_else_first[rule], net.rule_then_first[rule + 1], action, link, status, setting)
}

// ── options, times, units, quality, the report ────────────────────────

@(export, link_name = "EN_setoption")
EN_setoption :: proc "c" (p: ^Project, option: c.int, value: f64) -> c.int {
	context = runtime.default_context()
	net, hyd, q := &p.net, &p.hyd, &p.q
	u := &p.ucf
	if !p.openflag do return 102
	if option == 14 { // unbalanced: < 0 halts, else extra trials
		hyd.extra_iter = int(value)
		if hyd.extra_iter < 0 do hyd.extra_iter = -1
		return 0
	}
	if value < 0 do return 213
	switch option {
	case 0:
		if value < 1 do return 213
		hyd.max_iter = int(value)
	case 1:
		if value < 1.e-8 || value > 1.e-1 do return 213
		hyd.hacc = value
	case 2:
		q.ctol = value / u[.QUALITY]
	case 3:
		if value <= 0 do return 213
		n := 1.0 / value
		ucf := libc.pow(u[.FLOW], n) / u[.PRESSURE]
		for i in 1 ..= net.njuncs {
			ke: f64
			if EN_getnodevalue(p, c.int(i), 3, &ke) == 0 && ke > 0 do net.ke[i] = ucf / libc.pow(ke, n)
		}
		hyd.qexp = n
	case 4:
		hyd.dmult = value
	case 5:
		hyd.head_error_limit = value / u[.HEAD]
	case 6:
		hyd.flow_change_limit = value / u[.FLOW]
	case 7:
		if p.open_hflag do return 262
		f := int(libc.round(value))
		if f < 0 || f > 2 do return 213
		hyd.formflag = ep.Headloss_Formula(f)
		hyd.hexp = hyd.formflag == .HW ? 1.852 : 2.0
	case 8:
		if value <= 1 || value > 100 do return 213
		hyd.epump = value
	case 9:
		hyd.ecost = value
	case 10:
		pat := int(libc.round(value))
		if pat < 0 || pat >= len(net.patterns) do return 205
		hyd.epat = pat
	case 11:
		p.dcost = value
	case 12:
		if value <= 0 do return 213
		if p.pressure_units == .PSI || p.pressure_units == .KPA || p.pressure_units == .BAR {
			u[.PRESSURE] *= value / hyd.spgrav
			ep.sync_ucf(p)
		}
		hyd.spgrav = value
	case 13:
		if value <= 0 do return 213
		hyd.viscos = value * ep.VISCOS
	case 15:
		hyd.check_freq = int(value)
	case 16:
		hyd.max_check = int(value)
	case 17:
		hyd.damp_limit = value
	case 18:
		q.diffus = value * ep.DIFFUS
	case 19:
		q.bulk_order = value
	case 20:
		if value != 0 && value != 1 do return 213
		q.wall_order = value
	case 21:
		q.tank_order = value
	case 22:
		q.climit = value / u[.QUALITY]
	case 23:
		pat := int(libc.round(value))
		if pat < 0 || pat >= len(net.patterns) do return 205
		net.def_pat = pat
	case 24:
		if value != 0 && value != 1 do return 213
		hyd.emit_backflow = value == 1
	case 25:
		unit := int(libc.round(value))
		if unit < 0 || unit > int(ep.Pressure_Units.FEET) do return 205
		p.pressure_units = ep.Pressure_Units(unit)
		dfactor, pfactor, hfactor, qfactor := u[.DEMAND], u[.PRESSURE], u[.HEAD], u[.FLOW]
		ep.init_units(p)
		ep.update_rule_units(p, u[.DEMAND] / dfactor, u[.PRESSURE] / pfactor, u[.HEAD] / hfactor, u[.FLOW] / qfactor)
	case 26:
		s := int(libc.round(value))
		if s < 0 || s > 2 do return 213
		p.rpt.status = s
		sync_flags(p)
	case:
		return 251
	}
	return 0
}

// assign_curve_types names each curve's kind from what uses it.
assign_curve_types :: proc "contextless" (p: ^Project) {
	net := &p.net
	for m in 1 ..= net.npumps {
		if j := net.pump_hcurve[m]; j > 0 do p.curve_type[j] = .PUMP_CURVE
		if j := net.pump_ecurve[m]; j > 0 do p.curve_type[j] = .EFFIC_CURVE
	}
	for t in 1 ..= net.ntanks {
		if j := net.tank_vcurve[t]; j > 0 do p.curve_type[j] = .VOLUME_CURVE
	}
	for v in 1 ..= net.nvalves {
		k := net.valve_link[v]
		if net.link_type[k] == .PCV {
			if j := net.valve_curve[v]; j > 0 do p.curve_type[j] = .VALVE_CURVE
		} else if net.link_type[k] == .GPV {
			if j := net.valve_curve[v]; j > 0 do p.curve_type[j] = .HLOSS_CURVE
		}
	}
}

@(export, link_name = "EN_setflowunits")
EN_setflowunits :: proc "c" (p: ^Project, units: c.int) -> c.int {
	context = runtime.default_context()
	net := &p.net
	u := &p.ucf
	if !p.openflag do return 102
	qfactor, vfactor, hfactor, efactor, pfactor, dfactor := u[.FLOW], u[.VOLUME], u[.HEAD], u[.ELEV], u[.PRESSURE], u[.DEMAND]
	p.flow_units = ep.Flow_Units(units)
	p.units = p.flow_units >= .LPS ? .SI : .US
	ep.init_units(p)
	ep.update_rule_units(p, u[.DEMAND] / dfactor, u[.PRESSURE] / pfactor, u[.HEAD] / hfactor, u[.FLOW] / qfactor)
	assign_curve_types(p)
	for i in 1 ..< len(net.curves) {
		xfactor, yfactor := 1.0, 1.0
		#partial switch p.curve_type[i] {
		case .VOLUME_CURVE:
			xfactor = efactor / u[.ELEV]
			yfactor = vfactor / u[.VOLUME]
		case .HLOSS_CURVE, .PUMP_CURVE:
			xfactor = qfactor / u[.FLOW]
			yfactor = hfactor / u[.HEAD]
		case .EFFIC_CURVE:
			xfactor = qfactor / u[.FLOW]
		}
		cv := net.curves[i]
		for j in 0 ..< len(cv.x) {
			cv.x[j] = cv.x[j] / xfactor
			cv.y[j] = cv.y[j] / yfactor
		}
	}
	return 0
}

@(export, link_name = "EN_settimeparam")
EN_settimeparam :: proc "c" (p: ^Project, param: c.int, value: c.long) -> c.int {
	t := &p.times
	if !p.openflag do return 102
	if value < 0 do return 213
	v := i64(value)
	switch param {
	case 0:
		t.dur = v
		if t.rstart > t.dur do t.rstart = 0
	case 1:
		if v == 0 do return 213
		t.hstep = min(v, t.pstep)
		t.hstep = min(t.rstep, t.hstep)
		t.qstep = min(t.qstep, t.hstep)
	case 2:
		if v == 0 do return 213
		t.qstep = min(v, t.hstep)
	case 3:
		if v == 0 do return 213
		t.pstep = v
		if t.hstep > t.pstep do t.hstep = t.pstep
	case 4:
		t.pstart = v
	case 5:
		if v == 0 do return 213
		t.rstep = v
		if t.hstep > t.rstep do t.hstep = t.rstep
	case 6:
		if v > t.dur do return 213
		t.rstart = v
	case 7:
		if v == 0 do return 213
		t.rulestep = min(v, t.hstep)
	case 8:
		if v > i64(ep.Time_Stat.RANGE) do return 213
		p.rpt.tstat = ep.Time_Stat(v)
	case 11:
		t.htime = v
	case 12:
		t.qtime = v
	case 10:
		if v > ep.SEC_PER_DAY do return 213
		t.tstart = v
	case:
		return 251
	}
	return 0
}

@(export, link_name = "EN_setqualtype")
EN_setqualtype :: proc "c" (p: ^Project, qual_type: c.int, chem_name, chem_units, trace_node: cstring) -> c.int {
	context = arena_context(p)
	net, q := &p.net, &p.q
	u := &p.ucf
	if !p.openflag do return 102
	if p.hyd.openqflag do return 262
	if qual_type < 0 || qual_type > 3 do return 251
	trace := 0
	if qual_type == 3 {
		trace = ep.findnode(p, string(trace_node))
		if trace == 0 do return 212
	}
	q.trace_node = trace
	old := q.kind
	q.kind = ep.Qual_Type(qual_type)
	q.ctol *= u[.QUALITY]
	ccf := 1.0
	#partial switch q.kind {
	case .CHEM:
		p.chem_name = ep.kept(string(chem_name), MAXID)
		p.chem_units = ep.kept(string(chem_units), MAXID)
		p.rpt.fields[.QUALITY].units = p.chem_units
		p.rpt.fields[.REACTRATE].units = strings.concatenate({p.chem_units, "/day"})
		ccf = 1.0 / ep.L_PER_FT3
	case .TRACE:
		p.chem_name = "TRACE"
		p.chem_units = "% from"
		p.rpt.fields[.QUALITY].units = "% from"
	case .AGE:
		p.chem_name = "AGE"
		p.chem_units = "hrs"
		p.rpt.fields[.QUALITY].units = "hrs"
	}
	if (q.kind == .AGE || q.kind == .TRACE) && old == .CHEM {
		for i in 1 ..= net.nnodes do net.c0[i] *= u[.QUALITY]
	}
	u[.QUALITY], u[.LINKQUAL], u[.REACTRATE] = ccf, ccf, ccf
	q.ctol /= u[.QUALITY]
	ep.sync_ucf(p)
	if old == .NONE && q.kind != .NONE do p.rpt.fields[.QUALITY].enabled = true
	return 0
}

@(export, link_name = "EN_setreport")
EN_setreport :: proc "c" (p: ^Project, format: cstring) -> c.int {
	context = arena_context(p)
	if !p.openflag do return 102
	if len(format) >= MAXLINE do return 250
	ps := ep.Parser{p = p}
	ps.comment = ep.gettokens(&ps, string(format))
	if ps.ntok == 0 do return 250
	if ep.reportdata(&ps) > 0 do return 250
	sync_flags(p)
	return 0
}

@(export, link_name = "EN_setreportcallback")
EN_setreportcallback :: proc "c" (p: ^Project, callback: proc "c" (user: rawptr, pr: rawptr, line: cstring)) -> c.int {
	p.rpt.callback = callback
	return 0
}

@(export, link_name = "EN_setreportcallbackuserdata")
EN_setreportcallbackuserdata :: proc "c" (p: ^Project, user: rawptr) -> c.int {
	p.rpt.callback_user = user
	return 0
}
