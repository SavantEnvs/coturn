#!/usr/bin/env bash
#
# mayhem/build.sh — build coturn's fuzz harnesses (upstream's own fuzzing/Fuzz*.c, built through
# upstream's CMake -DFUZZER=ON recipe) plus its unit-test suite.
#
# Runs inside the commit image (mayhem/Dockerfile) as `mayhem` in /mayhem. Re-runnable and offline:
# every dependency is an apt -dev package or the pinned Unity checkout at $UNITY_SRC.
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
: "${UNITY_SRC:=/opt/toolchains/unity}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"
TARGETS="FuzzStun FuzzStunClient"

# Every build dir lives under build/, which upstream's .gitignore (`/build`) already covers.
# The fuzz dirs are rebuilt from scratch: re-running cmake in place over an existing -DFUZZER=ON tree
# drops the FuzzStun/FuzzStunClient rules from the top-level Makefile ("No rule to make target").
rm -rf build/fuzz
mkdir -p build/fuzz

# 1) Sanitized fuzz build. -DFUZZING_BUILD_MODE_UNSAFE_FOR_PRODUCTION is upstream's OSS-Fuzz define
#    (deterministic crypto/random paths in src/client/ns_turn_msg.c). -fsanitize=fuzzer-no-link puts
#    SanCov on the library; the engine itself is linked into the harnesses only.
FUZZ_CFLAGS="-O1 $SANITIZER_FLAGS $DEBUG_FLAGS -DFUZZING_BUILD_MODE_UNSAFE_FOR_PRODUCTION"

# LeakSanitizer off at build time: a TU linked into every harness (ASan/UBSan stay on).
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.cc" -o build/fuzz/lsan_off.o
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o build/fuzz/standalone_main.o

configure_variant() { # <dir> <extra cflags> <engine>
  cmake -S . -B "$1" -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
    -DFUZZER=ON -DLIB_FUZZING_ENGINE="$3" \
    -DCMAKE_C_FLAGS="$FUZZ_CFLAGS $2" -DCMAKE_CXX_FLAGS="$FUZZ_CFLAGS $2" \
    -DCMAKE_EXE_LINKER_FLAGS="$SRC/build/fuzz/lsan_off.o"
}

configure_variant build/fuzz/engine "-fsanitize=fuzzer-no-link" "$LIB_FUZZING_ENGINE"
configure_variant build/fuzz/standalone "" "$SRC/build/fuzz/standalone_main.o"
for v in engine standalone; do
  cmake --build "build/fuzz/$v" -j"$MAYHEM_JOBS" --target $TARGETS
done
for t in $TARGETS; do
  install -m 0755 "build/fuzz/engine/fuzzing/$t" "/mayhem/$t"
  install -m 0755 "build/fuzz/standalone/fuzzing/$t" "/mayhem/$t-standalone"
done

# 2) Unit-test suite with the project's NORMAL flags (no sanitizers, no DWARF pin), in its own dir.
#    Unity comes from the in-image checkout, so nothing is fetched.
env -u CFLAGS -u CXXFLAGS cmake -S . -B build/tests -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
  -DBUILD_TESTING=ON -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_FLAGS="$COVERAGE_FLAGS" -DCMAKE_CXX_FLAGS="$COVERAGE_FLAGS" \
  -DFETCHCONTENT_SOURCE_DIR_UNITY="$UNITY_SRC" -DFETCHCONTENT_FULLY_DISCONNECTED=ON
cmake --build build/tests -j"$MAYHEM_JOBS"
