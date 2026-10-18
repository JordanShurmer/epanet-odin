#+build wasm32
package epanet

// numbers_wasm.odin — a number read for the wasm build, by strconv (as
// strtod, correctly rounded; a trailing unit or junk is a refusal, as
// EPANET's check of what follows the number is).

import "core:strconv"

getfloat :: proc(s: string) -> (f64, bool) {
	y, n, ok := strconv.parse_f64_prefix(s)
	if !ok do return 0, false
	if n < len(s) do return y, false
	return y, true
}

// atol: the leading integer, 0 when none (C's atol).
atol :: proc(s: string) -> i64 {
	i := 0
	for i < len(s) && (s[i] == ' ' || s[i] == '\t') do i += 1
	neg := false
	if i < len(s) && (s[i] == '-' || s[i] == '+') {
		neg = s[i] == '-'
		i += 1
	}
	v: i64
	for i < len(s) && s[i] >= '0' && s[i] <= '9' {
		v = v * 10 + i64(s[i] - '0')
		i += 1
	}
	return neg ? -v : v
}
