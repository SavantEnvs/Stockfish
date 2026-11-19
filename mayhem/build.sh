#!/usr/bin/env bash
#
# mayhem/build.sh — build Stockfish's fuzz targets and its functional-test binary.
#
# Runs inside the commit image as `mayhem` in /mayhem. The base image exports CC/CXX,
# SANITIZER_FLAGS (ASan+UBSan, halting), LIB_FUZZING_ENGINE, STANDALONE_FUZZ_MAIN and SRC.
#
# Upstream's own Makefile (src/Makefile) compiles the engine three times, each into src/*.o:
#   1. normal flags (upstream's optimized `all`)        -> /mayhem/stockfish_test   (mayhem/test.sh)
#   2. clang++ + $SANITIZER_FLAGS + libFuzzer coverage  -> /mayhem/fuzz_search, /mayhem/fuzz_nnue
#                                                          (+ -standalone reproducers)
#   3. afl-clang-fast++ + $SANITIZER_FLAGS              -> /mayhem/uci_afl, /mayhem/syzygy_afl
# The harness objects are linked with every engine object except main.o.
#
# The NNUE network the engine embeds (src/evaluate.h EvalFileDefaultName, ~138 MB) is gitignored
# upstream and normally downloaded by scripts/net.sh. The Dockerfile caches it, sha256-checked, in
# /opt/toolchains/deps/stockfish-nnue/; this script copies it into src/ so the build runs offline and
# from a `git clean -ffdX`-ed tree. Upstream's `build` target is not used because its `net` step
# writes a 550 MB hex dump of the network on compilers without --embed-dir; `all` is what it runs.
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
: "${SF_NNUE_DIR:=/opt/toolchains/deps/stockfish-nnue}"
: "${SF_ARCH:=x86-64-sse41-popcnt}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC/src"

# 0) The embedded network(s): every nn-<sha256 prefix>.nnue named in evaluate.h.
for net in $(sed -n 's/^#define EvalFileDefaultName.*"\(nn-[a-z0-9]\{12\}\.nnue\)".*/\1/p' evaluate.h); do
  if [ ! -f "$net" ] || [ "nn-$(sha256sum "$net" | cut -c1-12).nnue" != "$net" ]; then
    cp "$SF_NNUE_DIR/$net" "$net"
  fi
done

MAKE_ARGS=(-j"$MAYHEM_JOBS" ARCH="$SF_ARCH" COMP=clang)

# The compile flags upstream's Makefile uses for its sources, so the harnesses see the same
# configuration macros (IS_64BIT, USE_SSE41, ...) as the engine objects they link against.
makefile_cxxflags() {
  make -s -n -B "$@" misc.o 2>/dev/null | sed -n 's/^[^ ]* \(.*\) -c -o misc\.o misc\.cpp$/\1/p' | tail -1
}
engine_objs() { ls *.o | grep -vx 'main\.o'; }

# 1) Test binary: upstream's normal optimized build (plus the optional COVERAGE_FLAGS).
make objclean
make "${MAKE_ARGS[@]}" EXTRACXXFLAGS="$COVERAGE_FLAGS" EXTRALDFLAGS="$COVERAGE_FLAGS" all
cp stockfish "$SRC/stockfish_test"

# 2) libFuzzer targets. -O1 (instead of upstream's -O3 -flto) keeps the sanitized build debuggable.
# debug=yes (what upstream's sanitizer CI uses) keeps the engine's asserts, incl. pos_is_ok(): with
# debug=no the Makefile appends -DNDEBUG after EXTRACXXFLAGS. It also adds -g -D_GLIBCXX_ASSERTIONS
# -D_GLIBCXX_DEBUG; the harnesses take the same flags (makefile_cxxflags), so the ABI matches, and
# the earlier -gdwarf-3 still sets the DWARF version.
FUZZ_CXXFLAGS="-O1 $SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link"
FUZZ_ARGS=(optimize=no debug=yes EXTRACXXFLAGS="$FUZZ_CXXFLAGS" EXTRALDFLAGS="$SANITIZER_FLAGS -fsanitize=fuzzer-no-link")
make objclean
make "${MAKE_ARGS[@]}" "${FUZZ_ARGS[@]}" all
CXXF=$(makefile_cxxflags "${MAKE_ARGS[@]}" "${FUZZ_ARGS[@]}")
[ -n "$CXXF" ] || { echo "could not read the compile flags from src/Makefile" >&2; exit 1; }
OBJS=$(engine_objs)
H="$SRC/mayhem/harnesses"
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.cc" -o "$SRC/mayhem/lsan_off.o"
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o "$SRC/mayhem/standalone_main.o"
for h in fuzz_search fuzz_nnue; do
  # shellcheck disable=SC2086
  $CXX $CXXF -I. -I"$H" -c "$H/$h.cpp" -o "$SRC/mayhem/$h.o"
  # shellcheck disable=SC2086
  $CXX $SANITIZER_FLAGS $DEBUG_FLAGS $LIB_FUZZING_ENGINE "$SRC/mayhem/$h.o" $OBJS "$SRC/mayhem/lsan_off.o" \
    -pthread -o "$SRC/$h"
  # shellcheck disable=SC2086
  $CXX $SANITIZER_FLAGS $DEBUG_FLAGS "$SRC/mayhem/standalone_main.o" "$SRC/mayhem/$h.o" $OBJS \
    "$SRC/mayhem/lsan_off.o" -pthread -o "$SRC/$h-standalone"
done

# 3) AFL file-input targets (the engine exit()s on some inputs, so these run one process per input).
AFL_ARGS=(CXX=afl-clang-fast++ optimize=no debug=yes EXTRACXXFLAGS="-O1 $SANITIZER_FLAGS $DEBUG_FLAGS" EXTRALDFLAGS="$SANITIZER_FLAGS")
make objclean
make "${MAKE_ARGS[@]}" "${AFL_ARGS[@]}" all
CXXF=$(makefile_cxxflags "${MAKE_ARGS[@]}" "${AFL_ARGS[@]}")
[ -n "$CXXF" ] || { echo "could not read the compile flags from src/Makefile" >&2; exit 1; }
OBJS=$(engine_objs)
afl-clang-fast++ $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.cc" -o "$SRC/mayhem/lsan_off_afl.o"
for h in uci syzygy; do
  # shellcheck disable=SC2086
  afl-clang-fast++ $CXXF -I. -I"$H" -c "$H/${h}_file.cpp" -o "$SRC/mayhem/${h}_file.o"
  # shellcheck disable=SC2086
  afl-clang-fast++ $SANITIZER_FLAGS $DEBUG_FLAGS "$SRC/mayhem/${h}_file.o" $OBJS "$SRC/mayhem/lsan_off_afl.o" \
    -pthread -o "$SRC/${h}_afl"
done

echo "built: $SRC/stockfish_test $SRC/fuzz_search $SRC/fuzz_nnue $SRC/uci_afl $SRC/syzygy_afl"
