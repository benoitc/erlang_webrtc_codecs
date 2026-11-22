# Set up on your system

This page tells you what to install before you build webrtc_codecs, system
by system, and how to check the result. You need it once per machine, and
again when you want a codec the build left out.

## What the build needs

| Need | For |
|---|---|
| Erlang/OTP 29 or later, rebar3 | everything |
| a C compiler, CMake 3.16 or later, pkg-config | the native codecs |
| libopus | Opus |
| libvpx | VP8, VP9 |
| OpenH264 | H.264 |
| dav1d | AV1 decoding |
| libaom | AV1 encoding |
| the `ffmpeg` executable | capture, recording to files, some tests |
| the `ffplay` executable | the window and the speaker |

Only the first line is required. A codec whose library is missing is left
out of the build and the rest works; G.711 needs nothing. Install the
development package of a library, the one with its headers and its
pkg-config file.

## macOS

With [Homebrew](https://brew.sh):

```sh
brew install erlang rebar3 cmake pkg-config ffmpeg opus libvpx openh264 dav1d aom
```

`ffmpeg` brings `ffplay`. To capture, the terminal or the application that
runs the node needs the camera and microphone permissions, which macOS asks
for the first time a device is opened (System Settings, Privacy & Security).

Tested on macOS on Apple silicon with Homebrew.

## Debian

Debian 13 has every library. It packages Erlang 27, so take Erlang 29 from
elsewhere (see [Erlang/OTP 29](#erlangotp-29)).

```sh
sudo apt-get install build-essential cmake pkg-config ffmpeg \
    libopus-dev libvpx-dev libopenh264-dev libdav1d-dev libaom-dev
```

To capture, your user has to be in the `video` and `audio` groups:

```sh
sudo usermod -aG video,audio "$USER"
```

Tested on Debian 13 in the `erlang:29` Docker image.

## Ubuntu

The packages have the same names as on Debian, from 24.04 on:

```sh
sudo apt-get install build-essential cmake pkg-config ffmpeg \
    libopus-dev libvpx-dev libopenh264-dev libdav1d-dev libaom-dev
```

Ubuntu 24.04 ships Erlang 25: take Erlang 29 from elsewhere (see
[Erlang/OTP 29](#erlangotp-29)). Its libraries are older than the ones
tested (libvpx 1.14, libaom 3.8, dav1d 1.4, Opus 1.4). The packages were
checked to exist; the build was not run on Ubuntu.

## Alpine

```sh
apk add build-base cmake pkgconf ffmpeg \
    opus-dev libvpx-dev openh264-dev dav1d-dev aom-dev
```

Alpine 3.24 packages Erlang 28: use the `erlang:29-alpine` Docker image,
which also has rebar3, or see [Erlang/OTP 29](#erlangotp-29).

Tested on Alpine 3.24 in the `erlang:29-alpine` Docker image.

## Fedora

```sh
sudo dnf install gcc cmake pkgconf-pkg-config ffmpeg-free \
    opus-devel libvpx-devel openh264-devel libdav1d-devel libaom-devel
```

`openh264-devel` comes from the `fedora-cisco-openh264` repository, which
Fedora enables by default. Fedora 45 packages Erlang 27: take Erlang 29 from
elsewhere (see [Erlang/OTP 29](#erlangotp-29)). The packages were checked
to exist on Fedora 45; the build was not run on Fedora.

## FreeBSD

```sh
pkg install erlang-runtime29 cmake-core pkgconf ffmpeg opus libvpx openh264 dav1d aom
```

The versioned Erlang package installs outside the default `PATH`, and the
`rebar3` package brings another Erlang with it, so put this Erlang first and
use rebar3 as its release script:

```sh
export PATH=/usr/local/lib/erlang29/bin:$PATH
fetch -o rebar3 https://github.com/erlang/rebar3/releases/download/3.27.0/rebar3
chmod +x rebar3
./rebar3 compile
```

Tested on FreeBSD 15.1 on arm64.

## Windows

Windows is not supported. The native codecs are not built there: there is
no build hook for it. Capture and playback have code for Windows (dshow,
and FFmpeg run without a shell) that has never been run. G.711 is written
in Erlang and has no reason to fail, but nothing was tested. Use WSL 2
with one of the Linux sections above.

## Erlang/OTP 29

Where the system has no Erlang 29, any of these gives you one:

- [kerl](https://github.com/kerl/kerl): `kerl build 29.1 29.1 && kerl install 29.1 ~/erlang/29.1 && . ~/erlang/29.1/activate`
- [asdf](https://asdf-vm.com) or [mise](https://mise.jdx.dev) with their Erlang plugin
- Docker: the `erlang:29` (Debian) and `erlang:29-alpine` images

rebar3 is one file: download it from
<https://github.com/erlang/rebar3/releases> and make it executable.

## Build

```sh
rebar3 compile
```

The build prints one line per codec library it found:

```
-- webrtc_codecs: webrtc_codecs_opus_nif with opus 1.6.1
-- webrtc_codecs: webrtc_codecs_vpx_nif with vpx 1.17.0
-- webrtc_codecs: openh264 not found, webrtc_codecs_openh264_nif is not built
```

## Check what you got

```erlang
1> [{Name, Decode, Encode} || #{name := Name, decode := Decode, encode := Encode} <- webrtc_codecs:available()].
[{<<"opus">>,true,true},
 {<<"PCMU">>,true,true},
 {<<"PCMA">>,true,true},
 {<<"VP8">>,true,true},
 {<<"VP9">>,true,true},
 {<<"H264">>,true,true},
 {<<"AV1">>,true,true}]
```

Run it in `rebar3 shell`. A codec that is missing from the list was left
out: install its library and run `rebar3 compile` again.

## Make a missing library an error

For a build that must have given codecs, such as a release or CI, name
their libraries by their pkg-config names:

```sh
WEBRTC_CODECS_REQUIRE="opus;vpx;openh264;dav1d;aom" rebar3 compile
```

The build then fails when one is missing, or when CMake is.

## Build without native code

```sh
WEBRTC_CODECS_SKIP_NIF=1 rebar3 compile
```

Only G.711, capture, playback and files are there.

## Use it as a dependency

The package is experimental: pin the version, and read the CHANGELOG before
you move to another.

```erlang
{deps, [
    {webrtc_codecs, "0.1.1"}
]}.
```

The native build runs when rebar3 compiles the dependency, with the same
libraries and the same two variables.

## Notes

- A library installed in a place pkg-config does not know needs
  `PKG_CONFIG_PATH` to point at the directory of its `.pc` file.
- After you install or remove a library, `rebar3 compile` builds again with
  what is there; `rebar3 clean` removes the NIFs.
- On a machine without CMake the build prints a notice and goes on without
  native codecs, unless `WEBRTC_CODECS_REQUIRE` is set.
- The versions tested are Opus 1.5 and 1.6, libvpx 1.15 and 1.17, OpenH264
  2.6 and 2.7, dav1d 1.5, libaom 3.12 to 3.15, FFmpeg 7 to 9.
- An OpenH264 you or your distribution built is not covered by the H.264
  patent licence Cisco pays for its own binaries.
