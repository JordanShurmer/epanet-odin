#+build wasm32
package epanet

// prof_wasm.odin — the stopwatch with no clock: the wasm build never
// profiles, so every call compiles to nothing.

PROF :: false

Prof_Phase :: enum {
	step, copy_in, demands, controls, headloss_coeffs, matrix_coeffs, linsolve, new_flows, converge, valves, status,
	new_hydraulics, copy_out, next_hyd, react, transport, mass_balance,
}

Prof :: struct {
	cycles: [Prof_Phase]i64,
	calls:  [Prof_Phase]i64,
}

prof: Prof

prof_now :: proc "contextless" () -> i64 {
	return 0
}

prof_begin :: #force_inline proc "contextless" () -> i64 {
	return 0
}

prof_end :: #force_inline proc "contextless" (ph: Prof_Phase, t0: i64) {
}

prof_reset :: proc "contextless" () {
	prof = {}
}
