#!/usr/bin/env bash
#
# mayhem/test.sh — RUN upstream's Unity unit tests (built by mayhem/build.sh into build/tests/tests).
# Each test binary is executed directly and its own Unity summary line ("N Tests F Failures I Ignored")
# is parsed. ctest is deliberately not used: it only sees exit codes, so a neutered (exit(0)) binary
# would pass; a neutered binary prints no summary, which here counts as a failure.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
cd "$SRC"

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

DIR="$SRC/build/tests/tests"
passed=0; failed=0; skipped=0; nbin=0
for exe in "$DIR"/test_*; do
  [ -f "$exe" ] && [ -x "$exe" ] || continue
  nbin=$((nbin + 1))
  out="$(cd "$DIR" && timeout 120 "$exe" 2>&1)"; rc=$?
  summary="$(printf '%s\n' "$out" | grep -E '^[0-9]+ Tests [0-9]+ Failures [0-9]+ Ignored' | tail -1)"
  if [ -z "$summary" ]; then
    echo "FAIL $(basename "$exe"): no Unity summary (rc=$rc)"; printf '%s\n' "$out" | tail -5
    failed=$((failed + 1)); continue
  fi
  read -r n _ f _ i _ <<<"$summary"
  p=$((n - f - i))
  echo "$(basename "$exe"): $summary (rc=$rc)"
  [ "$rc" -eq 0 ] || [ "$f" -gt 0 ] || f=1
  passed=$((passed + p)); failed=$((failed + f)); skipped=$((skipped + i))
done

# A missing suite is a build.sh bug, never a skip: coturn ships at least 15 test binaries.
if [ "$nbin" -lt 15 ]; then
  echo "FAIL: only $nbin test binaries found in $DIR (expected >= 15)"
  failed=$((failed + 1))
fi
emit_ctrf "unity" "$passed" "$failed" "$skipped"
