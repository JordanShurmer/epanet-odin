package epanet

// validate.odin — what EPANET checks before the first solve (validate.c):
// tank levels, pumps (which also fits each pump's curve), patterns and
// curves with data. Returns EPANET's error code; the messages are the
// caller's.

import "core:c/libc"

validate_tanks :: proc(p: ^Project) -> bool {
	net := &p.net
	result := true
	for j in 1 ..= net.ntanks {
		if net.tank_area[j] == 0 do continue
		levelerr := net.tank_h0[j] > net.tank_hmax[j] || net.tank_hmin[j] > net.tank_hmax[j] || net.tank_h0[j] < net.tank_hmin[j]
		el := net.el[net.tank_node[j]]
		if i := int(net.tank_vcurve[j]); i > 0 {
			c := net.curves[i]
			n := len(c.x) - 1
			if (net.tank_hmin[j] - el) * p.ucf[.ELEV] < c.x[0] - TINY ||
			   (net.tank_hmax[j] - el) * p.ucf[.ELEV] > c.x[n] + TINY {
				levelerr = true
			}
		}
		if levelerr do result = false
	}
	return result
}

validate_patterns :: proc(p: ^Project) -> bool {
	for pat in p.net.patterns do if len(pat.f) == 0 do return false
	return true
}

validate_curves :: proc(p: ^Project) -> bool {
	result := true
	for c in p.net.curves[1:] {
		if len(c.x) == 0 do result = false
		for i in 1 ..< len(c.x) {
			if c.x[i - 1] >= c.x[i] {
				result = false
				break
			}
		}
	}
	return result
}

// powerfunc_pump fits H = a - b·Q^c through the shutoff, design and
// maximum points.
powerfunc_pump :: proc(h0, h1, h2, q1, q2: f64) -> (a, b, c: f64, ok: bool) {
	if h0 < TINY || h0 - h1 < TINY || h1 - h2 < TINY || q1 < TINY || q2 - q1 < TINY do return
	a = h0
	h4 := h0 - h1
	h5 := h0 - h2
	c = libc.log(h5 / h4) / libc.log(q2 / q1)
	if c <= 0 || c > 20 do return
	b = -h4 / libc.pow(q1, c)
	if b >= 0 do return
	ok = true
	return
}

custom_curve_pump :: proc(p: ^Project, m: int, c: Curve) -> int {
	net := &p.net
	net.pump_type[m] = .CUSTOM
	npts := len(c.x)
	for i in 1 ..< npts {
		if c.y[i] >= c.y[i - 1] {
			net.pump_type[m] = .NOCURVE
			return 227
		}
	}
	p.pump_qmax[m] = c.x[npts - 1]
	net.pump_q0[m] = (c.x[0] + p.pump_qmax[m]) / 2 / p.ucf[.FLOW]
	p.pump_qmax[m] /= p.ucf[.FLOW]
	net.pump_hmax[m] = c.y[0] / p.ucf[.HEAD]
	return 0
}

pump_curve_pump :: proc(p: ^Project, m: int, ci: int) -> int {
	net := &p.net
	c := net.curves[ci]
	p.curve_type[ci] = .PUMP_CURVE
	npts := len(c.x)
	h0, h1, h2, q1, q2: f64
	if npts == 1 {
		net.pump_type[m] = .POWER_FUNC
		q1 = c.x[0]
		h1 = c.y[0]
		h0 = 1.33334 * h1
		q2 = 2 * q1
		h2 = 0
	} else if npts == 3 && c.x[0] == 0 {
		net.pump_type[m] = .POWER_FUNC
		h0 = c.y[0]
		q1 = c.x[1]
		h1 = c.y[1]
		q2 = c.x[2]
		h2 = c.y[2]
	} else {
		return custom_curve_pump(p, m, c)
	}
	a, b, cc, ok := powerfunc_pump(h0, h1, h2, q1, q2)
	if !ok {
		net.pump_type[m] = .NOCURVE
		return 227
	}
	net.pump_h0[m] = -a / p.ucf[.HEAD]
	net.pump_r[m] = -b * (libc.pow(p.ucf[.FLOW], cc) / p.ucf[.HEAD])
	net.pump_n[m] = cc
	net.pump_q0[m] = q1 / p.ucf[.FLOW]
	p.pump_qmax[m] = libc.pow(-a / b, 1 / cc) / p.ucf[.FLOW]
	net.pump_hmax[m] = h0 / p.ucf[.HEAD]
	return 0
}

const_power_pump :: proc(p: ^Project, m: int) -> int {
	net := &p.net
	net.pump_type[m] = .CONST_HP
	net.pump_h0[m] = 0
	net.pump_r[m] = -8.814 * net.km[net.pump_link[m]] / p.ucf[.POWER]
	net.pump_n[m] = -1
	net.pump_hmax[m] = BIG
	p.pump_qmax[m] = BIG
	net.pump_q0[m] = 1
	return 0
}

validate_pumps :: proc(p: ^Project) -> bool {
	net := &p.net
	result := true
	for m in 1 ..= net.npumps {
		errcode: int
		if net.pump_hcurve[m] > 0 {
			errcode = pump_curve_pump(p, m, int(net.pump_hcurve[m]))
		} else if net.km[net.pump_link[m]] > 0 {
			errcode = const_power_pump(p, m)
		} else {
			net.pump_type[m] = .NOCURVE
			errcode = 226
		}
		if errcode != 0 do result = false
	}
	return result
}

validate_project :: proc(p: ^Project) -> int {
	if p.net.nnodes < 2 do return 223
	if p.net.ntanks == 0 do return 224
	errcode := 0
	if !validate_tanks(p) do errcode = 110
	if !validate_pumps(p) do errcode = 110
	if !validate_patterns(p) do errcode = 110
	if !validate_curves(p) do errcode = 110
	return errcode
}
