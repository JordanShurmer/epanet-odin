package epanet

// simulate.odin — a whole run of a Model as tables: every reporting
// period, every node and link, in the modeller's units. It is
// sim_from_model, a loop of sim_step with the out columns copied at the
// reporting times, sim_delete: nothing a program cannot do itself.

// Results is one run. Each [][]f64 is one flat allocation with a slice
// header per period, so a column is contiguous.
Results :: struct {
	periods:      []i32, // the reporting times, seconds
	units:        Units, // what the numbers are in
	node:         Node_Table, // [period][node]
	link:         Link_Table, // [period][link]
	warnings:     []Warning, // one per period
	energy:       []Pump_Usage, // one per pump
	mass_balance: []Mass_Balance, // one per chemical
	ids:          Ids, // the names, by row
}

Node_Table :: struct {
	demand, head, pressure, quality: [][]f64, // demand is EPANET's: everything leaving the node
}

Link_Table :: struct {
	flow, velocity, headloss, quality, setting: [][]f64,
	status:                                     [][]Status,
}

Units :: struct {
	flow, pressure, head, length, diameter, velocity, headloss, quality: string,
}

Pump_Usage :: struct {
	link:   int, // the row
	energy: Pump_Energy,
}

// simulate runs the Model from its start to its duration.
simulate :: proc(model: ^Model, allocator := context.allocator) -> (r: Results, warn: Warning, err: Error) {
	context.allocator = allocator
	sim, ids, ferr := sim_from_model(model)
	if ferr != nil {
		sim_delete(&sim)
		return r, nil, ferr
	}
	defer sim_delete(&sim)
	r.ids = ids
	nn, nl := sim.nodes.count, sim.links.count
	nchem := len(sim.chemicals)
	t := &model.times
	rstep := t.report_step > 0 ? t.report_step : 3600
	nmax := int((t.duration - t.report_start) / rstep) + 2
	if nmax < 1 do nmax = 1
	r.periods = make([]i32, nmax)
	r.warnings = make([]Warning, nmax)
	r.node.demand = table(nmax, nn)
	r.node.head = table(nmax, nn)
	r.node.pressure = table(nmax, nn)
	r.node.quality = table(nmax, nn)
	r.link.flow = table(nmax, nl)
	r.link.velocity = table(nmax, nl)
	r.link.headloss = table(nmax, nl)
	r.link.quality = table(nmax, nl)
	r.link.setting = table(nmax, nl)
	r.link.status = make([][]Status, nmax)
	status_block := make([]Status, nmax * nl)
	for k in 0 ..< nmax do r.link.status[k] = status_block[k * nl:(k + 1) * nl]

	n := 0
	for {
		at := sim.t
		dt, w, e := sim_step(&sim)
		if w > warn && w != .Nothing_To_Solve do warn = w
		if e != nil {
			err = e
			break
		}
		if sim.at_report && n < nmax {
			r.periods[n] = at
			r.warnings[n] = w
			copy(r.node.demand[n], sim.out.outflow[:nn])
			copy(r.node.head[n], sim.out.head[:nn])
			copy(r.node.pressure[n], sim.out.pressure[:nn])
			if nchem > 0 do copy(r.node.quality[n], sim.out.quality[0][:nn])
			copy(r.link.flow[n], sim.link_out.flow[:nl])
			copy(r.link.velocity[n], sim.link_out.velocity[:nl])
			copy(r.link.headloss[n], sim.link_out.headloss[:nl])
			if nchem > 0 do copy(r.link.quality[n], sim.link_out.quality[0][:nl])
			copy(r.link.setting[n], sim.link_out.setting[:nl])
			copy(r.link.status[n], sim.link_out.status[:nl])
			n += 1
		}
		if dt == 0 do break
	}
	r.periods = r.periods[:n]
	r.warnings = r.warnings[:n]
	r.node.demand, r.node.head, r.node.pressure, r.node.quality = r.node.demand[:n], r.node.head[:n], r.node.pressure[:n], r.node.quality[:n]
	r.link.flow, r.link.velocity, r.link.headloss = r.link.flow[:n], r.link.velocity[:n], r.link.headloss[:n]
	r.link.quality, r.link.setting, r.link.status = r.link.quality[:n], r.link.setting[:n], r.link.status[:n]

	if p := sim.engine; p != nil {
		f := &p.rpt.fields
		r.units = {f[.FLOW].units, f[.PRESSURE].units, f[.HEAD].units, f[.LENGTH].units, f[.DIAM].units, f[.VELOCITY].units, f[.HEADLOSS].units, f[.QUALITY].units}
		r.energy = make([]Pump_Usage, p.net.npumps)
		for pm in 1 ..= p.net.npumps {
			row := 0
			for k in 0 ..< nl do if int(sim.link_engine[k]) == int(p.net.pump_link[pm]) do row = k
			r.energy[pm - 1] = {row, p.hyd.energy[pm]}
		}
	}
	r.mass_balance = make([]Mass_Balance, nchem)
	copy(r.mass_balance, sim.balance)
	return
}

// table: n rows of m, one block.
table :: proc(n, m: int) -> [][]f64 {
	rows := make([][]f64, n)
	block := make([]f64, n * m)
	for i in 0 ..< n do rows[i] = block[i * m:(i + 1) * m]
	return rows
}

delete_results :: proc(r: ^Results, allocator := context.allocator) {
	context.allocator = allocator
	delete_table(r.node.demand)
	delete_table(r.node.head)
	delete_table(r.node.pressure)
	delete_table(r.node.quality)
	delete_table(r.link.flow)
	delete_table(r.link.velocity)
	delete_table(r.link.headloss)
	delete_table(r.link.quality)
	delete_table(r.link.setting)
	if len(r.link.status) > 0 do delete(r.link.status[0])
	delete(r.link.status)
	delete(r.periods)
	delete(r.warnings)
	delete(r.energy)
	delete(r.mass_balance)
	delete_ids(&r.ids)
	r^ = {}
}

delete_table :: proc(t: [][]f64) {
	if len(t) > 0 do delete(t[0])
	delete(t)
}
