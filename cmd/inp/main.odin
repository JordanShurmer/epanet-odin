package inp

// inp — read an .inp as a Model and write it back.
//
//   inp <in.inp> <out.inp>
//
// test.sh diffs the file written against the one the toolkit writes
// from the same network (EN_saveinpfile, harness/rebuild.c): a Model
// round trip loses nothing the writer keeps.

import "core:fmt"
import "core:os"

import "../../epanet"

main :: proc() {
	if len(os.args) != 3 {
		fmt.eprintln("usage: inp <in.inp> <out.inp>")
		os.exit(2)
	}
	m, err := epanet.load(os.args[1])
	if err != nil && err != .Input_Errors {
		fmt.eprintf("inp: load: EPANET error %d\n", int(err))
		os.exit(2)
	}
	if werr := epanet.write_inp(&m, os.args[2]); werr != nil {
		fmt.eprintf("inp: write: EPANET error %d (%s)\n", int(werr), epanet.error_text(werr))
		os.exit(2)
	}
	epanet.delete_model(&m)
}
