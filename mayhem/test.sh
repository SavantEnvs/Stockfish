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
cd "$SRC"

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

# Stockfish's own test suites, run on the normally-built engine (build.sh -> /mayhem/stockfish_test),
# the same ones upstream's CI runs:
#  - tests/instrumented.py (CLI, interactive UCI, Syzygy probing, invalid FENs/options, bench files),
#    each test one CTRF test; the Syzygy tables are the Dockerfile's cache of the ones it downloads,
#  - tests/perft.sh (20 perft node counts, standard and Chess960), each position one test,
#  - tests/reprosearch.sh (search node counts reproducible across ucinewgame), one test,
# plus the `bench` signature against the "Bench: <n>" line upstream records in its commit messages
# (what upstream's tests/signature.sh checks in CI; skipped when no git history has one) and a few
# known-answer UCI checks: mate in one, a rejected FEN, an unloadable EvalFile, a FEN round trip.
SF="$SRC/stockfish_test"
[ -x "$SF" ] || { echo "missing $SF (mayhem/build.sh did not build it)" >&2; emit_ctrf stockfish-tests 0 1; exit 1; }

passed=0 failed=0 skipped=0
ok()   { echo "PASS $1"; passed=$((passed + 1)); }
bad()  { echo "FAIL $1"; failed=$((failed + 1)); }

# The upstream scripts run `./stockfish` from the cwd; in src/ that is the AFL build, so give them a
# scratch directory where it is the test binary.
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
ln -s "$SF" "$WORK/stockfish"

# tests/instrumented.py
SYZ=/opt/toolchains/deps/python-chess-syzygy
if [ ! -e "$SRC/tests/syzygy" ]; then
  if [ -d "$SYZ" ]; then ln -s "$SYZ" "$SRC/tests/syzygy"
  else bad "instrumented.py: no cached Syzygy tables at $SYZ (mayhem/Dockerfile)"; fi
fi
out=$(cd "$WORK" && timeout 1800 python3 "$SRC/tests/instrumented.py" --none "$SF" 2>&1); rc=$?
printf '%s\n' "$out" | tail -40
clean=$(printf '%s\n' "$out" | sed 's/\x1b\[[0-9;]*m//g')
summary=$(sed -n 's/^ *Tests: *\([0-9]*\) passed, \([0-9]*\) failed.*/\1 \2/p' <<<"$clean" | tail -1)
if [ -n "$summary" ]; then
  read -r p f <<<"$summary"
  passed=$((passed + p)); failed=$((failed + f))
  [ "$rc" -eq 0 ] || [ "$f" -gt 0 ] || bad "instrumented.py exited $rc"
  [ "$p" -gt 0 ] || bad "instrumented.py ran no tests"
else
  bad "instrumented.py printed no test summary (rc=$rc)"
fi

# tests/perft.sh
out=$(cd "$WORK" && timeout 1800 bash "$SRC/tests/perft.sh" 2>&1); rc=$?
p=$(grep -c '^Testing depth .*\.\.\. OK$' <<<"$out"); f=$(grep -c '^Testing depth .*FAILED' <<<"$out")
grep '^Testing depth\|failed' <<<"$out"
passed=$((passed + p)); failed=$((failed + f))
[ "$rc" -eq 0 ] || [ "$f" -gt 0 ] || bad "perft.sh exited $rc"
[ "$p" -gt 0 ] || bad "perft.sh ran no tests"

# tests/reprosearch.sh
out=$(cd "$WORK" && timeout 900 bash "$SRC/tests/reprosearch.sh" 2>&1); rc=$?
if [ "$rc" -eq 0 ] && grep -qx 'reprosearch testing OK' <<<"$out"; then ok "reprosearch.sh"
else printf '%s\n' "$out" | tail -5; bad "reprosearch.sh (rc=$rc)"; fi

# bench signature
ref=$(git -C "$SRC" log --format=%B 2>/dev/null | sed -n 's/^[Bb]ench[: ]*\([0-9][0-9]*\)[[:space:]]*$/\1/p' | head -1)
if [ -n "$ref" ]; then
  sig=$("$SF" bench 2>&1 >/dev/null | sed -n 's/^Nodes searched *: *\([0-9]*\).*/\1/p')
  if [ "$sig" = "$ref" ]; then ok "bench signature $sig"; else bad "bench signature (want $ref, got '${sig}')"; fi
else
  echo "SKIP bench signature: no 'Bench:' line in the git history"; skipped=$((skipped + 1))
fi

# mate in one: Ra1-a8#
# `go` searches asynchronously and EOF on stdin means `quit`, so keep stdin open until `bestmove`.
search() {  # search <uci commands...>: prints the engine's output up to and including bestmove
  local line
  coproc SFP { "$SF" 2>&1; }
  printf '%s\n' "$@" >&"${SFP[1]}"
  while IFS= read -r -t 60 line <&"${SFP[0]}"; do
    printf '%s\n' "$line"
    case "$line" in bestmove*) break ;; esac
  done
  printf 'quit\n' >&"${SFP[1]}" 2>/dev/null
  wait "$SFP_PID" 2>/dev/null
}
out=$(search 'position fen 6k1/5ppp/8/8/8/8/8/R5K1 w - - 0 1' 'go depth 6')
if grep -q '^bestmove a1a8' <<<"$out" && grep -q 'score mate 1 ' <<<"$out"; then ok "mate in one"; else bad "mate in one"; fi

# a FEN without kings is rejected with an error and a non-zero exit
out=$(printf 'position fen 8/8/8/8/8/8/8/8 w - - 0 1\nd\n' | "$SF" 2>&1); rc=$?
if [ "$rc" -ne 0 ] && grep -q 'CRITICAL ERROR' <<<"$out"; then ok "invalid FEN rejected"; else bad "invalid FEN rejected (rc=$rc)"; fi

# an EvalFile that cannot be loaded stops the engine at `go` with the network error
out=$(printf 'setoption name EvalFile value does-not-exist.nnue\ngo depth 1\n' | "$SF" 2>&1)
if grep -q 'The network file does-not-exist.nnue was not loaded successfully' <<<"$out"; then ok "bad EvalFile reported"; else bad "bad EvalFile reported"; fi

# the startpos FEN round-trips through `d`
out=$(printf 'position startpos moves e2e4 c7c5\nd\n' | "$SF" 2>&1)
if grep -qx 'Fen: rnbqkbnr/pp1ppppp/8/2p5/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 0 2' <<<"$out"; then ok "position d fen"; else bad "position d fen"; fi

emit_ctrf stockfish-tests "$passed" "$failed" "$skipped"
