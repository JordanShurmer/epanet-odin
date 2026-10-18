/*
 * bench.c — one network through the whole toolkit, timed phase by phase.
 *
 *   bench <file.inp> <reps> <rptfile>      one JSON object on stdout
 *
 * audit/audit.sh links this once against plain EPANET (libepanet2.a) and once
 * against the Odin toolkit (libepanet-api.a): the same driver, the same
 * networks. A rep opens the project, runs the hydraulics (saved to the
 * hydraulics file), runs the quality (saved to the binary output), writes the
 * report and closes. Every phase is timed on the monotonic clock, and the
 * resident set is read after each phase and after each close, so a leak shows
 * as growth rep over rep. Nothing is printed but the JSON, so an instruction
 * count of a run (callgrind) is the engine's, not printf's.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <time.h>
#include <unistd.h>

#include "epanet2_2.h"

enum { OPEN, HYDRAULICS, QUALITY, REPORT, CLOSE, PHASES };
static const char *phase_name[PHASES] = {"open", "hydraulics", "quality", "report", "close"};

static long long now_ns(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (long long)ts.tv_sec * 1000000000LL + ts.tv_nsec;
}

/* rss_kb — the resident set now, from /proc on Linux; 0 where there is none. */
static long rss_kb(void)
{
    long pages = 0, resident = 0;
    FILE *f = fopen("/proc/self/statm", "r");
    if (!f) return 0;
    if (fscanf(f, "%ld %ld", &pages, &resident) != 2) resident = 0;
    fclose(f);
    return resident * (sysconf(_SC_PAGESIZE) / 1024);
}

/* maxrss_kb — the peak, as the kernel counts it (KB on Linux, bytes on macOS). */
static long maxrss_kb(void)
{
    struct rusage ru;
    getrusage(RUSAGE_SELF, &ru);
#ifdef __APPLE__
    return ru.ru_maxrss / 1024;
#else
    return ru.ru_maxrss;
#endif
}

static const char *fixture_name(const char *path, char *buf, size_t n)
{
    const char *base = strrchr(path, '/');
    size_t len;
    base = base ? base + 1 : path;
    len = strlen(base);
    if (len > 4 && strcmp(base + len - 4, ".inp") == 0) len -= 4;
    if (len >= n) len = n - 1;
    memcpy(buf, base, len);
    buf[len] = 0;
    return buf;
}

static EN_Project ph;
static char fixture[256];

static int fail(const char *phase, int err)
{
    printf("{\"fixture\":\"%s\",\"phase\":\"%s\",\"errcode\":%d}\n", fixture, phase, err);
    EN_close(ph);
    EN_deleteproject(ph);
    return 2;
}

int main(int argc, char **argv)
{
    int err, reps, r, warn = 0;
    int nnodes = 0, nlinks = 0, qualtype = 0, tracenode;
    long t, tstep, duration = 0, hstep = 0;
    char chem[64], units[64];
    long long t0, *ns;
    long *rss, *rss_closed;
    struct rusage ru;

    if (argc != 4) {
        fprintf(stderr, "usage: bench <file.inp> <reps> <rptfile>\n");
        return 1;
    }
    reps = atoi(argv[2]);
    if (reps < 1) reps = 1;
    fixture_name(argv[1], fixture, sizeof fixture);
    ns = calloc((size_t)reps * PHASES, sizeof *ns);
    rss = calloc((size_t)reps * PHASES, sizeof *rss);
    rss_closed = calloc((size_t)reps, sizeof *rss_closed);

#define PHASE_END(i) \
    ns[r * PHASES + (i)] = now_ns() - t0; rss[r * PHASES + (i)] = rss_kb(); t0 = now_ns()

    for (r = 0; r < reps; r++) {
        t0 = now_ns();
        EN_createproject(&ph);
        if ((err = EN_open(ph, argv[1], argv[3], "")) > 100) return fail("open", err);
        PHASE_END(OPEN);
        if (r == 0) {
            EN_getcount(ph, EN_NODECOUNT, &nnodes);
            EN_getcount(ph, EN_LINKCOUNT, &nlinks);
            EN_gettimeparam(ph, EN_DURATION, &duration);
            EN_gettimeparam(ph, EN_HYDSTEP, &hstep);
            EN_getqualinfo(ph, &qualtype, chem, units, &tracenode);
        }

        if ((err = EN_openH(ph))) return fail("openH", err);
        if ((err = EN_initH(ph, EN_SAVE))) return fail("initH", err);
        do {
            err = EN_runH(ph, &t);
            if (err > 100) return fail("runH", err);
            if (err > warn) warn = err;
            if ((err = EN_nextH(ph, &tstep))) return fail("nextH", err);
        } while (tstep > 0);
        EN_closeH(ph);
        PHASE_END(HYDRAULICS);

        if ((err = EN_openQ(ph))) return fail("openQ", err);
        if ((err = EN_initQ(ph, EN_SAVE))) return fail("initQ", err);
        do {
            if ((err = EN_runQ(ph, &t))) return fail("runQ", err);
            if ((err = EN_nextQ(ph, &tstep))) return fail("nextQ", err);
        } while (tstep > 0);
        EN_closeQ(ph);
        PHASE_END(QUALITY);

        if ((err = EN_report(ph))) return fail("report", err);
        PHASE_END(REPORT);

        EN_close(ph);
        EN_deleteproject(ph);
        PHASE_END(CLOSE);
        rss_closed[r] = rss[r * PHASES + CLOSE];
    }

    getrusage(RUSAGE_SELF, &ru);
    printf("{\"fixture\":\"%s\",\"file\":\"%s\",\"nodes\":%d,\"links\":%d,\"duration_s\":%ld,"
           "\"hstep_s\":%ld,\"quality\":\"%s\",\"reps\":%d,\"warn\":%d,\"errcode\":0,",
           fixture, argv[1], nnodes, nlinks, duration, hstep,
           qualtype == EN_CHEM ? "chem" : qualtype == EN_AGE ? "age" : qualtype == EN_TRACE ? "trace" : "none",
           reps, warn);
    printf(" \"phases\":[");
    for (int i = 0; i < PHASES; i++) printf("%s\"%s\"", i ? "," : "", phase_name[i]);
    printf("], \"ns\":[");
    for (r = 0; r < reps; r++) {
        printf("%s[", r ? "," : "");
        for (int i = 0; i < PHASES; i++) printf("%s%lld", i ? "," : "", ns[r * PHASES + i]);
        printf("]");
    }
    printf("], \"rss_kb\":[");
    for (r = 0; r < reps; r++) {
        printf("%s[", r ? "," : "");
        for (int i = 0; i < PHASES; i++) printf("%s%ld", i ? "," : "", rss[r * PHASES + i]);
        printf("]");
    }
    printf("], \"rss_closed_kb\":[");
    for (r = 0; r < reps; r++) printf("%s%ld", r ? "," : "", rss_closed[r]);
    printf("], \"maxrss_kb\":%ld,\"cpu_user_ns\":%lld,\"cpu_sys_ns\":%lld}\n", maxrss_kb(),
           (long long)ru.ru_utime.tv_sec * 1000000000LL + (long long)ru.ru_utime.tv_usec * 1000LL,
           (long long)ru.ru_stime.tv_sec * 1000000000LL + (long long)ru.ru_stime.tv_usec * 1000LL);
    free(ns);
    free(rss);
    free(rss_closed);
    return 0;
}
