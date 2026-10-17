package epanet

// hydcoeffs.odin — the coefficients of the linearized network equations
// (EPANET's hydcoeffs.c).
//
// Every link gets P = 1/(dh/dq) and Y = h/(dh/dq) from its head-loss
// relation at the current flow (headloss_coeffs); then the matrix A and
// right-hand side F of Todini's gradient method are assembled from them,
// the emitters, the pressure-dependent demands and the control valves
// (matrix_coeffs). The arithmetic is EPANET's, operation for operation.

import "core:c/libc"
import "core:math"

// Darcy-Weisbach friction factor constants.
A1 : f64 : 3.14159265358979323850e+03 // 1000·π
A2 : f64 : 1.57079632679489661930e+03 // 500·π
A8 : f64 : 4.61841319859066668690e+00 // 5.74·(π/4)^0.9
A9 : f64 : -8.68588963806503655300e-01 // −2/ln 10
AB : f64 : 3.28895476345399058690e-03 // 5.74/4000^0.9
AC : f64 : -5.14214965799093883760e-03 // AA·AB

sgn :: #force_inline proc "contextless" (x: f64) -> f64 {
	return x < 0 ? -1 : 1
}

// add_lower_barrier adds a steep head loss as q falls below a lower
// limit (dq = q − limit), so the solution cannot cross it.
add_lower_barrier :: proc "contextless" (dq: f64, hloss, hgrad: ^f64) {
	a := 1e9 * dq
	b := math.sqrt(a * a + 1e-6)
	hloss^ += (a - b) / 2
	hgrad^ += (1e9 / 2) * (1 - a / b)
}

add_upper_barrier :: proc "contextless" (dq: f64, hloss, hgrad: ^f64) {
	a := 1e9 * dq
	b := math.sqrt(a * a + 1e-6)
	hloss^ += (a + b) / 2
	hgrad^ += (1e9 / 2) * (1 + a / b)
}

// headloss_coeffs computes P and Y for every link.
headloss_coeffs :: proc "contextless" (net: ^Network, hyd: ^Hydraulics) {
	for k in 1 ..= net.nlinks {
		#partial switch net.link_type[k] {
		case .CVPIPE, .PIPE:
			pipe_coeff(net, hyd, k)
		case .PUMP:
			pump_coeff(net, hyd, k)
		case .PBV:
			pbv_coeff(net, hyd, k)
		case .TCV:
			tcv_coeff(net, hyd, k)
		case .PCV:
			pcv_coeff(net, hyd, k)
		case .GPV:
			gpv_coeff(net, hyd, k)
		case .FCV, .PRV, .PSV:
			if hyd.setting[k] == MISSING {
				valve_coeff(net, hyd, k, net.km[k])
			} else {
				hyd.p[k] = 0
			}
		}
	}
}

// matrix_coeffs assembles A and F. Leakage, still C's, is called between
// the demands and the node balances when the network leaks.
matrix_coeffs :: proc "contextless" (net: ^Network, hyd: ^Hydraulics, m: ^Smatrix, hooks: ^Hooks) {
	for i in 0 ..= net.nnodes {
		m.aii[i] = 0
		m.f[i] = 0
		hyd.xflow[i] = 0
	}
	for k in 0 ..< len(m.aij) do m.aij[k] = 0

	link_coeffs(net, hyd, m)
	emitter_coeffs(net, hyd, m)
	demand_coeffs(net, hyd, m)
	if hyd.has_leakage do hooks.leakage_coeffs(hooks.ctx)
	node_coeffs(net, hyd, m)
	valve_coeffs(net, hyd, m)
}

// link_coeffs adds each link's P to the diagonals of its two ends and
// −P to their shared off-diagonal; a tank end goes to the right-hand side
// as P·H instead, since its head is known.
link_coeffs :: proc "contextless" (net: ^Network, hyd: ^Hydraulics, m: ^Smatrix) {
	for k in 1 ..= net.nlinks {
		if hyd.p[k] == 0 do continue
		n1, n2 := net.n1[k], net.n2[k]

		hyd.xflow[n1] -= hyd.flow[k]
		hyd.xflow[n2] += hyd.flow[k]

		m.aij[m.ndx[k]] -= hyd.p[k]

		if int(n1) <= net.njuncs {
			m.aii[m.row[n1]] += hyd.p[k]
			m.f[m.row[n1]] += hyd.y[k]
		} else {
			m.f[m.row[n2]] += hyd.p[k] * hyd.head[n1]
		}

		if int(n2) <= net.njuncs {
			m.aii[m.row[n2]] += hyd.p[k]
			m.f[m.row[n2]] -= hyd.y[k]
		} else {
			m.f[m.row[n1]] += hyd.p[k] * hyd.head[n2]
		}
	}
}

// node_coeffs closes each junction's flow balance with its demand.
node_coeffs :: proc "contextless" (net: ^Network, hyd: ^Hydraulics, m: ^Smatrix) {
	for i in 1 ..= net.njuncs {
		hyd.xflow[i] -= hyd.demand_flow[i]
		m.f[m.row[i]] += hyd.xflow[i]
	}
}

// valve_coeffs handles the PRVs, PSVs and FCVs that have a setting.
valve_coeffs :: proc "contextless" (net: ^Network, hyd: ^Hydraulics, m: ^Smatrix) {
	for i in 1 ..= net.nvalves {
		k := net.valve_link[i]
		if hyd.setting[k] == MISSING do continue
		n1, n2 := net.n1[k], net.n2[k]
		#partial switch net.link_type[k] {
		case .PRV:
			prv_coeff(net, hyd, m, int(k), n1, n2)
		case .PSV:
			psv_coeff(net, hyd, m, int(k), n1, n2)
		case .FCV:
			fcv_coeff(net, hyd, m, int(k), n1, n2)
		}
	}
}

// An emitter is a pipe to a reservoir at the node's own elevation with
// head loss Ke·q^Qexp.
emitter_coeffs :: proc "contextless" (net: ^Network, hyd: ^Hydraulics, m: ^Smatrix) {
	for i in 1 ..= net.njuncs {
		if net.ke[i] == 0 do continue
		hloss, hgrad := emitter_headloss(net, hyd, i)
		row := m.row[i]
		m.aii[row] += 1 / hgrad
		m.f[row] += (hloss + net.el[i]) / hgrad
		hyd.xflow[i] -= hyd.emitter_flow[i]
	}
}

emitter_headloss :: proc "contextless" (net: ^Network, hyd: ^Hydraulics, i: int) -> (hloss, hgrad: f64) {
	ke := max(CSMALL, net.ke[i])
	q := hyd.emitter_flow[i]
	hgrad = hyd.qexp * ke * libc.pow(abs(q), hyd.qexp - 1)
	if hgrad < hyd.rqtol {
		hgrad = hyd.rqtol / hyd.qexp
		hloss = hgrad * q
	} else {
		hloss = hgrad * q / hyd.qexp
	}
	if !hyd.emit_backflow do add_lower_barrier(q, &hloss, &hgrad)
	return
}

// A pressure-dependent demand is an emitter with loss
// Preq·(D/Dfull)^(1/Pexp): nothing below Pmin, all of it above Preq.
demand_coeffs :: proc "contextless" (net: ^Network, hyd: ^Hydraulics, m: ^Smatrix) {
	if hyd.demand_model == .DDA do return
	dp := hyd.preq - hyd.pmin
	n := 1 / hyd.pexp
	for i in 1 ..= net.njuncs {
		if hyd.full_demand[i] <= 0 do continue
		hloss, hgrad := demand_headloss(hyd, i, dp, n)
		if hgrad > 0 {
			row := m.row[i]
			m.aii[row] += 1 / hgrad
			m.f[row] += (hloss + net.el[i] + hyd.pmin) / hgrad
		}
	}
}

demand_headloss :: proc "contextless" (hyd: ^Hydraulics, i: int, dp, n: f64) -> (hloss, hgrad: f64) {
	d := hyd.demand_flow[i]
	dfull := hyd.full_demand[i]
	r := abs(d) / dfull
	hgrad = n * dp * libc.pow(r, n - 1) / dfull
	hloss = hgrad * d / n
	add_lower_barrier(d, &hloss, &hgrad)
	add_upper_barrier(d - dfull, &hloss, &hgrad)
	return
}

// closed_coeff is any link shut tight: a huge resistance.
closed_coeff :: #force_inline proc "contextless" (hyd: ^Hydraulics, k: int) {
	hyd.p[k] = 1 / CBIG
	hyd.y[k] = hyd.flow[k]
}

pipe_coeff :: proc "contextless" (net: ^Network, hyd: ^Hydraulics, k: int) {
	if hyd.status[k] <= .CLOSED {
		closed_coeff(hyd, k)
		return
	}
	if hyd.formflag == .DW {
		dw_pipe_coeff(net, hyd, k)
		return
	}
	q := abs(hyd.flow[k])
	ml := net.km[k]
	r := net.r[k]

	hloss: f64
	hgrad := hyd.hexp * r * libc.pow(q, hyd.hexp - 1)
	if hgrad < hyd.rqtol {
		hgrad = hyd.rqtol / hyd.hexp
		hloss = hgrad * q
	} else {
		hloss = hgrad * q / hyd.hexp
	}
	if ml > 0 {
		hloss += ml * q * q
		hgrad += 2 * ml * q
	}
	hloss *= sgn(hyd.flow[k])
	hyd.p[k] = 1 / hgrad
	hyd.y[k] = hloss / hgrad
}

dw_pipe_coeff :: proc "contextless" (net: ^Network, hyd: ^Hydraulics, k: int) {
	q := abs(hyd.flow[k])
	r := net.r[k]
	ml := net.km[k]
	e := net.kc[k] / net.diam[k] // relative roughness
	s := hyd.viscos * net.diam[k]
	hloss, hgrad: f64
	if q <= A2 * s {
		// Laminar (Re ≤ 2000): Hagen-Poiseuille.
		r = 16 * math.PI * s * r
		hloss = hyd.flow[k] * (r + ml * q)
		hgrad = r + 2 * ml * q
	} else {
		f, dfdq := friction_factor(q, e, s)
		r1 := f * r + ml
		hloss = r1 * q * hyd.flow[k]
		hgrad = (2 * r1 * q) + (dfdq * r * q * q)
	}
	hyd.p[k] = 1 / hgrad
	hyd.y[k] = hloss / hgrad
}

// friction_factor: Swamee-Jain above Re 4000, Dunlop's interpolating
// polynomial through the transition below it. w = Re·π/4.
friction_factor :: proc "contextless" (q, e, s: f64) -> (f, dfdq: f64) {
	w := q / s
	if w >= A1 {
		y1 := A8 / libc.pow(w, 0.9)
		y2 := e / 3.7 + y1
		y3 := A9 * libc.log(y2)
		f = 1 / (y3 * y3)
		dfdq = 1.8 * f * y1 * A9 / y2 / y3 / q
	} else {
		y2 := e / 3.7 + AB
		y3 := A9 * libc.log(y2)
		fa := 1 / (y3 * y3)
		fb := (2 + AC / (y2 * y3)) * fa
		r := w / A2
		x1 := 7 * fa - fb
		x2 := 0.128 - 17 * fa + 2.5 * fb
		x3 := -0.128 + 13 * fa - (fb + fb)
		x4 := 0.032 - 3 * fa + 0.5 * fb
		f = x1 + r * (x2 + r * (x3 + r * x4))
		dfdq = (x2 + r * (2 * x3 + r * 3 * x4)) / s / A2
	}
	return
}

pump_coeff :: proc "contextless" (net: ^Network, hyd: ^Hydraulics, k: int) {
	setting := hyd.setting[k]
	if hyd.status[k] <= .CLOSED || setting == 0 {
		closed_coeff(hyd, k)
		return
	}
	q := abs(hyd.flow[k])
	p := net.link_pump[k]
	if net.pump_type[p] == .NOCURVE {
		hyd.p[k] = 1 / CSMALL
		hyd.y[k] = hyd.flow[k]
		return
	}
	hloss, hgrad: f64
	if net.pump_type[p] == .CUSTOM {
		// The segment of the curve at the speed-adjusted flow, as a
		// head loss (negated gain).
		h0, r := curve_coeff(net, int(net.pump_hcurve[p]), q / setting)
		net.pump_h0[p] = -h0
		net.pump_r[p] = -r
		net.pump_n[p] = 1
		hgrad = net.pump_r[p] * setting
		hloss = net.pump_h0[p] * (setting * setting) + hgrad * hyd.flow[k]
	} else {
		h0 := (setting * setting) * net.pump_h0[p]
		n := net.pump_n[p]
		if abs(n - 1) < TINY do n = 1
		r := net.pump_r[p] * libc.pow(setting, 2 - n)
		if net.pump_type[p] == .CONST_HP {
			hgrad = -r / q / q
			if hgrad > CBIG {
				closed_coeff(hyd, k)
				return
			} else if hgrad < CSMALL {
				hyd.p[k] = 1 / CSMALL
				hyd.y[k] = hyd.flow[k]
				return
			}
			hloss = r / hyd.flow[k]
		} else if n != 1 {
			hgrad = n * r * libc.pow(q, n - 1)
			if hgrad < hyd.rqtol {
				hgrad = hyd.rqtol
				hloss = h0 + hgrad * hyd.flow[k]
			} else {
				hloss = h0 + hgrad * hyd.flow[k] / n
			}
		} else {
			hgrad = r
			hloss = h0 + hgrad * hyd.flow[k]
		}
	}
	hyd.p[k] = 1 / hgrad
	hyd.y[k] = hloss / hgrad
}

// curve_coeff: the intercept and slope of the curve segment that brackets
// flow q, converted from the curve's user units.
curve_coeff :: proc "contextless" (net: ^Network, i: int, q0: f64) -> (h0, r: f64) {
	q := q0 * net.ucf_flow
	x, y := net.curves[i].x, net.curves[i].y
	npts := len(x)
	k2 := 0
	for k2 < npts && x[k2] < q do k2 += 1
	if k2 == 0 {
		k2 += 1
	} else if k2 == npts {
		k2 -= 1
	}
	k1 := k2 - 1
	r = (y[k2] - y[k1]) / (x[k2] - x[k1])
	h0 = y[k1] - r * x[k1]
	h0 = h0 / net.ucf_head
	r = r * net.ucf_flow / net.ucf_head
	return
}

// A GPV follows its head loss curve; its setting is the curve index.
gpv_coeff :: proc "contextless" (net: ^Network, hyd: ^Hydraulics, k: int) {
	if hyd.status[k] == .CLOSED {
		valve_coeff(net, hyd, k, net.km[k])
		return
	}
	i := int(math.round(hyd.setting[k]))
	q := abs(hyd.flow[k])
	q = max(q, TINY)
	h0, r := curve_coeff(net, i, q)
	r = max(r, TINY)
	hyd.p[k] = 1 / r
	hyd.y[k] = (h0 / r + q) * sgn(hyd.flow[k])
}

// A PBV forces its setting as the head loss, unless its minor loss is
// already more than that.
pbv_coeff :: proc "contextless" (net: ^Network, hyd: ^Hydraulics, k: int) {
	if hyd.setting[k] == MISSING || hyd.setting[k] == 0 {
		valve_coeff(net, hyd, k, net.km[k])
	} else if net.km[k] * (hyd.flow[k] * hyd.flow[k]) > hyd.setting[k] {
		valve_coeff(net, hyd, k, net.km[k])
	} else {
		hyd.p[k] = CBIG
		hyd.y[k] = hyd.setting[k] * CBIG
	}
}

// A TCV's setting is a minor loss coefficient.
tcv_coeff :: proc "contextless" (net: ^Network, hyd: ^Hydraulics, k: int) {
	km := net.km[k]
	if hyd.setting[k] != MISSING {
		d2 := net.diam[k] * net.diam[k]
		km = 0.02517 * hyd.setting[k] / (d2 * d2)
	}
	valve_coeff(net, hyd, k, km)
}

// A PCV's loss coefficient was computed from its percent open into r.
pcv_coeff :: proc "contextless" (net: ^Network, hyd: ^Hydraulics, k: int) {
	km := net.km[k]
	if hyd.setting[k] != MISSING do km = net.r[k]
	valve_coeff(net, hyd, k, km)
}

// An active PRV pins the downstream head to its setting; otherwise it is
// an open or closed valve whose coefficients go straight into the matrix
// (link_coeffs skipped it, since P was 0).
prv_coeff :: proc "contextless" (net: ^Network, hyd: ^Hydraulics, m: ^Smatrix, k: int, n1, n2: i32) {
	i, j := m.row[n1], m.row[n2]
	hset := net.el[n2] + hyd.setting[k]
	if hyd.status[k] == .ACTIVE {
		hyd.p[k] = 0
		hyd.y[k] = hyd.flow[k] + hyd.xflow[n2]
		m.f[j] += hset * CBIG
		m.aii[j] += CBIG
		if hyd.xflow[n2] < 0 do m.f[i] += hyd.xflow[n2]
		return
	}
	valve_coeff(net, hyd, k, net.km[k])
	open_valve_into_matrix(hyd, m, k, i, j)
}


psv_coeff :: proc "contextless" (net: ^Network, hyd: ^Hydraulics, m: ^Smatrix, k: int, n1, n2: i32) {
	i, j := m.row[n1], m.row[n2]
	hset := net.el[n1] + hyd.setting[k]
	if hyd.status[k] == .ACTIVE {
		hyd.p[k] = 0
		hyd.y[k] = hyd.flow[k] - hyd.xflow[n1]
		m.f[i] += hset * CBIG
		m.aii[i] += CBIG
		if hyd.xflow[n1] > 0 do m.f[j] += hyd.xflow[n1]
		m.aij[m.ndx[k]] -= 1 / CBIG // keep the matrix connected
		m.aii[j] += 1 / CBIG
		return
	}
	valve_coeff(net, hyd, k, net.km[k])
	open_valve_into_matrix(hyd, m, k, i, j)
}

// An active FCV breaks the network at the valve: its setting leaves the
// upstream node as a demand and arrives downstream as a supply.
fcv_coeff :: proc "contextless" (net: ^Network, hyd: ^Hydraulics, m: ^Smatrix, k: int, n1, n2: i32) {
	q := hyd.setting[k]
	i, j := m.row[n1], m.row[n2]
	if hyd.status[k] == .ACTIVE {
		hyd.xflow[n1] -= q
		hyd.xflow[n2] += q
		hyd.y[k] = hyd.flow[k] - q
		m.f[i] -= q
		m.f[j] += q
		hyd.p[k] = 1 / CBIG
		m.aij[m.ndx[k]] -= hyd.p[k]
		m.aii[i] += hyd.p[k]
		m.aii[j] += hyd.p[k]
		return
	}
	valve_coeff(net, hyd, k, net.km[k])
	open_valve_into_matrix(hyd, m, k, i, j)
}

open_valve_into_matrix :: #force_inline proc "contextless" (hyd: ^Hydraulics, m: ^Smatrix, k: int, i, j: i32) {
	m.aij[m.ndx[k]] -= hyd.p[k]
	m.aii[i] += hyd.p[k]
	m.aii[j] += hyd.p[k]
	m.f[i] += (hyd.y[k] - hyd.flow[k])
	m.f[j] -= (hyd.y[k] - hyd.flow[k])
}

// valve_coeff is a fully open, closed or throttled valve with minor loss
// coefficient km.
valve_coeff :: proc "contextless" (net: ^Network, hyd: ^Hydraulics, k: int, km: f64) {
	flow := hyd.flow[k]
	if hyd.status[k] <= .CLOSED {
		closed_coeff(hyd, k)
		return
	}
	if km > 0 {
		q := abs(flow)
		hgrad := 2 * km * q
		hloss: f64
		if hgrad < hyd.rqtol {
			hgrad = hyd.rqtol / 2
			hloss = flow * hgrad
		} else {
			hloss = flow * hgrad / 2
		}
		hyd.p[k] = 1 / hgrad
		hyd.y[k] = hloss / hgrad
	} else {
		hyd.p[k] = 1 / CSMALL
		hyd.y[k] = flow
	}
}
