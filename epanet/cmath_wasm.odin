#+build wasm32
package epanet

// cmath_wasm.odin — pow, log and sqrt for the wasm build, from core:math:
// pow and exp come in as imports (env.pow, env.exp) the host supplies, so
// the last bits are the host's, not glibc's; the harness holds the wasm
// build to TOL, not to the byte.

import "core:math"

c_pow :: #force_inline proc "contextless" (x, y: f64) -> f64 {
	return math.pow(x, y)
}

c_log :: #force_inline proc "contextless" (x: f64) -> f64 {
	return math.ln(x)
}

c_sqrt :: #force_inline proc "contextless" (x: f64) -> f64 {
	return math.sqrt(x)
}
