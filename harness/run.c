/*
 * run.c — run a network's hydraulics and quality and print every result.
 *
 *   run <file.inp>                  hydraulics and quality together, step by step
 *   run <file.inp> stepq            hydraulics first (to the hydraulics file),
 *                                   then quality from it with EN_stepQ
 *   run <file.inp> <mode|-> <prefix> ...and write <prefix>.rpt (the report,
 *                                   results tables included), <prefix>.out
 *                                   (the binary output file) and <prefix>.hyd
 *                                   (the hydraulics file)
 *
 * test.sh links this driver once against plain EPANET and once against
 * EPANET with the Odin pieces plugged in, runs both on every fixture, and
 * diffs the two prints. A line is `t kind index v1 v2 …`, %.17g; the warn
 * lines carry the code EN_runH returned, which has to match too, and the
 * last line the mass balance ratio. The three files, when asked for, are
 * diffed too.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "epanet2_2.h"

static EN_Project ph;
static int nnodes, nlinks, qualtype;

/* fail — say what went wrong and close the project, so its temp files
   (the en?????? EPANET opens in the working directory) go with it. */
static int fail(const char *what, int err)
{
    fprintf(stderr, "run: %s: EPANET error %d\n", what, err);
    EN_close(ph);
    EN_deleteproject(ph);
    return 2;
}

static void dump(long t)
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
    int err, stepq, tracenode;
    long t, tstep, tleft;
    double ratio;
    char chem[64], units[64];

    char rpt[1024] = "/dev/null", out[1024] = "", hyd[1024] = "";
    int save = EN_NOSAVE; /* the files are written only when asked for */

    if (argc < 2 || argc > 4) {
        fprintf(stderr, "usage: run <file.inp> [stepq|-] [prefix]\n");
        return 1;
    }
    stepq = argc >= 3 && strcmp(argv[2], "stepq") == 0;
    if (argc == 4) {
        snprintf(rpt, sizeof rpt, "%s.rpt", argv[3]);
        snprintf(out, sizeof out, "%s.out", argv[3]);
        snprintf(hyd, sizeof hyd, "%s.hyd", argv[3]);
        save = EN_SAVE;
    }
    EN_createproject(&ph);
    if ((err = EN_open(ph, argv[1], rpt, out))) return fail("open", err);
    EN_getcount(ph, EN_NODECOUNT, &nnodes);
    EN_getcount(ph, EN_LINKCOUNT, &nlinks);
    EN_getqualinfo(ph, &qualtype, chem, units, &tracenode);
    printf("quality %d\n", qualtype);

    if (!stepq) {
        /* Hydraulics and quality together, one hydraulic step at a time. */
        if ((err = EN_openH(ph))) return fail("openH", err);
        if ((err = EN_initH(ph, save))) return fail("initH", err);
        if ((err = EN_openQ(ph))) return fail("openQ", err);
        if ((err = EN_initQ(ph, save))) return fail("initQ", err);
        do {
            err = EN_runH(ph, &t);
            if (err > 6) return fail("runH", err);
            printf("%ld warn %d\n", t, err);
            if ((err = EN_runQ(ph, &t))) return fail("runQ", err);
            dump(t);
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
        if ((err = EN_initQ(ph, save))) return fail("initQ", err);
        do {
            if ((err = EN_runQ(ph, &t))) return fail("runQ", err);
            dump(t);
            if ((err = EN_stepQ(ph, &tleft))) return fail("stepQ", err);
        } while (tleft > 0);
        EN_closeQ(ph);
    }
    if (save) {
        if ((err = EN_report(ph))) return fail("report", err);
        if ((err = EN_savehydfile(ph, hyd))) return fail("savehydfile", err);
    }
    EN_getstatistic(ph, EN_MASSBALANCE, &ratio);
    printf("massbalance %.17g\n", ratio);
    EN_close(ph);
    EN_deleteproject(ph);
    return 0;
}
