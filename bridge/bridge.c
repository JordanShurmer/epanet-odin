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
 */
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "types.h"

/* The originals, renamed at link time. */
int linsolve_c(Smatrix *sm, int n);

/* The ports, from the Odin package (src/export.odin). */
int odin_linsolve(int n, int ncoeffs, double *aii, double *aij, double *f,
                  double *temp, int *xlnz, int *nzsub, int *lnz, int *link,
                  int *first);

#ifdef SHADOW

typedef struct {
    const char *name;
    long calls, bad;
    double maxdiff;
} Shadow;

static Shadow shadow_linsolve = {"linsolve"};
static int shadow_registered;

static void shadow_report(void)
{
    Shadow *s[] = {&shadow_linsolve};
    for (size_t i = 0; i < sizeof s / sizeof *s; i++) {
        fprintf(stderr, "shadow %s: %ld calls, %ld mismatches, max rel diff %.3g\n",
                s[i]->name, s[i]->calls, s[i]->bad, s[i]->maxdiff);
    }
}

static void shadow_init(void)
{
    if (shadow_registered) return;
    shadow_registered = 1;
    atexit(shadow_report);
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

int linsolve(Smatrix *sm, int n)
{
    Shadow *s = &shadow_linsolve;
    int nc = sm->Ncoeffs;
    int rc_c, rc_o, i;
    Smatrix copy = *sm;

    shadow_init();
    s->calls++;

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
    rc_o = odin_linsolve(n, nc, sm->Aii, sm->Aij, sm->F, sm->temp, sm->XLNZ,
                         sm->NZSUB, sm->LNZ, sm->link, sm->first);

    if (rc_c != rc_o) {
        compare(s, "return", 0, rc_c, rc_o);
    } else {
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

int linsolve(Smatrix *sm, int n)
{
    return odin_linsolve(n, sm->Ncoeffs, sm->Aii, sm->Aij, sm->F, sm->temp,
                         sm->XLNZ, sm->NZSUB, sm->LNZ, sm->link, sm->first);
}

#endif
