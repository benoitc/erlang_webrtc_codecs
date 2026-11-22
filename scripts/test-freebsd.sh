#!/bin/sh
# Runs the checks on FreeBSD, in a virtual machine under QEMU: the
# official FreeBSD cloud image is booted, given Erlang/OTP 29, the codec
# libraries and FFmpeg from packages, and a copy of the sources is built
# and tested in it. Nothing is written to this directory.
#
#   scripts/test-freebsd.sh            compile, eunit, ct
#   scripts/test-freebsd.sh rebar3 dialyzer
#   scripts/test-freebsd.sh stop       stop the machine
#   scripts/test-freebsd.sh destroy    stop it and forget its disk
#
# You need qemu, ssh and xz; on macOS hdiutil makes the seed image, on
# other systems genisoimage or mkisofs. The image (600 MB) and the disk
# of the machine are kept in $WEBRTC_CODECS_FREEBSD_DIR, by default
# ~/.cache/webrtc_codecs/freebsd, so only the first run downloads and
# installs. The machine is left running between runs; `stop` ends it.
#
# The copy carries the dependencies already fetched in _build, so the
# machine does not need access to their repositories: run
# `rebar3 compile` here once first.
set -e
cd "$(dirname "$0")/.."
SRC=$PWD

RELEASE=${WEBRTC_CODECS_FREEBSD_RELEASE:-15.1-RELEASE}
DIR=${WEBRTC_CODECS_FREEBSD_DIR:-$HOME/.cache/webrtc_codecs/freebsd}
PORT=${WEBRTC_CODECS_FREEBSD_PORT:-52222}
PACKAGES="erlang-runtime29 cmake-core pkgconf opus libvpx openh264 dav1d aom ffmpeg"

case "$(uname -m)" in
    arm64 | aarch64) ARCH=aarch64 IMAGE_ARCH=arm64-aarch64 ;;
    x86_64 | amd64) ARCH=x86_64 IMAGE_ARCH=amd64 ;;
    *) echo "no FreeBSD image for $(uname -m)" >&2 && exit 1 ;;
esac
IMAGE=FreeBSD-$RELEASE-$IMAGE_ARCH-BASIC-CLOUDINIT-ufs.qcow2.xz
URL=https://download.freebsd.org/releases/VM-IMAGES/$RELEASE/${IMAGE_ARCH#*-}/Latest

vm() {
    ssh -q -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes \
        -o LogLevel=ERROR -o ConnectTimeout=5 -i "$DIR/id_ed25519" -p "$PORT" freebsd@127.0.0.1 "$@"
}

running() {
    [ -f "$DIR/qemu.pid" ] && kill -0 "$(cat "$DIR/qemu.pid")" 2>/dev/null
}

stop() {
    if running; then
        vm 'su -m root -c "shutdown -p now"' </dev/null >/dev/null 2>&1 || true
        for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
            running || break
            sleep 2
        done
        running && kill "$(cat "$DIR/qemu.pid")"
    fi
    rm -f "$DIR/qemu.pid"
}

# The image, checked against the checksum FreeBSD publishes with it.
fetch_image() {
    [ -f "$DIR/base-$RELEASE.qcow2" ] && return
    echo "downloading $IMAGE" >&2
    curl -fsSL -o "$DIR/$IMAGE" "$URL/$IMAGE"
    want=$(curl -fsSL "$URL/CHECKSUM.SHA256" | grep "($IMAGE)" | awk '{print $NF}')
    have=$( (sha256sum "$DIR/$IMAGE" 2>/dev/null || shasum -a 256 "$DIR/$IMAGE") | awk '{print $1}')
    [ -n "$want" ] && [ "$want" = "$have" ] || {
        echo "checksum of $IMAGE does not match" >&2
        rm -f "$DIR/$IMAGE"
        exit 1
    }
    xz -dc "$DIR/$IMAGE" >"$DIR/base-$RELEASE.qcow2.part"
    mv "$DIR/base-$RELEASE.qcow2.part" "$DIR/base-$RELEASE.qcow2"
    rm -f "$DIR/$IMAGE"
}

# A cloud-init seed that lets our key in as the user freebsd.
seed() {
    [ -f "$DIR/id_ed25519" ] || ssh-keygen -q -t ed25519 -N "" -C webrtc_codecs-test -f "$DIR/id_ed25519"
    rm -rf "$DIR/seed" "$DIR/seed.iso"
    mkdir "$DIR/seed"
    printf 'instance-id: webrtc-codecs-test\nlocal-hostname: freebsd-test\n' >"$DIR/seed/meta-data"
    printf '#cloud-config\nssh_authorized_keys:\n  - %s\n' "$(cat "$DIR/id_ed25519.pub")" >"$DIR/seed/user-data"
    if command -v hdiutil >/dev/null 2>&1; then
        hdiutil makehybrid -quiet -iso -joliet -default-volume-name cidata -o "$DIR/seed.iso" "$DIR/seed"
    elif command -v genisoimage >/dev/null 2>&1; then
        genisoimage -quiet -J -r -V cidata -o "$DIR/seed.iso" "$DIR/seed"
    else
        mkisofs -quiet -J -r -V cidata -o "$DIR/seed.iso" "$DIR/seed"
    fi
}

start() {
    running && return
    fetch_image
    [ -f "$DIR/disk.qcow2" ] ||
        qemu-img create -q -f qcow2 -b "$DIR/base-$RELEASE.qcow2" -F qcow2 "$DIR/disk.qcow2" 24G
    seed
    case "$(uname -s)" in
        Darwin) ACCEL=hvf ;;
        Linux) ACCEL=kvm ;;
        *) ACCEL=tcg ;;
    esac
    if [ "$ARCH" = aarch64 ]; then
        FIRMWARE=$(dirname "$(dirname "$(command -v qemu-system-aarch64)")")/share/qemu/edk2-aarch64-code.fd
        set -- -machine "virt,accel=$ACCEL" -cpu host -drive "if=pflash,format=raw,readonly=on,file=$FIRMWARE"
    else
        set -- -machine "q35,accel=$ACCEL" -cpu host
    fi
    # The sound card is there to try a microphone by hand: after
    # `kldload snd_hda` in the machine it is /dev/dsp0 and gives silence.
    "qemu-system-$ARCH" "$@" -smp 4 -m 4096 \
        -drive "if=virtio,file=$DIR/disk.qcow2,format=qcow2" \
        -drive "if=virtio,file=$DIR/seed.iso,format=raw,readonly=on" \
        -device virtio-net-pci,netdev=n0 -netdev "user,id=n0,hostfwd=tcp:127.0.0.1:$PORT-:22" \
        -audiodev none,id=snd -device intel-hda -device hda-duplex,audiodev=snd \
        -display none -serial "file:$DIR/serial.log" -daemonize -pidfile "$DIR/qemu.pid"
    for _ in $(seq 1 60); do
        vm true </dev/null 2>/dev/null && return
        sleep 3
    done
    echo "the machine did not come up; see $DIR/serial.log" >&2
    exit 1
}

# Packages, and rebar3 as its release script: the rebar3 package brings
# another Erlang with it.
provision() {
    vm 'test -f /usr/local/bin/rebar3 && test -f /var/db/webrtc_codecs_packages' </dev/null && return
    echo "installing packages in the machine" >&2
    vm "su -m root -c 'env ASSUME_ALWAYS_YES=yes pkg bootstrap -f >/dev/null 2>&1; pkg update -q &&
        pkg install -y -q $PACKAGES &&
        fetch -q -o /usr/local/bin/rebar3 https://github.com/erlang/rebar3/releases/download/3.27.0/rebar3 &&
        chmod +x /usr/local/bin/rebar3 && touch /var/db/webrtc_codecs_packages'" </dev/null
}

mkdir -p "$DIR"
case "${1:-}" in
    stop)
        stop
        exit 0
        ;;
    destroy)
        stop
        rm -f "$DIR/disk.qcow2" "$DIR/seed.iso" "$DIR/serial.log"
        rm -rf "$DIR/seed"
        exit 0
        ;;
esac

[ -d _build/default/lib/webrtc ] || {
    echo "run rebar3 compile first: _build/default/lib/webrtc is missing" >&2
    exit 1
}
start
provision

if [ $# -eq 0 ]; then
    set -- sh -c 'rebar3 compile && rebar3 eunit && rebar3 ct'
fi

# The sources without what this machine built, and the dependencies as
# rebar3 checkouts, which are compiled in place of fetched ones.
# COPYFILE_DISABLE keeps macOS from adding its ._ files to the archives.
vm 'rm -rf src && mkdir -p src/_checkouts/webrtc' </dev/null
COPYFILE_DISABLE=1 tar -c --no-xattrs \
    --exclude ./_build --exclude ./priv --exclude ./c_src/build --exclude ./c_src/build.log \
    --exclude ./doc --exclude ./.git -C "$SRC" . | vm 'tar -x -C src'
COPYFILE_DISABLE=1 tar -c --no-xattrs --exclude ./ebin --exclude ./_build \
    -C "$SRC/_build/default/lib/webrtc" . | vm 'tar -x -C src/_checkouts/webrtc'

# The versioned Erlang package installs outside the default PATH.
quoted=
for arg in "$@"; do
    quoted="$quoted '$(printf '%s' "$arg" | sed "s/'/'\\\\''/g")'"
done
vm "cd src && PATH=\$(ls -d /usr/local/lib/erlang29/bin):\$PATH &&
    export PATH WEBRTC_CODECS_REQUIRE='opus;vpx;openh264;dav1d;aom' &&
    erl -noshell -eval 'io:format(\"FreeBSD, OTP ~s~n\", [erlang:system_info(otp_release)]), halt().' &&
    $quoted" </dev/null
