#+build !wasm32
package epanet

// prof.odin — the engine's stopwatch, for cmd/prof. Off unless the build
// says -define:PROF=true; then the phases of a step are timed into one
// global table that cmd/prof prints. Off, prof_begin and prof_end are
// empty and the compiler drops them. The clock is the CPU's cycle
// counter, read in a few cycles, so a phase of a microsecond is still
// measured and not swamped (cmd/prof calibrates cycles against the wall
// clock over the run). The wasm build (prof_wasm.odin) has no counter,
// so its prof_now is zero.

import "base:intrinsics"

PROF :: #config(PROF, false)

// Prof_Phase is what a step is made of, in the order it runs. `step`
// holds the whole of sim_step; the rest are its parts, so they add up
// to a little under it.
Prof_Phase :: enum {
	step,
	copy_in,
	demands, // the period's demands
	controls, // the simple controls
	headloss_coeffs,
	matrix_coeffs,
	linsolve,
	new_flows,
	converge, // has_converged: the head-loss balance (a second headloss_coeffs pass), leakage and PDA checks
	valves, // valve_status: the PRVs and PSVs, when the damping allows a check
	status, // link_status and pswitch, once converged or every check_freq trials
	new_hydraulics, // quality: wall rates, flow directions, the sort
	copy_out,
	next_hyd, // energy, the time step, the tanks moved, the rules
	react, // the segments reacted
	transport, // the segments moved, node by node
	mass_balance,
}

Prof :: struct {
	cycles: [Prof_Phase]i64,
	calls:  [Prof_Phase]i64,
}

prof: Prof

prof_now :: proc "contextless" () -> i64 {
	return intrinsics.read_cycle_counter()
}

prof_begin :: #force_inline proc "contextless" () -> i64 {
	when PROF {
		return prof_now()
	} else {
		return 0
	}
}

prof_end :: #force_inline proc "contextless" (ph: Prof_Phase, t0: i64) {
	when PROF {
		prof.cycles[ph] += prof_now() - t0
		prof.calls[ph] += 1
	}
}

prof_reset :: proc "contextless" () {
	prof = {}
}
