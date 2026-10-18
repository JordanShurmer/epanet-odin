package epanet

// output.odin — the binary files (EPANET's output.c and the file opening
// in project.c): the hydraulics file a run writes period by period and
// quality reads back, and the output file of results per reporting
// period that the report's tables come from. Values go out as 4-byte
// floats and ints, EPANET's layout exactly. No context: scratch memory
// is the C library's.

import "core:c"
import "core:c/libc"

MAGICNUMBER :: 516114521
ENGINE_VERSION :: 201 // the hydraulics file's
EOFMARK :: 0x1A

// cpath: a file name as the C library takes it.
cpath :: proc "contextless" (buf: ^[1024]u8, s: string) -> cstring {
	n := min(len(s), 1023)
	copy(buf[:n], s)
	buf[n] = 0
	return cstring(raw_data(buf[:]))
}

write_i32 :: #force_inline proc "contextless" (f: ^libc.FILE, x: i32) -> bool {
	v := x
	return libc.fwrite(&v, size_of(i32), 1, f) == 1
}

// scratch: n floats from the C heap, zeroed; nil when it has none.
scratch :: #force_inline proc "contextless" (n: int) -> [^]f32 {
	return ([^]f32)(libc.calloc(c.size_t(n), size_of(f32)))
}

// ── opening ───────────────────────────────────────────────────────────

// openhydfile opens the hydraulics file: a scratch or named one to write
// with the network's sizes at its head, or a saved one to read, whose
// sizes must match.
openhydfile :: proc "contextless" (p: ^Project) -> int {
	net, o := &p.net, &p.out
	if o.hyd_file != nil {
		libc.fclose(o.hyd_file)
		o.hyd_file = nil
	}
	buf: [1024]u8
	switch o.hydflag {
	case .SCRATCH:
		o.hyd_fname = p.tmp_hyd_fname
		o.hyd_file = libc.fopen(cpath(&buf, o.hyd_fname), "w+b")
	case .SAVE:
		o.hyd_file = libc.fopen(cpath(&buf, o.hyd_fname), "w+b")
	case .USE:
		o.hyd_file = libc.fopen(cpath(&buf, o.hyd_fname), "rb")
	}
	if o.hyd_file == nil do return 305
	nsize: [6]i32
	if o.hydflag != .USE {
		nsize = {i32(net.nnodes), i32(net.nlinks), i32(net.ntanks), i32(net.npumps), i32(net.nvalves), i32(p.times.dur)}
		write_i32(o.hyd_file, MAGICNUMBER)
		write_i32(o.hyd_file, ENGINE_VERSION)
		libc.fwrite(&nsize[0], size_of(i32), 6, o.hyd_file)
	} else {
		magic, version: i32
		libc.fread(&magic, size_of(i32), 1, o.hyd_file)
		if magic != MAGICNUMBER do return 306
		libc.fread(&version, size_of(i32), 1, o.hyd_file)
		if version != ENGINE_VERSION do return 306
		if libc.fread(&nsize[0], size_of(i32), 6, o.hyd_file) < 6 do return 306
		if int(nsize[0]) != net.nnodes || int(nsize[1]) != net.nlinks || int(nsize[2]) != net.ntanks ||
		   int(nsize[3]) != net.npumps || int(nsize[4]) != net.nvalves || i64(nsize[5]) != p.times.dur {
			return 306
		}
		o.save_hflag = true
	}
	o.hyd_offset = i64(libc.ftell(o.hyd_file))
	return 0
}

// openoutfile starts the output file with the network and the energy
// results, and a scratch file beside it when a time statistic is wanted.
openoutfile :: proc "contextless" (p: ^Project) -> int {
	o := &p.out
	closeoutfile(p)
	buf: [1024]u8
	o.out_file = libc.fopen(cpath(&buf, o.out_fname), "w+b")
	if o.out_file == nil do return 304
	errcode := savenetdata(p)
	o.out_offset1 = i64(libc.ftell(o.out_file))
	if errcode == 0 do errcode = saveenergy(p)
	o.out_offset2 = i64(libc.ftell(o.out_file))
	if errcode == 0 {
		if p.rpt.tstat != .SERIES {
			o.tmp_out_file = libc.fopen(cpath(&buf, p.tmp_stat_fname), "w+b")
			if o.tmp_out_file == nil do errcode = 304
		} else {
			o.tmp_out_file = o.out_file
		}
	}
	return errcode
}

closeoutfile :: proc "contextless" (p: ^Project) {
	o := &p.out
	if o.tmp_out_file != o.out_file && o.tmp_out_file != nil {
		libc.fclose(o.tmp_out_file)
		o.tmp_out_file = nil
	}
	if o.out_file != nil {
		if o.out_file == o.tmp_out_file do o.tmp_out_file = nil
		libc.fclose(o.out_file)
		o.out_file = nil
	}
}

// ── the output file's prolog ──────────────────────────────────────────

// write_text puts s in a fixed-width field of n bytes, NUL padded.
write_text :: proc "contextless" (f: ^libc.FILE, s: string, n: int) {
	buf: [1024]u8
	k := min(len(s), n - 1, 1023)
	copy(buf[:k], s)
	for i in k ..< n do buf[i] = 0
	libc.fwrite(&buf[0], 1, c.size_t(n), f)
}

savenetdata :: proc "contextless" (p: ^Project) -> int {
	net, o, r, q := &p.net, &p.out, &p.rpt, &p.q
	f := o.out_file
	nmax := max(net.nnodes, net.nlinks) + 1
	nmax = max(nmax, 15)
	ibuf := ([^]i32)(libc.calloc(c.size_t(nmax), size_of(i32)))
	x := scratch(nmax)
	if ibuf == nil || x == nil {
		libc.free(ibuf)
		libc.free(x)
		return 101
	}
	defer libc.free(ibuf)
	defer libc.free(x)
	errcode := 0

	head := [15]i32 {
		MAGICNUMBER, 20012, // the version stays 2.00.12 so the GUI reads it
		i32(net.nnodes), i32(net.ntanks), i32(net.nlinks), i32(net.npumps), i32(net.nvalves),
		i32(q.kind), i32(q.trace_node), i32(p.flow_units), i32(p.pressure_units), i32(r.tstat),
		i32(p.times.rstart), i32(p.times.rstep), i32(p.times.dur),
	}
	libc.fwrite(&head[0], size_of(i32), 15, f)
	write_text(f, p.title[0], TITLELEN + 1)
	write_text(f, p.title[1], TITLELEN + 1)
	write_text(f, p.title[2], TITLELEN + 1)
	write_text(f, p.inp_fname, MAXFNAME + 1)
	write_text(f, r.rpt2_fname, MAXFNAME + 1)
	write_text(f, p.chem_name, MAXID + 1)
	write_text(f, r.fields[.QUALITY].units, MAXID + 1)
	for i in 1 ..= net.nnodes do write_text(f, p.node_id[i], MAXID + 1)
	for i in 1 ..= net.nlinks do write_text(f, p.link_id[i], MAXID + 1)

	for i in 1 ..= net.nlinks do ibuf[i] = net.n1[i]
	libc.fwrite(&ibuf[1], size_of(i32), c.size_t(net.nlinks), f)
	for i in 1 ..= net.nlinks do ibuf[i] = net.n2[i]
	libc.fwrite(&ibuf[1], size_of(i32), c.size_t(net.nlinks), f)
	for i in 1 ..= net.nlinks do ibuf[i] = i32(net.link_type[i])
	libc.fwrite(&ibuf[1], size_of(i32), c.size_t(net.nlinks), f)
	for i in 1 ..= net.ntanks do ibuf[i] = net.tank_node[i]
	libc.fwrite(&ibuf[1], size_of(i32), c.size_t(net.ntanks), f)
	for i in 1 ..= net.ntanks do x[i] = f32(net.tank_area[i])
	libc.fwrite(&x[1], size_of(f32), c.size_t(net.ntanks), f)
	for i in 1 ..= net.nnodes do x[i] = f32(net.el[i] * p.ucf[.ELEV])
	libc.fwrite(&x[1], size_of(f32), c.size_t(net.nnodes), f)
	for i in 1 ..= net.nlinks do x[i] = f32(net.len[i] * p.ucf[.ELEV])
	libc.fwrite(&x[1], size_of(f32), c.size_t(net.nlinks), f)
	for i in 1 ..= net.nlinks {
		x[i] = net.link_type[i] != .PUMP ? f32(net.diam[i] * p.ucf[.DIAM]) : 0
	}
	if libc.fwrite(&x[1], size_of(f32), c.size_t(net.nlinks), f) < c.size_t(net.nlinks) do errcode = 308
	return errcode
}

// saveenergy turns each pump's running totals into the averages EPANET
// reports and writes them, then the demand charge.
saveenergy :: proc "contextless" (p: ^Project) -> int {
	net, hyd := &p.net, &p.hyd
	f := p.out.out_file
	hdur := f64(p.times.dur) / 3600.0
	for i in 1 ..= net.npumps {
		e := &hyd.energy[i]
		if hdur == 0 {
			e.total_cost *= 24.0
		} else {
			t := e.time_on_line
			e.time_on_line = t / hdur
			if t > 0 {
				e.efficiency /= t
				e.kwhrs_per_flow /= t
				e.kwhrs /= t
			}
			e.total_cost *= 24.0 / hdur
		}
		e.time_on_line *= 100.0
		e.efficiency *= 100.0
		if p.units == .SI {
			e.kwhrs_per_flow *= 1000. / LPS_PER_CFS / 3600.
		} else {
			e.kwhrs_per_flow *= 1.0e6 / GPM_PER_CFS / 60.
		}
		x := [6]f32{f32(e.time_on_line), f32(e.efficiency), f32(e.kwhrs_per_flow), f32(e.kwhrs), f32(e.max_kwatts), f32(e.total_cost)}
		if !write_i32(f, net.pump_link[i]) do return 308
		if libc.fwrite(&x[0], size_of(f32), 6, f) < 6 do return 308
	}
	hyd.emax = hyd.emax * p.dcost
	x0 := f32(hyd.emax)
	if libc.fwrite(&x0, size_of(f32), 1, f) < 1 do return 308
	return 0
}

// ── the hydraulics file ───────────────────────────────────────────────

savehyd :: proc "contextless" (p: ^Project, htime: i64) -> int {
	net, hyd := &p.net, &p.hyd
	f := p.out.hyd_file
	x := scratch(max(net.nnodes, net.nlinks) + 1)
	if x == nil do return 101
	defer libc.free(x)
	errcode := 0
	write_i32(f, i32(htime))
	for i in 1 ..= net.nnodes do x[i] = f32(hyd.node_demand[i])
	libc.fwrite(&x[1], size_of(f32), c.size_t(net.nnodes), f)
	for i in 1 ..= net.nnodes do x[i] = f32(hyd.head[i])
	libc.fwrite(&x[1], size_of(f32), c.size_t(net.nnodes), f)
	for i in 1 ..= net.nlinks {
		x[i] = hyd.status[i] <= .CLOSED ? 0 : f32(hyd.flow[i])
	}
	libc.fwrite(&x[1], size_of(f32), c.size_t(net.nlinks), f)
	for i in 1 ..= net.nlinks do x[i] = f32(hyd.status[i])
	libc.fwrite(&x[1], size_of(f32), c.size_t(net.nlinks), f)
	for i in 1 ..= net.nlinks do x[i] = f32(hyd.setting[i])
	if libc.fwrite(&x[1], size_of(f32), c.size_t(net.nlinks), f) < c.size_t(net.nlinks) do errcode = 308
	libc.fflush(f)
	return errcode
}

savehydstep :: proc "contextless" (p: ^Project, hydstep: i64) -> int {
	f := p.out.hyd_file
	errcode := 0
	t := i32(hydstep)
	if !write_i32(f, t) do errcode = 308
	if t == 0 do libc.fputc(EOFMARK, f)
	libc.fflush(f)
	return errcode
}

// readhyd reads one period's results back; false at the file's end.
readhyd :: proc "contextless" (p: ^Project, hydtime: ^i64) -> bool {
	net, hyd := &p.net, &p.hyd
	f := p.out.hyd_file
	x := scratch(max(net.nnodes, net.nlinks) + 1)
	if x == nil do return false
	defer libc.free(x)
	ok := true
	t: i32
	if libc.fread(&t, size_of(i32), 1, f) < 1 do ok = false
	hydtime^ = i64(t)
	nn, nl := c.size_t(net.nnodes), c.size_t(net.nlinks)
	if libc.fread(&x[1], size_of(f32), nn, f) < nn {
		ok = false
	} else {
		for i in 1 ..= net.nnodes do hyd.node_demand[i] = f64(x[i])
	}
	if libc.fread(&x[1], size_of(f32), nn, f) < nn {
		ok = false
	} else {
		for i in 1 ..= net.nnodes do hyd.head[i] = f64(x[i])
	}
	if libc.fread(&x[1], size_of(f32), nl, f) < nl {
		ok = false
	} else {
		for i in 1 ..= net.nlinks do hyd.flow[i] = f64(x[i])
	}
	if libc.fread(&x[1], size_of(f32), nl, f) < nl {
		ok = false
	} else {
		for i in 1 ..= net.nlinks do hyd.status[i] = Status(i8(x[i]))
	}
	if libc.fread(&x[1], size_of(f32), nl, f) < nl {
		ok = false
	} else {
		for i in 1 ..= net.nlinks do hyd.setting[i] = f64(x[i])
	}
	return ok
}

readhydstep :: proc "contextless" (p: ^Project, hydstep: ^i64) -> bool {
	t: i32
	if libc.fread(&t, size_of(i32), 1, p.out.hyd_file) < 1 do return false
	hydstep^ = i64(t)
	return true
}

// ── results per reporting period ──────────────────────────────────────

saveoutput :: proc "contextless" (p: ^Project) -> int {
	net := &p.net
	x := scratch(max(net.nnodes, net.nlinks) + 1)
	if x == nil do return 101
	defer libc.free(x)
	for j in Field.DEMAND ..= Field.QUALITY {
		if err := nodeoutput(p, j, x, p.ucf[j]); err != 0 do return err
	}
	for j in Field.FLOW ..= Field.FRICTION {
		if err := linkoutput(p, j, x, p.ucf[j]); err != 0 do return err
	}
	return 0
}

nodeoutput :: proc "contextless" (p: ^Project, j: Field, x: [^]f32, ucf: f64) -> int {
	net, hyd, q := &p.net, &p.hyd, &p.q
	#partial switch j {
	case .DEMAND:
		for i in 1 ..= net.nnodes do x[i] = f32(hyd.node_demand[i] * ucf)
	case .HEAD:
		for i in 1 ..= net.nnodes do x[i] = f32(hyd.head[i] * ucf)
	case .PRESSURE:
		for i in 1 ..= net.nnodes do x[i] = f32((hyd.head[i] - net.el[i]) * ucf)
	case .QUALITY:
		for i in 1 ..= net.nnodes do x[i] = f32(q.node_qual[i] * ucf)
	}
	n := c.size_t(net.nnodes)
	if libc.fwrite(&x[1], size_of(f32), n, p.out.tmp_out_file) < n do return 308
	return 0
}

linkoutput :: proc "contextless" (p: ^Project, j: Field, x: [^]f32, ucf: f64) -> int {
	net, hyd, q := &p.net, &p.hyd, &p.q
	#partial switch j {
	case .FLOW:
		for i in 1 ..= net.nlinks do x[i] = f32(hyd.flow[i] * ucf)
	case .VELOCITY:
		for i in 1 ..= net.nlinks {
			if net.link_type[i] == .PUMP {
				x[i] = 0
			} else {
				qq := abs(hyd.flow[i])
				a := PI * (net.diam[i] * net.diam[i]) / 4.0
				x[i] = f32(qq / a * ucf)
			}
		}
	case .HEADLOSS:
		for i in 1 ..= net.nlinks {
			if hyd.status[i] <= .CLOSED {
				x[i] = 0
			} else {
				h := hyd.head[net.n1[i]] - hyd.head[net.n2[i]]
				if net.link_type[i] != .PUMP do h = abs(h)
				if net.link_type[i] <= .PIPE {
					x[i] = f32(1000.0 * h / net.len[i])
				} else {
					x[i] = f32(h * ucf)
				}
			}
		}
	case .LINKQUAL:
		for i in 1 ..= net.nlinks do x[i] = f32(avg_qual(net, q, i) * ucf)
	case .STATUS:
		for i in 1 ..= net.nlinks do x[i] = f32(hyd.status[i])
	case .SETTING:
		for i in 1 ..= net.nlinks {
			setting := hyd.setting[i]
			if setting == MISSING {
				x[i] = 0
				continue
			}
			switch net.link_type[i] {
			case .CVPIPE, .PIPE, .PUMP, .TCV, .PCV:
				x[i] = f32(setting)
			case .PRV, .PSV, .PBV:
				x[i] = f32(setting * p.ucf[.PRESSURE])
			case .FCV:
				x[i] = f32(setting * p.ucf[.FLOW])
			case .GPV:
				x[i] = 0
			}
		}
	case .REACTRATE:
		if q.kind == .NONE {
			for i in 0 ..= net.nlinks do x[i] = 0
		} else {
			for i in 1 ..= net.nlinks do x[i] = f32(q.pipe_rate[i] * ucf)
		}
	case .FRICTION:
		// f = 2ghd/(Lu²), with the head loss, diameter, length and flow
		for i in 1 ..= net.nlinks {
			if net.link_type[i] <= .PIPE && abs(hyd.flow[i]) > TINY {
				h := abs(hyd.head[net.n1[i]] - hyd.head[net.n2[i]])
				f := 39.725 * h * libc.pow(net.diam[i], 5) / net.len[i] / (hyd.flow[i] * hyd.flow[i])
				x[i] = f32(f)
			} else {
				x[i] = 0
			}
		}
	}
	n := c.size_t(net.nlinks)
	if libc.fwrite(&x[1], size_of(f32), n, p.out.tmp_out_file) < n do return 308
	return 0
}

// savefinaloutput closes the output file: the time statistic over every
// period when one was asked for, the average reaction rates, the epilog.
savefinaloutput :: proc "contextless" (p: ^Project) -> int {
	net, o, r, q := &p.net, &p.out, &p.rpt, &p.q
	errcode := 0
	if r.tstat != .SERIES && o.tmp_out_file != nil {
		x := scratch(max(net.nnodes, net.nlinks) + 1)
		if x == nil do return 101
		errcode = savetimestat(p, x, .NODEHDR)
		if errcode == 0 do errcode = savetimestat(p, x, .LINKHDR)
		if errcode == 0 do r.nperiods = 1
		libc.fclose(o.tmp_out_file)
		o.tmp_out_file = nil
		libc.free(x)
	}
	if o.out_file != nil {
		if errcode == 0 do errcode = savenetreacts(p, q.wbulk, q.wwall, q.wtank, q.wsource)
		if errcode == 0 do errcode = saveepilog(p)
	}
	return errcode
}

// savetimestat reduces every period of a variable to one value per node
// or link: the average, the least, the most or the range, in single
// precision as EPANET keeps it.
savetimestat :: proc "contextless" (p: ^Project, x: [^]f32, objtype: Header_Kind) -> int {
	net, hyd, q, o, r := &p.net, &p.hyd, &p.q, &p.out, &p.rpt
	NV :: int(Field.QUALITY) - int(Field.DEMAND) + 1 // node variables
	LV :: int(Field.FRICTION) - int(Field.FLOW) + 1 // link variables
	startbyte, skipbytes: int
	n: int
	n1, n2: Field
	if objtype == .NODEHDR {
		startbyte = 0
		skipbytes = (net.nnodes * (NV - 1) + net.nlinks * LV) * size_of(f32)
		n = net.nnodes
		n1, n2 = .DEMAND, .QUALITY
	} else {
		startbyte = net.nnodes * NV * size_of(f32)
		skipbytes = (net.nnodes * NV + net.nlinks * (LV - 1)) * size_of(f32)
		n = net.nlinks
		n1, n2 = .FLOW, .FRICTION
	}
	stat1 := scratch(n + 1)
	stat2 := scratch(n + 1)
	if stat1 == nil || stat2 == nil {
		libc.free(stat1)
		libc.free(stat2)
		return 101
	}
	defer libc.free(stat1)
	defer libc.free(stat2)
	errcode := 0
	for j in n1 ..= n2 {
		if r.tstat == .AVG {
			for i in 0 ..= n do stat1[i] = 0
		} else {
			for i in 1 ..= n {
				stat1[i] = f32(-MISSING)
				stat2[i] = f32(MISSING)
			}
		}
		libc.fseek(o.tmp_out_file, c.long(startbyte + (int(j) - int(n1)) * n * size_of(f32)), .SET)
		for period in 1 ..= r.nperiods {
			libc.fread(&x[1], size_of(f32), c.size_t(n), o.tmp_out_file)
			for i in 1 ..= n {
				xx := x[i]
				if objtype == .LINKHDR {
					if j == .FLOW do xx = abs(xx)
					if j == .STATUS do xx = xx >= f32(Status.OPEN) ? 1 : 0
				}
				if r.tstat == .AVG {
					stat1[i] += xx
				} else {
					stat1[i] = min(stat1[i], xx)
					stat2[i] = max(stat2[i], xx)
				}
			}
			if period < r.nperiods do libc.fseek(o.tmp_out_file, c.long(skipbytes), .CUR)
		}
		#partial switch r.tstat {
		case .AVG:
			for i in 1 ..= n do x[i] = stat1[i] / f32(r.nperiods)
		case .MIN:
			for i in 1 ..= n do x[i] = stat1[i]
		case .MAX:
			for i in 1 ..= n do x[i] = stat2[i]
		case .RANGE:
			for i in 1 ..= n do x[i] = stat2[i] - stat1[i]
		}
		if objtype == .LINKHDR && j == .STATUS {
			for i in 1 ..= n do x[i] = x[i] < 0.5 ? f32(Status.CLOSED) : f32(Status.OPEN)
		}
		if libc.fwrite(&x[1], size_of(f32), c.size_t(n), o.out_file) < c.size_t(n) do errcode = 308
		// the statistic stands in for the last period's results
		if objtype == .NODEHDR {
			#partial switch j {
			case .DEMAND:
				for i in 1 ..= n do hyd.node_demand[i] = f64(x[i]) / p.ucf[.DEMAND]
			case .HEAD:
				for i in 1 ..= n do hyd.head[i] = f64(x[i]) / p.ucf[.HEAD]
			case .QUALITY:
				for i in 1 ..= n do q.node_qual[i] = f64(x[i]) / p.ucf[.QUALITY]
			}
		} else if j == .FLOW {
			for i in 1 ..= n do hyd.flow[i] = f64(x[i]) / p.ucf[.FLOW]
		}
	}
	return errcode
}

savenetreacts :: proc "contextless" (p: ^Project, wbulk, wwall, wtank, wsource: f64) -> int {
	t := p.times.dur > 0 ? f64(p.times.dur) / 3600. : 1.
	w := [4]f32{f32(wbulk / t), f32(wwall / t), f32(wtank / t), f32(wsource / t)}
	if libc.fwrite(&w[0], size_of(f32), 4, p.out.out_file) < 4 do return 308
	return 0
}

saveepilog :: proc "contextless" (p: ^Project) -> int {
	f := p.out.out_file
	errcode := 0
	if !write_i32(f, i32(p.rpt.nperiods)) do errcode = 308
	if !write_i32(f, i32(p.warnflag)) do errcode = 308
	if !write_i32(f, MAGICNUMBER) do errcode = 308
	return errcode
}
