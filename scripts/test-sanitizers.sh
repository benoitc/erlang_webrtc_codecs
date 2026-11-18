#!/bin/sh
# Runs the tests on Linux in Docker with the NIFs built with the address
# and undefined behaviour sanitizers and with fault injection, so the
# tests that make allocations fail run too. A report from a sanitizer
# ends the emulator and fails the run.
#
#   scripts/test-sanitizers.sh            eunit, then the lifecycle suite
#   scripts/test-sanitizers.sh rebar3 eunit --module=webrtc_codecs_opus_tests
#
# The emulator itself is not instrumented: the sanitizer runtime is
# preloaded into it. Leak detection is off, since it would report the
# emulator's own memory at exit.
set -e
cd "$(dirname "$0")/.."

if [ $# -eq 0 ]; then
    set -- sh -c 'rebar3 eunit && rebar3 ct --suite=test/webrtc_codecs_lifecycle_SUITE'
fi

exec scripts/test-linux.sh sh -c '
    export WEBRTC_CODECS_SANITIZE=ON WEBRTC_CODECS_FAULT_INJECTION=ON
    rebar3 as test compile
    LD_PRELOAD=$(gcc -print-file-name=libasan.so):$(gcc -print-file-name=libubsan.so)
    export LD_PRELOAD
    export ASAN_OPTIONS=detect_leaks=0:abort_on_error=1:halt_on_error=1
    export UBSAN_OPTIONS=print_stacktrace=1:halt_on_error=1
    # The emulator allocates through malloc instead of its own carriers,
    # or the sanitizer would not see a resource being freed.
    export ERL_FLAGS="+Mea min"
    exec "$@"' sh "$@"
