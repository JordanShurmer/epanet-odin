/*
 * bridge.c — the EPANET symbols that the Odin rewrite replaces.
 *
 * test.sh compiles EPANET's own sources, then renames each swapped symbol in
 * the object that defines it (linsolve -> linsolve_c, with objcopy), and links
 * this file in. EPANET's callers still call `linsolve`; they get the version
 * below, which hands the arrays straight to the Odin package. EPANET's source
 * is not edited.
 *
 * Built with -DSHADOW, every call runs both: the C original on a copy of the
 * inputs, the Odin port on the live ones, and compares what came back. The
 * first difference is printed with the call number and the index, and an
 * exit handler prints one tally line per symbol. That is how a port is proved:
 * not on one network's final answer but on every call the whole suite makes.
 *
 * One section per symbol: the Odin-backed version as a static `*_odin`, then
 * the exported name, which is either that or the shadow of both.
 */
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "types.h"
#include "funcs.h"
#include "text.h"

/* The originals, renamed at link time. */
int linsolve_c(Smatrix *sm, int n);
int createsparse_c(Project *pr);

/* The ports, from the Odin package (src/export.odin). */
int odin_linsolve(int n, int ncoeffs, double *aii, double *aij, double *f,
                  double *temp, int *xlnz, int *nzsub, int *lnz, int *link,
                  int *first);
void odin_createsparse(int nnodes, int njuncs, int nlinks, int *n1, int *n2,
                       int *order, int *row, int *ndx, int *ncoeffs,
                       int **xlnz, int **nzsub, int **lnz);

/* ── shadow bookkeeping ─────────────────────────────────────────────── */

typedef struct {
    const char *name;
    long calls, bad;
    double maxdiff;
} Shadow;

static Shadow shadow_linsolve = {"linsolve"};
static Shadow shadow_createsparse = {"createsparse"};
static Shadow shadow_headlosscoeffs = {"headlosscoeffs"};
static Shadow shadow_matrixcoeffs = {"matrixcoeffs"};
static Shadow shadow_hydsolve = {"hydsolve"};
static Shadow *shadows[] = {&shadow_linsolve, &shadow_createsparse,
                            &shadow_headlosscoeffs, &shadow_matrixcoeffs,
                            &shadow_hydsolve};
static int shadow_registered;

static void shadow_report(void)
{
    size_t i;
    for (i = 0; i < sizeof shadows / sizeof *shadows; i++) {
        fprintf(stderr, "shadow %s: %ld calls, %ld mismatches, max rel diff %.3g\n",
                shadows[i]->name, shadows[i]->calls, shadows[i]->bad,
                shadows[i]->maxdiff);
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
            fprintf(stderr, "shadow %s: call %ld %s[%d] c=%.17g odin=%.17g\n",
                    s->name, s->calls, what, i, c, o);
        }
        s->bad++;
    }
}

static void compare_ints(Shadow *s, const char *what, int *c, int *o, int from, int to)
{
    int i;
    for (i = from; i <= to; i++) compare(s, what, i, c[i], o[i]);
}

/* ── linsolve ───────────────────────────────────────────────────────── */

static int linsolve_odin(Smatrix *sm, int n)
{
    return odin_linsolve(n, sm->Ncoeffs, sm->Aii, sm->Aij, sm->F, sm->temp,
                         sm->XLNZ, sm->NZSUB, sm->LNZ, sm->link, sm->first);
}

#ifdef SHADOW
int linsolve(Smatrix *sm, int n)
{
    Shadow *s = &shadow_linsolve;
    int nc = sm->Ncoeffs;
    int rc_c, rc_o;
    Smatrix copy = *sm;

    shadow_begin(s);

    /* The C original works on a copy of what linsolve writes. */
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

    free(copy.Aii);
    free(copy.Aij);
    free(copy.F);
    free(copy.temp);
    free(copy.link);
    free(copy.first);
    return rc_o;
}
#else
int linsolve(Smatrix *sm, int n) { return linsolve_odin(sm, n); }
#endif

/* ── createsparse ───────────────────────────────────────────────────── */

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
    odin_createsparse(nn, net->Njuncs, nl, n1, n2, sm->Order, sm->Row, sm->Ndx,
                      &sm->Ncoeffs, &sm->XLNZ, &sm->NZSUB, &sm->LNZ);
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

#ifdef SHADOW
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
#else
int createsparse(Project *pr) { return createsparse_odin(pr); }
#endif

/* ── headlosscoeffs / matrixcoeffs ──────────────────────────────────── */

/* The Odin package's view of the model: one array per field (the layout
 * of Network_C, Hydraulics_C and Matrix_C in src/export.odin). The
 * hydraulic state arrays are EPANET's own, used in place; the per-struct
 * fields of Slink, Spump, Svalve and Scurve are copied into a mirror on
 * every call, which is what a harness that must never go stale has to do. */
typedef struct {
    int nnodes, njuncs, nlinks;
    int ntanks, npumps, nvalves, ncontrols, ncurves;
    double *el, *ke, *leak_cfa, *leak_cva;
    int *link_type, *n1, *n2;
    double *diam, *km, *kc, *r;
    int *link_pump, *link_valve;
    double *tank_area, *tank_hmin, *tank_hmax;
    int *tank_overflow;
    int *pump_type, *pump_hcurve;
    double *pump_h0, *pump_r, *pump_n, *pump_hmax;
    int *valve_link, *valve_curve;
    int *curve_npts;
    double **curve_x, **curve_y;
    int *control_link, *control_node, *control_type;
    double *control_grade, *control_setting;
    int *control_status;
    double ucf_flow, ucf_head;
} OdinNetwork;

typedef struct {
    int formflag, demand_model, emit_backflow, has_leakage;
    int max_iter, extra_iter, check_freq, max_check, status_report;
    double hexp, qexp, pexp, pmin, preq, rqtol, viscos;
    double htol, qtol, hacc, head_error_limit, flow_change_limit;
    double damp_limit;
    double *head, *node_demand, *demand_flow, *full_demand;
    double *emitter_flow, *leak_flow, *leak_qfa, *leak_qva, *xflow;
    double *flow, *setting;
    int *status;
    double *p, *y;
} OdinHydraulics;

/* What the solver still leaves to C: the status report's lines. */
typedef struct {
    void *ctx;
    void (*write_relerr)(void *, int, double);
    void (*write_statchange)(void *, int, int, int);
    void (*write_hyderr)(void *, int);
    void (*write_hydbal)(void *, double, double, int, int, int);
    void (*write_badvalve)(void *, int);
} OdinHooks;

typedef struct {
    int errcode, iterations, deficient_nodes;
    double relative_error, max_head_error, max_flow_change;
    double demand_reduction, relax;
} OdinSolution;

typedef struct {
    int ncoeffs;
    double *aii, *aij, *f, *temp;
    int *xlnz, *nzsub, *lnz, *link, *first;
    int *order, *row, *ndx;
} OdinMatrix;

void odin_headlosscoeffs(OdinNetwork *n, OdinHydraulics *h);
void odin_matrixcoeffs(OdinNetwork *n, OdinHydraulics *h, OdinMatrix *m);
void odin_hydsolve(OdinNetwork *n, OdinHydraulics *h, OdinMatrix *m, OdinHooks *hooks,
                   OdinSolution *out);

void headlosscoeffs_c(Project *pr);
void matrixcoeffs_c(Project *pr);
int hydsolve_c(Project *pr, int *iter, double *relerr);

static OdinNetwork mirror;
static int mirror_nodes, mirror_links, mirror_tanks, mirror_pumps, mirror_valves,
           mirror_controls, mirror_curves;
/* hyd->Leakage is a struct per junction; the Odin side wants its four
 * fields as four arrays. qfa and qva are state, copied back after a solve. */
static double *leak_cfa, *leak_cva, *leak_qfa, *leak_qva;

/* grow — (re)allocate a mirror array when the network got bigger. */
static void *grow(void *p, int n, size_t size)
{
    return realloc(p, (size_t)(n + 1) * size);
}

static void fill_mirror(Project *pr)
{
    Network *net = &pr->network;
    OdinNetwork *m = &mirror;
    int i, k;

    if (net->Nnodes > mirror_nodes) {
        mirror_nodes = net->Nnodes;
        m->el = grow(m->el, mirror_nodes, sizeof(double));
        m->ke = grow(m->ke, mirror_nodes, sizeof(double));
        leak_cfa = grow(leak_cfa, mirror_nodes, sizeof(double));
        leak_cva = grow(leak_cva, mirror_nodes, sizeof(double));
        leak_qfa = grow(leak_qfa, mirror_nodes, sizeof(double));
        leak_qva = grow(leak_qva, mirror_nodes, sizeof(double));
    }
    if (net->Nlinks > mirror_links) {
        mirror_links = net->Nlinks;
        m->link_type = grow(m->link_type, mirror_links, sizeof(int));
        m->n1 = grow(m->n1, mirror_links, sizeof(int));
        m->n2 = grow(m->n2, mirror_links, sizeof(int));
        m->diam = grow(m->diam, mirror_links, sizeof(double));
        m->km = grow(m->km, mirror_links, sizeof(double));
        m->kc = grow(m->kc, mirror_links, sizeof(double));
        m->r = grow(m->r, mirror_links, sizeof(double));
        m->link_pump = grow(m->link_pump, mirror_links, sizeof(int));
        m->link_valve = grow(m->link_valve, mirror_links, sizeof(int));
    }
    if (net->Ntanks > mirror_tanks) {
        mirror_tanks = net->Ntanks;
        m->tank_area = grow(m->tank_area, mirror_tanks, sizeof(double));
        m->tank_hmin = grow(m->tank_hmin, mirror_tanks, sizeof(double));
        m->tank_hmax = grow(m->tank_hmax, mirror_tanks, sizeof(double));
        m->tank_overflow = grow(m->tank_overflow, mirror_tanks, sizeof(int));
    }
    if (net->Npumps > mirror_pumps) {
        mirror_pumps = net->Npumps;
        m->pump_type = grow(m->pump_type, mirror_pumps, sizeof(int));
        m->pump_hcurve = grow(m->pump_hcurve, mirror_pumps, sizeof(int));
        m->pump_h0 = grow(m->pump_h0, mirror_pumps, sizeof(double));
        m->pump_r = grow(m->pump_r, mirror_pumps, sizeof(double));
        m->pump_n = grow(m->pump_n, mirror_pumps, sizeof(double));
        m->pump_hmax = grow(m->pump_hmax, mirror_pumps, sizeof(double));
    }
    if (net->Ncontrols > mirror_controls) {
        mirror_controls = net->Ncontrols;
        m->control_link = grow(m->control_link, mirror_controls, sizeof(int));
        m->control_node = grow(m->control_node, mirror_controls, sizeof(int));
        m->control_type = grow(m->control_type, mirror_controls, sizeof(int));
        m->control_grade = grow(m->control_grade, mirror_controls, sizeof(double));
        m->control_setting = grow(m->control_setting, mirror_controls, sizeof(double));
        m->control_status = grow(m->control_status, mirror_controls, sizeof(int));
    }
    if (net->Nvalves > mirror_valves) {
        mirror_valves = net->Nvalves;
        m->valve_link = grow(m->valve_link, mirror_valves, sizeof(int));
        m->valve_curve = grow(m->valve_curve, mirror_valves, sizeof(int));
    }
    if (net->Ncurves > mirror_curves) {
        mirror_curves = net->Ncurves;
        m->curve_npts = grow(m->curve_npts, mirror_curves, sizeof(int));
        m->curve_x = grow(m->curve_x, mirror_curves, sizeof(double *));
        m->curve_y = grow(m->curve_y, mirror_curves, sizeof(double *));
    }

    m->nnodes = net->Nnodes;
    m->njuncs = net->Njuncs;
    m->nlinks = net->Nlinks;
    m->ntanks = net->Ntanks;
    m->npumps = net->Npumps;
    m->nvalves = net->Nvalves;
    m->ncontrols = net->Ncontrols;
    m->ncurves = net->Ncurves;
    for (i = 1; i <= net->Nnodes; i++) {
        m->el[i] = net->Node[i].El;
        m->ke[i] = net->Node[i].Ke;
        leak_cfa[i] = leak_cva[i] = leak_qfa[i] = leak_qva[i] = 0.0;
    }
    if (pr->hydraul.Leakage) for (i = 1; i <= net->Njuncs; i++) {
        leak_cfa[i] = pr->hydraul.Leakage[i].cfa;
        leak_cva[i] = pr->hydraul.Leakage[i].cva;
        leak_qfa[i] = pr->hydraul.Leakage[i].qfa;
        leak_qva[i] = pr->hydraul.Leakage[i].qva;
    }
    m->leak_cfa = leak_cfa;
    m->leak_cva = leak_cva;
    for (k = 1; k <= net->Nlinks; k++) {
        Slink *l = &net->Link[k];
        m->link_type[k] = l->Type;
        m->n1[k] = l->N1;
        m->n2[k] = l->N2;
        m->diam[k] = l->Diam;
        m->km[k] = l->Km;
        m->kc[k] = l->Kc;
        m->r[k] = l->R;
        m->link_pump[k] = 0;
        m->link_valve[k] = 0;
    }
    for (i = 1; i <= net->Ntanks; i++) {
        m->tank_area[i] = net->Tank[i].A;
        m->tank_hmin[i] = net->Tank[i].Hmin;
        m->tank_hmax[i] = net->Tank[i].Hmax;
        m->tank_overflow[i] = net->Tank[i].CanOverflow;
    }
    for (i = 1; i <= net->Npumps; i++) {
        Spump *p = &net->Pump[i];
        m->link_pump[p->Link] = i;
        m->pump_type[i] = p->Ptype;
        m->pump_hcurve[i] = p->Hcurve;
        m->pump_h0[i] = p->H0;
        m->pump_r[i] = p->R;
        m->pump_n[i] = p->N;
        m->pump_hmax[i] = p->Hmax;
    }
    for (i = 1; i <= net->Ncontrols; i++) {
        Scontrol *c = &net->Control[i];
        m->control_link[i] = c->Link;
        m->control_node[i] = c->Node;
        m->control_type[i] = c->Type;
        m->control_grade[i] = c->Grade;
        m->control_setting[i] = c->Setting;
        m->control_status[i] = c->Status;
    }
    for (i = 1; i <= net->Nvalves; i++) {
        m->link_valve[net->Valve[i].Link] = i;
        m->valve_link[i] = net->Valve[i].Link;
        m->valve_curve[i] = net->Valve[i].Curve;
    }
    for (i = 1; i <= net->Ncurves; i++) {
        m->curve_npts[i] = net->Curve[i].Npts;
        m->curve_x[i] = net->Curve[i].X;
        m->curve_y[i] = net->Curve[i].Y;
    }
    m->ucf_flow = pr->Ucf[FLOW];
    m->ucf_head = pr->Ucf[HEAD];
}

/* pumpcoeff rewrites a custom-curve pump's H0, R and N: carry them back. */
static void pumps_from_mirror(Project *pr)
{
    Network *net = &pr->network;
    int i;
    for (i = 1; i <= net->Npumps; i++) {
        net->Pump[i].H0 = mirror.pump_h0[i];
        net->Pump[i].R = mirror.pump_r[i];
        net->Pump[i].N = mirror.pump_n[i];
    }
}

static void leaks_from_mirror(Project *pr)
{
    int i;
    if (!pr->hydraul.Leakage) return;
    for (i = 1; i <= pr->network.Njuncs; i++) {
        pr->hydraul.Leakage[i].qfa = leak_qfa[i];
        pr->hydraul.Leakage[i].qva = leak_qva[i];
    }
}

static OdinHydraulics hydraulics_view(Project *pr)
{
    Hydraul *hyd = &pr->hydraul;
    OdinHydraulics h;
    h.formflag = hyd->Formflag;
    h.demand_model = hyd->DemandModel;
    h.emit_backflow = hyd->EmitBackFlag;
    h.has_leakage = hyd->HasLeakage;
    h.max_iter = hyd->MaxIter;
    h.extra_iter = hyd->ExtraIter;
    h.check_freq = hyd->CheckFreq;
    h.max_check = hyd->MaxCheck;
    h.status_report = pr->report.Statflag == FULL;
    h.htol = hyd->Htol;
    h.qtol = hyd->Qtol;
    h.hacc = hyd->Hacc;
    h.head_error_limit = hyd->HeadErrorLimit;
    h.flow_change_limit = hyd->FlowChangeLimit;
    h.damp_limit = hyd->DampLimit;
    h.hexp = hyd->Hexp;
    h.qexp = hyd->Qexp;
    h.pexp = hyd->Pexp;
    h.pmin = hyd->Pmin;
    h.preq = hyd->Preq;
    h.rqtol = hyd->RQtol;
    h.viscos = hyd->Viscos;
    h.head = hyd->NodeHead;
    h.node_demand = hyd->NodeDemand;
    h.demand_flow = hyd->DemandFlow;
    h.full_demand = hyd->FullDemand;
    h.emitter_flow = hyd->EmitterFlow;
    h.leak_flow = hyd->LeakageFlow;
    h.leak_qfa = leak_qfa;
    h.leak_qva = leak_qva;
    h.xflow = hyd->Xflow;
    h.flow = hyd->LinkFlow;
    h.setting = hyd->LinkSetting;
    h.status = (int *)hyd->LinkStatus;
    h.p = hyd->P;
    h.y = hyd->Y;
    return h;
}

static OdinMatrix matrix_view(Project *pr)
{
    Smatrix *sm = &pr->hydraul.smatrix;
    OdinMatrix m;
    m.ncoeffs = sm->Ncoeffs;
    m.aii = sm->Aii;
    m.aij = sm->Aij;
    m.f = sm->F;
    m.temp = sm->temp;
    m.xlnz = sm->XLNZ;
    m.nzsub = sm->NZSUB;
    m.lnz = sm->LNZ;
    m.link = sm->link;
    m.first = sm->first;
    m.order = sm->Order;
    m.row = sm->Row;
    m.ndx = sm->Ndx;
    return m;
}

/* The hooks: each one is the EPANET function of the same purpose. */
static void hook_relerr(void *ctx, int iter, double relerr) { writerelerr(ctx, iter, relerr); }
static void hook_statchange(void *ctx, int k, int s0, int s1) { writestatchange(ctx, k, s0, s1); }
static void hook_hyderr(void *ctx, int n) { writehyderr(ctx, n); }
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

static OdinHooks hooks_for(Project *pr)
{
    OdinHooks h;
    h.ctx = pr;
    h.write_relerr = hook_relerr;
    h.write_statchange = hook_statchange;
    h.write_hyderr = hook_hyderr;
    h.write_hydbal = hook_hydbal;
    h.write_badvalve = hook_badvalve;
    return h;
}

static void headlosscoeffs_odin(Project *pr)
{
    OdinHydraulics h;
    fill_mirror(pr);
    h = hydraulics_view(pr);
    odin_headlosscoeffs(&mirror, &h);
    pumps_from_mirror(pr);
}

static void matrixcoeffs_odin(Project *pr)
{
    OdinMatrix m = matrix_view(pr);
    OdinHydraulics h;
    fill_mirror(pr);
    h = hydraulics_view(pr);
    odin_matrixcoeffs(&mirror, &h, &m);
}

static int hydsolve_odin(Project *pr, int *iter, double *relerr)
{
    Hydraul *hyd = &pr->hydraul;
    OdinMatrix m = matrix_view(pr);
    OdinHooks hooks = hooks_for(pr);
    OdinHydraulics h;
    OdinSolution sol;
    fill_mirror(pr);
    h = hydraulics_view(pr);
    odin_hydsolve(&mirror, &h, &m, &hooks, &sol);
    pumps_from_mirror(pr);
    leaks_from_mirror(pr);
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

#ifdef SHADOW

static double *dup_doubles(double *a, int n)
{
    double *d = malloc((n + 1) * sizeof(double));
    memcpy(d, a, (n + 1) * sizeof(double));
    return d;
}

static void compare_doubles(Shadow *s, const char *what, double *c, double *o, int from, int to)
{
    int i;
    for (i = from; i <= to; i++) compare(s, what, i, c[i], o[i]);
}

void headlosscoeffs(Project *pr)
{
    Shadow *s = &shadow_headlosscoeffs;
    Network *net = &pr->network;
    Hydraul *hyd = &pr->hydraul;
    int nl = net->Nlinks, np = net->Npumps, i;
    double *p0 = dup_doubles(hyd->P, nl), *y0 = dup_doubles(hyd->Y, nl);
    double *pc, *yc, *h0c, *rc, *nc;

    shadow_begin(s);
    h0c = malloc((np + 1) * sizeof(double));
    rc = malloc((np + 1) * sizeof(double));
    nc = malloc((np + 1) * sizeof(double));
    for (i = 1; i <= np; i++) {
        h0c[i] = net->Pump[i].H0; rc[i] = net->Pump[i].R; nc[i] = net->Pump[i].N;
    }

    /* C on the live project, remembered; then the state put back and Odin. */
    headlosscoeffs_c(pr);
    pc = dup_doubles(hyd->P, nl);
    yc = dup_doubles(hyd->Y, nl);
    memcpy(hyd->P, p0, (nl + 1) * sizeof(double));
    memcpy(hyd->Y, y0, (nl + 1) * sizeof(double));
    for (i = 1; i <= np; i++) {
        double t;
        t = net->Pump[i].H0; net->Pump[i].H0 = h0c[i]; h0c[i] = t;
        t = net->Pump[i].R; net->Pump[i].R = rc[i]; rc[i] = t;
        t = net->Pump[i].N; net->Pump[i].N = nc[i]; nc[i] = t;
    }
    headlosscoeffs_odin(pr);

    compare_doubles(s, "P", pc, hyd->P, 1, nl);
    compare_doubles(s, "Y", yc, hyd->Y, 1, nl);
    for (i = 1; i <= np; i++) {
        compare(s, "Pump.H0", i, h0c[i], net->Pump[i].H0);
        compare(s, "Pump.R", i, rc[i], net->Pump[i].R);
        compare(s, "Pump.N", i, nc[i], net->Pump[i].N);
    }
    free(p0); free(y0); free(pc); free(yc); free(h0c); free(rc); free(nc);
}

void matrixcoeffs(Project *pr)
{
    Shadow *s = &shadow_matrixcoeffs;
    Network *net = &pr->network;
    Hydraul *hyd = &pr->hydraul;
    Smatrix *sm = &hyd->smatrix;
    int nn = net->Nnodes, nl = net->Nlinks, nc = sm->Ncoeffs;
    double *p0 = dup_doubles(hyd->P, nl), *y0 = dup_doubles(hyd->Y, nl);
    double *x0 = dup_doubles(hyd->Xflow, nn);
    double *aii, *aij, *f, *xf, *pc, *yc;

    shadow_begin(s);
    matrixcoeffs_c(pr);
    aii = dup_doubles(sm->Aii, nn);
    aij = dup_doubles(sm->Aij, nc);
    f = dup_doubles(sm->F, nn);
    xf = dup_doubles(hyd->Xflow, nn);
    pc = dup_doubles(hyd->P, nl);
    yc = dup_doubles(hyd->Y, nl);
    memcpy(hyd->P, p0, (nl + 1) * sizeof(double));
    memcpy(hyd->Y, y0, (nl + 1) * sizeof(double));
    memcpy(hyd->Xflow, x0, (nn + 1) * sizeof(double));
    matrixcoeffs_odin(pr);

    compare_doubles(s, "Aii", aii, sm->Aii, 1, nn);
    compare_doubles(s, "Aij", aij, sm->Aij, 1, nc);
    compare_doubles(s, "F", f, sm->F, 1, nn);
    compare_doubles(s, "Xflow", xf, hyd->Xflow, 1, nn);
    compare_doubles(s, "P", pc, hyd->P, 1, nl);
    compare_doubles(s, "Y", yc, hyd->Y, 1, nl);
    free(p0); free(y0); free(x0);
    free(aii); free(aij); free(f); free(xf); free(pc); free(yc);
}
/* Everything hydsolve writes, as one snapshot: a table of arrays and a
 * few scalars. take fills it from the project, put writes it back,
 * compare_snap checks one against the live project. */
typedef struct {
    const char *name;
    double *live, *copy;
    int n;
} DArr;
typedef struct {
    const char *name;
    int *live, *copy;
    int n;
} IArr;

typedef struct {
    DArr d[32];
    IArr i[4];
    int nd, ni;
    double *leak; /* hyd->Leakage[i].{qfa,qva} interleaved, i over the junctions */
    double scalars[8];
} Snapshot;

static void snap_d(Snapshot *s, const char *name, double *live, int n)
{
    DArr *a = &s->d[s->nd++];
    a->name = name; a->live = live; a->n = n;
    a->copy = malloc((n + 1) * sizeof(double));
}
static void snap_i(Snapshot *s, const char *name, int *live, int n)
{
    IArr *a = &s->i[s->ni++];
    a->name = name; a->live = live; a->n = n;
    a->copy = malloc((n + 1) * sizeof(int));
}

static void snap_setup(Snapshot *s, Project *pr)
{
    Network *net = &pr->network;
    Hydraul *hyd = &pr->hydraul;
    Smatrix *sm = &hyd->smatrix;
    int nn = net->Nnodes, nl = net->Nlinks, i;
    memset(s, 0, sizeof *s);
    snap_d(s, "NodeHead", hyd->NodeHead, nn);
    snap_d(s, "NodeDemand", hyd->NodeDemand, nn);
    snap_d(s, "DemandFlow", hyd->DemandFlow, nn);
    snap_d(s, "EmitterFlow", hyd->EmitterFlow, nn);
    snap_d(s, "LeakageFlow", hyd->LeakageFlow, nn);
    snap_d(s, "Xflow", hyd->Xflow, nn);
    snap_d(s, "LinkFlow", hyd->LinkFlow, nl);
    snap_d(s, "LinkSetting", hyd->LinkSetting, nl);
    snap_d(s, "P", hyd->P, nl);
    snap_d(s, "Y", hyd->Y, nl);
    snap_d(s, "Aii", sm->Aii, nn);
    snap_d(s, "Aij", sm->Aij, sm->Ncoeffs);
    snap_d(s, "F", sm->F, nn);
    snap_i(s, "LinkStatus", (int *)hyd->LinkStatus, nl);
    for (i = 1; i <= net->Npumps; i++) {
        snap_d(s, "Pump.H0", &net->Pump[i].H0, 0);
        snap_d(s, "Pump.R", &net->Pump[i].R, 0);
        snap_d(s, "Pump.N", &net->Pump[i].N, 0);
        if (s->nd > 28) break; /* enough pumps for the fixtures */
    }
    if (hyd->Leakage) s->leak = malloc(2 * (net->Njuncs + 1) * sizeof(double));
}

static void snap_scalars(Snapshot *s, Project *pr, int iter, double relerr, int rc)
{
    Hydraul *hyd = &pr->hydraul;
    s->scalars[0] = hyd->RelaxFactor;
    s->scalars[1] = hyd->RelativeError;
    s->scalars[2] = hyd->MaxHeadError;
    s->scalars[3] = hyd->MaxFlowChange;
    s->scalars[4] = hyd->Iterations;
    s->scalars[5] = hyd->DeficientNodes;
    s->scalars[6] = hyd->DemandReduction;
    s->scalars[7] = rc * 1000000.0 + iter + relerr;
}

static void snap_take(Snapshot *s, Project *pr)
{
    int k, i;
    for (k = 0; k < s->nd; k++) memcpy(s->d[k].copy, s->d[k].live, (s->d[k].n + 1) * sizeof(double));
    for (k = 0; k < s->ni; k++) memcpy(s->i[k].copy, s->i[k].live, (s->i[k].n + 1) * sizeof(int));
    if (s->leak) for (i = 0; i <= pr->network.Njuncs; i++) {
        s->leak[2 * i] = pr->hydraul.Leakage[i].qfa;
        s->leak[2 * i + 1] = pr->hydraul.Leakage[i].qva;
    }
}

static void snap_put(Snapshot *s, Project *pr)
{
    int k, i;
    for (k = 0; k < s->nd; k++) memcpy(s->d[k].live, s->d[k].copy, (s->d[k].n + 1) * sizeof(double));
    for (k = 0; k < s->ni; k++) memcpy(s->i[k].live, s->i[k].copy, (s->i[k].n + 1) * sizeof(int));
    if (s->leak) for (i = 0; i <= pr->network.Njuncs; i++) {
        pr->hydraul.Leakage[i].qfa = s->leak[2 * i];
        pr->hydraul.Leakage[i].qva = s->leak[2 * i + 1];
    }
}

static void snap_compare(Shadow *sh, Snapshot *s, Project *pr, double *scalars)
{
    static const char *names[] = {"RelaxFactor", "RelativeError", "MaxHeadError",
        "MaxFlowChange", "Iterations", "DeficientNodes", "DemandReduction", "rc/iter/relerr"};
    int k, i;
    for (k = 0; k < s->nd; k++)
        for (i = (s->d[k].n ? 1 : 0); i <= s->d[k].n; i++)
            compare(sh, s->d[k].name, i, s->d[k].copy[i], s->d[k].live[i]);
    for (k = 0; k < s->ni; k++)
        for (i = 1; i <= s->i[k].n; i++)
            compare(sh, s->i[k].name, i, s->i[k].copy[i], s->i[k].live[i]);
    if (s->leak) for (i = 1; i <= pr->network.Njuncs; i++) {
        compare(sh, "Leakage.qfa", i, s->leak[2 * i], pr->hydraul.Leakage[i].qfa);
        compare(sh, "Leakage.qva", i, s->leak[2 * i + 1], pr->hydraul.Leakage[i].qva);
    }
    for (k = 0; k < 8; k++) compare(sh, names[k], 0, s->scalars[k], scalars[k]);
}

static void snap_free(Snapshot *s)
{
    int k;
    for (k = 0; k < s->nd; k++) free(s->d[k].copy);
    for (k = 0; k < s->ni; k++) free(s->i[k].copy);
    free(s->leak);
}

int hydsolve(Project *pr, int *iter, double *relerr)
{
    Shadow *s = &shadow_hydsolve;
    Snapshot before, after;
    int rc_c, rc_o, iter_c, iter_o;
    double relerr_c, relerr_o, scalars_o[8];

    shadow_begin(s);
    snap_setup(&before, pr);
    snap_setup(&after, pr);
    snap_take(&before, pr);

    rc_c = hydsolve_c(pr, &iter_c, &relerr_c);
    snap_take(&after, pr);
    snap_scalars(&after, pr, iter_c, relerr_c, rc_c);

    snap_put(&before, pr);
    rc_o = hydsolve_odin(pr, &iter_o, &relerr_o);
    snap_scalars(&before, pr, iter_o, relerr_o, rc_o);
    memcpy(scalars_o, before.scalars, sizeof scalars_o);
    snap_compare(s, &after, pr, scalars_o);

    snap_free(&before);
    snap_free(&after);
    *iter = iter_o;
    *relerr = relerr_o;
    return rc_o;
}
#else
void headlosscoeffs(Project *pr) { headlosscoeffs_odin(pr); }
void matrixcoeffs(Project *pr) { matrixcoeffs_odin(pr); }
int hydsolve(Project *pr, int *iter, double *relerr) { return hydsolve_odin(pr, iter, relerr); }
#endif
