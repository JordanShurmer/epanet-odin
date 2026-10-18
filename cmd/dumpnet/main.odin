package dumpnet

// dumpnet — read an .inp with the Odin reader and print the project.
//
//   dumpnet <file.inp>            the reader's project
//   dumpnet --model <file.inp>    the same file read as a Model and built
//                                 back into a project (epanet/model.odin)
//
// harness/dumpnet.c is its twin over EPANET's own reader; test.sh diffs
// the two prints for every fixture, and the --model print against the
// first: a Model loses nothing.

import "core:fmt"
import "core:os"
import "core:strings"

import "../../epanet"

main :: proc() {
	via_model := len(os.args) == 3 && os.args[1] == "--model"
	if len(os.args) != 2 && !via_model {
		fmt.eprintln("usage: dumpnet [--model] <file.inp>")
		os.exit(2)
	}
	path := os.args[len(os.args) - 1]
	sb: strings.Builder
	if via_model {
		m, err := epanet.load(path)
		if err != nil && err != .Input_Errors {
			fmt.sbprintf(&sb, "errcode %d 0\n", int(err))
		} else {
			b := epanet.project_from_model(&m)
			if b.err != nil {
				fmt.sbprintf(&sb, "errcode %d 0 (build: %s at %d)\n", int(b.err), epanet.error_text(b.err), b.at)
			} else {
				valcode := epanet.validate_project(b.p)
				epanet.dump_project(&sb, b.p, int(err), valcode)
			}
			if b.p != nil do epanet.project_free(b.p)
		}
		epanet.delete_model(&m)
	} else {
		p, errcode := epanet.parse_inp(path)
		if p == nil {
			fmt.sbprintf(&sb, "errcode %d 0\n", errcode)
		} else {
			valcode := 0
			if errcode == 0 || errcode == 200 do valcode = epanet.validate_project(p)
			epanet.dump_project(&sb, p, errcode, valcode)
			epanet.project_free(p)
		}
	}
	os.write_string(os.stdout, strings.to_string(sb))
	strings.builder_destroy(&sb)
}
