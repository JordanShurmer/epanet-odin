#+build wasm32
package epanet

// report_wasm.odin — the report and file routines the step calls, for a
// build with no files: each does nothing and says so. The warning code
// (writehydwarn, text.odin) is computed on every build.

writeline :: proc "contextless" (p: ^Project, s: string) {}
writehydstat :: proc "contextless" (p: ^Project, iter: int, relerr: f64) {}
writeflowbalance :: proc "contextless" (p: ^Project) {}
writerelerr :: proc "contextless" (p: ^Project, iter: int, relerr: f64) {}
writehydbal :: proc "contextless" (p: ^Project, qchange, herror: f64, qlink, qnode, hlink: int) {}
writebadvalve :: proc "contextless" (p: ^Project, k: int) {}
writestatchange :: proc "contextless" (p: ^Project, k: int, s1, s2: Status) {}
writecontrolaction :: proc "contextless" (p: ^Project, k, i: int) {}
writeruleaction :: proc "contextless" (p: ^Project, k: int, rule_id: string) {}
writehyderr :: proc "contextless" (p: ^Project, errnode: int) {}
disconnected :: proc "contextless" (p: ^Project) -> int {return 0}
savehyd :: proc "contextless" (p: ^Project, htime: i64) -> int {return 0}
savehydstep :: proc "contextless" (p: ^Project, hydstep: i64) -> int {return 0}
