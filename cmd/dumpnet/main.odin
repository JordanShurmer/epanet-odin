package dumpnet

// dumpnet — read an .inp with the Odin reader and print the project.
//
//   dumpnet <file.inp>
//
// harness/dumpnet.c is its twin over EPANET's own reader; test.sh diffs
// the two prints for every fixture.

import "core:fmt"
import "core:os"
import "core:strings"

import "../../epanet"

main :: proc() {
	if len(os.args) != 2 {
		fmt.eprintln("usage: dumpnet <file.inp>")
		os.exit(2)
	}
	p, errcode := epanet.parse_inp(os.args[1])
	sb: strings.Builder
	if p == nil {
		fmt.sbprintf(&sb, "errcode %d 0\n", errcode)
	} else {
		valcode := 0
		if errcode == 0 || errcode == 200 do valcode = epanet.validate_project(p)
		epanet.dump_project(&sb, p, errcode, valcode)
		epanet.project_free(p)
	}
	os.write_string(os.stdout, strings.to_string(sb))
	strings.builder_destroy(&sb)
}
