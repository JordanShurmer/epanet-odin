// check.mjs — the wasm build's road: cmd/check's network laid through
// epanet.js, two chemicals on it, stepped for a day; every hour mark
// printed as `check-api --reference` prints it natively. test.sh diffs
// the two within TOL (the host's pow and exp are not glibc's).
//
//   node wasm/check.mjs build/epanet.wasm

import { readFileSync } from "node:fs";
import { instantiate, Node, Link, Units, Headloss, Chemical, Source } from "./epanet.js";

const engine = await instantiate(readFileSync(process.argv[2]));
const sim = engine.sim(16, 16, { flowUnits: Units.GPM, headloss: Headloss.HW });
const v = () => sim.v;

const r1 = sim.nodeAdd(Node.RESERVOIR);
v().head[r1] = 700;
const els = [0, 710, 700, 695, 690], demands = [0, 150, 200, 150, 100];
const j = [0];
for (let i = 1; i <= 4; i++) {
  j[i] = sim.nodeAdd(Node.JUNCTION);
  v().elevation[j[i]] = els[i];
  v().demand[j[i]] = demands[i];
}
v().emitter[j[4]] = 2;
const t1 = sim.nodeAdd(Node.TANK);
v().elevation[t1] = 850;
v().level[t1] = 120; v().minLevel[t1] = 100; v().maxLevel[t1] = 150; v().diameter[t1] = 50.5;
const p1 = sim.linkAdd(Link.PUMP, r1, j[1]);
v().pumpQ[p1] = 1500; v().pumpH[p1] = 250;
const pipe = (from, to, length, diam, rough) => {
  const k = sim.linkAdd(Link.PIPE, from, to);
  v().length[k] = length; v().linkDiameter[k] = diam; v().roughness[k] = rough;
};
pipe(j[1], j[2], 5280, 14, 100);
pipe(j[2], j[3], 5280, 12, 100);
pipe(j[3], j[4], 5280, 10, 100);
pipe(j[2], j[4], 5280, 8, 100);
pipe(j[3], t1, 3000, 12, 100);

sim.setChemicals(2);
sim.chemical(0, { kind: Chemical.CHEM, decay: -0.5, wall: -1 });
for (let i = 0; i < sim.nodeCount; i++) v().qualityInit0[i] = 0.5;
sim.source(0, r1, Source.CONCEN, 1);
sim.chemical(1, { kind: Chemical.AGE });

const lines = [];
for (let at = 0; at < 24 * 3600 + 1; at = sim.t) {
  sim.step();
  if (!sim.atReport) continue;
  const h = at / 3600, c = sim.v;
  for (let i = 0; i < sim.nodeCount; i++)
    lines.push(`${h} node ${i} ${c.pressure[i]} ${c.outHead[i]} ${c.outflow[i]} ${c.quality0[i]} ${c.quality1[i]}`);
  for (let k = 0; k < sim.linkCount; k++)
    lines.push(`${h} link ${k} ${c.flow[k]} ${c.headloss[k]} ${c.linkQuality0[k]} ${c.linkQuality1[k]}`);
}
lines.push(`massbalance ${sim.massBalance(0)} ${sim.massBalance(1)}`);
sim.free();
process.stdout.write(lines.join("\n") + "\n");
