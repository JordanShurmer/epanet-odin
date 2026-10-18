#+build !wasm32
package epanet

// arena.odin — what a project and a Model allocate from: a growing
// virtual-memory arena. The wasm build (arena_wasm.odin) grows a
// block arena from the wasm heap instead. File is the C library's.

import "base:runtime"
import "core:c/libc"
import "core:mem/virtual"

Arena :: virtual.Arena
File :: ^libc.FILE

arena_init :: proc(a: ^Arena) -> bool {
	return virtual.arena_init_growing(a) == nil
}

arena_allocator :: proc (a: ^Arena) -> runtime.Allocator {
	return virtual.arena_allocator(a)
}

arena_destroy :: proc(a: ^Arena) {
	virtual.arena_destroy(a)
}
