package run

// run — run a network through the Odin API and print every result.
//
//   run <file.inp>            hydraulics and quality together, step by step
//
// The print is harness/run.c's, line for line: `quality k`, then for
// every hydraulic step `t warn w`, a node line and a link line per
// object in the engine's order (junctions first), and `massbalance r`
// last. test.sh diffs it against plain EPANET's print of the same file:
// the Sim's step loop is EPANET's run.

import "core:c/libc"
import "core:fmt"
import "core:os"

import "../../epanet"

main :: proc() {
	if len(os.args) != 2 {
		fmt.eprintln("usage: run <file.inp>")
		os.exit(2)
	}
	model, err := epanet.load(os.args[1])
	if err != nil && err != .Input_Errors do fail("load", err)
	sim, _, ferr := epanet.sim_from_model(&model)
	if ferr != nil do fail("sim_from_model", ferr)
	defer epanet.sim_delete(&sim)

	nchem := len(sim.chemicals)
	libc.printf("quality %d\n", libc.int(model.options.quality))
	nn, nl := sim.nodes.count, sim.links.count

	// the engine's order: the row of each engine index
	by_node := make([]int, nn + 1)
	by_link := make([]int, nl + 1)
	for {
		at := sim.t
		dt, warn, serr := epanet.sim_step(&sim)
		if serr != nil do fail("step", serr)
		libc.printf("%ld warn %d\n", libc.long(at), libc.int(warn))
		for row in 0 ..< nn do if i := sim.node_engine[row]; i > 0 do by_node[i] = row
		for row in 0 ..< nl do if k := sim.link_engine[row]; k > 0 do by_link[k] = row
		for i in 1 ..= nn {
			row := by_node[i]
			q := nchem > 0 ? sim.out.quality[0][row] : 0
			libc.printf("%ld node %d %.17g %.17g %.17g %.17g\n", libc.long(at), libc.int(i), sim.out.head[row], sim.out.pressure[row], sim.out.outflow[row], q)
		}
		for k in 1 ..= nl {
			row := by_link[k]
			lo := &sim.link_out
			q := nchem > 0 ? lo.quality[0][row] : 0
			status := 0.0
			if lo.status[row] > .CLOSED do status = 1
			if sim.links.kind[row] >= .PRV && lo.status[row] > .OPEN do status = 2
			libc.printf("%ld link %d %.17g %.17g %.17g %g %.17g %.17g\n", libc.long(at), libc.int(k), lo.flow[row], lo.velocity[row], lo.headloss[row], status, lo.setting[row], q)
		}
		if dt == 0 do break
	}
	ratio := nchem > 0 ? sim.balance[0].ratio : 1
	libc.printf("massbalance %.17g\n", ratio)
}

fail :: proc(what: string, err: epanet.Error) {
	fmt.eprintf("run: %s: EPANET error %d\n", what, int(err))
	os.exit(2)
}
