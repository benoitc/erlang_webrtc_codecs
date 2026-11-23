# Agents

Instructions for AI coding agents working on erlang_webrtc_codecs. Read this
file before you change anything; it applies to every agent and every change.

## Project Overview

Codec plugins for [erlang_webrtc](https://github.com/benoitc/erlang_webrtc):
modules with the `webrtc_media_codec` behaviour that decode the frames a
transceiver receives and encode the raw media an application sends, plus
device capture and playback. erlang_webrtc stays pure Erlang; this package is
where native code comes in. Requires Erlang/OTP 29 or later and rebar3. Native
codecs also need CMake, a C compiler and the codec libraries.

## First principle: the VM survives, the transport is not held up

A plugin runs inside the transport process of a peer connection, on data a
remote peer chose. Every change to a plugin, a NIF or a port must hold these
before it is called done, committed or opened as a pull request:

1. **No crash, no leak.** Native code checks every size and every return
   code and gives `{error, Reason}`; it never trusts a length found in the
   media. Codec contexts live in resource objects freed by a destructor.
   Anything that can block or crash on its own (a device, FFmpeg) runs in a
   port, not in the VM.
2. **No blocked scheduler.** Codec work runs on dirty CPU schedulers. A
   normal scheduler never waits on a codec, a device or a lock a dirty call
   holds.
3. **Bounded.** No queue, buffer or picture size grows with what a peer
   sends. A video decoder refuses a picture over `max_pixels` before the
   library allocates for it, and that means everything the library will
   read in the call: every frame of a superframe, every parameter set, on
   the size as coded rather than as shown, and nothing the check did not
   see. What cannot be read is refused, not tried. A frame that cannot be
   decoded is dropped and reported, not kept and not retried.
   [docs/limits.md](docs/limits.md) lists every limit: add yours to it.
4. **The plugin stays on.** erlang_webrtc turns a plugin off for good when
   it raises or returns `{error, Reason}`. Bad media from the peer is not an
   error: `decode/2` returns a `t:webrtc_codecs:dropped/0` output, counted in
   `framesDropped`. What the application got wrong (raw media in the wrong
   format) is `{error, Reason, State}`, which loses one picture and leaves
   the plugin on. `{error, Reason}` is for a codec that cannot start.

5. **An external program has one owner and an end.** FFmpeg and ffplay are
   started through `webrtc_codecs_exec`, without a shell. Media to or from
   them goes through a socket or a write that cannot block for ever, with a
   deadline. Whatever the program does, stopping returns and the program is
   gone: waited for, asked to end, then killed. What it says is kept short.

Each of these has a test: a truncated or corrupt frame for the first and
third, the error path for the fourth, a program that misbehaves
(`test/fake_ffmpeg.escript`) for the fifth. A constructor's failure paths
are run with fault injection.

A plugin with native contexts closes them in `terminate/1`, and where it
replaces one. Every NIF call on a context goes through `WC_ENTER`, so a
closed context answers `{error, closed}`.

In a constructor, nothing is read from a resource after
`enif_release_resource`: the release may free it. Constructors use
`wc_resource`, `wc_mutex`, `wc_new_failed` and `wc_new_ok` of
`c_src/webrtc_codecs_nif.h`, which hold that rule, and ask `wc_fail()`
before creating the codec.

## Do not change erlang_webrtc to suit a plugin

When the behaviour lacks something, write it down in
[docs/behaviour-gaps.md](docs/behaviour-gaps.md) and ask the maintainer. Work
within the behaviour as it is.

## Required Checks

Every change must be formatted and pass all checks before committing. This
list matches what CI gates on; see [CONTRIBUTING.md](CONTRIBUTING.md) for the
rest of the workflow.

```bash
rebar3 fmt                  # Auto-format (always run first)
rebar3 compile              # Must compile cleanly
rebar3 eunit                # Unit tests
rebar3 ct                   # Suites that run the plugins in erlang_webrtc
rebar3 fmt --check          # CI fails on unformatted code
rebar3 lint                 # Elvis linter must pass
rebar3 dialyzer             # Type checking must pass
rebar3 xref                 # Cross-reference analysis must pass
rebar3 ex_doc               # Docs must build
```

For a change to native code, also `scripts/test-sanitizers.sh`: the unit
tests and the lifecycle suite with the NIFs built with ASan, UBSan and fault
injection.

## Platforms

macOS, Linux and FreeBSD; Windows is not supported. A change to native code, to the build or to a
port program is run on all three before it is committed:
`rebar3 eunit && rebar3 ct` here, `scripts/test-linux.sh` (Docker, Debian
and with `WEBRTC_CODECS_LINUX=alpine` Alpine) and `scripts/test-freebsd.sh`
(QEMU). What each system needs installed is in
[docs/install.md](docs/install.md): keep it in step when a library is added. Behaviour differs between them where the
operating system is involved: on Linux a write to a program that has exited
closes the port with `epipe`, on macOS the exit status comes first.

## Pull Requests

Work on one item goes in one pull request. Give each change a reviewer has to
look at its own commit, with its tests, rather than opening a pull request per
change. Docs and CHANGELOG entries go in the same pull request.

- Every bug fix and feature has a test. Show it failing on main.
- Never relax a limit or a check to make a peer or a file pass; exclude the
  legitimate case precisely.
- Descriptions state what was wrong, the fix in a few lines, and breaking
  changes. Reference issues with `Fixes #N`. No test plan, no file-by-file
  walkthrough.
- No `Co-Authored-By`, "Generated with" or similar trailers, in commits or
  pull requests.
- CHANGELOG: plain English, what was wrong or what is new and what it means
  for the user. No implementation details.
- Follow "Write for the person who reads it" in
  [CONTRIBUTING.md](CONTRIBUTING.md#write-for-the-person-who-reads-it): plain
  English, no inflated or pseudo-technical wording, and a person has read the
  change before it is opened.

## Documentation

Guides are task-oriented and in the second person. Each page opens with one
paragraph saying what it is and when you need it, then concrete steps with
little prose between code blocks, then short notes. Snippets are in Erlang.

## Architecture

### Module Layers

**Public API:** `webrtc_codecs.erl`: `available/0`, the raw media types, and
the plugin that calls the module of the negotiated codec.

**Codec plugins:** one module per codec family, each with the
`webrtc_media_codec` behaviour plus `codecs/0`, the codecs it can run in this
build (none when its native library is missing). `webrtc_codecs_opus.erl`
(libopus), `webrtc_codecs_vpx.erl` (VP8 and VP9, libvpx),
`webrtc_codecs_h264.erl` (OpenH264), `webrtc_codecs_av1.erl` (dav1d to
decode, libaom to encode), `webrtc_codecs_g711.erl` (PCMU and PCMA, pure Erlang). To add one, write the module and add it to
`?MODULES` in `webrtc_codecs.erl`.

**Video logic:** `webrtc_codecs_video.erl` holds what the video plugins
share: the picture size limit, waiting for a key frame after a frame that
was not decoded, bitrate and key frame requests, timestamps and statistics.
A video plugin implements its callbacks (the library calls and
`frame_info/2`, which reads a frame header) and delegates the rest.

**Native code:** `c_src/CMakeLists.txt` builds one NIF per codec library
pkg-config finds, into `priv/`; `c_src/build_nif.sh` runs it from the rebar3
compile hook. Each NIF has a private Erlang module, `webrtc_codecs_<lib>_nif`,
that loads without it: `loaded/0` is then false and the codec is not listed.
`c_src/webrtc_codecs_nif.h` holds the helpers the NIFs share.
`WEBRTC_CODECS_REQUIRE="opus;vpx;openh264;dav1d;aom"` fails the build when a library is missing,
`WEBRTC_CODECS_SKIP_NIF=1` skips native code.

**Devices and files:** `webrtc_codecs_capture.erl`, a process that runs
`ffmpeg` on a camera, a microphone, a file or a generated source
and sends raw media, or with `encode` frames FFmpeg encoded, to its owner,
dropping when the owner is behind. Three internal modules do its parts:
`webrtc_codecs_capture_devices.erl` lists devices,
`webrtc_codecs_capture_command.erl` builds FFmpeg's command line, and
`webrtc_codecs_capture_stream.erl` cuts what FFmpeg writes and holds the
drop policy.
`webrtc_codecs_playback.erl`, a process that owns an `ffplay` or `ffmpeg`
port and writes raw media to a window, the speaker or a file.
`webrtc_codecs_exec.erl` owns the program for both: its port, the end of
what it says, and its end. `webrtc_codecs_file.erl` reads and writes IVF
and WAV in Erlang. Devices
never go through a NIF.

**Demo:** `examples/browser_media/` shows the camera and the microphone of
the machine in a browser, see [docs/demo.md](docs/demo.md). It is not
compiled with the application.

**Test media:** `webrtc_codecs_pattern.erl` (a moving picture, a tone, PSNR
and SNR).

### Raw media

What `decode/2` gives and `encode/2` takes, see
[docs/raw-media.md](docs/raw-media.md):

- pictures are I420 planes without padding, `t:webrtc_codecs:picture/0`;
- audio is signed 16 bit little endian, interleaved, `t:webrtc_codecs:audio/0`;
- timestamps are in the RTP clock of the negotiated codec in both directions;
- `keyframe` and `bitrate` travel in the raw map given to `encode/2`, because
  the behaviour has no other way in.

### Test Organization

- `test/webrtc_codecs_*_tests.erl`: EUnit, the modules on their own. Tests
  that compare with FFmpeg skip themselves when `ffmpeg` is not installed,
  and the tests of a native codec when its library was not there at build
  time. CI sets `WEBRTC_CODECS_REQUIRE` so that a skip there is a failure.
- `test/webrtc_codecs_video_checks.erl`: the checks every video plugin runs
  (round trip, bitrate, key frames, damaged and oversized frames, random
  input); `test/webrtc_codecs_test_media.erl` reads the encoded video of
  `test/corpus` and uses FFmpeg as a reference decoder.
- `test/webrtc_codecs_nif_tests.erl`: every native constructor, with each
  of its allocations made to fail in turn in a fault injection build.
- `test/webrtc_codecs_docs_tests.erl`: the module map against the source
  tree, the links between pages, the pages of the documentation build, and
  that the calls in the code blocks of the guides exist.
- `test/webrtc_codecs_peer_SUITE.erl`: Common Test, the plugins and the
  captures inside two erlang_webrtc peer connections on loopback.
- `test/webrtc_codecs_lifecycle_SUITE.erl`: native contexts shared between
  processes, left by killed owners, fed bad media for long, created and
  dropped in numbers, with timings and memory in the log.
- `test/fake_ffmpeg.escript`: stands in for FFmpeg in the capture and
  playback tests and misbehaves on demand (floods, stops reading, ignores
  the end of input and SIGTERM).
- `test/webrtc_codecs_browser_SUITE.erl`: the video plugins against headless
  Chromium, both ways, through the browser peer of erlang_webrtc's interop
  suite. It skips itself when that peer is not installed, which is the case
  in CI.

## Linting Notes

Elvis rules are configured in `elvis.config`, the only lint configuration.
`rebar3 lint` reads that file and ignores any `{elvis, ...}` entry in
`rebar.config` while it exists. Notable exceptions:

- `webrtc_codecs` is excluded from `no_invalid_dynamic_calls`: it calls the
  plugin module of the negotiated codec.
- Atom naming regex: `^[a-z](_?[a-zA-Z0-9]+)*(_SUITE)?$`
