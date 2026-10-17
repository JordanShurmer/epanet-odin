/*
 * dumpnet.c — read an .inp with EPANET's own reader and print the project.
 *
 *   dumpnet <file.inp> <report-file>
 *
 * The twin of cmd/dumpnet (the Odin reader); the two prints must match
 * byte for byte. Every number is %.17g. Reads the project's structs
 * directly, so it is compiled against EPANET's src/.
 */
#include <stdio.h>
#include <string.h>

#include "types.h"
#include "funcs.h"
#include "epanet2_2.h"

extern int validateproject(Project *);

static void num(double x) { printf(" %.17g", x); }
static void inum(long x) { printf(" %ld", x); }
static void str(const char *s) { printf(" [%s]", s); }

static void dump(Project *pr, int errcode, int valcode)
{
    Network *net = &pr->network;
    Hydraul *hyd = &pr->hydraul;
    Quality *q = &pr->quality;
    Times *t = &pr->times;
    Report *r = &pr->report;
    Parser *ps = &pr->parser;
    int i, k;

    printf("errcode"); inum(errcode); inum(valcode);
    printf("\ncounts");
    inum(net->Nnodes); inum(net->Njuncs); inum(net->Ntanks); inum(net->Nlinks);
    inum(net->Npumps); inum(net->Nvalves); inum(net->Ncontrols); inum(net->Nrules);
    inum(net->Npats); inum(net->Ncurves);
    printf("\ntitle"); for (i = 0; i < 3; i++) str(pr->Title[i]);
    printf("\nunits");
    inum(ps->Unitsflag); inum(ps->Flowflag); inum(ps->Pressflag); inum(pr->outfile.Hydflag);
    str(pr->outfile.HydFname); str(pr->MapFname); str(q->ChemName); str(q->ChemUnits); str(ps->DefPatID);
    printf("\nucf"); for (i = 0; i < MAXVAR; i++) num(pr->Ucf[i]);
    printf("\nhyd");
    inum(hyd->Formflag); inum(hyd->DemandModel); inum(hyd->EmitBackFlag);
    num(hyd->Hexp); num(hyd->Qexp); num(hyd->Pexp); num(hyd->Pmin); num(hyd->Preq); num(hyd->RQtol);
    num(hyd->Viscos); num(hyd->Htol); num(hyd->Qtol); num(hyd->Hacc); num(hyd->HeadErrorLimit);
    num(hyd->FlowChangeLimit); num(hyd->DampLimit);
    inum(hyd->MaxIter); inum(hyd->ExtraIter); inum(hyd->CheckFreq); inum(hyd->MaxCheck);
    num(hyd->Dmult); num(hyd->SpGrav); num(hyd->Epump); num(hyd->Ecost); num(hyd->Dcost);
    inum(hyd->Epat); inum(hyd->DefPat);
    printf("\nqual");
    inum(q->Qualflag); inum(q->TraceNode);
    num(q->Ctol); num(q->Diffus); num(q->Climit); num(q->BulkOrder); num(q->WallOrder); num(q->TankOrder);
    num(q->Kbulk); num(q->Kwall); num(q->Rfactor);
    printf("\ntimes");
    inum(t->Dur); inum(t->Tstart); inum(t->Pstart); inum(t->Hstep); inum(t->Qstep); inum(t->Pstep);
    inum(t->Rstep); inum(t->Rulestep); inum(t->Rstart);
    printf("\nreport");
    inum(r->PageSize); inum(r->Summaryflag); inum(r->Messageflag); inum(r->Statflag); inum(r->Energyflag);
    inum(r->Nodeflag); inum(r->Linkflag); inum(r->Tstatflag); str(r->Rpt2Fname);
    for (i = 0; i < MAXVAR; i++) {
        printf("\nfield"); inum(i); inum(r->Field[i].Enabled); inum(r->Field[i].Precision);
        num(r->Field[i].RptLim[LOW]); num(r->Field[i].RptLim[HI]);
    }
    for (i = 1; i <= net->Nnodes; i++) {
        Snode *n = &net->Node[i];
        Pdemand d;
        printf("\nnode"); inum(i); str(n->ID); inum(n->Type);
        num(n->El); num(n->C0); num(n->Ke); num(n->X); num(n->Y); inum(n->Rpt);
        for (d = n->D; d; d = d->next) { printf("\ndem"); inum(i); num(d->Base); inum(d->Pat); }
        if (n->S) { printf("\nsrc"); inum(i); inum(n->S->Type); num(n->S->C0); inum(n->S->Pat); }
    }
    for (k = 1; k <= net->Nlinks; k++) {
        Slink *l = &net->Link[k];
        printf("\nlink"); inum(k); str(l->ID); inum(l->Type); inum(l->N1); inum(l->N2);
        num(l->Diam); num(l->Len); num(l->Kc); num(l->Km); num(l->Kb); num(l->Kw);
        inum(l->InitStatus); num(l->InitSetting); num(l->LeakArea); num(l->LeakExpan); inum(l->Rpt);
    }
    for (i = 1; i <= net->Ntanks; i++) {
        Stank *tk = &net->Tank[i];
        printf("\ntank"); inum(i); inum(tk->Node);
        num(tk->A); num(tk->Hmin); num(tk->Hmax); num(tk->H0); num(tk->Vmin); num(tk->Vmax); num(tk->V0);
        num(tk->Kb); num(tk->V); num(tk->C);
        inum(tk->Pat); inum(tk->Vcurve); inum(tk->MixModel); num(tk->V1frac); inum(tk->CanOverflow);
    }
    for (i = 1; i <= net->Npumps; i++) {
        Spump *pm = &net->Pump[i];
        printf("\npump"); inum(i); inum(pm->Link); inum(pm->Ptype);
        num(pm->Q0); num(pm->Qmax); num(pm->Hmax); num(pm->H0); num(pm->R); num(pm->N);
        inum(pm->Hcurve); inum(pm->Ecurve); inum(pm->Upat); inum(pm->Epat); num(pm->Ecost);
    }
    for (i = 1; i <= net->Nvalves; i++) {
        printf("\nvalve"); inum(i); inum(net->Valve[i].Link); inum(net->Valve[i].Curve);
    }
    for (i = 0; i <= net->Npats; i++) {
        Spattern *pt = &net->Pattern[i];
        printf("\npat"); inum(i); str(pt->ID); inum(pt->Length);
        for (k = 0; k < pt->Length; k++) num(pt->F[k]);
    }
    for (i = 1; i <= net->Ncurves; i++) {
        Scurve *c = &net->Curve[i];
        printf("\ncurve"); inum(i); str(c->ID); inum(c->Type); inum(c->Npts);
        for (k = 0; k < c->Npts; k++) { num(c->X[k]); num(c->Y[k]); }
    }
    for (i = 1; i <= net->Ncontrols; i++) {
        Scontrol *c = &net->Control[i];
        printf("\ncontrol"); inum(i); inum(c->Link); inum(c->Node); inum(c->Time);
        num(c->Grade); num(c->Setting); inum(c->Status); inum(c->Type); inum(c->isEnabled);
    }
    for (i = 1; i <= net->Nrules; i++) {
        Srule *rl = &net->Rule[i];
        Spremise *pm;
        Saction *a;
        printf("\nrule"); inum(i); str(rl->label); num(rl->priority); inum(rl->isEnabled);
        for (pm = rl->Premises; pm; pm = pm->next) {
            printf("\nprem"); inum(pm->logop); inum(pm->object); inum(pm->index); inum(pm->variable);
            inum(pm->relop); inum(pm->status); num(pm->value);
        }
        for (a = rl->ThenActions; a; a = a->next) { printf("\nthen"); inum(a->link); inum(a->status); num(a->setting); }
        for (a = rl->ElseActions; a; a = a->next) { printf("\nelse"); inum(a->link); inum(a->status); num(a->setting); }
    }
    printf("\n");
}

int main(int argc, char **argv)
{
    EN_Project pr;
    int errcode, valcode = 0;

    if (argc != 3) {
        fprintf(stderr, "usage: dumpnet <file.inp> <report-file>\n");
        return 2;
    }
    EN_createproject(&pr);
    errcode = EN_openX(pr, argv[1], argv[2], "");
    if (errcode == 0 || errcode == 200) {
        valcode = validateproject(pr);
        dump(pr, errcode, valcode);
    } else {
        printf("errcode %d 0\n", errcode);
    }
    fflush(stdout);
    EN_close(pr);
    EN_deleteproject(pr);
    return 0;
}
