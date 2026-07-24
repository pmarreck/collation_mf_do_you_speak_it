/*
 * collate — CLI front-end for collation_mf_do_you_speak_it.
 *
 * Reads lines from stdin (or a file), sorts them via the collation FFI, and
 * writes the sorted lines to stdout. The whole point: a fast, opinionated,
 * REPRODUCIBLE sort that ignores the OS locale entirely.
 *
 * Conventions (per Mecha LLC standards):
 *   - UTF-8 everywhere
 *   - `-h`/`--help`, `--about`, `--version` always work
 *   - `-` / `@stdin` accepted where an input file is expected
 *   - Output about output goes to stderr; the sorted lines go to stdout
 *
 * SPDX-License-Identifier: MIT
 */

#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "collation_mf_do_you_speak_it.h"

#if defined(__aarch64__) || defined(_M_ARM64)
#define CMF_ARCH "aarch64"
#elif defined(__x86_64__) || defined(_M_X64)
#define CMF_ARCH "x86_64"
#else
#define CMF_ARCH "unknown"
#endif

#if defined(__APPLE__)
#define CMF_OS "macos"
#elif defined(__linux__)
#define CMF_OS "linux"
#elif defined(_WIN32)
#define CMF_OS "windows"
#else
#define CMF_OS "unknown"
#endif

static void announce_debug_build(void) {
#ifndef NDEBUG
    if (getenv("MUTE_DEBUG_STATUS") == NULL) {
        fputs("\x1b[33mDEBUG BUILD\x1b[0m\n", stderr);
    }
#endif
}

static int print_help(void) {
    fputs(
        "collate — fast, opinionated, reproducible, locale-free line sort\n"
        "\n"
        "Usage:\n"
        "  collate [OPTIONS] [FILE]\n"
        "\n"
        "Reads lines from FILE (or stdin) and writes them sorted to stdout.\n"
        "FILE may be '-' or '@stdin' to read standard input (the default).\n"
        "\n"
        "Ordering (default = the opinionated house style):\n"
        "  whitespace < punctuation < digits < letters (structural-first)\n"
        "  natural numeric runs (file2 < file10)\n"
        "  case-insensitive base letters (apple ~ Apple), lowercase first\n"
        "  diacritics as a secondary tie-break (café near cafe, not after z)\n"
        "\n"
        "Options:\n"
        "  -c, --code-point   Pure UTF-8 byte order (== LC_ALL=C sort)\n"
        "  -h, --help         Show this help\n"
        "      --about        Print one-line version + platform\n"
        "      --version      Print the library version\n",
        stdout);
    return 0;
}

static int print_about(void) {
    printf("collate %s (%s-%s) — locale-free opinionated collation\n",
           collation_mf_version(), CMF_OS, CMF_ARCH);
    return 0;
}

/* Read an entire stream into a heap buffer. Caller frees *out_buf.
 * Returns 0 on success, -1 on error (message to stderr). */
static int read_all(FILE *f, const char *name, uint8_t **out_buf, size_t *out_len) {
    size_t cap = 1 << 16;
    size_t len = 0;
    uint8_t *buf = (uint8_t *)malloc(cap);
    if (!buf) {
        fputs("collate: out of memory\n", stderr);
        return -1;
    }
    for (;;) {
        if (len == cap) {
            size_t ncap = cap * 2;
            uint8_t *nb = (uint8_t *)realloc(buf, ncap);
            if (!nb) {
                free(buf);
                fputs("collate: out of memory\n", stderr);
                return -1;
            }
            buf = nb;
            cap = ncap;
        }
        size_t got = fread(buf + len, 1, cap - len, f);
        len += got;
        if (got == 0) {
            if (ferror(f)) {
                fprintf(stderr, "collate: read error on '%s': %s\n", name, strerror(errno));
                free(buf);
                return -1;
            }
            break; /* EOF */
        }
    }
    *out_buf = buf;
    *out_len = len;
    return 0;
}

typedef struct {
    const uint8_t *line; /* points into the input buffer (not NUL-terminated) */
    size_t line_len;
    uint8_t *key; /* owned sort key */
    size_t key_len;
} row_t;

static const collation_mf_collator *g_coll; /* used by qsort comparator */

/* Order by sort-key memcmp; break ties by raw line bytes for determinism. */
static int cmp_rows(const void *pa, const void *pb) {
    const row_t *a = (const row_t *)pa;
    const row_t *b = (const row_t *)pb;
    size_t n = a->key_len < b->key_len ? a->key_len : b->key_len;
    int c = memcmp(a->key, b->key, n);
    if (c != 0) return c;
    if (a->key_len != b->key_len) return a->key_len < b->key_len ? -1 : 1;
    /* keys equal: stable-ish tie-break on the raw line */
    size_t m = a->line_len < b->line_len ? a->line_len : b->line_len;
    c = memcmp(a->line, b->line, m);
    if (c != 0) return c;
    if (a->line_len != b->line_len) return a->line_len < b->line_len ? -1 : 1;
    return 0;
}

static int cmd_sort(const char *path, uint32_t options) {
    FILE *f = stdin;
    int close_f = 0;
    if (path && strcmp(path, "-") != 0 && strcmp(path, "@stdin") != 0) {
        f = fopen(path, "rb");
        if (!f) {
            fprintf(stderr, "collate: cannot open '%s': %s\n", path, strerror(errno));
            return 1;
        }
        close_f = 1;
    }

    uint8_t *data = NULL;
    size_t data_len = 0;
    const char *name = close_f ? path : "<stdin>";
    int rc = read_all(f, name, &data, &data_len);
    if (close_f) fclose(f);
    if (rc != 0) return 1;

    /* Split into lines on '\n'. A trailing line without '\n' still counts. */
    size_t nlines = 0;
    for (size_t i = 0; i < data_len; i++) {
        if (data[i] == '\n') nlines++;
    }
    if (data_len > 0 && data[data_len - 1] != '\n') nlines++;

    if (nlines == 0) {
        free(data);
        return 0; /* empty input => empty output */
    }

    row_t *rows = (row_t *)calloc(nlines, sizeof(row_t));
    if (!rows) {
        free(data);
        fputs("collate: out of memory\n", stderr);
        return 1;
    }

    collation_mf_collator *coll = collation_mf_open(options);
    if (!coll) {
        free(rows);
        free(data);
        fputs("collate: failed to open collator\n", stderr);
        return 1;
    }
    g_coll = coll;

    size_t idx = 0;
    size_t start = 0;
    int exit_code = 0;
    for (size_t i = 0; i <= data_len; i++) {
        int at_end = (i == data_len);
        if (at_end && start >= data_len) break; /* no trailing partial line */
        if (at_end || data[i] == '\n') {
            const uint8_t *line = data + start;
            size_t line_len = i - start;
            /* Safe upper bound on key length: 6 bytes/input byte + structural. */
            size_t cap = line_len * 6 + 16;
            uint8_t *key = (uint8_t *)malloc(cap);
            if (!key) {
                exit_code = 1;
                fputs("collate: out of memory\n", stderr);
                break;
            }
            size_t need = collation_mf_get_sort_key(coll, line, line_len, key, cap);
            if (need > cap) {
                uint8_t *nk = (uint8_t *)realloc(key, need);
                if (!nk) {
                    free(key);
                    exit_code = 1;
                    fputs("collate: out of memory\n", stderr);
                    break;
                }
                key = nk;
                need = collation_mf_get_sort_key(coll, line, line_len, key, need);
            }
            rows[idx].line = line;
            rows[idx].line_len = line_len;
            rows[idx].key = key;
            rows[idx].key_len = need;
            idx++;
            start = i + 1;
        }
    }

    if (exit_code == 0) {
        qsort(rows, idx, sizeof(row_t), cmp_rows);
        for (size_t k = 0; k < idx; k++) {
            fwrite(rows[k].line, 1, rows[k].line_len, stdout);
            fputc('\n', stdout);
        }
    }

    for (size_t k = 0; k < idx; k++) free(rows[k].key);
    collation_mf_close(coll);
    free(rows);
    free(data);
    return exit_code;
}

int main(int argc, char *argv[]) {
    announce_debug_build();

    uint32_t options = 0;
    const char *path = NULL;
    int only_switches = 0; /* set once we see "--" */

    for (int i = 1; i < argc; i++) {
        const char *a = argv[i];
        if (!only_switches && strcmp(a, "--") == 0) {
            only_switches = 1;
            continue;
        }
        if (!only_switches && a[0] == '-' && a[1] != '\0' &&
            !(strcmp(a, "-") == 0)) {
            if (strcmp(a, "-h") == 0 || strcmp(a, "--help") == 0) {
                return print_help();
            } else if (strcmp(a, "--about") == 0) {
                return print_about();
            } else if (strcmp(a, "--version") == 0) {
                printf("%s\n", collation_mf_version());
                return 0;
            } else if (strcmp(a, "-c") == 0 || strcmp(a, "--code-point") == 0) {
                options |= COLLATION_MF_CODE_POINT;
            } else {
                fprintf(stderr, "collate: unknown option '%s' (try --help)\n", a);
                return 2;
            }
        } else {
            /* positional: input path ('-'/'@stdin' handled in cmd_sort) */
            if (path != NULL) {
                fprintf(stderr, "collate: unexpected extra argument '%s'\n", a);
                return 2;
            }
            path = a;
        }
    }

    return cmd_sort(path, options);
}
