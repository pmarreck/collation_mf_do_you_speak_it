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

#include <ctype.h>
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

/* ── i18n (PREPARE phase) ──────────────────────────────────────────────────
 * English is canonical and the fallback; German (de) is a demonstration locale
 * that exercises the localized-alias + env-precedence machinery. Strings live
 * in this typed table (never inline at the use site). Full 50-locale coverage
 * and compile-time enforcement are DEFERRED to the enforce phase — see
 * RULES.md and the i18n skill. */
typedef enum { LANG_EN = 0, LANG_DE, LANG_COUNT } lang_t;

typedef struct {
    const char *code;       /* ISO code, e.g. "en" */
    const char *about_desc; /* trailing one-line description in --about */
    const char *help_text;  /* full --help body */
} messages_t;

static const messages_t MESSAGES[LANG_COUNT] = {
    [LANG_EN] = {
        "en",
        "locale-free opinionated collation",
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
        "  -t, --field-separator <SEP>  Split each line on SEP (default: whole line)\n"
        "  -k, --key <N>                Sort by the 1-based Nth field; ties -> whole line\n"
        "  -c, --code-point             Pure UTF-8 byte order (== LC_ALL=C sort)\n"
        "  -d, --decimal[=SEP]          Declare the input contains DECIMAL numbers.\n"
        "                               SEP is the decimal mark, '.' (default) or\n"
        "                               ','. Digit-group separators (space, NBSP,\n"
        "                               thin space, ' _ and the other of . ,) are\n"
        "                               then absorbed between digits, so\n"
        "                               999,999.00 < 1,000,000.00 and the same\n"
        "                               values order alike in any convention.\n"
        "                               Default: every '.' is a separator, giving\n"
        "                               version order (1.9 < 1.10).\n"
        "  -s, --sci, --scientific[=SEP]  Recognize scientific notation and order\n"
        "                               by value (2e5 < 1e10). Plain numbers are\n"
        "                               normalized as exponent 0 so mixed lists\n"
        "                               work. Does NOT absorb group separators.\n"
        "  -n, --num, --numeric[=SEP]   Both of the above: exponents AND\n"
        "                               digit-group absorption.\n"
        "      --version-sort           Explicit form of the default dot handling\n"
        "  -h, --help                   Show this help\n"
        "      --about                  Print one-line version + platform\n"
        "      --version                Print the library version\n"
        "      --lang <code>            UI language (e.g. en, de); overrides env\n"
        "\n"
        "Environment:\n"
        "  COLLATION_MF_LANG            UI language (overrides LANG/LC_*)\n"
        "  COLLATE_FIELD_SEP            Default field separator (overridden by -t)\n",
    },
    [LANG_DE] = {
        "de",
        "gebietsschema-freie, eigensinnige Sortierung",
        "collate — schnelle, eigensinnige, reproduzierbare Zeilensortierung ohne Gebietsschema\n"
        "\n"
        "Verwendung:\n"
        "  collate [OPTIONEN] [DATEI]\n"
        "\n"
        "Liest Zeilen aus DATEI (oder stdin) und schreibt sie sortiert nach stdout.\n"
        "DATEI darf '-' oder '@stdin' sein, um die Standardeingabe zu lesen (Standard).\n"
        "\n"
        "Reihenfolge (Standard = der eigensinnige Hausstil):\n"
        "  Leerraum < Satzzeichen < Ziffern < Buchstaben (struktur-zuerst)\n"
        "  natürliche Zahlenläufe (file2 < file10)\n"
        "  Groß-/Kleinschreibung-unabhängige Grundbuchstaben (apple ~ Apple), klein zuerst\n"
        "  Diakritika als sekundäres Kriterium (café nahe cafe, nicht nach z)\n"
        "\n"
        "Optionen:\n"
        "  -t, --field-separator <SEP>  Zeile an SEP trennen (Standard: ganze Zeile)\n"
        "  -k, --key <N>                Nach dem N-ten Feld sortieren; gleich -> ganze Zeile\n"
        "  -c, --code-point             Reine UTF-8-Byte-Reihenfolge (== LC_ALL=C sort)\n"
        "  -d, --decimal[=TRZ]          Eingabe enthält DEZIMALZAHLEN. TRZ ist das\n"
        "                               Dezimaltrennzeichen, '.' (Standard) oder ','.\n"
        "                               Tausendertrennzeichen (Leerzeichen, NBSP,\n"
        "                               schmales Leerzeichen, ' _ und das jeweils\n"
        "                               andere von . ,) werden dann zwischen Ziffern\n"
        "                               absorbiert. Standard: jedes '.' ist ein\n"
        "                               Trenner (1.9 < 1.10).\n"
        "  -s, --sci, --scientific[=TRZ]  Wissenschaftliche Notation erkennen und\n"
        "                               nach Wert sortieren (2e5 < 1e10). Zahlen\n"
        "                               ohne Exponent gelten als Exponent 0.\n"
        "  -n, --num, --numeric[=TRZ]   Beides: Exponenten UND Tausendertrenner.\n"
        "      --version-sort           Ausdrückliche Form des Standardverhaltens\n"
        "  -h, --help / --hilfe         Diese Hilfe anzeigen\n"
        "      --about                  Version + Plattform in einer Zeile\n"
        "      --version                Bibliotheksversion anzeigen\n"
        "      --lang / --sprache <code>  Anzeigesprache (z. B. en, de); überschreibt Umgebung\n"
        "\n"
        "Umgebung:\n"
        "  COLLATION_MF_LANG            Anzeigesprache (überschreibt LANG/LC_*)\n"
        "  COLLATE_FIELD_SEP            Standard-Feldtrenner (durch -t überschrieben)\n",
    },
};

/* Map a locale code (bare "de" or "de_DE.UTF-8" etc.) to a supported lang by
 * its leading language subtag (longest-match is unnecessary at 2 locales).
 * Returns 1 and sets *out on match; 0 if unsupported. */
static int lang_from_code(const char *code, lang_t *out) {
    if (!code || !code[0]) return 0;
    char buf[8];
    size_t n = 0;
    while (code[n] && n < sizeof(buf) - 1 &&
           code[n] != '_' && code[n] != '-' && code[n] != '.' && code[n] != '@') {
        buf[n] = (char)tolower((unsigned char)code[n]);
        n++;
    }
    buf[n] = '\0';
    for (int i = 0; i < LANG_COUNT; i++) {
        if (strcmp(buf, MESSAGES[i].code) == 0) { *out = (lang_t)i; return 1; }
    }
    return 0;
}

/* Resolve UI language. Precedence (highest first): explicit request (--lang or
 * a localized alias) > COLLATION_MF_LANG > LC_ALL > LC_MESSAGES > LANG >
 * English. An unsupported EXPLICIT app request WARNs (non-fatal in prepare
 * phase; enforce phase would make it fatal) and falls back to English; ambient
 * env locales fall back SILENTLY so a foreign host locale never spams stderr. */
static lang_t resolve_lang(const char *explicit_code) {
    lang_t lang;
    if (explicit_code && explicit_code[0]) {
        if (lang_from_code(explicit_code, &lang)) return lang;
        fprintf(stderr, "collate: WARN i18n missing-locale '%s' (falling back to English)\n",
                explicit_code);
        return LANG_EN;
    }
    const char *app = getenv("COLLATION_MF_LANG");
    if (app && app[0]) {
        if (lang_from_code(app, &lang)) return lang;
        fprintf(stderr, "collate: WARN i18n missing-locale '%s' (falling back to English)\n", app);
        return LANG_EN;
    }
    const char *ambient[3];
    ambient[0] = getenv("LC_ALL");
    ambient[1] = getenv("LC_MESSAGES");
    ambient[2] = getenv("LANG");
    for (int i = 0; i < 3; i++) {
        if (ambient[i] && ambient[i][0] && lang_from_code(ambient[i], &lang)) return lang;
    }
    return LANG_EN;
}

static int print_help(lang_t lang) {
    fputs(MESSAGES[lang].help_text, stdout);
    return 0;
}

static int print_about(lang_t lang) {
    printf("collate %s (%s-%s) — %s\n",
           collation_mf_version(), CMF_OS, CMF_ARCH, MESSAGES[lang].about_desc);
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

/* Locate the (1-based) Nth field of `line` when split on the `sep` substring,
 * returning the field's [ptr,len) via out-params. With no separator (sep NULL
 * or empty) or n < 1, the whole line is the field. A line with fewer than n
 * fields yields an empty field (sorts as empty — first). Naive substring search
 * (separators are short in practice). Kept in the C CLI so the Zig core stays
 * field-agnostic — the hexagonal boundary is preserved. */
static void extract_field(const uint8_t *line, size_t line_len,
                          const char *sep, size_t sep_len, long n,
                          const uint8_t **fptr, size_t *flen) {
    if (!sep || sep_len == 0 || n < 1) {
        *fptr = line;
        *flen = line_len;
        return;
    }
    size_t field_start = 0;
    for (long field = 1; field < n; field++) {
        const uint8_t *hit = NULL;
        for (size_t i = field_start; i + sep_len <= line_len; i++) {
            if (memcmp(line + i, sep, sep_len) == 0) { hit = line + i; break; }
        }
        if (!hit) { /* fewer than n fields => empty field */
            *fptr = line + line_len;
            *flen = 0;
            return;
        }
        field_start = (size_t)(hit - line) + sep_len;
    }
    for (size_t i = field_start; i + sep_len <= line_len; i++) {
        if (memcmp(line + i, sep, sep_len) == 0) {
            *fptr = line + field_start;
            *flen = i - field_start;
            return;
        }
    }
    *fptr = line + field_start;
    *flen = (field_start <= line_len) ? (line_len - field_start) : 0;
}

static int cmd_sort(const char *path, uint32_t options,
                    const char *sep, size_t sep_len, long key_field) {
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
            /* The sort key is computed from the chosen FIELD (whole line when no
             * separator is configured); the original line is still emitted. */
            const uint8_t *ksrc;
            size_t ksrc_len;
            extract_field(line, line_len, sep, sep_len, key_field, &ksrc, &ksrc_len);
            /* Safe upper bound on key length: 6 bytes/input byte + structural. */
            size_t cap = ksrc_len * 6 + 16;
            uint8_t *key = (uint8_t *)malloc(cap);
            if (!key) {
                exit_code = 1;
                fputs("collate: out of memory\n", stderr);
                break;
            }
            size_t need = collation_mf_get_sort_key(coll, ksrc, ksrc_len, key, cap);
            if (need > cap) {
                uint8_t *nk = (uint8_t *)realloc(key, need);
                if (!nk) {
                    free(key);
                    exit_code = 1;
                    fputs("collate: out of memory\n", stderr);
                    break;
                }
                key = nk;
                need = collation_mf_get_sort_key(coll, ksrc, ksrc_len, key, need);
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
    const char *sep = NULL; /* field separator (NULL => whole line) */
    long key_field = 0;     /* 1-based field for -k; 0 => unset */
    int key_set = 0;        /* explicit -k/--key seen */
    int sep_from_flag = 0;  /* -t/--field-separator seen (overrides env) */
    int only_switches = 0;  /* set once we see "--" */
    const char *lang_code = NULL;     /* explicit --lang/--sprache code */
    const char *inferred_lang = NULL; /* from a localized alias (e.g. --hilfe) */
    int want_help = 0, want_about = 0, want_version = 0;

    for (int i = 1; i < argc; i++) {
        const char *a = argv[i];
        if (!only_switches && strcmp(a, "--") == 0) {
            only_switches = 1;
            continue;
        }
        if (!only_switches && a[0] == '-' && a[1] != '\0' &&
            !(strcmp(a, "-") == 0)) {
            if (strcmp(a, "-h") == 0 || strcmp(a, "--help") == 0) {
                want_help = 1;
            } else if (strcmp(a, "--hilfe") == 0) {
                /* German help alias: infers German UI (an explicit --lang still
                 * wins). Aliases like this must stay disjoint from every English
                 * canonical option name (see the i18n skill's collision rule). */
                want_help = 1;
                if (!inferred_lang) inferred_lang = "de";
            } else if (strcmp(a, "--about") == 0) {
                want_about = 1;
            } else if (strcmp(a, "--version") == 0) {
                want_version = 1;
            } else if (strcmp(a, "--lang") == 0 || strcmp(a, "--sprache") == 0) {
                if (i + 1 >= argc) {
                    fprintf(stderr, "collate: %s requires a language code\n", a);
                    return 2;
                }
                lang_code = argv[++i];
            } else if (strncmp(a, "--lang=", 7) == 0) {
                lang_code = a + 7;
            } else if (strncmp(a, "--sprache=", 10) == 0) {
                lang_code = a + 10;
            } else if (strcmp(a, "-c") == 0 || strcmp(a, "--code-point") == 0) {
                options |= COLLATION_MF_CODE_POINT;
            } else if (strcmp(a, "-d") == 0 || strcmp(a, "--decimal") == 0
                       || strcmp(a, "--decimals") == 0 || strcmp(a, "--dec") == 0) {
                options |= COLLATION_MF_DECIMAL;
                options &= ~(uint32_t)COLLATION_MF_DECIMAL_COMMA;
            } else if (strcmp(a, "-s") == 0 || strcmp(a, "--scientific") == 0
                       || strcmp(a, "--sci") == 0) {
                options |= COLLATION_MF_SCIENTIFIC;
            } else if (strcmp(a, "-n") == 0 || strcmp(a, "--numeric") == 0
                       || strcmp(a, "--num") == 0) {
                options |= COLLATION_MF_SCIENTIFIC | COLLATION_MF_DECIMAL;
                options &= ~(uint32_t)COLLATION_MF_DECIMAL_COMMA;
            } else if (strncmp(a, "--scientific=", 13) == 0
                       || strncmp(a, "--sci=", 6) == 0
                       || strncmp(a, "--numeric=", 10) == 0
                       || strncmp(a, "--num=", 6) == 0) {
                /* Same SEP grammar as --decimal; --numeric also turns on
                 * digit-group absorption, --scientific does not. */
                const char *sep = strchr(a, '=') + 1;
                options |= COLLATION_MF_SCIENTIFIC;
                if (a[2] == 'n') options |= COLLATION_MF_DECIMAL;
                if (strcmp(sep, ".") == 0) {
                    options &= ~(uint32_t)COLLATION_MF_DECIMAL_COMMA;
                } else if (strcmp(sep, ",") == 0) {
                    options |= COLLATION_MF_DECIMAL_COMMA;
                } else {
                    fprintf(stderr,
                            "collate: decimal separator must be '.' or ',' "
                            "(got \"%s\")\n", sep);
                    return 2;
                }
            } else if (strncmp(a, "--decimal=", 10) == 0
                       || strncmp(a, "--decimals=", 11) == 0
                       || strncmp(a, "--dec=", 6) == 0) {
                /* Attached form only: a detached value would be ambiguous with
                 * the positional FILE argument. */
                const char *sep = strchr(a, '=') + 1;
                if (strcmp(sep, ".") == 0) {
                    options |= COLLATION_MF_DECIMAL;
                    options &= ~(uint32_t)COLLATION_MF_DECIMAL_COMMA;
                } else if (strcmp(sep, ",") == 0) {
                    options |= COLLATION_MF_DECIMAL | COLLATION_MF_DECIMAL_COMMA;
                } else {
                    fprintf(stderr,
                            "collate: --decimal separator must be '.' or ',' "
                            "(got \"%s\")\n", sep);
                    return 2;
                }
            } else if (strcmp(a, "--version-sort") == 0) {
                /* The explicit form of the default. Present so a later argument
                 * can override an earlier --decimal, per the CLI convention. */
                options &= ~(uint32_t)COLLATION_MF_DECIMAL;
            } else if (strcmp(a, "--field-separator") == 0) {
                if (i + 1 >= argc) {
                    fputs("collate: --field-separator requires an argument\n", stderr);
                    return 2;
                }
                sep = argv[++i];
                sep_from_flag = 1;
            } else if (strncmp(a, "--field-separator=", 18) == 0) {
                sep = a + 18;
                sep_from_flag = 1;
            } else if (a[1] == 't') { /* -t or -tSEP (SEP may be empty=>whole line) */
                if (a[2] != '\0') {
                    sep = a + 2;
                } else if (i + 1 < argc) {
                    sep = argv[++i];
                } else {
                    fputs("collate: -t requires an argument\n", stderr);
                    return 2;
                }
                sep_from_flag = 1;
            } else if (strcmp(a, "--key") == 0 || strncmp(a, "--key=", 6) == 0 ||
                       a[1] == 'k') {
                const char *val;
                if (strcmp(a, "--key") == 0) {
                    if (i + 1 >= argc) {
                        fputs("collate: --key requires an argument\n", stderr);
                        return 2;
                    }
                    val = argv[++i];
                } else if (strncmp(a, "--key=", 6) == 0) {
                    val = a + 6;
                } else { /* -k or -kN */
                    if (a[2] != '\0') {
                        val = a + 2;
                    } else if (i + 1 < argc) {
                        val = argv[++i];
                    } else {
                        fputs("collate: -k requires an argument\n", stderr);
                        return 2;
                    }
                }
                char *endp;
                long v = strtol(val, &endp, 10);
                if (*val == '\0' || *endp != '\0' || v < 1) {
                    fprintf(stderr, "collate: invalid field number '%s'\n", val);
                    return 2;
                }
                key_field = v;
                key_set = 1;
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

    /* Resolve the UI language once (all args parsed => later args win), then
     * handle terminal actions. Help/version/about must not be blocked by sort
     * argument validation, so they dispatch before it. */
    lang_t lang = resolve_lang(lang_code ? lang_code : inferred_lang);
    if (want_help) return print_help(lang);
    if (want_version) {
        printf("%s\n", collation_mf_version());
        return 0;
    }
    if (want_about) return print_about(lang);

    /* Field separator precedence: -t/--field-separator wins; else the
     * COLLATE_FIELD_SEP env default; else whole-line (IFS-style). */
    if (!sep_from_flag) {
        const char *env = getenv("COLLATE_FIELD_SEP");
        if (env && env[0] != '\0') sep = env;
    }
    size_t sep_len = sep ? strlen(sep) : 0;

    if (key_set && sep_len == 0) {
        fputs("collate: -k/--key requires a field separator "
              "(-t/--field-separator or COLLATE_FIELD_SEP)\n", stderr);
        return 2;
    }
    /* A separator with no explicit -k sorts by field 1. */
    if (sep_len > 0 && !key_set) key_field = 1;

    return cmd_sort(path, options, sep, sep_len, key_field);
}
