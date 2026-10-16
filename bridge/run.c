/*
 * run.c — run a network's hydraulics and print every result in full.
 *
 *   run <file.inp>      one line per node and link per time step, %.17g
 *
 * test.sh links this driver once against plain EPANET and once against
 * EPANET with the Odin pieces plugged in, runs both on every fixture, and
 * diffs the two prints. A line is `t kind index v1 v2 …`; the first lines
 * carry the per-step warning code EN_runH returned, which has to match too.
 */
#include <stdio.h>
#include <stdlib.h>

#include "epanet2_2.h"

static int fail(const char *what, int err)
{
    fprintf(stderr, "run: %s: EPANET error %d\n", what, err);
    return 2;
}

int main(int argc, char **argv)
{
    EN_Project ph;
    int err, nnodes, nlinks, i;
    long t, tstep;
    double head, pres, dem, flow, vel, hloss, status, setting;

    if (argc != 2) {
        fprintf(stderr, "usage: run <file.inp>\n");
        return 1;
    }
    EN_createproject(&ph);
    if ((err = EN_open(ph, argv[1], "/dev/null", ""))) return fail("open", err);
    EN_getcount(ph, EN_NODECOUNT, &nnodes);
    EN_getcount(ph, EN_LINKCOUNT, &nlinks);
    if ((err = EN_openH(ph))) return fail("openH", err);
    if ((err = EN_initH(ph, EN_NOSAVE))) return fail("initH", err);
    do {
        err = EN_runH(ph, &t);
        if (err > 6) return fail("runH", err);
        printf("%ld warn %d\n", t, err);
        for (i = 1; i <= nnodes; i++) {
            EN_getnodevalue(ph, i, EN_HEAD, &head);
            EN_getnodevalue(ph, i, EN_PRESSURE, &pres);
            EN_getnodevalue(ph, i, EN_DEMAND, &dem);
            printf("%ld node %d %.17g %.17g %.17g\n", t, i, head, pres, dem);
        }
        for (i = 1; i <= nlinks; i++) {
            EN_getlinkvalue(ph, i, EN_FLOW, &flow);
            EN_getlinkvalue(ph, i, EN_VELOCITY, &vel);
            EN_getlinkvalue(ph, i, EN_HEADLOSS, &hloss);
            EN_getlinkvalue(ph, i, EN_STATUS, &status);
            EN_getlinkvalue(ph, i, EN_SETTING, &setting);
            printf("%ld link %d %.17g %.17g %.17g %g %.17g\n", t, i, flow, vel,
                   hloss, status, setting);
        }
        if ((err = EN_nextH(ph, &tstep))) return fail("nextH", err);
    } while (tstep > 0);
    EN_closeH(ph);
    EN_close(ph);
    EN_deleteproject(ph);
    return 0;
}
