#!/usr/bin/env bash
#
# mayhem/test.sh — RUN this repo's OWN functional test suite (already built by mayhem/build.sh).
# exit 0 = pass. EDIT per repo. PATCH-grade oracle: after an agent patches the source, the grader
# rebuilds (build.sh) then runs this. DELETE this file if the repo has no meaningful tests.
#
# IMPORTANT:
#  * Must assert BEHAVIOR/OUTPUT, not just exit status. The oracle has to check asserted values /
#    golden-output diffs / known-answer results — so a PATCH that "fixes" a bug by making the program
#    exit(0) (or any no-op) FAILS here. Running inputs and checking only "exit 0 / didn't crash" is
#    NOT a functional test (it's trivially reward-hackable) — use the project's real assertion suite.
#  * Do NOT build here — mayhem/build.sh already compiled the test suite (with the project's normal
#    flags). This script only RUNS the pre-built tests and reports counts. If the test runner is
#    missing, that's a build.sh bug — fail loudly rather than silently rebuilding.
#  * REQUIRED OUTPUT — a CTRF (https://ctrf.io) summary so Mayhem/the PATCH grader reads the counts:
#      - writes a CTRF JSON report to ${CTRF_REPORT:-$SRC/ctrf-report.json}, and
#      - prints a one-line `CTRF {...}` marker to stdout (same JSON, compact).
#    Only `results.summary` (with tests/passed/failed/pending/skipped/other) is required.
#    Use the emit_ctrf helper below; it computes tests = passed+failed+skipped and sets the exit
#    code (0 iff failed==0). Map your framework's output to passed/failed/skipped.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"   # build parallelism; env-overridable, falls back to nproc (use -j"$MAYHEM_JOBS")
cd "$SRC"   # u-boot's tests read fixtures relative to the source root

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker) and returns non-zero iff failed>0.
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

UBOOT="$SRC/mayhem/out/test/u-boot"
[ -x "$UBOOT" ] || { echo "missing $UBOOT: mayhem/build.sh must build it" >&2; emit_ctrf "u-boot-sandbox" 0 1; exit 1; }

passed=0; failed=0

# The sandbox's own unit-test suites. The `Tests run: N, ..., failures: F` summary line is mandatory: a
# neutered binary prints nothing, which counts as a failed suite, never a skip.
for suite in lib bloblist cmd hush env common; do
  out=$(timeout 600 "$UBOOT" -T -c "ut $suite" 2>&1 </dev/null)
  line=$(printf '%s\n' "$out" | grep -a -E '^Tests run: [0-9]+,' | tail -1)
  n=$(printf '%s' "$line" | sed -n 's/^Tests run: \([0-9]*\),.*/\1/p')
  f=$(printf '%s' "$line" | sed -n 's/.*failures: \([0-9]*\).*/\1/p')
  if [ -z "$n" ] || [ -z "$f" ] || [ "$n" -eq 0 ]; then
    echo "FAIL ut $suite: no summary line"; failed=$((failed + 1)); continue
  fi
  echo "ut $suite: $line"
  passed=$((passed + n - f)); failed=$((failed + f))
done

# Known-answer probes through the same binary: fixed memory contents / fixed arithmetic -> asserted values.
probe=$(timeout 120 "$UBOOT" -T -c 'mw.b 0 0x61 1; mw.b 1 0x62 1; mw.b 2 0x63 1; hash sha256 0 3; crc32 0 3; setexpr r 0x20 + 0xa; echo r=$r; setexpr s 100 * 3; echo s=$s' 2>&1 </dev/null)
kat() {  # kat <description> <expected substring>
  if printf '%s\n' "$probe" | grep -a -q -F -- "$2"; then
    echo "ok   kat $1"; passed=$((passed + 1))
  else
    echo "FAIL kat $1 (wanted: $2)"; failed=$((failed + 1))
  fi
}
kat "sha256(abc)" "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
kat "crc32(abc)" "352441c2"
kat "setexpr 0x20+0xa" "r=2a"
kat "setexpr 100*3" "s=300"

emit_ctrf "u-boot-sandbox-ut" "$passed" "$failed"
