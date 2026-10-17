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
static Shadow *shadows[] = {&shadow_linsolve, &shadow_createsparse};
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
