#+build !wasm32
package epanet

// numbers.odin — a number read as EPANET reads it, by the C library.

import "core:c"
import "core:c/libc"

// getfloat: the number in s, by strtod; false when anything follows it.
getfloat :: proc(s: string) -> (f64, bool) {
	buf: [256]u8
	n := min(len(s), 255)
	copy(buf[:n], s)
	buf[n] = 0
	end: [^]u8
	y := libc.strtod(cstring(&buf[0]), (^[^]c.char)(&end))
	if end[0] > 0 do return y, false
	return y, true
}

atol :: proc(s: string) -> i64 {
	buf: [256]u8
	n := min(len(s), 255)
	copy(buf[:n], s)
	buf[n] = 0
	return i64(libc.atol(cstring(&buf[0])))
}
