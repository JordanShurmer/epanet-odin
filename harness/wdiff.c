/*
 * wdiff.c — compare two binary files word by word, floats within a tolerance.
 *
 *   wdiff <a> <b> <tol>        exit 0 when every 4-byte word is equal, or
 *                              differs only as a float32 within tol
 *                              (relative); else prints the first word that
 *                              is not and exits 1
 *
 * EPANET's output and hydraulics files are 4-byte ints and float32s. Two
 * builds that round a last bit differently write the same ints and floats
 * a hair apart; this says whether that is all.
 */
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(int argc, char **argv)
{
    FILE *fa, *fb;
    unsigned char wa[4], wb[4];
    float a, b;
    double tol, d, m;
    long n = 0, worst_at = -1;
    double worst = 0;
    size_t ra, rb;

    if (argc != 4) {
        fprintf(stderr, "usage: wdiff <a> <b> <tol>\n");
        return 2;
    }
    tol = atof(argv[3]);
    fa = fopen(argv[1], "rb");
    fb = fopen(argv[2], "rb");
    if (!fa || !fb) {
        fprintf(stderr, "wdiff: cannot open %s\n", fa ? argv[2] : argv[1]);
        return 2;
    }
    for (;;) {
        ra = fread(wa, 1, 4, fa);
        rb = fread(wb, 1, 4, fb);
        if (ra != rb) {
            printf("word %ld: sizes differ\n", n);
            return 1;
        }
        if (ra == 0) break;
        if (memcmp(wa, wb, ra) != 0) {
            if (ra < 4) {
                printf("word %ld: trailing bytes differ\n", n);
                return 1;
            }
            memcpy(&a, wa, 4);
            memcpy(&b, wb, 4);
            if (!isfinite(a) || !isfinite(b)) {
                printf("word %ld: %g vs %g\n", n, a, b);
                return 1;
            }
            d = fabs((double)a - (double)b);
            m = fmax(fabs((double)a), fabs((double)b));
            if (m == 0 || d / m > tol) {
                printf("word %ld: %.9g vs %.9g (rel %.3g)\n", n, a, b, m ? d / m : d);
                return 1;
            }
            if (d / m > worst) {
                worst = d / m;
                worst_at = n;
            }
        }
        n++;
    }
    if (worst_at >= 0) printf("within %.3g (word %ld)\n", worst, worst_at);
    return 0;
}
