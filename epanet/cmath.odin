#+build !wasm32
package epanet

// cmath.odin — the C library's pow, log and sqrt, which EPANET's numbers
// come from. The wasm build (cmath_wasm.odin) takes core:math's instead.

import "core:c/libc"

c_pow :: #force_inline proc "contextless" (x, y: f64) -> f64 {
	return libc.pow(x, y)
}

c_log :: #force_inline proc "contextless" (x: f64) -> f64 {
	return libc.log(x)
}

c_sqrt :: #force_inline proc "contextless" (x: f64) -> f64 {
	return libc.sqrt(x)
}
