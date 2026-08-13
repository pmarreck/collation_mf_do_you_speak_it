#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#define main collate_program_main
#include "../../cli/main.c"
#undef main

static size_t zero_sort_key(const rcol_collator *coll,
		const uint8_t *s, size_t slen, uint8_t *out, size_t out_cap) {
	(void)coll;
	(void)s;
	(void)slen;
	(void)out;
	(void)out_cap;
	return 0;
}

int main(void) {
	int passed = 0;
	int failed = 0;
	uint8_t *key = (uint8_t *)(uintptr_t)1;
	size_t key_len = 99;

	if (build_sort_key(zero_sort_key, NULL, (const uint8_t *)"x", 1,
			&key, &key_len) == SORT_KEY_BUILD_FAILED
		&& key == NULL && key_len == 0) {
		passed++;
	} else {
		failed++;
	}

	rcol_collator *coll = rcol_open(0);
	if (coll != NULL
		&& build_sort_key(rcol_get_sort_key, coll, (const uint8_t *)"", 0,
			&key, &key_len) == SORT_KEY_OK
		&& key != NULL && key_len > 0) {
		passed++;
	} else {
		failed++;
	}
	free(key);
	if (coll != NULL) rcol_close(coll);

	row_t row = {
		.line = (const uint8_t *)"x",
		.line_len = 1,
		.key = NULL,
		.key_len = 0,
	};
	FILE *read_only = fopen(__FILE__, "rb");
	if (read_only != NULL && write_rows(read_only, &row, 1) != 0) {
		passed++;
	} else {
		failed++;
	}
	if (read_only != NULL) fclose(read_only);

	printf("cli_key_failure: %d passed, %d failed\n", passed, failed);
	return failed;
}
