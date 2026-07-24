/*
 * strcoll_sort.c — sort lines of a text file using glibc strcoll().
 *
 * This is the classic, non-reproducible locale collation the project is
 * replacing: strcoll() honors the process locale (LC_ALL/LANG from the
 * environment), so the order depends on the host's installed locale data.
 * Benchmark competitor: reads the whole file into one heap buffer, NUL-
 * terminates each line in place, sorts an array of char* by strcoll() (ties
 * broken by strcmp for determinism), and writes the sorted lines to a big
 * buffered stdout.
 *
 * Compile (host glibc):
 *   cc -O2 -std=c11 -Wall -Wextra -o strcoll_sort bench/strcoll_sort.c
 */
#include <locale.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void die(const char *msg) {
	fprintf(stderr, "strcoll_sort: %s\n", msg);
	exit(1);
}

/* Order by strcoll() (locale collation); break exact ties by strcmp so the
 * output is deterministic regardless of qsort's internal ordering. */
static int cmp_lines(const void *a, const void *b) {
	const char *sa = *(const char *const *)a;
	const char *sb = *(const char *const *)b;
	int c = strcoll(sa, sb);
	if (c != 0) return c;
	return strcmp(sa, sb);
}

int main(int argc, char **argv) {
	if (argc < 2) die("usage: strcoll_sort <file>");

	/* Collation order comes from the environment (LC_ALL/LANG). */
	setlocale(LC_ALL, "");

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

	/* --- index lines, NUL-terminating each in place --- */
	/* Final line may lack a trailing newline; the buf[sz] = '\0' above
	 * terminates it in that case. */
	size_t cap = 1024, n = 0;
	char **lines = malloc(cap * sizeof(*lines));
	if (!lines) die("out of memory");
	size_t start = 0;
	for (size_t i = 0; i < (size_t)sz; i++) {
		if (buf[i] == '\n') {
			buf[i] = '\0';
			if (n == cap) {
				cap *= 2;
				char **tmp = realloc(lines, cap * sizeof(*lines));
				if (!tmp) die("out of memory");
				lines = tmp;
			}
			lines[n++] = buf + start;
			start = i + 1;
		}
	}
	/* Trailing partial line with no newline (already NUL-terminated). */
	if (start < (size_t)sz) {
		if (n == cap) {
			cap *= 2;
			char **tmp = realloc(lines, cap * sizeof(*lines));
			if (!tmp) die("out of memory");
			lines = tmp;
		}
		lines[n++] = buf + start;
	}

	/* --- sort by locale collation --- */
	qsort(lines, n, sizeof(*lines), cmp_lines);

	/* --- write sorted lines (re-adding '\n') via big buffered stdout --- */
	static char outbuf[1 << 20];
	setvbuf(stdout, outbuf, _IOFBF, sizeof(outbuf));
	for (size_t i = 0; i < n; i++) {
		fputs(lines[i], stdout);
		fputc('\n', stdout);
	}
	fflush(stdout);

	free(lines);
	free(buf);
	return 0;
}
