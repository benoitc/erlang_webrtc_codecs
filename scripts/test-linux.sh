#!/bin/sh
# Runs the checks on Linux in Docker: a copy of the sources is built and
# tested in an image that has Erlang/OTP 29, the codec libraries and
# FFmpeg. Nothing is written to this directory.
#
#   scripts/test-linux.sh            compile, eunit, ct
#   scripts/test-linux.sh rebar3 dialyzer
#   WEBRTC_CODECS_LINUX=alpine scripts/test-linux.sh
#
# The image is Debian (glibc) by default, or Alpine (musl).
#
# The copy carries the dependencies already fetched in _build, so the
# container does not need access to their repositories: run
# `rebar3 compile` here once first.
set -e
cd "$(dirname "$0")/.."

DISTRO=${WEBRTC_CODECS_LINUX:-debian}
case "$DISTRO" in
    debian) DOCKERFILE=docker/Dockerfile.linux ;;
    alpine) DOCKERFILE=docker/Dockerfile.alpine ;;
    *) echo "WEBRTC_CODECS_LINUX is debian or alpine" >&2 && exit 1 ;;
esac
IMAGE=webrtc_codecs-$DISTRO
[ -d _build/default/lib/webrtc ] || {
    echo "run rebar3 compile first: _build/default/lib/webrtc is missing" >&2
    exit 1
}

docker build -q -t "$IMAGE" -f "$DOCKERFILE" docker >/dev/null

if [ $# -eq 0 ]; then
    set -- sh -c 'rebar3 compile && rebar3 eunit && rebar3 ct'
fi

# The sources without what this machine built, and the dependencies as
# rebar3 checkouts, which are compiled in place of fetched ones.
# COPYFILE_DISABLE keeps macOS from adding its ._ files to the archive.
COPYFILE_DISABLE=1 tar -c --no-xattrs \
    --exclude ./_build --exclude ./priv --exclude ./c_src/build --exclude ./c_src/build.log \
    --exclude ./doc --exclude ./.git . |
    docker run --rm -i \
        -v "$PWD/_build/default/lib/webrtc:/deps/webrtc:ro" \
        -e WEBRTC_CODECS_REQUIRE="opus;vpx;openh264;dav1d;aom" \
        "$IMAGE" sh -c '
            set -e
            tar -x -C /src
            mkdir -p /src/_checkouts/webrtc
            tar -c -C /deps/webrtc --exclude ./ebin --exclude ./_build . | tar -x -C /src/_checkouts/webrtc
            cd /src
            exec "$@"' sh "$@"
