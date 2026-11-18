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
   sends. A frame that cannot be decoded is dropped and reported, not kept
   and not retried.
4. **The plugin stays on.** erlang_webrtc turns a plugin off for good when
   it raises or returns `{error, _}`. Bad media from the peer is not an
   error: `decode/2` returns a `t:webrtc_codecs:dropped/0` output. Errors are
   for what the application got wrong (raw media in the wrong format) and
   for a codec that cannot start.

Each of these has a test: a truncated or corrupt frame for the first and
third, and the error path for the fourth.

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
build (none when its native library is missing). `webrtc_codecs_g711.erl`
(PCMU and PCMA, pure Erlang). To add one, write the module and add it to
`?MODULES` in `webrtc_codecs.erl`.

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
  that compare with FFmpeg skip themselves when `ffmpeg` is not installed.
- `test/webrtc_codecs_*_SUITE.erl`: Common Test, the plugins inside two
  erlang_webrtc peer connections on loopback.

## Linting Notes

Elvis rules are configured in `elvis.config`, the only lint configuration.
`rebar3 lint` reads that file and ignores any `{elvis, ...}` entry in
`rebar.config` while it exists. Notable exceptions:

- `webrtc_codecs` is excluded from `no_invalid_dynamic_calls`: it calls the
  plugin module of the negotiated codec.
- Atom naming regex: `^[a-z](_?[a-zA-Z0-9]+)*(_SUITE)?$`
