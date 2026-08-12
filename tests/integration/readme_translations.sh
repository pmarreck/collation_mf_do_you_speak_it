#!/usr/bin/env bash
# Integration test: every supported Romance-language README exists and carries
# the same reciprocal language selector as English. This treats the selector as
# a set, so a missing or one-way translation link cannot pass by coincidence.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "  ok: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1 -- $2" >&2; }

readmes=(README.md README.fr.md README.es.md README.it.md README.pt_br.md README.ca.md README.ro.md)
for readme in "${readmes[@]}"; do
	path="$REPO_ROOT/$readme"
	if [[ -f "$path" ]]; then
		pass "$readme exists"
	else
		fail "$readme exists" "missing $path"
		continue
	fi
	for target in "${readmes[@]}"; do
		if [[ "$readme" == "$target" ]]; then continue; fi
		if rg -Fq "($target)" "$path"; then
			pass "$readme links $target"
		else
			fail "$readme links $target" "selector has no ($target)"
		fi
	done
done

echo ""
echo "readme_translations: $PASS passed, $FAIL failed"
exit $FAIL
