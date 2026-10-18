package epanet

// leakage.odin — pipe leaks as extra demand at the pipes' end nodes
// (EPANET's leakage.c, the part the solver runs each trial).
//
// A leak follows FAVAD, Q = Co·(Ao + m·H)·√H: a fixed area plus one that
// grows with pressure head. Each end node gets two inverted emitters,
//   H = cfa·qfa²        the fixed-area part
//   H = cva·qva^(2/3)   the variable-area part
// with cfa and cva summed over the node's leaking pipes when the system
// is opened (still C's job). This file is what happens per trial.

import "core:math"

// leakage_coeffs adds each leaking junction's two emitters to A and F.
leakage_coeffs :: proc "contextless" (net: ^Network, hyd: ^Hydraulics, m: ^Smatrix) {
	for i in 1 ..= net.njuncs {
		hfa, gfa, hva, gva, leaks := leakage_headloss(net, hyd, i)
		if !leaks do continue
		row := m.row[i]
		if gfa > 0 {
			m.aii[row] += 1 / gfa
			m.f[row] += (hfa + net.el[i]) / gfa
		}
		if gva > 0 {
			m.aii[row] += 1 / gva
			m.f[row] += (hva + net.el[i]) / gva
		}
		hyd.xflow[i] -= (hyd.leak_qfa[i] + hyd.leak_qva[i])
	}
}

// leakage_headloss: the head loss and gradient of each inverted emitter
// at the node's current leak flows; leaks is false at a node with none.
leakage_headloss :: proc "contextless" (net: ^Network, hyd: ^Hydraulics, i: int) -> (hfa, gfa, hva, gva: f64, leaks: bool) {
	if net.leak_cfa[i] == 0 && net.leak_cva[i] == 0 do return
	if net.leak_cfa[i] != 0 do hfa, gfa = eval_leak_headloss(hyd.leak_qfa[i], net.leak_cfa[i], 0.5)
	if net.leak_cva[i] != 0 do hva, gva = eval_leak_headloss(hyd.leak_qva[i], net.leak_cva[i], 1.5)
	return hfa, gfa, hva, gva, true
}

// eval_leak_headloss: hloss = c·q^(1/n) and its gradient, with a barrier
// that keeps the leak from flowing backwards.
eval_leak_headloss :: proc "contextless" (q, c, n0: f64) -> (hloss, hgrad: f64) {
	n := 1 / n0
	hgrad = n * c * c_pow(abs(q), n - 1)
	hloss = hgrad * q / n
	add_lower_barrier(q, &hloss, &hgrad)
	return
}

// leakage_flow_change: the Newton step for a node's two leak flows after
// new heads; returns the total change.
leakage_flow_change :: proc "contextless" (net: ^Network, hyd: ^Hydraulics, i: int) -> f64 {
	hfa, gfa, hva, gva, leaks := leakage_headloss(net, hyd, i)
	if !leaks do return 0
	h := hyd.head[i] - net.el[i]
	dqfa, dqva := 0.0, 0.0
	if gfa > 0 {
		dqfa = (hfa - h) / gfa * hyd.relax
		hyd.leak_qfa[i] -= dqfa
	}
	if gva > 0 {
		dqva = (hva - h) / gva * hyd.relax
		hyd.leak_qva[i] -= dqva
	}
	hyd.leak_flow[i] = hyd.leak_qfa[i] + hyd.leak_qva[i]
	return dqfa + dqva
}

// leakage_converged: every leaking node's solved leak must agree with the
// leak equation evaluated at its solved pressure head.
leakage_converged :: proc "contextless" (net: ^Network, hyd: ^Hydraulics) -> bool {
	QTOL :: 0.0001 // cfs
	for i in 1 ..= net.njuncs {
		if net.leak_cfa[i] == 0 && net.leak_cva[i] == 0 do continue
		h := hyd.head[i] - net.el[i]
		qref := 0.0
		if h > 0 {
			if net.leak_cfa[i] > 0 do qref = math.sqrt(h / net.leak_cfa[i])
			if net.leak_cva[i] > 0 do qref += c_pow(h / net.leak_cva[i], 1.5)
		}
		qtest := hyd.leak_qfa[i] + hyd.leak_qva[i]
		if abs(qref - qtest) > QTOL do return false
	}
	return true
}
