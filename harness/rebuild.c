/*
 * rebuild.c — read a network, build it again through the editing API, run
 * that, and write both as .inp files.
 *
 *   rebuild <file.inp> <prefix>     the rebuilt network's results, every
 *                                   step, like run.c; then the same for
 *                                   <prefix>.rebuilt.inp read back in
 *
 * Three projects: the file as read, written out as <prefix>.orig.inp; a
 * project made with EN_init and filled through every EN_set*, EN_add* the
 * getters can feed (nodes, links, demands, patterns, curves, controls,
 * rules, options, times, quality), run and written as <prefix>.rebuilt.inp;
 * and that file read back and run. test.sh links this against plain EPANET
 * and against the Odin toolkit and diffs the prints and the files, so every
 * editing call is proved on every fixture.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "epanet2_2.h"

static int nnodes, nlinks, qualtype;

static int fail(const char *what, int err)
{
    fprintf(stderr, "rebuild: %s: EPANET error %d\n", what, err);
    return 2;
}

#define TRY(what, call) do { int e_ = (call); if (e_ > 100) return fail(what, e_); } while (0)

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

/* run — hydraulics and quality together, every step printed. */
static int run(EN_Project ph, const char *tag)
{
    int err, tracenode;
    long t, tstep;
    double ratio;
    char chem[64], units[64];

    EN_getcount(ph, EN_NODECOUNT, &nnodes);
    EN_getcount(ph, EN_LINKCOUNT, &nlinks);
    EN_getqualinfo(ph, &qualtype, chem, units, &tracenode);
    printf("%s quality %d nodes %d links %d\n", tag, qualtype, nnodes, nlinks);
    TRY("openH", EN_openH(ph));
    TRY("initH", EN_initH(ph, EN_NOSAVE));
    TRY("openQ", EN_openQ(ph));
    TRY("initQ", EN_initQ(ph, EN_NOSAVE));
    do {
        err = EN_runH(ph, &t);
        if (err > 6) return fail("runH", err);
        printf("%ld warn %d\n", t, err);
        TRY("runQ", EN_runQ(ph, &t));
        dump(ph, t);
        TRY("nextH", EN_nextH(ph, &tstep));
        TRY("nextQ", EN_nextQ(ph, &tstep));
    } while (tstep > 0);
    EN_closeQ(ph);
    EN_closeH(ph);
    EN_getstatistic(ph, EN_MASSBALANCE, &ratio);
    printf("massbalance %.17g\n", ratio);
    return 0;
}

static const char *VARWORD[] = {"DEMAND", "HEAD", "GRADE", "LEVEL", "PRESSURE", "FLOW", "STATUS",
    "SETTING", "POWER", "TIME", "CLOCKTIME", "FILLTIME", "DRAINTIME"};
static const char *OPERATOR[] = {"=", "<>", "<=", ">=", "<", ">", "IS", "NOT", "BELOW", "ABOVE"};
static const char *VALUE[] = {"XXXX", "OPEN", "CLOSED", "ACTIVE"};
static const char *LOGOP[] = {"RULE", "IF", "AND", "OR", "THEN", "ELSE", "PRIORITY"};

static void objtext(EN_Project p, int object, int index, char *obj, char *id)
{
    int t;
    if (object == EN_R_NODE) {
        EN_getnodetype(p, index, &t);
        strcpy(obj, t == EN_JUNCTION ? "JUNCTION" : t == EN_RESERVOIR ? "RESERVOIR" : "TANK");
        EN_getnodeid(p, index, id);
    } else if (object == EN_R_LINK) {
        EN_getlinktype(p, index, &t);
        strcpy(obj, t <= EN_PIPE ? "PIPE" : t == EN_PUMP ? "PUMP" : "VALVE");
        EN_getlinkid(p, index, id);
    } else {
        strcpy(obj, "SYSTEM");
        strcpy(id, "");
    }
}

/* timetext — seconds as h:mm:ss (the rule parser reads it back as hours). */
static void timetext(double secs, char *s)
{
    long t = (long)secs;
    sprintf(s, "%ld:%02ld:%02ld", t / 3600, (t % 3600) / 60, t % 60);
}

/* rebuild_rules — every rule as text, through EN_addrule. */
static int rebuild_rules(EN_Project p, EN_Project q, int nrules)
{
    int i, k, np, nthen, nelse, enabled;
    int logop, object, index, variable, relop, status, link;
    double priority, value, setting;
    char text[8192], line[512], obj[32], id[EN_MAXID + 1], val[64];

    for (i = 1; i <= nrules; i++) {
        TRY("getrule", EN_getrule(p, i, &np, &nthen, &nelse, &priority));
        EN_getruleID(p, i, id);
        sprintf(text, "RULE %s\n", id);
        for (k = 1; k <= np; k++) {
            EN_getpremise(p, i, k, &logop, &object, &index, &variable, &relop, &status, &value);
            objtext(p, object, index, obj, id);
            if (value == EN_MISSING) strcpy(val, VALUE[status]);
            else if (variable == EN_R_TIME || variable == EN_R_CLOCKTIME) timetext(value, val);
            else if (variable == EN_R_FILLTIME || variable == EN_R_DRAINTIME) sprintf(val, "%.6f", value / 3600.0);
            else sprintf(val, "%.6f", value);
            sprintf(line, "%s %s %s %s %s %s\n", k == 1 ? "IF" : LOGOP[logop], obj, id,
                    VARWORD[variable], OPERATOR[relop], val);
            strcat(text, line);
        }
        for (k = 1; k <= nthen; k++) {
            EN_getthenaction(p, i, k, &link, &status, &setting);
            objtext(p, EN_R_LINK, link, obj, id);
            if (setting == EN_MISSING) sprintf(line, "%s %s %s STATUS IS %s\n", k == 1 ? "THEN" : "AND", obj, id, VALUE[status]);
            else sprintf(line, "%s %s %s SETTING IS %.6f\n", k == 1 ? "THEN" : "AND", obj, id, setting);
            strcat(text, line);
        }
        for (k = 1; k <= nelse; k++) {
            EN_getelseaction(p, i, k, &link, &status, &setting);
            objtext(p, EN_R_LINK, link, obj, id);
            if (setting == EN_MISSING) sprintf(line, "%s %s %s STATUS IS %s\n", k == 1 ? "ELSE" : "AND", obj, id, VALUE[status]);
            else sprintf(line, "%s %s %s SETTING IS %.6f\n", k == 1 ? "ELSE" : "AND", obj, id, setting);
            strcat(text, line);
        }
        if (priority > 0) {
            sprintf(line, "PRIORITY %.6f\n", priority);
            strcat(text, line);
        }
        EN_getruleenabled(p, i, &enabled);
        if (!enabled) strcat(text, "DISABLED\n");
        TRY("addrule", EN_addrule(q, text));
    }
    return 0;
}

/* rebuild — q becomes what p is, through the API. */
static int rebuild(EN_Project p, EN_Project q, const char *rpt)
{
    int i, k, n, units, type, idx, npats, ncurves, ncontrols, nrules, len, node1, node2, enabled;
    int d, nd, t;
    double v, x, y, el, lvl, minlvl, maxlvl, diam, minvol, setting, level;
    double xs[2048], ys[2048];
    char id[EN_MAXID + 1], id1[EN_MAXID + 1], id2[EN_MAXID + 1], cid[EN_MAXID + 1];
    char t1[EN_MAXMSG + 1], t2[EN_MAXMSG + 1], t3[EN_MAXMSG + 1];
    char chem[EN_MAXID + 1], chemunits[EN_MAXID + 1];
    int order_first[] = {EN_TRIALS, EN_ACCURACY, EN_EMITEXPON, EN_DEMANDMULT, EN_HEADERROR, EN_FLOWCHANGE,
        EN_GLOBALEFFIC, EN_GLOBALPRICE, EN_DEMANDCHARGE, EN_SP_GRAVITY, EN_SP_VISCOS, EN_UNBALANCED,
        EN_CHECKFREQ, EN_MAXCHECK, EN_DAMPLIMIT, EN_SP_DIFFUS, EN_BULKORDER, EN_WALLORDER, EN_TANKORDER,
        EN_EMITBACKFLOW, EN_PRESS_UNITS, EN_STATUS_REPORT};
    int times_order[] = {EN_PATTERNSTEP, EN_REPORTSTEP, EN_HYDSTEP, EN_QUALSTEP, EN_RULESTEP, EN_DURATION,
        EN_PATTERNSTART, EN_REPORTSTART, EN_STATISTIC, EN_STARTTIME};
    long tv;

    EN_getflowunits(p, &units);
    EN_getoption(p, EN_HEADLOSSFORM, &v);
    TRY("init", EN_init(q, rpt, "", units, (int)v));
    EN_gettitle(p, t1, t2, t3);
    TRY("settitle", EN_settitle(q, t1, t2, t3));

    for (i = 0; i < (int)(sizeof order_first / sizeof *order_first); i++) {
        EN_getoption(p, order_first[i], &v);
        TRY("setoption", EN_setoption(q, order_first[i], v));
    }
    for (i = 0; i < (int)(sizeof times_order / sizeof *times_order); i++) {
        EN_gettimeparam(p, times_order[i], &tv);
        TRY("settimeparam", EN_settimeparam(q, times_order[i], tv));
    }

    EN_getcount(p, EN_PATCOUNT, &npats);
    for (i = 1; i <= npats; i++) {
        EN_getpatternid(p, i, id);
        TRY("addpattern", EN_addpattern(q, id));
        EN_getpatternlen(p, i, &len);
        for (k = 1; k <= len && k <= 2048; k++) EN_getpatternvalue(p, i, k, &xs[k - 1]);
        TRY("setpattern", EN_setpattern(q, i, xs, len > 2048 ? 2048 : len));
        if (EN_getcomment(p, EN_TIMEPAT, i, t1) == 0 && t1[0]) TRY("setcomment", EN_setcomment(q, EN_TIMEPAT, i, t1));
    }
    EN_getoption(p, EN_GLOBALPATTERN, &v);
    TRY("setoption", EN_setoption(q, EN_GLOBALPATTERN, v));
    EN_getoption(p, EN_DEMANDPATTERN, &v);
    TRY("setoption", EN_setoption(q, EN_DEMANDPATTERN, v));

    EN_getcount(p, EN_CURVECOUNT, &ncurves);
    for (i = 1; i <= ncurves; i++) {
        EN_getcurveid(p, i, id);
        TRY("addcurve", EN_addcurve(q, id));
        EN_getcurvelen(p, i, &len);
        for (k = 1; k <= len && k <= 2048; k++) EN_getcurvevalue(p, i, k, &xs[k - 1], &ys[k - 1]);
        TRY("setcurve", EN_setcurve(q, i, xs, ys, len > 2048 ? 2048 : len));
        EN_getcurvetype(p, i, &type);
        TRY("setcurvetype", EN_setcurvetype(q, i, type));
        if (EN_getcomment(p, EN_CURVE, i, t1) == 0 && t1[0]) TRY("setcomment", EN_setcomment(q, EN_CURVE, i, t1));
    }

    EN_getcount(p, EN_NODECOUNT, &n);
    for (i = 1; i <= n; i++) {
        EN_getnodeid(p, i, id);
        EN_getnodetype(p, i, &type);
        TRY("addnode", EN_addnode(q, id, type, &idx));
        EN_getnodevalue(p, i, EN_ELEVATION, &el);
        TRY("set elevation", EN_setnodevalue(q, i, EN_ELEVATION, el));
        if (EN_getcoord(p, i, &x, &y) == 0) TRY("setcoord", EN_setcoord(q, i, x, y));
        if (EN_getcomment(p, EN_NODE, i, t1) == 0 && t1[0]) TRY("setcomment", EN_setcomment(q, EN_NODE, i, t1));
        if (EN_gettag(p, EN_NODE, i, t1) == 0 && t1[0]) TRY("settag", EN_settag(q, EN_NODE, i, t1));
        if (type == EN_JUNCTION) {
            EN_getnumdemands(p, i, &nd);
            if (nd == 0) TRY("deletedemand", EN_deletedemand(q, i, 1));
            for (d = 1; d <= nd; d++) {
                double base;
                int pat;
                EN_getbasedemand(p, i, d, &base);
                EN_getdemandpattern(p, i, d, &pat);
                EN_getdemandname(p, i, d, t1);
                if (pat > 0) EN_getpatternid(p, pat, cid); else cid[0] = 0;
                if (d == 1) {
                    TRY("setbasedemand", EN_setbasedemand(q, i, 1, base));
                    TRY("setdemandpattern", EN_setdemandpattern(q, i, 1, pat));
                    if (t1[0]) TRY("setdemandname", EN_setdemandname(q, i, 1, t1));
                } else {
                    TRY("adddemand", EN_adddemand(q, i, base, cid, t1));
                }
            }
            EN_getnodevalue(p, i, EN_EMITTER, &v);
            if (v > 0) TRY("set emitter", EN_setnodevalue(q, i, EN_EMITTER, v));
        } else if (type == EN_TANK) {
            EN_getnodevalue(p, i, EN_TANKLEVEL, &lvl);
            EN_getnodevalue(p, i, EN_MINLEVEL, &minlvl);
            EN_getnodevalue(p, i, EN_MAXLEVEL, &maxlvl);
            EN_getnodevalue(p, i, EN_TANKDIAM, &diam);
            EN_getnodevalue(p, i, EN_MINVOLUME, &minvol);
            EN_getnodevalue(p, i, EN_VOLCURVE, &v);
            if (v > 0) EN_getcurveid(p, (int)v, cid); else cid[0] = 0;
            TRY("settankdata", EN_settankdata(q, i, el, lvl, minlvl, maxlvl, diam, minvol, cid));
            EN_getnodevalue(p, i, EN_MIXMODEL, &v);
            TRY("set mixmodel", EN_setnodevalue(q, i, EN_MIXMODEL, v));
            EN_getnodevalue(p, i, EN_MIXFRACTION, &v);
            TRY("set mixfraction", EN_setnodevalue(q, i, EN_MIXFRACTION, v));
            EN_getnodevalue(p, i, EN_TANK_KBULK, &v);
            TRY("set tank kbulk", EN_setnodevalue(q, i, EN_TANK_KBULK, v));
            EN_getnodevalue(p, i, EN_CANOVERFLOW, &v);
            TRY("set canoverflow", EN_setnodevalue(q, i, EN_CANOVERFLOW, v));
        } else {
            EN_getnodevalue(p, i, EN_PATTERN, &v);
            TRY("set head pattern", EN_setnodevalue(q, i, EN_PATTERN, v));
        }
    }

    /* The quality type sets the concentration units, so it comes before
       every concentration; the trace node has to exist first. */
    EN_getqualinfo(p, &t, chem, chemunits, &idx);
    if (t == EN_TRACE) EN_getnodeid(p, idx, id); else id[0] = 0;
    TRY("setqualtype", EN_setqualtype(q, t, chem, chemunits, id));
    TRY("setreport", EN_setreport(q, t == EN_NONE ? "QUALITY NO" : "QUALITY YES"));
    EN_getoption(p, EN_TOLERANCE, &v);
    TRY("set tolerance", EN_setoption(q, EN_TOLERANCE, v));
    EN_getoption(p, EN_CONCENLIMIT, &v);
    TRY("set concenlimit", EN_setoption(q, EN_CONCENLIMIT, v));
    for (i = 1; i <= n; i++) {
        EN_getnodevalue(p, i, EN_INITQUAL, &v);
        if (v != 0) TRY("set initqual", EN_setnodevalue(q, i, EN_INITQUAL, v));
        if (EN_getnodevalue(p, i, EN_SOURCETYPE, &v) == 0) {
            TRY("set sourcetype", EN_setnodevalue(q, i, EN_SOURCETYPE, v));
            EN_getnodevalue(p, i, EN_SOURCEQUAL, &v);
            TRY("set sourcequal", EN_setnodevalue(q, i, EN_SOURCEQUAL, v));
            EN_getnodevalue(p, i, EN_SOURCEPAT, &v);
            TRY("set sourcepat", EN_setnodevalue(q, i, EN_SOURCEPAT, v));
        }
    }

    EN_getcount(p, EN_LINKCOUNT, &n);
    for (k = 1; k <= n; k++) {
        EN_getlinkid(p, k, id);
        EN_getlinktype(p, k, &type);
        EN_getlinknodes(p, k, &node1, &node2);
        EN_getnodeid(p, node1, id1);
        EN_getnodeid(p, node2, id2);
        TRY("addlink", EN_addlink(q, id, type, id1, id2, &idx));
        if (type <= EN_PIPE) {
            double length, rough, mloss;
            EN_getlinkvalue(p, k, EN_LENGTH, &length);
            EN_getlinkvalue(p, k, EN_DIAMETER, &diam);
            EN_getlinkvalue(p, k, EN_ROUGHNESS, &rough);
            EN_getlinkvalue(p, k, EN_MINORLOSS, &mloss);
            TRY("setpipedata", EN_setpipedata(q, k, length, diam, rough, mloss));
            if (type == EN_PIPE) {
                EN_getlinkvalue(p, k, EN_INITSTATUS, &v);
                TRY("set initstatus", EN_setlinkvalue(q, k, EN_INITSTATUS, v));
            }
            EN_getlinkvalue(p, k, EN_KBULK, &v);
            TRY("set kbulk", EN_setlinkvalue(q, k, EN_KBULK, v));
            EN_getlinkvalue(p, k, EN_KWALL, &v);
            TRY("set kwall", EN_setlinkvalue(q, k, EN_KWALL, v));
            EN_getlinkvalue(p, k, EN_LEAK_AREA, &v);
            if (v != 0) TRY("set leak area", EN_setlinkvalue(q, k, EN_LEAK_AREA, v));
            EN_getlinkvalue(p, k, EN_LEAK_EXPAN, &v);
            if (v != 0) TRY("set leak expan", EN_setlinkvalue(q, k, EN_LEAK_EXPAN, v));
        } else if (type == EN_PUMP) {
            EN_getlinkvalue(p, k, EN_PUMP_POWER, &v);
            if (v > 0) TRY("set pump power", EN_setlinkvalue(q, k, EN_PUMP_POWER, v));
            EN_getlinkvalue(p, k, EN_PUMP_HCURVE, &v);
            if (v > 0) TRY("set pump hcurve", EN_setlinkvalue(q, k, EN_PUMP_HCURVE, v));
            EN_getlinkvalue(p, k, EN_PUMP_ECURVE, &v);
            if (v > 0) TRY("set pump ecurve", EN_setlinkvalue(q, k, EN_PUMP_ECURVE, v));
            EN_getlinkvalue(p, k, EN_LINKPATTERN, &v);
            if (v > 0) TRY("set pump pattern", EN_setlinkvalue(q, k, EN_LINKPATTERN, v));
            EN_getlinkvalue(p, k, EN_PUMP_ECOST, &v);
            if (v > 0) TRY("set pump ecost", EN_setlinkvalue(q, k, EN_PUMP_ECOST, v));
            EN_getlinkvalue(p, k, EN_PUMP_EPAT, &v);
            if (v > 0) TRY("set pump epat", EN_setlinkvalue(q, k, EN_PUMP_EPAT, v));
            EN_getlinkvalue(p, k, EN_INITSETTING, &v);
            TRY("set pump speed", EN_setlinkvalue(q, k, EN_INITSETTING, v));
            EN_getlinkvalue(p, k, EN_INITSTATUS, &v);
            TRY("set pump status", EN_setlinkvalue(q, k, EN_INITSTATUS, v));
        } else {
            EN_getlinkvalue(p, k, EN_DIAMETER, &diam);
            TRY("set valve diameter", EN_setlinkvalue(q, k, EN_DIAMETER, diam));
            EN_getlinkvalue(p, k, EN_MINORLOSS, &v);
            TRY("set valve minorloss", EN_setlinkvalue(q, k, EN_MINORLOSS, v));
            if (type == EN_GPV) {
                EN_getlinkvalue(p, k, EN_GPV_CURVE, &v);
                TRY("set gpv curve", EN_setlinkvalue(q, k, EN_GPV_CURVE, v));
            } else {
                EN_getlinkvalue(p, k, EN_INITSETTING, &v);
                TRY("set valve setting", EN_setlinkvalue(q, k, EN_INITSETTING, v));
                if (type == EN_PCV) {
                    EN_getlinkvalue(p, k, EN_PCV_CURVE, &v);
                    if (v > 0) TRY("set pcv curve", EN_setlinkvalue(q, k, EN_PCV_CURVE, v));
                }
            }
            EN_getlinkvalue(p, k, EN_INITSTATUS, &v);
            if (v == 0 || v == 1) TRY("set valve status", EN_setlinkvalue(q, k, EN_INITSTATUS, v));
        }
        EN_getvertexcount(p, k, &len);
        if (len > 0) {
            for (i = 1; i <= len && i <= 2048; i++) EN_getvertex(p, k, i, &xs[i - 1], &ys[i - 1]);
            TRY("setvertices", EN_setvertices(q, k, xs, ys, len > 2048 ? 2048 : len));
        }
        if (EN_getcomment(p, EN_LINK, k, t1) == 0 && t1[0]) TRY("setcomment", EN_setcomment(q, EN_LINK, k, t1));
        if (EN_gettag(p, EN_LINK, k, t1) == 0 && t1[0]) TRY("settag", EN_settag(q, EN_LINK, k, t1));
    }

    EN_getcount(p, EN_CONTROLCOUNT, &ncontrols);
    for (i = 1; i <= ncontrols; i++) {
        int ctype, link, node;
        EN_getcontrol(p, i, &ctype, &link, &setting, &node, &level);
        TRY("addcontrol", EN_addcontrol(q, ctype, link, setting, node, level, &idx));
        EN_getcontrolenabled(p, i, &enabled);
        TRY("setcontrolenabled", EN_setcontrolenabled(q, idx, enabled));
    }
    EN_getcount(p, EN_RULECOUNT, &nrules);
    if (rebuild_rules(p, q, nrules)) return 2;

    {
        int model;
        double pmin, preq, pexp;
        EN_getdemandmodel(p, &model, &pmin, &preq, &pexp);
        TRY("setdemandmodel", EN_setdemandmodel(q, model, pmin, preq, pexp));
    }
    return 0;
}

int main(int argc, char **argv)
{
    EN_Project p, q, r;
    int err;
    char rpt[1024], orig[1024], rebuilt[1024], rpt2[1024], rpt3[1024];

    if (argc != 3) {
        fprintf(stderr, "usage: rebuild <file.inp> <prefix>\n");
        return 1;
    }
    snprintf(rpt, sizeof rpt, "%s.p.rpt", argv[2]);
    snprintf(rpt2, sizeof rpt2, "%s.q.rpt", argv[2]);
    snprintf(rpt3, sizeof rpt3, "%s.r.rpt", argv[2]);
    snprintf(orig, sizeof orig, "%s.orig.inp", argv[2]);
    snprintf(rebuilt, sizeof rebuilt, "%s.rebuilt.inp", argv[2]);

    EN_createproject(&p);
    if ((err = EN_open(p, argv[1], rpt, "")) > 100) {
        EN_deleteproject(p);
        return fail("open", err);
    }
    if ((err = EN_saveinpfile(p, orig))) return fail("saveinpfile", err);

    EN_createproject(&q);
    if (rebuild(p, q, rpt2)) return 2;
    EN_close(p);
    EN_deleteproject(p);
    if (run(q, "rebuilt")) return 2;
    if ((err = EN_saveinpfile(q, rebuilt))) return fail("saveinpfile rebuilt", err);
    EN_close(q);
    EN_deleteproject(q);

    EN_createproject(&r);
    if ((err = EN_open(r, rebuilt, rpt3, "")) > 100) return fail("open rebuilt", err);
    if (run(r, "reread")) return 2;
    EN_close(r);
    EN_deleteproject(r);
    return 0;
}
