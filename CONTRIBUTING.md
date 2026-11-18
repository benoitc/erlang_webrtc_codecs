# Contributing

This page is for people changing erlang_webrtc_codecs itself. For using it,
start with the [README](README.md) and [docs/raw-media.md](docs/raw-media.md).

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

AI tools are fine to use. Before you open anything, you must have read the
change, run the tests, and be able to answer questions about it yourself.

## Set up

You need Erlang/OTP 29 or later, rebar3, CMake, pkg-config and a C compiler,
plus the codec libraries: libopus and libvpx. A codec whose library is missing is left
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

A codec gets a round trip (encode, decode, compare with
`webrtc_codecs_pattern:psnr/2` or `snr/2`), a comparison with another
implementation where one is at hand, and the error paths: raw media in the
wrong format, and a truncated or corrupt frame.

## Add a codec

1. Write `src/webrtc_codecs_<family>.erl` with the `webrtc_media_codec`
   behaviour and `codecs/0`, which lists the codecs the module can run in
   this build.
2. Add the module to `?MODULES` in `src/webrtc_codecs.erl`. For a native
   codec, add the NIF to `c_src/CMakeLists.txt` with `add_codec_nif` and its
   library to `WEBRTC_CODECS_REQUIRE` in the CI workflow.
3. Follow [docs/raw-media.md](docs/raw-media.md) for what `decode/2` gives
   and `encode/2` takes, and the rules in [AGENTS.md](https://github.com/benoitc/erlang_webrtc_codecs/blob/main/AGENTS.md) for native
   code.
4. Add its guide under `docs/`, a row in the README table and a CHANGELOG
   entry.

## Documentation

Guides are task-oriented and in the second person: one paragraph saying what
the page is and when you need it, then steps with code, then short notes.
