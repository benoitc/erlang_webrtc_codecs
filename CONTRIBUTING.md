# Contributing

This page is for people changing erlang_webrtc_codecs itself. For using it,
start with the [README](README.md) and [docs/raw-media.md](docs/raw-media.md).
Before you change anything, read [How it works](docs/architecture.md), then
find the file and the test in the [module map](docs/module-map.md).

## Write for the person who reads it

Every issue, pull request and comment is read by a person. Make it easy for
them.

- Read what you send before you send it. You are responsible for every line,
  whether you wrote it or a tool did.
- Use plain English and short sentences. Say what happens, what you
  expected, and how to reproduce it. Explain any term a reader may not know.
- Don't inflate it. No buzzwords, no severity scores, no "critical" for a
  bug, no long generated write-ups. If it takes a page to explain, cut it
  down until it doesn't.
- A bug report gives: the erlang_webrtc_codecs, erlang_webrtc and OTP
  versions, the operating system, the codec and the version of its library,
  the options you set, a minimal reproduction, what you got and what you
  expected. A file with the frames that fail helps most.
- A pull request says what was wrong and why it matters, the fix in a few
  lines, and any breaking change. Link the issue. Don't walk through the diff
  file by file; the reviewer reads the code.
- A fix comes with a test that fails without it.

For a security problem, follow [SECURITY.md](SECURITY.md) instead of opening
an issue.

AI tools are fine to use. Before you open anything, you must have read the
change, run the tests, and be able to answer questions about it yourself.

## Set up

You need Erlang/OTP 29 or later, rebar3, CMake, pkg-config and a C compiler,
plus the codec libraries: libopus, libvpx, OpenH264, dav1d and libaom.
[docs/install.md](docs/install.md) has the packages for each system. A codec whose library is missing is left
out and its tests skip themselves. Install `ffmpeg` to run the tests that
compare with it; they skip themselves too.

```bash
git clone https://github.com/benoitc/erlang_webrtc_codecs.git
cd erlang_webrtc_codecs
rebar3 compile
```

## Before you commit

Run what CI runs:

```bash
rebar3 fmt          # format first, then check the rest
rebar3 compile
rebar3 eunit
rebar3 ct
rebar3 fmt --check
rebar3 lint
rebar3 xref
rebar3 dialyzer
rebar3 ex_doc
```

## Tests

- `test/webrtc_codecs_*_tests.erl` are EUnit tests of the modules on their
  own, run by `rebar3 eunit`.
- `test/webrtc_codecs_*_SUITE.erl` are Common Test suites that run the
  plugins inside two erlang_webrtc peer connections on loopback, run by
  `rebar3 ct`.

`webrtc_codecs_browser_SUITE` runs the video plugins against headless
Chromium, both ways. It uses the browser peer of erlang_webrtc's interop
suite, which this package does not carry:

```bash
cd ../erlang_webrtc/interop/browser && npm ci && npx playwright install chromium
export WEBRTC_CODECS_BROWSER_PEER=$PWD
```

Without it, or without node, the suite skips itself with the reason. It
looks in `../erlang_webrtc/interop/browser` when the variable is not set.

## Test on Linux and FreeBSD

The native code has to build and pass on the three systems. From macOS or
Linux, run the same tests on the other two:

```bash
rebar3 compile              # fetches the dependencies the copies carry
scripts/test-linux.sh       # Debian in Docker
WEBRTC_CODECS_LINUX=alpine scripts/test-linux.sh   # Alpine, for musl
scripts/test-freebsd.sh     # FreeBSD in a QEMU virtual machine
```

Each builds a copy of the sources with every codec library required, so a
library that is missing there is a failure, not a skip. Give a command to
run something else, for example `scripts/test-linux.sh rebar3 dialyzer`.

The FreeBSD script downloads the official cloud image once (600 MB, checked
against its published checksum), keeps the machine's disk in
`~/.cache/webrtc_codecs/freebsd`, and leaves the machine running between
runs: `scripts/test-freebsd.sh stop` ends it, `destroy` also forgets its
disk. It needs `qemu`, and listens for SSH on `127.0.0.1:52222`
(`WEBRTC_CODECS_FREEBSD_PORT` to change it).

For a change to native code, run the tests with the NIFs built with ASan,
UBSan and fault injection, which makes each allocation of a constructor
fail in turn:

```bash
scripts/test-sanitizers.sh
```

The browser suite only runs on the machine you work on.

CI runs the same on GitHub: Linux with every check, then macOS and FreeBSD
with the tests.

A codec gets a round trip (encode, decode, compare with
`webrtc_codecs_pattern:psnr/2` or `snr/2`), a comparison with another
implementation where one is at hand, and the error paths: raw media in the
wrong format, and a truncated or corrupt frame.

## Add a codec

1. Write `src/webrtc_codecs_<family>.erl` with the `webrtc_media_codec`
   behaviour and `codecs/0`, which lists the codecs the module can run in
   this build. A video codec also implements `webrtc_codecs_video` and
   delegates to it, and its tests run `webrtc_codecs_video_checks:all/1`.
2. Add the module to `?MODULES` in `src/webrtc_codecs.erl`. For a native
   codec, add the NIF to `c_src/CMakeLists.txt` with `add_codec_nif` and its
   library to `WEBRTC_CODECS_REQUIRE` in the CI workflow.
3. Follow [docs/raw-media.md](docs/raw-media.md) for what `decode/2` gives
   and `encode/2` takes, and the rules in [AGENTS.md](https://github.com/benoitc/erlang_webrtc_codecs/blob/main/AGENTS.md) for native
   code.
4. Add its guide under `docs/`, a row in the README table and a CHANGELOG
   entry.

## If you want to...

Each of these names the files to open. The [module map](docs/module-map.md)
has the tests.

**Add an option to a codec.** Read it in the module's `init`, validate it
there (a bad value is `{error, {badarg, Opts}}`, never a crash later), add a
row to the options table of the codec's guide, and a test for the good and
the bad value. Options shared by the video codecs are validated in `init/3` of `webrtc_codecs_video`.

**Change or add a limit.** A limit on what a peer can cause is enforced in
Erlang before a library is called: in the codec's `frame_info/2` for
pictures, in `decode/2` for sizes. Add it to
[docs/limits.md](docs/limits.md), and write a test with a frame that
declares too much and never reaches the library.

**Find out why a frame is not decoded.** Look at the dropped output
(`#{dropped => Reason}`): `waiting_for_keyframe` means an earlier frame
failed, `too_large` and `unsupported_parameter_set` come from the header
reader, anything else from the library. Call the module's `frame_info/2` on
the frame to see what the reader makes of it, and
`webrtc_codecs:available/0` to see that the codec is built.

**Add a capture source, or an encoder for encoded capture.** Both are in
`webrtc_codecs_capture_command`. A source is a clause of `input/3`. An
encoder is a clause of `default_encoder/2` and of `encoder_options/1`, which
holds its real time settings. A new stream format is cut in
`webrtc_codecs_capture_stream`. Test it with FFmpeg's generated sources, and say in
[docs/capture.md](docs/capture.md) what was and was not run.

**Support devices on another system.** `device_input/3` in
`webrtc_codecs_capture_command` names the device for FFmpeg;
`webrtc_codecs_capture_devices` lists them by reading what FFmpeg prints. Opening a real
device needs a person, so say in the guide that it was tried by hand, and
how.

**Change native code.** Read the first principle in
[AGENTS.md](https://github.com/benoitc/erlang_webrtc_codecs/blob/main/AGENTS.md).
Check every size and every return code, read nothing from a resource after
releasing it, and give constructors a fault injection point per allocation.
Then run `scripts/test-sanitizers.sh` and the tests on the three systems.

**Change how FFmpeg is run or ended.** That is `webrtc_codecs_exec`, used by
capture and playback. Whatever you change, stopping has to return and the
program has to be gone: add a mode to `test/fake_ffmpeg.escript` that
misbehaves the way you are guarding against.

## Documentation

`webrtc_codecs_docs_tests`, run by `rebar3 eunit`, fails when the module map
misses a source file or names one that is gone, when a link between pages
leads nowhere, or when a guide is not in the documentation build. Add your
module to [docs/module-map.md](docs/module-map.md) and your page to the
`ex_doc` extras in `rebar.config`.

Guides are task-oriented and in the second person: one paragraph saying what
the page is and when you need it, then steps with code, then short notes.
