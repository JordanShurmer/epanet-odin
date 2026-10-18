// epanet.js — the engine in a page or in Node: load epanet.wasm, lay a
// network as columns, step it, read the results from the same columns.
//
//   import { instantiate, Node, Link, Status } from "./epanet.js";
//   const engine = await instantiate(await fetch("epanet.wasm").then(r => r.arrayBuffer()));
//   const sim = engine.sim(256, 256, { flowUnits: Units.LPS, headloss: Headloss.HW });
//   const spring = sim.nodeAdd(Node.RESERVOIR); sim.v.head[spring] = 204;
//   const house  = sim.nodeAdd(Node.JUNCTION);  sim.v.elevation[house] = 140; sim.v.demand[house] = 0.3;
//   const main   = sim.linkAdd(Link.PIPE, spring, house);
//   sim.v.length[main] = 312; sim.v.linkDiameter[main] = 100; sim.v.roughness[main] = 140;
//   sim.step();                      // every quarter hour, say
//   sim.v.pressure[house]            // m
//
// sim.v is a set of typed-array views over the engine's own columns: write
// a demand there, read a pressure there. The views are rebuilt after every
// call that can move memory (a row added, a step), so take them from sim.v
// each time rather than keeping one around.

export const Node = { NONE: 0, JUNCTION: 1, RESERVOIR: 2, TANK: 3 };
export const Link = { NONE: 0, PIPE: 1, PUMP: 2, PRV: 3, PSV: 4, PBV: 5, FCV: 6, TCV: 7, GPV: 8, PCV: 9 };
export const Status = { XHEAD: 0, TEMPCLOSED: 1, CLOSED: 2, OPEN: 3, ACTIVE: 4, XFLOW: 5, XFCV: 6, XPRESSURE: 7, FILLING: 8, EMPTYING: 9, OVERFLOWING: 10 };
export const Units = { CFS: 0, GPM: 1, MGD: 2, IMGD: 3, AFD: 4, LPS: 5, LPM: 6, MLD: 7, CMH: 8, CMD: 9, CMS: 10 };
export const Pressure = { PSI: 0, KPA: 1, METERS: 2, BAR: 3, FEET: 4 };
export const Headloss = { HW: 0, DW: 1, CM: 2 };
export const DemandModel = { DDA: 0, PDA: 1 };
export const Chemical = { CHEM: 0, AGE: 1, TRACE: 2 };
export const Source = { CONCEN: 0, MASS: 1, SETPOINT: 2, FLOWPACED: 3 };
export const Warning = { NONE: 0, UNBALANCED: 1, UNSTABLE: 2, DISCONNECTED: 3, PUMPS: 4, VALVES: 5, NEGATIVE_PRESSURE: 6, NOTHING_TO_SOLVE: 7 };

// the options sim_option takes, by number
const OPTION = {
  flowUnits: 0, pressureUnits: 1, headloss: 2, demandModel: 3, minPressure: 4, requiredPressure: 5,
  pressureExponent: 6, emitterExponent: 7, trials: 8, accuracy: 9, continueUnbalanced: 10, extraTrials: 11,
  hydraulicStep: 12, qualityStep: 13, specificGravity: 14, viscosity: 15, demandMultiplier: 16,
};

// the column table, in the order wasm/epanet.odin lays it out
const COUNTS = ["nodeCount", "linkCount", "nodeCap", "linkCap"];
const COLUMNS = [
  ["kind", Uint8Array, "node"],
  ["elevation", Float64Array, "node"], ["demand", Float64Array, "node"], ["emitter", Float64Array, "node"], ["head", Float64Array, "node"],
  ["level", Float64Array, "node"], ["minLevel", Float64Array, "node"], ["maxLevel", Float64Array, "node"],
  ["diameter", Float64Array, "node"], ["minVolume", Float64Array, "node"],
  ["linkKind", Uint8Array, "link"],
  ["from", Int32Array, "link"], ["to", Int32Array, "link"], ["status", Int32Array, "link"],
  ["setting", Float64Array, "link"], ["length", Float64Array, "link"], ["linkDiameter", Float64Array, "link"],
  ["roughness", Float64Array, "link"], ["minorLoss", Float64Array, "link"], ["checkValve", Uint8Array, "link"],
  ["pumpQ", Float64Array, "link"], ["pumpH", Float64Array, "link"], ["pumpPower", Float64Array, "link"],
  ["solved", Uint8Array, "node"],
  ["pressure", Float64Array, "node"], ["outHead", Float64Array, "node"], ["outDemand", Float64Array, "node"], ["wanted", Float64Array, "node"],
  ["outflow", Float64Array, "node"], ["emitterFlow", Float64Array, "node"], ["leakFlow", Float64Array, "node"],
  ["flow", Float64Array, "link"], ["velocity", Float64Array, "link"], ["headloss", Float64Array, "link"], ["energy", Float64Array, "link"],
  ["outSetting", Float64Array, "link"], ["outStatus", Int32Array, "link"],
];

export class EpanetError extends Error {
  constructor(code, fault) {
    super(`EPANET error ${code}` + (fault >= 0 ? ` at row ${fault}` : ""));
    this.code = code;
    this.fault = fault;
  }
}

// instantiate loads the module. The engine wants pow and exp from the
// host; anything else it asks for is a bug and throws when called.
export async function instantiate(bytes) {
  const mod = await WebAssembly.compile(bytes);
  const env = { pow: Math.pow, exp: Math.exp, ln: Math.log, log: Math.log, sqrt: Math.sqrt, sin: Math.sin, cos: Math.cos,
                fmuladd: (a, b, c) => a * b + c };
  for (const i of WebAssembly.Module.imports(mod)) {
    if (i.module !== "env") throw new Error(`epanet.wasm imports ${i.module}.${i.name}`);
    if (!(i.name in env)) env[i.name] = () => { throw new Error(`epanet.wasm called ${i.name}, which the host does not supply`); };
  }
  const { exports } = await WebAssembly.instantiate(mod, { env });
  return new Engine(exports);
}

export class Engine {
  constructor(exports) {
    this.e = exports;
    this.memory = exports.memory;
  }
  sim(nodeCap, linkCap, options = {}) {
    return new Sim(this, nodeCap, linkCap, options);
  }
}

export class Sim {
  constructor(engine, nodeCap, linkCap, options) {
    this.engine = engine;
    this.e = engine.e;
    this.ptr = this.e.sim_new(nodeCap, linkCap);
    this.v = {};
    this.chemicals = 0;
    for (const [name, value] of Object.entries(options)) this.option(name, value);
    this.refresh();
  }

  // option sets one of the Sim's options by name (see OPTION); read on the next rewire.
  option(name, value) {
    if (!(name in OPTION)) throw new Error(`no option ${name}`);
    this.e.sim_option(this.ptr, OPTION[name], typeof value === "boolean" ? (value ? 1 : 0) : value);
  }

  // refresh rebuilds the views over the columns.
  refresh() {
    const table = new Uint32Array(this.engine.memory.buffer, this.e.sim_columns(this.ptr), COUNTS.length + COLUMNS.length);
    const v = {};
    COUNTS.forEach((name, i) => { v[name] = table[i]; });
    COLUMNS.forEach(([name, Type, of], i) => {
      const n = of === "node" ? v.nodeCap : v.linkCap;
      v[name] = new Type(this.engine.memory.buffer, table[COUNTS.length + i], n);
    });
    for (let c = 0; c < this.chemicals; c++) {
      const q = this.e.sim_quality(this.ptr, c), lq = this.e.sim_link_quality(this.ptr, c);
      v[`quality${c}`] = q ? new Float64Array(this.engine.memory.buffer, q, v.nodeCap) : null;
      v[`linkQuality${c}`] = lq ? new Float64Array(this.engine.memory.buffer, lq, v.linkCap) : null;
      v[`qualityInit${c}`] = new Float64Array(this.engine.memory.buffer, this.e.sim_quality_init(this.ptr, c), v.nodeCap);
    }
    this.v = v;
    return v;
  }

  get nodeCount() { return this.v.nodeCount; }
  get linkCount() { return this.v.linkCount; }
  get t() { return this.e.sim_time(this.ptr); }
  get warn() { return this.e.sim_warn(this.ptr); }
  get atReport() { return this.e.sim_at_report(this.ptr) === 1; }

  nodeAdd(kind) { const i = this.e.sim_node_add(this.ptr, kind); this.refresh(); return i; }
  nodeRemove(i) { this.e.sim_node_remove(this.ptr, i); this.refresh(); }
  linkAdd(kind, from, to) { const k = this.e.sim_link_add(this.ptr, kind, from, to); this.refresh(); return k; }
  linkRemove(k) { this.e.sim_link_remove(this.ptr, k); this.refresh(); }
  rewire() { this.e.sim_rewire(this.ptr); }

  // setChemicals gives the Sim n chemicals; chemical(i, …) and source(i, …) fill them in.
  setChemicals(n) { this.chemicals = this.e.sim_chemicals(this.ptr, n); this.refresh(); }
  chemical(i, { kind = Chemical.CHEM, decay = 0, wall = 0, trace = 0 } = {}) { this.e.sim_chemical(this.ptr, i, kind, decay, wall, trace); }
  source(i, node, kind, strength) { this.e.sim_source(this.ptr, i, node, kind, strength); this.refresh(); }
  massBalance(i) { return this.e.sim_mass_balance(this.ptr, i); }

  // step solves at t with the tanks where they are, writes the out columns,
  // and moves the tanks and the clock on; returns dt (0: a model's end).
  step() {
    const dt = this.e.sim_step(this.ptr);
    this.refresh();
    if (dt < 0) throw new EpanetError(-dt, this.e.sim_fault(this.ptr));
    return dt;
  }

  // solve solves at t again without moving: after an edit mid-step.
  solve() {
    const rc = this.e.sim_solve(this.ptr);
    this.refresh();
    if (rc < 0) throw new EpanetError(-rc, this.e.sim_fault(this.ptr));
  }

  free() { this.e.sim_free(this.ptr); this.ptr = 0; this.v = {}; }
}
