/*
 * run.c — run a network's hydraulics and quality and print every result.
 *
 *   run <file.inp>         hydraulics and quality together, step by step
 *   run <file.inp> stepq   hydraulics first (to the hydraulics file), then
 *                          quality from it with EN_stepQ
 *
 * test.sh links this driver once against plain EPANET and once against
 * EPANET with the Odin pieces plugged in, runs both on every fixture, and
 * diffs the two prints. A line is `t kind index v1 v2 …`, %.17g; the warn
 * lines carry the code EN_runH returned, which has to match too, and the
 * last line the mass balance ratio.
 */
#include <stdio.h>
#include <stdlib.h>

#include "epanet2_2.h"

static int fail(const char *what, int err)
{
    fprintf(stderr, "run: %s: EPANET error %d\n", what, err);
    return 2;
}

static int nnodes, nlinks, qualtype;

static void dump(EN_Project ph, long t)
{
    int i;
    double head, pres, dem, flow, vel, hloss, status, setting, q;
    for (i = 1; i <= nnodes; i++) {
        EN_getnodevalue(ph, i, EN_HEAD, &head);
        EN_getnodevalue(ph, i, EN_PRESSURE, &pres);
        EN_getnodevalue(ph, i, EN_DEMAND, &dem);
        q = 0;
        if (qualtype) EN_getnodevalue(ph, i, EN_QUALITY, &q);
        printf("%ld node %d %.17g %.17g %.17g %.17g\n", t, i, head, pres, dem, q);
    }
    for (i = 1; i <= nlinks; i++) {
        EN_getlinkvalue(ph, i, EN_FLOW, &flow);
        EN_getlinkvalue(ph, i, EN_VELOCITY, &vel);
        EN_getlinkvalue(ph, i, EN_HEADLOSS, &hloss);
        EN_getlinkvalue(ph, i, EN_STATUS, &status);
        EN_getlinkvalue(ph, i, EN_SETTING, &setting);
        q = 0;
        if (qualtype) EN_getlinkvalue(ph, i, EN_LINKQUAL, &q);
        printf("%ld link %d %.17g %.17g %.17g %g %.17g %.17g\n", t, i, flow, vel,
               hloss, status, setting, q);
    }
}

int main(int argc, char **argv)
{
    EN_Project ph;
    int err, stepq, tracenode;
    long t, tstep, tleft;
    double ratio;
    char chem[64], units[64];

    if (argc < 2 || argc > 3) {
        fprintf(stderr, "usage: run <file.inp> [stepq]\n");
        return 1;
    }
    stepq = argc == 3;
    EN_createproject(&ph);
    if ((err = EN_open(ph, argv[1], "/dev/null", ""))) return fail("open", err);
    EN_getcount(ph, EN_NODECOUNT, &nnodes);
    EN_getcount(ph, EN_LINKCOUNT, &nlinks);
    EN_getqualinfo(ph, &qualtype, chem, units, &tracenode);
    printf("quality %d\n", qualtype);

    if (!stepq) {
        /* Hydraulics and quality together, one hydraulic step at a time. */
        if ((err = EN_openH(ph))) return fail("openH", err);
        if ((err = EN_initH(ph, EN_NOSAVE))) return fail("initH", err);
        if ((err = EN_openQ(ph))) return fail("openQ", err);
        if ((err = EN_initQ(ph, EN_NOSAVE))) return fail("initQ", err);
        do {
            err = EN_runH(ph, &t);
            if (err > 6) return fail("runH", err);
            printf("%ld warn %d\n", t, err);
            if ((err = EN_runQ(ph, &t))) return fail("runQ", err);
            dump(ph, t);
            if ((err = EN_nextH(ph, &tstep))) return fail("nextH", err);
            if ((err = EN_nextQ(ph, &tstep))) return fail("nextQ", err);
        } while (tstep > 0);
        EN_closeQ(ph);
        EN_closeH(ph);
    } else {
        /* Hydraulics to the file first, then quality read back from it. */
        err = EN_solveH(ph);
        if (err > 6) return fail("solveH", err);
        printf("0 warn %d\n", err);
        if ((err = EN_openQ(ph))) return fail("openQ", err);
        if ((err = EN_initQ(ph, EN_NOSAVE))) return fail("initQ", err);
        do {
            if ((err = EN_runQ(ph, &t))) return fail("runQ", err);
            dump(ph, t);
            if ((err = EN_stepQ(ph, &tleft))) return fail("stepQ", err);
        } while (tleft > 0);
        EN_closeQ(ph);
    }
    EN_getstatistic(ph, EN_MASSBALANCE, &ratio);
    printf("massbalance %.17g\n", ratio);
    EN_close(ph);
    EN_deleteproject(ph);
    return 0;
}
