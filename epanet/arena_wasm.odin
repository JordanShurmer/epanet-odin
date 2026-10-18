#+build wasm32
package epanet

// arena_wasm.odin — the project's arena on wasm: blocks from the caller's
// allocator (the wasm heap). There are no files; File is a placeholder
// the file-world code, which the wasm build leaves out, never sees.

import "base:runtime"
import "core:mem"

Arena :: mem.Dynamic_Arena
File :: rawptr

arena_init :: proc(a: ^Arena) -> bool {
	mem.dynamic_arena_init(a, context.allocator, context.allocator)
	return true
}

arena_allocator :: proc (a: ^Arena) -> runtime.Allocator {
	return mem.dynamic_arena_allocator(a)
}

arena_destroy :: proc(a: ^Arena) {
	mem.dynamic_arena_destroy(a)
}
