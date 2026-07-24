/*
 * icu_sort.c — sort lines of a text file using ICU4C collation sort keys.
 *
 * Benchmark competitor for the "reproducible collation" project: this mirrors
 * the "precompute a binary sort key once per record, then compare many times
 * with memcmp" model. Reads the whole file into one heap buffer, indexes lines
 * in place, precomputes an ICU sort key per line, sorts an array of records by
 * memcmp of those keys (ties broken by raw line bytes for determinism), and
 * writes the sorted lines to a big buffered stdout.
 *
 * Compile (NixOS):
 *   cc -O2 -std=c11 -Wall -Wextra -o icu_sort bench/icu_sort.c \
 *       $(pkg-config --cflags --libs icu-uc icu-i18n)
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <unicode/ucol.h>
#include <unicode/ustring.h>
#include <unicode/utypes.h>

/* One indexed line plus its precomputed ICU collation sort key. */
typedef struct {
	const char *line; /* pointer into the file buffer (not NUL-terminated) */
	size_t line_len;  /* byte length of the line (excludes newline) */
	unsigned char *key; /* ICU binary sort key (NUL-terminated per ICU) */
	int32_t key_len;    /* length of key including trailing NUL */
} Record;

static void die(const char *msg) {
	fprintf(stderr, "icu_sort: %s\n", msg);
	exit(1);
}

/* Order by binary sort key (memcmp); break exact ties by raw line bytes so the
 * output is deterministic regardless of qsort's internal ordering. */
static int cmp_records(const void *a, const void *b) {
	const Record *ra = (const Record *)a;
	const Record *rb = (const Record *)b;
	int32_t n = ra->key_len < rb->key_len ? ra->key_len : rb->key_len;
	int c = memcmp(ra->key, rb->key, (size_t)n);
	if (c != 0) return c;
	if (ra->key_len != rb->key_len)
		return ra->key_len < rb->key_len ? -1 : 1;
	/* Tie-break on raw line bytes. */
	size_t m = ra->line_len < rb->line_len ? ra->line_len : rb->line_len;
	c = memcmp(ra->line, rb->line, m);
	if (c != 0) return c;
	if (ra->line_len != rb->line_len)
		return ra->line_len < rb->line_len ? -1 : 1;
	return 0;
}

int main(int argc, char **argv) {
	if (argc < 2) die("usage: icu_sort <file>");

	/* --- read the whole file into one heap buffer --- */
	FILE *f = fopen(argv[1], "rb");
	if (!f) die("cannot open input file");
	if (fseek(f, 0, SEEK_END) != 0) die("fseek failed");
	long sz = ftell(f);
	if (sz < 0) die("ftell failed");
	if (fseek(f, 0, SEEK_SET) != 0) die("fseek failed");

	char *buf = malloc((size_t)sz + 1);
	if (!buf) die("out of memory");
	size_t got = fread(buf, 1, (size_t)sz, f);
	if (got != (size_t)sz) die("short read");
	fclose(f);
	buf[sz] = '\0';

	/* --- index lines in place (final line may lack a trailing newline) --- */
	size_t cap = 1024, n = 0;
	Record *recs = malloc(cap * sizeof(*recs));
	if (!recs) die("out of memory");
	size_t start = 0;
	for (size_t i = 0; i < (size_t)sz; i++) {
		if (buf[i] == '\n') {
			if (n == cap) {
				cap *= 2;
				Record *tmp = realloc(recs, cap * sizeof(*recs));
				if (!tmp) die("out of memory");
				recs = tmp;
			}
			recs[n].line = buf + start;
			recs[n].line_len = i - start;
			recs[n].key = NULL;
			recs[n].key_len = 0;
			n++;
			start = i + 1;
		}
	}
	/* Trailing partial line with no newline. */
	if (start < (size_t)sz) {
		if (n == cap) {
			cap *= 2;
			Record *tmp = realloc(recs, cap * sizeof(*recs));
			if (!tmp) die("out of memory");
			recs = tmp;
		}
		recs[n].line = buf + start;
		recs[n].line_len = (size_t)sz - start;
		recs[n].key = NULL;
		recs[n].key_len = 0;
		n++;
	}

	/* --- open a realistic locale collator --- */
	UErrorCode status = U_ZERO_ERROR;
	UCollator *coll = ucol_open("en_US", &status);
	if (U_FAILURE(status)) {
		fprintf(stderr, "icu_sort: ucol_open failed: %s\n",
			u_errorName(status));
		exit(1);
	}

	/* --- precompute an ICU sort key per line --- */
	/* Reusable scratch buffers, grown as needed. */
	UChar *u16 = NULL;
	int32_t u16_cap = 0;
	for (size_t i = 0; i < n; i++) {
		int32_t needed16 = 0;
		UErrorCode s = U_ZERO_ERROR;
		/* Pre-flight to size the UTF-16 buffer (pass 0 capacity). */
		u_strFromUTF8(NULL, 0, &needed16, recs[i].line,
			(int32_t)recs[i].line_len, &s);
		/* Pre-flight sets s to U_BUFFER_OVERFLOW_ERROR; that's expected. */
		if (needed16 + 1 > u16_cap) {
			u16_cap = needed16 + 1;
			UChar *tmp = realloc(u16, (size_t)u16_cap * sizeof(UChar));
			if (!tmp) die("out of memory");
			u16 = tmp;
		}
		s = U_ZERO_ERROR;
		int32_t u16_len = 0;
		u_strFromUTF8(u16, u16_cap, &u16_len, recs[i].line,
			(int32_t)recs[i].line_len, &s);
		if (U_FAILURE(s)) die("u_strFromUTF8 failed");

		/* Size the sort key (pass 0 capacity), then produce it. */
		int32_t klen = ucol_getSortKey(coll, u16, u16_len, NULL, 0);
		if (klen <= 0) die("ucol_getSortKey sizing failed");
		unsigned char *key = malloc((size_t)klen);
		if (!key) die("out of memory");
		int32_t klen2 = ucol_getSortKey(coll, u16, u16_len, key, klen);
		if (klen2 != klen) die("ucol_getSortKey length mismatch");
		recs[i].key = key;
		recs[i].key_len = klen; /* includes ICU's trailing NUL */
	}
	free(u16);

	/* --- sort by sort key --- */
	qsort(recs, n, sizeof(*recs), cmp_records);

	/* --- write sorted lines via a big buffered stdout --- */
	static char outbuf[1 << 20];
	setvbuf(stdout, outbuf, _IOFBF, sizeof(outbuf));
	for (size_t i = 0; i < n; i++) {
		fwrite(recs[i].line, 1, recs[i].line_len, stdout);
		fputc('\n', stdout);
	}
	fflush(stdout);

	/* --- free ICU + heap resources --- */
	for (size_t i = 0; i < n; i++) free(recs[i].key);
	free(recs);
	free(buf);
	ucol_close(coll);
	return 0;
}
