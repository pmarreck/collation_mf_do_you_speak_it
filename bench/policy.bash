#!/usr/bin/env bash
# Pure benchmark-policy functions. Safe to source from ./bm and unit tests.

readonly COMPLEXITY_RATIO_MIN="1.5"
readonly COMPLEXITY_RATIO_MAX="3.0"
readonly COMPLEXITY_WORK_TO_STARTUP_MIN="5.0"

# Classify one per-doubling ratio against the agreed half-open gate [1.5, 3.0).
complexity_ratio_verdict() {
	local ratio="$1"
	awk -v ratio="$ratio" \
		-v minimum="$COMPLEXITY_RATIO_MIN" \
		-v maximum="$COMPLEXITY_RATIO_MAX" \
		'BEGIN { print (ratio >= minimum && ratio < maximum) ? "pass" : "fail" }'
}

complexity_ratio_failure_kind() {
	local ratio="$1"
	awk -v ratio="$ratio" \
		-v minimum="$COMPLEXITY_RATIO_MIN" \
		-v maximum="$COMPLEXITY_RATIO_MAX" \
		'BEGIN {
			if (ratio < minimum) print "unexpectedly low";
			else if (ratio >= maximum) print "unexpectedly high";
			else print "none";
		}'
}

# Fixed process startup must account for at most 20% of the smallest workload.
complexity_workload_verdict() {
	local work_to_startup="$1"
	awk -v multiple="$work_to_startup" \
		-v minimum="$COMPLEXITY_WORK_TO_STARTUP_MIN" \
		'BEGIN { print (multiple >= minimum) ? "pass" : "fail" }'
}
