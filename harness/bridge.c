/*
 * bridge.c — the EPANET symbols that the Odin rewrite replaces.
 *
 * test.sh compiles EPANET's own sources, then renames each swapped symbol in
 * the object that defines it (linsolve -> linsolve_c, with objcopy), and links
 * this file in. EPANET's callers still call `linsolve`; they get the version
 * below, which hands the project to the Odin package. EPANET's source is not
 * edited.
 *
 * The Odin package sees the project as Project_C (epanet/export.odin): the
 * hydraulic state arrays are EPANET's own, used in place, and the fields of
 * EPANET's node, link, tank, pump, valve, curve and pattern structs are
 * copied into one array per field — the mirror — on every call in, with the
 * ones the package writes copied back on the way out. A harness that must
 * never go stale copies; the finished library will own the arrays.
 *
 * Built with -DSHADOW, every swapped call runs both: a snapshot of all the
 * state the engine writes is taken, the C original runs and its result is
 * kept, the snapshot is put back, the Odin port runs, and the two results are
 * compared element by element. The first difference is printed with the call
 * number and the index, and an exit handler prints one tally line per symbol.
 * That is how a port is proved: on every call the whole suite makes.
 */
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "types.h"
#include "funcs.h"
#include "text.h"

/* ── the Odin package's view (epanet/export.odin, field for field) ───── */

typedef struct {
    int nnodes, njuncs, nlinks;
    int ntanks, npumps, nvalves, ncontrols;
    int ncurves, npatterns, ndemands;
    int def_pat;
    double *el, *ke, *leak_cfa, *leak_cva;
    int *demand_first, *demand_pat;
    double *demand_base;
    int *link_type, *n1, *n2;
    double *diam, *len, *km, *kc, *r;
    int *link_pump, *link_valve;
    int *init_status;
    double *init_setting;
    int *tank_node;
    double *tank_area, *tank_hmin, *tank_hmax;
    double *tank_vmin, *tank_vmax;
    int *tank_pat, *tank_vcurve;
    int *tank_overflow;
    int *pump_link, *pump_type, *pump_hcurve;
    int *pump_ecurve;
    double *pump_h0, *pump_r, *pump_n, *pump_hmax, *pump_q0;
    int *pump_upat, *pump_epat;
    double *pump_ecost;
    int *valve_link, *valve_curve;
    int *curve_npts;
    double **curve_x, **curve_y;
    int *pattern_len;
    double **pattern_f;
    int *control_link, *control_node, *control_type;
    double *control_grade, *control_setting;
    int *control_status;
    long long *control_time;
    int *control_enabled;
    double ucf_flow, ucf_head, ucf_volume;
} OdinNetwork;

typedef struct {
    int formflag, demand_model, emit_backflow, has_leakage;
    int max_iter, extra_iter, check_freq, max_check;
    int status_report, status_report_any, epat;
    double hexp, qexp, pexp, pmin, preq, rqtol, viscos;
    double htol, qtol, hacc, head_error_limit, flow_change_limit;
    double damp_limit, dmult, spgrav, epump, ecost;
    double dsystem, emax;
    double *head, *node_demand, *demand_flow, *full_demand;
    double *emitter_flow, *leak_flow, *leak_qfa, *leak_qva, *xflow;
    double *flow, *setting;
    int *status;
    double *p, *y;
    double *tank_volume;
    Senergy *energy; /* Pump_Energy has Senergy's eight doubles in order */
} OdinHydraulics;

typedef struct {
    int ncoeffs;
    double *aii, *aij, *f, *temp;
    int *xlnz, *nzsub, *lnz, *link, *first;
    int *order, *row, *ndx;
} OdinMatrix;

/* What is still C's: the status report's lines, and the rules. */
typedef struct {
    void *ctx;
    void (*write_relerr)(void *, int, double);
    void (*write_statchange)(void *, int, int, int);
    void (*write_hyderr)(void *, int);
    void (*write_hydbal)(void *, double, double, int, int, int);
    void (*write_badvalve)(void *, int);
    void (*write_control_action)(void *, int, int);
    int (*check_rules)(void *, long long, long long);
} OdinHooks;

typedef struct {
    OdinNetwork *net;
    OdinHydraulics *hyd;
    OdinMatrix *m;
    Times *times; /* EPANET's own; Odin's Times matches its layout */
    OdinHooks *hooks;
} OdinProject;

typedef struct {
    int errcode, iterations, deficient_nodes;
    double relative_error, max_head_error, max_flow_change;
    double demand_reduction, relax;
} OdinSolution;

/* The ports (epanet/export.odin). */
int odin_linsolve(int n, int ncoeffs, double *aii, double *aij, double *f, double *temp,
                  int *xlnz, int *nzsub, int *lnz, int *link, int *first);
void odin_createsparse(int nnodes, int njuncs, int nlinks, int *n1, int *n2, int *order, int *row,
                       int *ndx, int *ncoeffs, int **xlnz, int **nzsub, int **lnz);
void odin_headlosscoeffs(OdinProject *);
void odin_matrixcoeffs(OdinProject *);
void odin_hydsolve(OdinProject *, OdinSolution *);
void odin_resistcoeff(OdinProject *, int k);
double odin_pcvlosscoeff(OdinProject *, int k, double s);
void odin_initlinkflow(OdinProject *, int i, int s, double k);
void odin_resetpumpflow(OdinProject *, int i);
void odin_setlinkstatus(OdinProject *, int k, int value);
void odin_setlinksetting(OdinProject *, int k, double value);
void odin_demands(OdinProject *);
int odin_controls(OdinProject *);
long long odin_timestep(OdinProject *, int nrules);
void odin_tanklevels(OdinProject *, long long tstep);
double odin_tankvolume(OdinProject *, int i, double h);
double odin_tankgrade(OdinProject *, int i, double v);
void odin_getenergy(OdinProject *, int k, double *kw, double *eff);
void odin_getallpumpsenergy(OdinProject *);
void odin_addenergy(OdinProject *, long long hstep);

/* The originals, renamed at link time. */
int linsolve_c(Smatrix *sm, int n);
int createsparse_c(Project *pr);
void headlosscoeffs_c(Project *pr);
void matrixcoeffs_c(Project *pr);
int hydsolve_c(Project *pr, int *iter, double *relerr);
void resistcoeff_c(Project *pr, int k);
double pcvlosscoeff_c(Project *pr, int k, double s);
void initlinkflow_c(Project *pr, int i, char s, double k);
void resetpumpflow_c(Project *pr, int i);
void setlinkstatus_c(Project *pr, int k, char value, StatusType *s, double *kk);
void setlinksetting_c(Project *pr, int k, double value, StatusType *s, double *kk);
void demands_c(Project *pr);
int controls_c(Project *pr);
long timestep_c(Project *pr);
void tanklevels_c(Project *pr, long tstep);
double tankvolume_c(Project *pr, int i, double h);
double tankgrade_c(Project *pr, int i, double v);
void getenergy_c(Project *pr, int k, double *kw, double *eff);
void getallpumpsenergy_c(Project *pr);
void addenergy_c(Project *pr, long hstep);

/* ── the mirror ──────────────────────────────────────────────────────── */

static OdinNetwork mir;
static OdinHydraulics hydv;
static OdinMatrix matv;
static OdinHooks hooks;
static OdinProject proj = {&mir, &hydv, &matv, NULL, &hooks};
static int mir_nodes, mir_links, mir_tanks, mir_pumps, mir_valves, mir_controls,
           mir_curves, mir_demands, mir_patterns = -1; /* -1: pattern 0 always exists */
static double *leak_cfa, *leak_cva, *leak_qfa, *leak_qva, *tank_volume;
static Senergy *energy;

/* grow — (re)allocate a mirror array when the network got bigger. */
static void *grow(void *p, int n, size_t size)
{
    return realloc(p, (size_t)(n + 1) * size);
}

static void hooks_init(Project *pr);

/* enter — refresh the mirror from the project. Called on every way in. */
static OdinProject *enter(Project *pr)
{
    Network *net = &pr->network;
    Hydraul *hyd = &pr->hydraul;
    Smatrix *sm = &hyd->smatrix;
    OdinNetwork *m = &mir;
    int i, k, nd;

    if (net->Nnodes > mir_nodes) {
        mir_nodes = net->Nnodes;
        m->el = grow(m->el, mir_nodes, sizeof(double));
        m->ke = grow(m->ke, mir_nodes, sizeof(double));
        leak_cfa = grow(leak_cfa, mir_nodes, sizeof(double));
        leak_cva = grow(leak_cva, mir_nodes, sizeof(double));
        leak_qfa = grow(leak_qfa, mir_nodes, sizeof(double));
        leak_qva = grow(leak_qva, mir_nodes, sizeof(double));
        m->demand_first = grow(m->demand_first, mir_nodes + 1, sizeof(int));
    }
    if (net->Nlinks > mir_links) {
        mir_links = net->Nlinks;
        m->link_type = grow(m->link_type, mir_links, sizeof(int));
        m->n1 = grow(m->n1, mir_links, sizeof(int));
        m->n2 = grow(m->n2, mir_links, sizeof(int));
        m->diam = grow(m->diam, mir_links, sizeof(double));
        m->len = grow(m->len, mir_links, sizeof(double));
        m->km = grow(m->km, mir_links, sizeof(double));
        m->kc = grow(m->kc, mir_links, sizeof(double));
        m->r = grow(m->r, mir_links, sizeof(double));
        m->link_pump = grow(m->link_pump, mir_links, sizeof(int));
        m->link_valve = grow(m->link_valve, mir_links, sizeof(int));
        m->init_status = grow(m->init_status, mir_links, sizeof(int));
        m->init_setting = grow(m->init_setting, mir_links, sizeof(double));
    }
    if (net->Ntanks > mir_tanks) {
        mir_tanks = net->Ntanks;
        m->tank_node = grow(m->tank_node, mir_tanks, sizeof(int));
        m->tank_area = grow(m->tank_area, mir_tanks, sizeof(double));
        m->tank_hmin = grow(m->tank_hmin, mir_tanks, sizeof(double));
        m->tank_hmax = grow(m->tank_hmax, mir_tanks, sizeof(double));
        m->tank_vmin = grow(m->tank_vmin, mir_tanks, sizeof(double));
        m->tank_vmax = grow(m->tank_vmax, mir_tanks, sizeof(double));
        m->tank_pat = grow(m->tank_pat, mir_tanks, sizeof(int));
        m->tank_vcurve = grow(m->tank_vcurve, mir_tanks, sizeof(int));
        m->tank_overflow = grow(m->tank_overflow, mir_tanks, sizeof(int));
        tank_volume = grow(tank_volume, mir_tanks, sizeof(double));
    }
    if (net->Npumps > mir_pumps) {
        mir_pumps = net->Npumps;
        m->pump_link = grow(m->pump_link, mir_pumps, sizeof(int));
        m->pump_type = grow(m->pump_type, mir_pumps, sizeof(int));
        m->pump_hcurve = grow(m->pump_hcurve, mir_pumps, sizeof(int));
        m->pump_ecurve = grow(m->pump_ecurve, mir_pumps, sizeof(int));
        m->pump_h0 = grow(m->pump_h0, mir_pumps, sizeof(double));
        m->pump_r = grow(m->pump_r, mir_pumps, sizeof(double));
        m->pump_n = grow(m->pump_n, mir_pumps, sizeof(double));
        m->pump_hmax = grow(m->pump_hmax, mir_pumps, sizeof(double));
        m->pump_q0 = grow(m->pump_q0, mir_pumps, sizeof(double));
        m->pump_upat = grow(m->pump_upat, mir_pumps, sizeof(int));
        m->pump_epat = grow(m->pump_epat, mir_pumps, sizeof(int));
        m->pump_ecost = grow(m->pump_ecost, mir_pumps, sizeof(double));
        energy = grow(energy, mir_pumps, sizeof(Senergy));
    }
    if (net->Nvalves > mir_valves) {
        mir_valves = net->Nvalves;
        m->valve_link = grow(m->valve_link, mir_valves, sizeof(int));
        m->valve_curve = grow(m->valve_curve, mir_valves, sizeof(int));
    }
    if (net->Ncontrols > mir_controls) {
        mir_controls = net->Ncontrols;
        m->control_link = grow(m->control_link, mir_controls, sizeof(int));
        m->control_node = grow(m->control_node, mir_controls, sizeof(int));
        m->control_type = grow(m->control_type, mir_controls, sizeof(int));
        m->control_grade = grow(m->control_grade, mir_controls, sizeof(double));
        m->control_setting = grow(m->control_setting, mir_controls, sizeof(double));
        m->control_status = grow(m->control_status, mir_controls, sizeof(int));
        m->control_time = grow(m->control_time, mir_controls, sizeof(long long));
        m->control_enabled = grow(m->control_enabled, mir_controls, sizeof(int));
    }
    if (net->Ncurves > mir_curves) {
        mir_curves = net->Ncurves;
        m->curve_npts = grow(m->curve_npts, mir_curves, sizeof(int));
        m->curve_x = grow(m->curve_x, mir_curves, sizeof(double *));
        m->curve_y = grow(m->curve_y, mir_curves, sizeof(double *));
    }
    if (net->Npats > mir_patterns) {
        mir_patterns = net->Npats;
        m->pattern_len = grow(m->pattern_len, mir_patterns, sizeof(int));
        m->pattern_f = grow(m->pattern_f, mir_patterns, sizeof(double *));
    }

    m->nnodes = net->Nnodes;
    m->njuncs = net->Njuncs;
    m->nlinks = net->Nlinks;
    m->ntanks = net->Ntanks;
    m->npumps = net->Npumps;
    m->nvalves = net->Nvalves;
    m->ncontrols = net->Ncontrols;
    m->ncurves = net->Ncurves;
    m->npatterns = net->Npats;
    m->def_pat = hyd->DefPat;

    /* Nodes, and their demand lists flattened. */
    nd = 0;
    for (i = 1; i <= net->Nnodes; i++) {
        Pdemand d;
        m->el[i] = net->Node[i].El;
        m->ke[i] = net->Node[i].Ke;
        leak_cfa[i] = leak_cva[i] = leak_qfa[i] = leak_qva[i] = 0.0;
        for (d = net->Node[i].D; d; d = d->next) nd++;
    }
    if (nd > mir_demands) {
        mir_demands = nd;
        m->demand_base = grow(m->demand_base, mir_demands, sizeof(double));
        m->demand_pat = grow(m->demand_pat, mir_demands, sizeof(int));
    }
    m->ndemands = nd;
    nd = 1;
    for (i = 1; i <= net->Nnodes; i++) {
        Pdemand d;
        m->demand_first[i] = nd;
        for (d = net->Node[i].D; d; d = d->next, nd++) {
            m->demand_base[nd] = d->Base;
            m->demand_pat[nd] = d->Pat;
        }
    }
    m->demand_first[net->Nnodes + 1] = nd;
    if (hyd->Leakage) for (i = 1; i <= net->Njuncs; i++) {
        leak_cfa[i] = hyd->Leakage[i].cfa;
        leak_cva[i] = hyd->Leakage[i].cva;
        leak_qfa[i] = hyd->Leakage[i].qfa;
        leak_qva[i] = hyd->Leakage[i].qva;
    }
    m->leak_cfa = leak_cfa;
    m->leak_cva = leak_cva;

    for (k = 1; k <= net->Nlinks; k++) {
        Slink *l = &net->Link[k];
        m->link_type[k] = l->Type;
        m->n1[k] = l->N1;
        m->n2[k] = l->N2;
        m->diam[k] = l->Diam;
        m->len[k] = l->Len;
        m->km[k] = l->Km;
        m->kc[k] = l->Kc;
        m->r[k] = l->R;
        m->link_pump[k] = 0;
        m->link_valve[k] = 0;
        m->init_status[k] = l->InitStatus;
        m->init_setting[k] = l->InitSetting;
    }
    for (i = 1; i <= net->Ntanks; i++) {
        Stank *t = &net->Tank[i];
        m->tank_node[i] = t->Node;
        m->tank_area[i] = t->A;
        m->tank_hmin[i] = t->Hmin;
        m->tank_hmax[i] = t->Hmax;
        m->tank_vmin[i] = t->Vmin;
        m->tank_vmax[i] = t->Vmax;
        m->tank_pat[i] = t->Pat;
        m->tank_vcurve[i] = t->Vcurve;
        m->tank_overflow[i] = t->CanOverflow;
        tank_volume[i] = t->V;
    }
    for (i = 1; i <= net->Npumps; i++) {
        Spump *p = &net->Pump[i];
        m->link_pump[p->Link] = i;
        m->pump_link[i] = p->Link;
        m->pump_type[i] = p->Ptype;
        m->pump_hcurve[i] = p->Hcurve;
        m->pump_ecurve[i] = p->Ecurve;
        m->pump_h0[i] = p->H0;
        m->pump_r[i] = p->R;
        m->pump_n[i] = p->N;
        m->pump_hmax[i] = p->Hmax;
        m->pump_q0[i] = p->Q0;
        m->pump_upat[i] = p->Upat;
        m->pump_epat[i] = p->Epat;
        m->pump_ecost[i] = p->Ecost;
        energy[i] = p->Energy;
    }
    for (i = 1; i <= net->Nvalves; i++) {
        m->link_valve[net->Valve[i].Link] = i;
        m->valve_link[i] = net->Valve[i].Link;
        m->valve_curve[i] = net->Valve[i].Curve;
    }
    for (i = 1; i <= net->Ncontrols; i++) {
        Scontrol *c = &net->Control[i];
        m->control_link[i] = c->Link;
        m->control_node[i] = c->Node;
        m->control_type[i] = c->Type;
        m->control_grade[i] = c->Grade;
        m->control_setting[i] = c->Setting;
        m->control_status[i] = c->Status;
        m->control_time[i] = c->Time;
        m->control_enabled[i] = c->isEnabled;
    }
    for (i = 1; i <= net->Ncurves; i++) {
        m->curve_npts[i] = net->Curve[i].Npts;
        m->curve_x[i] = net->Curve[i].X;
        m->curve_y[i] = net->Curve[i].Y;
    }
    /* Pattern 0 is EPANET's one-multiplier dummy for demands without one. */
    for (i = 0; i <= net->Npats; i++) {
        m->pattern_len[i] = net->Pattern[i].Length;
        m->pattern_f[i] = net->Pattern[i].F;
    }
    m->ucf_flow = pr->Ucf[FLOW];
    m->ucf_head = pr->Ucf[HEAD];
    m->ucf_volume = pr->Ucf[VOLUME];

    /* The hydraulic state: EPANET's arrays, in place. */
    hydv.formflag = hyd->Formflag;
    hydv.demand_model = hyd->DemandModel;
    hydv.emit_backflow = hyd->EmitBackFlag;
    hydv.has_leakage = hyd->HasLeakage;
    hydv.max_iter = hyd->MaxIter;
    hydv.extra_iter = hyd->ExtraIter;
    hydv.check_freq = hyd->CheckFreq;
    hydv.max_check = hyd->MaxCheck;
    hydv.status_report = pr->report.Statflag == FULL;
    hydv.status_report_any = pr->report.Statflag != 0;
    hydv.epat = hyd->Epat;
    hydv.hexp = hyd->Hexp;
    hydv.qexp = hyd->Qexp;
    hydv.pexp = hyd->Pexp;
    hydv.pmin = hyd->Pmin;
    hydv.preq = hyd->Preq;
    hydv.rqtol = hyd->RQtol;
    hydv.viscos = hyd->Viscos;
    hydv.htol = hyd->Htol;
    hydv.qtol = hyd->Qtol;
    hydv.hacc = hyd->Hacc;
    hydv.head_error_limit = hyd->HeadErrorLimit;
    hydv.flow_change_limit = hyd->FlowChangeLimit;
    hydv.damp_limit = hyd->DampLimit;
    hydv.dmult = hyd->Dmult;
    hydv.spgrav = hyd->SpGrav;
    hydv.epump = hyd->Epump;
    hydv.ecost = hyd->Ecost;
    hydv.dsystem = hyd->Dsystem;
    hydv.emax = hyd->Emax;
    hydv.head = hyd->NodeHead;
    hydv.node_demand = hyd->NodeDemand;
    hydv.demand_flow = hyd->DemandFlow;
    hydv.full_demand = hyd->FullDemand;
    hydv.emitter_flow = hyd->EmitterFlow;
    hydv.leak_flow = hyd->LeakageFlow;
    hydv.leak_qfa = leak_qfa;
    hydv.leak_qva = leak_qva;
    hydv.xflow = hyd->Xflow;
    hydv.flow = hyd->LinkFlow;
    hydv.setting = hyd->LinkSetting;
    hydv.status = (int *)hyd->LinkStatus;
    hydv.p = hyd->P;
    hydv.y = hyd->Y;
    hydv.tank_volume = tank_volume;
    hydv.energy = energy;

    matv.ncoeffs = sm->Ncoeffs;
    matv.aii = sm->Aii;
    matv.aij = sm->Aij;
    matv.f = sm->F;
    matv.temp = sm->temp;
    matv.xlnz = sm->XLNZ;
    matv.nzsub = sm->NZSUB;
    matv.lnz = sm->LNZ;
    matv.link = sm->link;
    matv.first = sm->first;
    matv.order = sm->Order;
    matv.row = sm->Row;
    matv.ndx = sm->Ndx;
    proj.m = sm->Aii ? &matv : NULL;
    proj.times = &pr->times;
    hooks_init(pr);
    return &proj;
}

/* leave — carry back what the package writes into EPANET's structs.
 * Called on every way out. */
static void leave(Project *pr)
{
    Network *net = &pr->network;
    Hydraul *hyd = &pr->hydraul;
    int i;
    for (i = 1; i <= net->Npumps; i++) {
        net->Pump[i].H0 = mir.pump_h0[i];
        net->Pump[i].R = mir.pump_r[i];
        net->Pump[i].N = mir.pump_n[i];
        net->Pump[i].Energy = energy[i];
    }
    for (i = 1; i <= net->Nlinks; i++) net->Link[i].R = mir.r[i];
    for (i = 1; i <= net->Ntanks; i++) net->Tank[i].V = tank_volume[i];
    if (hyd->Leakage) for (i = 1; i <= net->Njuncs; i++) {
        hyd->Leakage[i].qfa = leak_qfa[i];
        hyd->Leakage[i].qva = leak_qva[i];
    }
    hyd->Dsystem = hydv.dsystem;
    hyd->Emax = hydv.emax;
}

/* ── the hooks: each one is the EPANET function of the same purpose ─── */

static void hook_relerr(void *ctx, int iter, double relerr) { writerelerr(ctx, iter, relerr); }
static void hook_statchange(void *ctx, int k, int s0, int s1) { writestatchange(ctx, k, s0, s1); }
static void hook_hyderr(void *ctx, int n) { writehyderr(ctx, n); }
static void hook_control_action(void *ctx, int k, int i) { writecontrolaction(ctx, k, i); }
static void hook_badvalve(void *ctx, int k)
{
    Project *pr = ctx;
    sprintf(pr->Msg, FMT61, clocktime(pr->report.Atime, pr->times.Htime), pr->network.Link[k].ID);
    writeline(pr, pr->Msg);
}
static void hook_hydbal(void *ctx, double qchange, double herror, int qlink, int qnode, int hlink)
{
    Project *pr = ctx;
    if (qlink >= 1) {
        sprintf(pr->Msg, FMT66, qchange, pr->network.Link[qlink].ID);
        writeline(pr, pr->Msg);
    } else if (qnode >= 1) {
        sprintf(pr->Msg, FMT67, qchange, pr->network.Node[qnode].ID);
        writeline(pr, pr->Msg);
    }
    if (hlink >= 1) {
        sprintf(pr->Msg, FMT68, herror, pr->network.Link[hlink].ID);
        writeline(pr, pr->Msg);
    }
}
/* rules.c reads the clock and the tank volumes from the project, and acts
 * through setlinkstatus/setlinksetting, which come back through this file:
 * so the mirror goes out before, and comes back in after. */
static int hook_check_rules(void *ctx, long long htime, long long dt)
{
    Project *pr = ctx;
    long saved = pr->times.Htime;
    int fired;
    leave(pr);
    pr->times.Htime = (long)htime;
    fired = checkrules(pr, (long)dt);
    pr->times.Htime = saved;
    enter(pr);
    return fired;
}

static void hooks_init(Project *pr)
{
    hooks.ctx = pr;
    hooks.write_relerr = hook_relerr;
    hooks.write_statchange = hook_statchange;
    hooks.write_hyderr = hook_hyderr;
    hooks.write_hydbal = hook_hydbal;
    hooks.write_badvalve = hook_badvalve;
    hooks.write_control_action = hook_control_action;
    hooks.check_rules = hook_check_rules;
}

/* ── the Odin-backed versions ────────────────────────────────────────── */

static int linsolve_odin(Smatrix *sm, int n)
{
    return odin_linsolve(n, sm->Ncoeffs, sm->Aii, sm->Aij, sm->F, sm->temp, sm->XLNZ, sm->NZSUB,
                         sm->LNZ, sm->link, sm->first);
}

/* The arrays smatrix.c's allocsmatrix + alloclinsolve would have made, so
 * that freesparse frees the same set. */
static int createsparse_odin(Project *pr)
{
    Network *net = &pr->network;
    Smatrix *sm = &pr->hydraul.smatrix;
    int nn = net->Nnodes, nl = net->Nlinks, k;
    int *n1 = malloc((nl + 1) * sizeof(int));
    int *n2 = malloc((nl + 1) * sizeof(int));

    for (k = 1; k <= nl; k++) {
        n1[k] = net->Link[k].N1;
        n2[k] = net->Link[k].N2;
    }
    sm->Order = calloc(nn + 1, sizeof(int));
    sm->Row = calloc(nn + 1, sizeof(int));
    sm->Ndx = calloc(nl + 1, sizeof(int));
    odin_createsparse(nn, net->Njuncs, nl, n1, n2, sm->Order, sm->Row, sm->Ndx, &sm->Ncoeffs,
                      &sm->XLNZ, &sm->NZSUB, &sm->LNZ);
    free(n1);
    free(n2);

    sm->Aij = calloc(sm->Ncoeffs + 1, sizeof(double));
    sm->Aii = calloc(nn + 1, sizeof(double));
    sm->F = calloc(nn + 1, sizeof(double));
    sm->temp = calloc(nn + 1, sizeof(double));
    sm->link = calloc(nn + 1, sizeof(int));
    sm->first = calloc(nn + 1, sizeof(int));

    /* The C version leaves the full adjacency lists built; so does this. */
    return buildadjlists(net);
}

static void headlosscoeffs_odin(Project *pr) { odin_headlosscoeffs(enter(pr)); leave(pr); }
static void matrixcoeffs_odin(Project *pr) { odin_matrixcoeffs(enter(pr)); leave(pr); }

static int hydsolve_odin(Project *pr, int *iter, double *relerr)
{
    Hydraul *hyd = &pr->hydraul;
    OdinSolution sol;
    odin_hydsolve(enter(pr), &sol);
    leave(pr);
    hyd->RelaxFactor = sol.relax;
    hyd->RelativeError = sol.relative_error;
    hyd->MaxHeadError = sol.max_head_error;
    hyd->MaxFlowChange = sol.max_flow_change;
    hyd->Iterations = sol.iterations;
    hyd->DeficientNodes = sol.deficient_nodes;
    hyd->DemandReduction = sol.demand_reduction;
    *iter = sol.iterations;
    *relerr = sol.relative_error;
    return sol.errcode;
}

static void resistcoeff_odin(Project *pr, int k) { odin_resistcoeff(enter(pr), k); leave(pr); }
static double pcvlosscoeff_odin(Project *pr, int k, double s)
{
    double r = odin_pcvlosscoeff(enter(pr), k, s);
    leave(pr);
    return r;
}
static void initlinkflow_odin(Project *pr, int i, char s, double k) { odin_initlinkflow(enter(pr), i, s, k); leave(pr); }
static void resetpumpflow_odin(Project *pr, int i) { odin_resetpumpflow(enter(pr), i); leave(pr); }
/* Every caller passes &hyd->LinkStatus[k], &hyd->LinkSetting[k]: the Odin
 * versions write those arrays by index. */
static void setlinkstatus_odin(Project *pr, int k, char value, StatusType *s, double *kk)
{
    (void)s; (void)kk;
    odin_setlinkstatus(enter(pr), k, value);
    leave(pr);
}
static void setlinksetting_odin(Project *pr, int k, double value, StatusType *s, double *kk)
{
    (void)s; (void)kk;
    odin_setlinksetting(enter(pr), k, value);
    leave(pr);
}
static void demands_odin(Project *pr) { odin_demands(enter(pr)); leave(pr); }
static int controls_odin(Project *pr)
{
    int n = odin_controls(enter(pr));
    leave(pr);
    return n;
}
static long timestep_odin(Project *pr)
{
    long t = (long)odin_timestep(enter(pr), pr->network.Nrules);
    leave(pr);
    return t;
}
static void tanklevels_odin(Project *pr, long tstep) { odin_tanklevels(enter(pr), tstep); leave(pr); }
static double tankvolume_odin(Project *pr, int i, double h)
{
    double v = odin_tankvolume(enter(pr), i, h);
    leave(pr);
    return v;
}
static double tankgrade_odin(Project *pr, int i, double v)
{
    double h = odin_tankgrade(enter(pr), i, v);
    leave(pr);
    return h;
}
static void getenergy_odin(Project *pr, int k, double *kw, double *eff) { odin_getenergy(enter(pr), k, kw, eff); leave(pr); }
static void getallpumpsenergy_odin(Project *pr) { odin_getallpumpsenergy(enter(pr)); leave(pr); }
static void addenergy_odin(Project *pr, long hstep) { odin_addenergy(enter(pr), hstep); leave(pr); }

#ifndef SHADOW

int linsolve(Smatrix *sm, int n) { return linsolve_odin(sm, n); }
int createsparse(Project *pr) { return createsparse_odin(pr); }
void headlosscoeffs(Project *pr) { headlosscoeffs_odin(pr); }
void matrixcoeffs(Project *pr) { matrixcoeffs_odin(pr); }
int hydsolve(Project *pr, int *iter, double *relerr) { return hydsolve_odin(pr, iter, relerr); }
void resistcoeff(Project *pr, int k) { resistcoeff_odin(pr, k); }
double pcvlosscoeff(Project *pr, int k, double s) { return pcvlosscoeff_odin(pr, k, s); }
void initlinkflow(Project *pr, int i, char s, double k) { initlinkflow_odin(pr, i, s, k); }
void resetpumpflow(Project *pr, int i) { resetpumpflow_odin(pr, i); }
void setlinkstatus(Project *pr, int k, char v, StatusType *s, double *kk) { setlinkstatus_odin(pr, k, v, s, kk); }
void setlinksetting(Project *pr, int k, double v, StatusType *s, double *kk) { setlinksetting_odin(pr, k, v, s, kk); }
void demands(Project *pr) { demands_odin(pr); }
int controls(Project *pr) { return controls_odin(pr); }
long timestep(Project *pr) { return timestep_odin(pr); }
void tanklevels(Project *pr, long tstep) { tanklevels_odin(pr, tstep); }
double tankvolume(Project *pr, int i, double h) { return tankvolume_odin(pr, i, h); }
double tankgrade(Project *pr, int i, double v) { return tankgrade_odin(pr, i, v); }
void getenergy(Project *pr, int k, double *kw, double *eff) { getenergy_odin(pr, k, kw, eff); }
void getallpumpsenergy(Project *pr) { getallpumpsenergy_odin(pr); }
void addenergy(Project *pr, long hstep) { addenergy_odin(pr, hstep); }

#else /* SHADOW */

/* ── shadow bookkeeping ─────────────────────────────────────────────── */

typedef struct {
    const char *name;
    long calls, bad;
    double maxdiff;
} Shadow;

#define SHADOW(sym) static Shadow shadow_##sym = {#sym};
SHADOW(linsolve) SHADOW(createsparse) SHADOW(headlosscoeffs) SHADOW(matrixcoeffs)
SHADOW(hydsolve) SHADOW(resistcoeff) SHADOW(pcvlosscoeff) SHADOW(initlinkflow)
SHADOW(resetpumpflow) SHADOW(setlinkstatus) SHADOW(setlinksetting) SHADOW(demands)
SHADOW(controls) SHADOW(timestep) SHADOW(tanklevels) SHADOW(tankvolume) SHADOW(tankgrade)
SHADOW(getenergy) SHADOW(getallpumpsenergy) SHADOW(addenergy)
static Shadow *shadows[] = {
    &shadow_linsolve, &shadow_createsparse, &shadow_headlosscoeffs, &shadow_matrixcoeffs,
    &shadow_hydsolve, &shadow_resistcoeff, &shadow_pcvlosscoeff, &shadow_initlinkflow,
    &shadow_resetpumpflow, &shadow_setlinkstatus, &shadow_setlinksetting, &shadow_demands,
    &shadow_controls, &shadow_timestep, &shadow_tanklevels, &shadow_tankvolume, &shadow_tankgrade,
    &shadow_getenergy, &shadow_getallpumpsenergy, &shadow_addenergy};
static int shadow_registered;

static void shadow_report(void)
{
    size_t i;
    for (i = 0; i < sizeof shadows / sizeof *shadows; i++) {
        fprintf(stderr, "shadow %s: %ld calls, %ld mismatches, max rel diff %.3g\n",
                shadows[i]->name, shadows[i]->calls, shadows[i]->bad, shadows[i]->maxdiff);
    }
}

static void shadow_begin(Shadow *s)
{
    if (!shadow_registered) {
        shadow_registered = 1;
        atexit(shadow_report);
    }
    s->calls++;
}

/* reldiff — |a-b| relative to the larger magnitude; 0 when bit-equal. */
static double reldiff(double a, double b)
{
    double m;
    if (a == b) return 0.0;
    m = fabs(a) > fabs(b) ? fabs(a) : fabs(b);
    return fabs(a - b) / m;
}

/* compare — the one place a mismatch is counted and the first one printed. */
static void compare(Shadow *s, const char *what, int i, double c, double o)
{
    double d = reldiff(c, o);
    double tol = getenv("SHADOW_TOL") ? atof(getenv("SHADOW_TOL")) : 0.0;
    if (d > s->maxdiff) s->maxdiff = d;
    if (d > tol) {
        if (s->bad == 0) {
            fprintf(stderr, "shadow %s: call %ld %s[%d] c=%.17g odin=%.17g\n", s->name, s->calls,
                    what, i, c, o);
        }
        s->bad++;
    }
}

/* A snapshot of everything the engine writes, as a table of (name, live
 * array, copy, length): every double or int array of the hydraulic state,
 * the fields of the pump, tank and link structs it changes, and the
 * scalars. take fills the copies, put writes them back, check compares a
 * copy against the live project. */
typedef struct {
    const char *name;
    void *live;
    void *copy;
    int n, is_int;
} Arr;

typedef struct {
    Arr *a;
    int n, cap;
    double scalars[16];
} Snapshot;

static void snap_add(Snapshot *s, const char *name, void *live, int n, int is_int)
{
    Arr *a;
    if (!live) return;
    if (s->n == s->cap) {
        s->cap = s->cap ? 2 * s->cap : 64;
        s->a = realloc(s->a, s->cap * sizeof(Arr));
    }
    a = &s->a[s->n++];
    a->name = name; a->live = live; a->n = n; a->is_int = is_int;
    a->copy = malloc((n + 1) * (is_int ? sizeof(int) : sizeof(double)));
}

static void snap_setup(Snapshot *s, Project *pr)
{
    Network *net = &pr->network;
    Hydraul *hyd = &pr->hydraul;
    Smatrix *sm = &hyd->smatrix;
    int nn = net->Nnodes, nl = net->Nlinks, i;
    memset(s, 0, sizeof *s);
    snap_add(s, "NodeHead", hyd->NodeHead, nn, 0);
    snap_add(s, "NodeDemand", hyd->NodeDemand, nn, 0);
    snap_add(s, "FullDemand", hyd->FullDemand, nn, 0);
    snap_add(s, "DemandFlow", hyd->DemandFlow, nn, 0);
    snap_add(s, "EmitterFlow", hyd->EmitterFlow, nn, 0);
    snap_add(s, "LeakageFlow", hyd->LeakageFlow, nn, 0);
    snap_add(s, "Xflow", hyd->Xflow, nn, 0);
    snap_add(s, "LinkFlow", hyd->LinkFlow, nl, 0);
    snap_add(s, "LinkSetting", hyd->LinkSetting, nl, 0);
    snap_add(s, "P", hyd->P, nl, 0);
    snap_add(s, "Y", hyd->Y, nl, 0);
    snap_add(s, "Aii", sm->Aii, nn, 0);
    snap_add(s, "Aij", sm->Aij, sm->Ncoeffs, 0);
    snap_add(s, "F", sm->F, nn, 0);
    snap_add(s, "LinkStatus", hyd->LinkStatus, nl, 1);
    for (i = 1; i <= net->Npumps; i++) {
        snap_add(s, "Pump.H0", &net->Pump[i].H0, 0, 0);
        snap_add(s, "Pump.R", &net->Pump[i].R, 0, 0);
        snap_add(s, "Pump.N", &net->Pump[i].N, 0, 0);
        snap_add(s, "Pump.Energy", &net->Pump[i].Energy, sizeof(Senergy) / sizeof(double) - 1, 0);
    }
    for (i = 1; i <= net->Ntanks; i++) snap_add(s, "Tank.V", &net->Tank[i].V, 0, 0);
    for (i = 1; i <= nl; i++) snap_add(s, "Link.R", &net->Link[i].R, 0, 0);
    if (hyd->Leakage)
        snap_add(s, "Leakage", hyd->Leakage, (net->Njuncs + 1) * (int)(sizeof(Sleakage) / sizeof(double)) - 1, 0);
}

static void snap_take(Snapshot *s)
{
    int k;
    for (k = 0; k < s->n; k++) {
        Arr *a = &s->a[k];
        memcpy(a->copy, a->live, (a->n + 1) * (a->is_int ? sizeof(int) : sizeof(double)));
    }
}

static void snap_put(Snapshot *s)
{
    int k;
    for (k = 0; k < s->n; k++) {
        Arr *a = &s->a[k];
        memcpy(a->live, a->copy, (a->n + 1) * (a->is_int ? sizeof(int) : sizeof(double)));
    }
}

static void snap_scalars(Snapshot *s, Project *pr)
{
    Hydraul *hyd = &pr->hydraul;
    double *v = s->scalars;
    v[0] = hyd->RelaxFactor;
    v[1] = hyd->RelativeError;
    v[2] = hyd->MaxHeadError;
    v[3] = hyd->MaxFlowChange;
    v[4] = hyd->Iterations;
    v[5] = hyd->DeficientNodes;
    v[6] = hyd->DemandReduction;
    v[7] = hyd->Dsystem;
    v[8] = hyd->Emax;
    v[9] = (double)pr->times.Htime;
}

static const char *scalar_names[] = {"RelaxFactor", "RelativeError", "MaxHeadError", "MaxFlowChange",
    "Iterations", "DeficientNodes", "DemandReduction", "Dsystem", "Emax", "Htime"};

/* snap_check — compare a snapshot (the C result) with the live project
 * (the Odin result). */
static void snap_check(Shadow *sh, Snapshot *c, Project *pr)
{
    int k, i;
    double live[16];
    Snapshot now = *c;
    for (k = 0; k < c->n; k++) {
        Arr *a = &c->a[k];
        for (i = (a->n ? 1 : 0); i <= a->n; i++) {
            if (a->is_int) compare(sh, a->name, i, ((int *)a->copy)[i], ((int *)a->live)[i]);
            else compare(sh, a->name, i, ((double *)a->copy)[i], ((double *)a->live)[i]);
        }
    }
    now.scalars[0] = 0;
    snap_scalars(&now, pr);
    memcpy(live, now.scalars, sizeof live);
    for (k = 0; k < 10; k++) compare(sh, scalar_names[k], 0, c->scalars[k], live[k]);
}

static void snap_free(Snapshot *s)
{
    int k;
    for (k = 0; k < s->n; k++) free(s->a[k].copy);
    free(s->a);
}

/* The shape of every shadowed call:
 *   SHADOW_BEGIN(sym)      remember the state
 *   … the C original …
 *   SHADOW_MID()           keep its result, put the state back
 *   … the Odin port …
 *   SHADOW_END()           compare, free
 * Return values and output arguments are compared by the caller. */
#define SHADOW_BEGIN(sym) \
    Shadow *sh_ = &shadow_##sym; Snapshot before_, after_; \
    shadow_begin(sh_); snap_setup(&before_, pr); snap_setup(&after_, pr); snap_take(&before_)
#define SHADOW_MID() snap_take(&after_); snap_scalars(&after_, pr); snap_put(&before_)
#define SHADOW_END() snap_check(sh_, &after_, pr); snap_free(&before_); snap_free(&after_)

int linsolve(Smatrix *sm, int n)
{
    Shadow *s = &shadow_linsolve;
    int nc = sm->Ncoeffs;
    int rc_c, rc_o;
    Smatrix copy = *sm;

    shadow_begin(s);
    copy.Aii = malloc((n + 1) * sizeof(double));
    copy.Aij = malloc((nc + 1) * sizeof(double));
    copy.F = malloc((n + 1) * sizeof(double));
    copy.temp = malloc((n + 1) * sizeof(double));
    copy.link = malloc((n + 1) * sizeof(int));
    copy.first = malloc((n + 1) * sizeof(int));
    memcpy(copy.Aii, sm->Aii, (n + 1) * sizeof(double));
    memcpy(copy.Aij, sm->Aij, (nc + 1) * sizeof(double));
    memcpy(copy.F, sm->F, (n + 1) * sizeof(double));

    rc_c = linsolve_c(&copy, n);
    rc_o = linsolve_odin(sm, n);

    if (rc_c != rc_o) {
        compare(s, "return", 0, rc_c, rc_o);
    } else {
        int i;
        for (i = 1; i <= n; i++) compare(s, "F", i, copy.F[i], sm->F[i]);
        for (i = 1; i <= n; i++) compare(s, "Aii", i, copy.Aii[i], sm->Aii[i]);
        for (i = 1; i <= nc; i++) compare(s, "Aij", i, copy.Aij[i], sm->Aij[i]);
    }
    free(copy.Aii); free(copy.Aij); free(copy.F);
    free(copy.temp); free(copy.link); free(copy.first);
    return rc_o;
}

static void compare_ints(Shadow *s, const char *what, int *c, int *o, int from, int to)
{
    int i;
    for (i = from; i <= to; i++) compare(s, what, i, c[i], o[i]);
}

int createsparse(Project *pr)
{
    Shadow *s = &shadow_createsparse;
    Network *net = &pr->network;
    Smatrix *sm = &pr->hydraul.smatrix;
    Smatrix c;
    int rc_c, rc_o;

    shadow_begin(s);
    rc_c = createsparse_c(pr);
    c = *sm;
    memset(sm, 0, sizeof *sm);
    rc_o = createsparse_odin(pr);

    if (rc_c != rc_o || c.Ncoeffs != sm->Ncoeffs) {
        compare(s, "return", 0, rc_c, rc_o);
        compare(s, "Ncoeffs", 0, c.Ncoeffs, sm->Ncoeffs);
    } else {
        compare_ints(s, "Order", c.Order, sm->Order, 1, net->Nnodes);
        compare_ints(s, "Row", c.Row, sm->Row, 1, net->Nnodes);
        compare_ints(s, "Ndx", c.Ndx, sm->Ndx, 1, net->Nlinks);
        compare_ints(s, "XLNZ", c.XLNZ, sm->XLNZ, 1, net->Njuncs + 1);
        compare_ints(s, "NZSUB", c.NZSUB, sm->NZSUB, 1, sm->Ncoeffs);
        compare_ints(s, "LNZ", c.LNZ, sm->LNZ, 1, sm->Ncoeffs);
    }
    free(c.Order); free(c.Row); free(c.Ndx);
    free(c.XLNZ); free(c.NZSUB); free(c.LNZ);
    free(c.Aij); free(c.Aii); free(c.F);
    free(c.temp); free(c.link); free(c.first);
    return rc_o;
}

void headlosscoeffs(Project *pr)
{
    SHADOW_BEGIN(headlosscoeffs);
    headlosscoeffs_c(pr);
    SHADOW_MID();
    headlosscoeffs_odin(pr);
    SHADOW_END();
}

void matrixcoeffs(Project *pr)
{
    SHADOW_BEGIN(matrixcoeffs);
    matrixcoeffs_c(pr);
    SHADOW_MID();
    matrixcoeffs_odin(pr);
    SHADOW_END();
}

int hydsolve(Project *pr, int *iter, double *relerr)
{
    int rc_c, rc_o, iter_c;
    double relerr_c;
    SHADOW_BEGIN(hydsolve);
    rc_c = hydsolve_c(pr, &iter_c, &relerr_c);
    SHADOW_MID();
    rc_o = hydsolve_odin(pr, iter, relerr);
    SHADOW_END();
    compare(sh_, "return", 0, rc_c, rc_o);
    compare(sh_, "iter", 0, iter_c, *iter);
    compare(sh_, "relerr", 0, relerr_c, *relerr);
    return rc_o;
}

void resistcoeff(Project *pr, int k)
{
    SHADOW_BEGIN(resistcoeff);
    resistcoeff_c(pr, k);
    SHADOW_MID();
    resistcoeff_odin(pr, k);
    SHADOW_END();
}

double pcvlosscoeff(Project *pr, int k, double s)
{
    double c, o;
    SHADOW_BEGIN(pcvlosscoeff);
    c = pcvlosscoeff_c(pr, k, s);
    SHADOW_MID();
    o = pcvlosscoeff_odin(pr, k, s);
    SHADOW_END();
    compare(sh_, "return", k, c, o);
    return o;
}

void initlinkflow(Project *pr, int i, char s, double k)
{
    SHADOW_BEGIN(initlinkflow);
    initlinkflow_c(pr, i, s, k);
    SHADOW_MID();
    initlinkflow_odin(pr, i, s, k);
    SHADOW_END();
}

void resetpumpflow(Project *pr, int i)
{
    SHADOW_BEGIN(resetpumpflow);
    resetpumpflow_c(pr, i);
    SHADOW_MID();
    resetpumpflow_odin(pr, i);
    SHADOW_END();
}

void setlinkstatus(Project *pr, int k, char v, StatusType *s, double *kk)
{
    SHADOW_BEGIN(setlinkstatus);
    setlinkstatus_c(pr, k, v, s, kk);
    SHADOW_MID();
    setlinkstatus_odin(pr, k, v, s, kk);
    SHADOW_END();
}

void setlinksetting(Project *pr, int k, double v, StatusType *s, double *kk)
{
    SHADOW_BEGIN(setlinksetting);
    setlinksetting_c(pr, k, v, s, kk);
    SHADOW_MID();
    setlinksetting_odin(pr, k, v, s, kk);
    SHADOW_END();
}

void demands(Project *pr)
{
    SHADOW_BEGIN(demands);
    demands_c(pr);
    SHADOW_MID();
    demands_odin(pr);
    SHADOW_END();
}

int controls(Project *pr)
{
    int c, o;
    SHADOW_BEGIN(controls);
    c = controls_c(pr);
    SHADOW_MID();
    o = controls_odin(pr);
    SHADOW_END();
    compare(sh_, "return", 0, c, o);
    return o;
}

/* Rules keep state of their own (which premises held, when), so a step that
 * evaluates them cannot be run twice: with rules in the network the Odin
 * version runs alone and the call is counted but not compared. */
long timestep(Project *pr)
{
    long c, o;
    if (pr->network.Nrules > 0) {
        shadow_begin(&shadow_timestep);
        return timestep_odin(pr);
    }
    {
        SHADOW_BEGIN(timestep);
        c = timestep_c(pr);
        SHADOW_MID();
        o = timestep_odin(pr);
        SHADOW_END();
        compare(sh_, "return", 0, (double)c, (double)o);
    }
    return o;
}

void tanklevels(Project *pr, long tstep)
{
    SHADOW_BEGIN(tanklevels);
    tanklevels_c(pr, tstep);
    SHADOW_MID();
    tanklevels_odin(pr, tstep);
    SHADOW_END();
}

double tankvolume(Project *pr, int i, double h)
{
    double c, o;
    SHADOW_BEGIN(tankvolume);
    c = tankvolume_c(pr, i, h);
    SHADOW_MID();
    o = tankvolume_odin(pr, i, h);
    SHADOW_END();
    compare(sh_, "return", i, c, o);
    return o;
}

double tankgrade(Project *pr, int i, double v)
{
    double c, o;
    SHADOW_BEGIN(tankgrade);
    c = tankgrade_c(pr, i, v);
    SHADOW_MID();
    o = tankgrade_odin(pr, i, v);
    SHADOW_END();
    compare(sh_, "return", i, c, o);
    return o;
}

void getenergy(Project *pr, int k, double *kw, double *eff)
{
    double kw_c, eff_c;
    SHADOW_BEGIN(getenergy);
    getenergy_c(pr, k, &kw_c, &eff_c);
    SHADOW_MID();
    getenergy_odin(pr, k, kw, eff);
    SHADOW_END();
    compare(sh_, "kw", k, kw_c, *kw);
    compare(sh_, "eff", k, eff_c, *eff);
}

void getallpumpsenergy(Project *pr)
{
    SHADOW_BEGIN(getallpumpsenergy);
    getallpumpsenergy_c(pr);
    SHADOW_MID();
    getallpumpsenergy_odin(pr);
    SHADOW_END();
}

void addenergy(Project *pr, long hstep)
{
    SHADOW_BEGIN(addenergy);
    addenergy_c(pr, hstep);
    SHADOW_MID();
    addenergy_odin(pr, hstep);
    SHADOW_END();
}

#endif /* SHADOW */
