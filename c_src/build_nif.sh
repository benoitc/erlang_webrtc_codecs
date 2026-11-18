#!/bin/sh
# Builds the codec NIFs for rebar3, one per codec library found.
#
# Without cmake nothing is built and the package keeps the codecs written
# in Erlang. With cmake, a build that fails fails the compile.
# WEBRTC_CODECS_SKIP_NIF=1 skips the build; WEBRTC_CODECS_REQUIRE="opus"
# (pkg-config names, separated by ;) fails it when a library is missing.
set -e
cd "$(dirname "$0")"

case "${1:-build}" in
    build)
        [ "$WEBRTC_CODECS_SKIP_NIF" = 1 ] && exit 0
        if ! command -v cmake >/dev/null 2>&1; then
            if [ -n "$WEBRTC_CODECS_REQUIRE" ]; then
                echo "webrtc_codecs: WEBRTC_CODECS_REQUIRE is set but cmake is not installed" >&2
                exit 1
            fi
            echo "webrtc_codecs: cmake not found, native codecs are not built" >&2
            exit 0
        fi
        cmake -S . -B build -DWEBRTC_CODECS_REQUIRE="$WEBRTC_CODECS_REQUIRE" >build.log 2>&1 &&
            cmake --build build >>build.log 2>&1 || {
            cat build.log >&2
            echo "webrtc_codecs: the native build failed; fix it or set WEBRTC_CODECS_SKIP_NIF=1" >&2
            exit 1
        }
        grep "^-- webrtc_codecs:" build.log || true
        ;;
    clean)
        rm -rf build build.log ../priv/*.so
        ;;
esac
