# Documentation and maintainability review, 2026-11-19

This is the review that comes before a release. It looks at `main` at
`3d8c814` as a person arriving in the project would, and says what to change
so that they can understand it, change it and check their change. It edits
no source code. You decide which findings have to be fixed before 0.1.0 and
which can wait; nothing is released until then.

## Update before the release after 0.1.1, 2026-11-23

`main` at `271abef`, 14 commits and 2691 added lines after `v0.1.1`.
Nothing is released until you have said which of these must be fixed first.

What changed since 0.1.1:

- Requires erlang_webrtc 0.3.0 and uses every callback it gives a plugin:
  `control/2`, `terminate/1`, key frame requests from the decoder,
  `framesDropped`, the error that leaves the plugin on.
- `webrtc_codecs_async` (285 lines, new, public) runs a plugin in a process
  of its own.
- H.264 follows `profile-level-id` and `packetization-mode`; Opus follows
  `maxplaybackrate`; microphones are listed and picked on Linux and FreeBSD.
- Each NIF has close functions; CI has Alpine and sanitizer jobs.
- Question 6 is answered: Windows is stated as not supported.

Findings for this release:

| Finding | Kind | Suggestion |
|---|---|---|
| `docs/glossary.md` is behind in three rows: "transport process" and "codec plugin" say plugins run inside the transport process, which `webrtc_codecs_async` changes, and "resource" says the VM frees a codec when no process holds it, where `terminate/1` now closes it. It has no entry for "in flight", "key frame request" or "target bitrate". | documentation | Fix the three rows, add the three terms |
| Nothing leads a user of a codec to `docs/async.md`: the codec guides do not link it, and `docs/raw-media.md` still ends on "encoding and decoding run in the transport process" with no way out. | navigation | One line in that note and in the notes of the video guides |
| `docs/architecture.md` explains the synchronous path only. The asynchronous plugin is one row in a table; the prose still says each call "has to be short". A reader does not learn where the worker sits or what bounds it. | documentation | A short section "With webrtc_codecs_async", with where the frame goes and what is dropped |
| `CONTRIBUTING.md`, "Add a codec", does not say a plugin has `control/2` and `terminate/1`, that a video plugin implements `decoder_close/1` and `encoder_close/1`, or which error form to return. There is no "If you want to..." entry for changing the asynchronous plugin. | documentation | Three lines in the first, one entry in the second |
| The key frame request policy (first drop, then one in 30) is written twice, in `webrtc_codecs_video` and in `webrtc_codecs_async`, with the same constant. | code readability | After the release: one function, or a comment in each pointing at the other |
| `webrtc_codecs_video` went from 291 to 381 lines (36 clauses): it now also holds the peer's bitrate limit, `control/2` and closing. Still one subject, what the video plugins share. | module organisation | Leave |
| `webrtc_codecs_opus` is 385 lines; the part that applies the peer's limit to a bitrate libopus chose (`started/1`, `effective/1`) is the hardest to follow in the package. It is commented and tested. | code complexity | Leave; genuine |
| The README still shows `{webrtc_codecs, "0.1.1"}` and its "Tested" paragraph does not mention the asynchronous plugin. | documentation | With the version bump |
| The CHANGELOG "Unreleased" section has to become the release section; its "Changed" list is the breaking changes and should say so. | documentation | With the version bump |
| `webrtc_codecs_docs_tests` checks that calls in code blocks exist, not their arguments. | documentation | Carried over; can wait |
| Question 4 of section 13 (which exported helpers are public API) | design | Yours; can wait |

Decided: version 0.2.0, with the first four findings fixed before it (the
glossary, the links to the asynchronous guide, the architecture page, the
contributing guide). They are done on this branch. The two README and
CHANGELOG findings go with the version bump; the rest waits.

Not established, and said so in the pages: a physical microphone on Linux
or FreeBSD, sndio, a peer that offers only `packetization-mode=0`.

Version: the minimum erlang_webrtc moved to 0.3.0, a microphone index
changed meaning, the H.264 plugin can refuse to start, and `decode/2` and
`encode/2` of the plugin modules have new return forms. That is more than
a patch: 0.2.0.

## Update before the next release, 2026-11-19

`main` at `b004dee`, nine commits after `v0.1.0`. Nothing is released until
you have said which of these must be fixed first.

What changed since 0.1.0:

- Requires erlang_webrtc 0.2.0 (the dropped AV1 and H.264 frames are fixed
  there; the guides use its `webrtc:prefer_codec/2`).
- The capture module is split in four, the NIF constructors share one
  pattern, and the documentation has its architecture page, module map,
  glossary and a drift test.
- The public API did not change: every new export is in an internal module.

Findings for this release:

| Finding | Kind | Suggestion |
|---|---|---|
| `AGENTS.md` is now wrong in three places: it describes capture as one module (there are four), says the tests read "the frame corpus of erlang_webrtc" (they read `test/corpus`), and does not know `webrtc_codecs_nif_tests`, `webrtc_codecs_docs_tests` or the shared constructor helpers. You chose earlier to leave the file as it is; that was before it was out of date. | documentation | Fix the three passages, nothing else |
| The dependency is written `{webrtc, "0.2.0"}`, an exact version. The 0.1.0 on Hex requires exactly `webrtc` 0.1.0 the same way. A user cannot take a `webrtc` 0.2.1 with it. | packaging | `"~> 0.2.0"` |
| Four tests keep a `false -> ok` branch for a corpus that is not found. `corpus/1` no longer returns `false`: the files are in this repository. | code readability | Remove the dead branches |
| `webrtc_codecs_playback` is now the largest module (421 lines): the process and FFmpeg's command line. | module organisation | Leave: two responsibilities, 41 clauses, readable |
| `webrtc_codecs_docs_tests` does not check the code blocks of the guides. | documentation | After the release |
| Questions 4 (which exported helpers are public API) and 6 (Windows) of section 13 | design | Yours, can wait |

Decided: version 0.1.1, with the first three findings fixed before it (the
dependency as `~> 0.2.0`, `AGENTS.md`, the dead test branches).

Version: nothing public changed and nothing was removed, so 0.1.1 fits. The
one thing a user notices is the new minimum for erlang_webrtc; if you would
rather signal that, 0.2.0 does, and matches the stack's number.

## State on 2026-11-19, after the 0.1.0 release

Done since this plan was written:

- Release blockers: the dependency is `webrtc` 0.1.0 from Hex, `LICENSE` and
  `SECURITY.md` exist, the CHANGELOG has one 0.1.0 section, the README
  status is current. 0.1.0 is tagged and released on GitHub.
- `docs/glossary.md`, `docs/architecture.md` (with the two paths) and
  `docs/module-map.md` exist, and the README has a "Where to start" section
  with the three doors.
- `CONTRIBUTING.md` has the "If you want to..." guides.
- The codec guides no longer repeat the install commands.
- `webrtc_codecs_capture` (682 lines, five responsibilities) is split: the
  process stays (345 lines, a third of it documentation and types), device
  listing, FFmpeg's command line and stream cutting are internal modules of
  98, 139 and 176 lines. Its public API did not change.
- `webrtc_codecs_docs_tests` checks the module map against the source tree,
  the links between pages and the pages of the documentation build. It does
  not check the code blocks of the guides.
- The constructor pattern of the NIFs is written once in the shared header,
  with the plane copy and fault injection for every constructor.

Still open:

- `AGENTS.md` keeps its own copy of the architecture and test sections: the
  maintainer chose to leave that file as it is.
- `docs/behaviour-gaps.md` still holds the two issues met in erlang_webrtc.
  They were rechecked against 0.1.0 and are still there; they have not been
  filed upstream.
- Question 5 is answered by erlang_webrtc 0.2.0: `webrtc:default_codecs/1`
  and `webrtc:prefer_codec/2` are public, and the guides and tests use them.
  The padding issue is fixed there too; this package now requires 0.2.0.
- Questions 4 and 6 of section 13 have no answer yet.

## What it found, in short

- **The user side is in good shape.** A reader who wants to use a codec
  finds a starting point (README), a setup page, one guide per codec built
  on the same template, and a page of limits.
- **The "how does it work" side is missing.** The only map from concepts to
  modules is the Architecture section of `AGENTS.md`, which a person does not
  think to open. There is no page that says where code runs (which process,
  which scheduler, which program) or follows a frame through the system.
- **Vocabulary is used before it is defined.** Frame, access unit, temporal
  unit, key frame, raw media, plugin, transceiver, mid, superframe,
  parameter set, dirty scheduler and `rtx` all appear without a definition.
- **One module is an outlier.** `webrtc_codecs_capture` is 682 lines, 2.4
  times the median plugin, and holds five responsibilities.
- **Three things block a release whatever you decide on the rest**, and are
  not documentation: see "Before a release" below.

## Before a release

These came up while reviewing and are yours to decide. They are not
documentation findings, but a release cannot be coherent without them.

| Finding | Why it matters |
|---|---|
| The dependency is pinned to erlang_webrtc `a09466e`. erlang_webrtc has since tagged `v0.1.0`, 63 commits and 145 changed files later, with `src/transport` moved to `src/media`. | This package has never been built or tested against the released stack. The README still says it builds against the `feature/webrtc-stack` branch. |
| erlang_webrtc is not on Hex (`webrtc`, `erlang_webrtc`: not found). | A Hex package cannot have a git dependency, so 0.1.0 can be a tag and a CHANGELOG section, not a Hex release, until the stack is there. |
| There is no `LICENSE` file. `app.src` and the README say Apache-2.0. | A public repository with no licence text grants nothing; Hex also requires one. |
| There is no `SECURITY.md`. | The package runs native code on media from peers; a reader needs to know where to report a problem. |
| `CHANGELOG.md` has "Fixed" and "Changed" sections under Unreleased. | They describe fixes to code that was never released. For a first release they read oddly. |
| The README says a real camera and microphone are not tested. | You ran the demo with a real camera, a real microphone and the browser's microphone in Safari on macOS on 2026-11-19. |

## 1. Recommended structure

A path a reader follows in order:

1. **Orientation**: `README.md`. What it is, who for, status, the smallest
   example, where to go next.
2. **Use**: `docs/install.md`, `docs/demo.md`, `docs/raw-media.md`, then one
   guide per codec and per device module.
3. **Understand**: `docs/architecture.md` (missing), `docs/glossary.md`
   (missing), `docs/limits.md`, `docs/behaviour-gaps.md`.
4. **Change**: `CONTRIBUTING.md`, with "If you want to..." guides, and
   `docs/module-map.md` (missing) mapping concepts to files and tests.
5. **Rules for agents**: `AGENTS.md`, which points at the pages above
   instead of holding the only copy of the architecture.

## 2. Starting point

`README.md`. It should end its introduction with three doors: "You want to
try it" (demo), "You want to use a codec" (raw media, then the codec),
"You want to understand or change it" (architecture, then CONTRIBUTING).

## 3 and 4. Each existing document

| Document | Lines | Reader | Verdict | Reason |
|---|---|---|---|---|
| `README.md` | 128 | everyone | rewrite parts | Status section is stale (real devices, dependency branch). Add the three doors. |
| `docs/install.md` | 207 | user | keep | Says per system what was run and what was only checked. |
| `docs/demo.md` | 109 | user | keep | Add the real-device result once you confirm it. |
| `docs/raw-media.md` | 89 | user | keep | It is the central concept page for users; link it from every codec guide's first paragraph. |
| `docs/opus.md`, `vp8-vp9.md`, `h264.md`, `av1.md`, `g711.md` | 59 to 110 | user | keep, trim | Same template, which works. Each repeats the install commands that `install.md` has: four copies to keep in step. Keep one line and the link. |
| `docs/capture.md` | 168 | user | keep | The longest guide, for the largest module. The encoded-capture half could become its own page if it grows. |
| `docs/playback.md` | 111 | user | keep | |
| `docs/limits.md` | 72 | user deciding on trust, contributor | keep | The "what is not covered" half is what makes it honest; do not let it shrink. |
| `docs/behaviour-gaps.md` | 38 | contributor, erlang_webrtc maintainer | split | It holds two things: what the behaviour lacks, and two issues found in erlang_webrtc at `a09466e`. The second part is dated and has to be rechecked against `v0.1.0`, then filed upstream rather than kept here. |
| `CONTRIBUTING.md` | 139 | contributor | extend | Has setup, checks, platforms and "Add a codec". Lacks the other "If you want to..." guides, see section 11. |
| `AGENTS.md` | 212 | agents | keep, point outward | Its Architecture and Test Organization sections are the only map of the code. Move that content to `docs/architecture.md` and `docs/module-map.md` and link to them, so there is one copy. |
| `CHANGELOG.md` | 67 | user | rewrite for the release | See "Before a release". |

## 5. Missing documents

| Document | Intent | Reader | After reading, they know | Points to | Detail |
|---|---|---|---|---|---|
| `docs/architecture.md` | The mental model: what runs where, and the path of a frame each way | someone trying to understand, a new contributor | That a plugin runs in the transport process of a connection; that codec calls go to a dirty scheduler; that devices are another program; why each is so | module map, limits | One page, two diagrams |
| `docs/glossary.md` | Define the terms once | everyone | What each word in the other pages means | the page where each is used | A line or two per term |
| `docs/module-map.md` | Concept to module to test | contributor | Which file to open for a behaviour and which test covers it | CONTRIBUTING | A table, see section 7 |
| `LICENSE` | Apache-2.0 text | everyone | | | |
| `SECURITY.md` | Where to report, what is in scope | user, reporter | That native libraries run in the node, and how to report | limits | Short |

## 6. Concepts that need their own explanation

- **Where code runs.** Plugin in the transport process, NIF call on a dirty
  CPU scheduler, FFmpeg in its own program reached over a socket. Everything
  about blocking, limits and crashes follows from this, and no page says it
  in one place.
- **Raw media and the control map.** Why bitrate and key frame requests
  travel inside the media map (the behaviour has no other way in). Explained
  in `raw-media.md` and `behaviour-gaps.md`; the architecture page should
  give the reason once.
- **Dropped outputs instead of errors.** Why `decode/2` never returns
  `{error, _}` for bad media. It is in `AGENTS.md` and `behaviour-gaps.md`,
  not where a user reads.
- **The limit before the library.** Why sizes are read from headers in
  Erlang before the native library is called.
- **Frame, access unit, temporal unit, superframe.** Four names for "what
  `decode/2` gets", one per codec.

## 7. Navigation: concept to module to test

| You want to change | Read first | Module | Tests |
|---|---|---|---|
| Which codec a plugin picks | architecture | `webrtc_codecs.erl` | `webrtc_codecs_tests` |
| What every video plugin does around the library (key frame wait, bitrate, stats) | architecture | `webrtc_codecs_video.erl` | `webrtc_codecs_video_checks` |
| A codec's options or bitstream checks | its guide, limits | `webrtc_codecs_<codec>.erl` | `webrtc_codecs_<codec>_tests` |
| A call into a library | AGENTS first principle | `c_src/webrtc_codecs_<lib>_nif.c` and its `_nif.erl` | codec tests, `scripts/test-sanitizers.sh` |
| How FFmpeg is started or ended | limits | `webrtc_codecs_exec.erl` | capture and playback tests with `test/fake_ffmpeg.escript` |
| A capture source, device listing, encoded capture | capture guide | `webrtc_codecs_capture.erl` | `webrtc_codecs_capture_tests` |
| A sink | playback guide | `webrtc_codecs_playback.erl` | `webrtc_codecs_playback_tests` |
| The plugins inside a real connection | | | `webrtc_codecs_peer_SUITE`, `webrtc_codecs_browser_SUITE` |
| Life of native contexts | limits | NIFs | `webrtc_codecs_lifecycle_SUITE` |
| The build | install | `c_src/CMakeLists.txt`, `c_src/build_nif.sh`, `rebar.config` hooks | CI, `scripts/test-linux.sh`, `scripts/test-freebsd.sh` |

## 8. Modules that need better documentation

| Module | Role | What is missing |
|---|---|---|
| `webrtc_codecs_video` | core | Its callbacks are the contract every video codec fills in. It is `-moduledoc false`; a contributor adding a codec has only comments. Needs a contributor page, not API docs. |
| `webrtc_codecs_exec` | core for devices | Same: internal, and the rule "one owner, deadline, forced end" lives in `AGENTS.md`. |
| `webrtc_codecs_h264`, `webrtc_codecs_vpx`, `webrtc_codecs_av1` | plugin plus header reader | The header readers (`sps_info/1`, `frame_size/2`, `superframe/1`, `obu_types/1`) are what the size limit rests on. Nothing tells a contributor that changing them is a safety change. |
| the five `_nif.erl` modules | adapter | Fine as they are. |

## 9 and 10. Size and responsibilities, with measurements

Source: 18 modules, 4171 lines. Median plugin module: 280 lines. C: 5 NIFs,
1720 lines. Tests: 3373 lines.

| Module | Lines | Function clauses | Exports | Responsibilities | Primary problem |
|---|---|---|---|---|---|
| `webrtc_codecs_capture` | 682 | 91 | 9 | 5: device listing for three systems (parsing FFmpeg's text), building FFmpeg's command line (inputs per system, encoders, containers), the process and its socket, three stream cutters (raw, IVF, Annex B), the drop policy | module organisation |
| `webrtc_codecs_playback` | 421 | 41 | 9 | 2: the process, the command line | none worth acting on |
| `webrtc_codecs_h264` | 350 | 35 | 14 | 2: plugin, parameter set reader (about 200 lines) | documentation |
| `webrtc_codecs_opus` | 320 | 36 | 5 | 1 | architecture (genuine) |
| `webrtc_codecs_video` | 291 | 32 | 4 | 1 | documentation |
| `webrtc_codecs_vpx` | 276 | 32 | 14 | 2: plugin, header and superframe reader | documentation |
| `webrtc_codecs_exec` | 271 | 27 | 10 | 1 | none |

`webrtc_codecs_capture`: you cannot say what it is responsible for in one
sentence, and a change to how a camera is named on Linux sits in the same
file as the IVF cutter. Document the boundaries first (a comment block per
part already exists). A later split into the process, device listing, the
FFmpeg command line and the stream cutters would likely help; it would touch
`webrtc_codecs_capture_tests` (472 lines) and nothing else. Not for this
release.

Longest functions: `capture:deliver` 54 lines over 8 clauses,
`capture:handle_info` 46 over 9, `h264:sps` 43, `opus:init` 42. None is long
for what it does.

In C, `plane()` (copy a plane without its padding) is written three times
(vpx, dav1d, OpenH264) and the resource, lock and constructor-failure
pattern five times. It is the kind of repetition where the Opus bug lived.
A shared helper in `webrtc_codecs_nif.h` would make the pattern one thing to
read. Primary problem: module organisation. Not for this release.

## 11. "If you want to..." guides to add to CONTRIBUTING

- **Add a codec**: exists. Add: implement `webrtc_codecs_video`, write
  `frame_info/2` first, add its limits to `docs/limits.md`.
- **Add an option to a codec**: the module's `init`, its validation, its
  guide's table, a test.
- **Change or add a limit**: the header reader, `docs/limits.md`, a test
  with a frame that declares too much.
- **Add a capture source or an encoder for encoded capture**:
  `input/3`, `default_encoder/2`, `encoder_options/1`, the guide.
- **Support a device system** (Linux audio other than pulse, Windows):
  `device_input/3`, `devices/2`.
- **Find out why a frame is not decoded**: the `dropped` output and its
  reason, `frame_info/2`, `webrtc_codecs:available/0`, the page title of the
  demo.
- **Change native code**: the first principle, fault injection,
  `scripts/test-sanitizers.sh`, the three platforms.

## 12. Diagrams and examples

- Send path: capture process, owner, `send_media/3`, plugin in the
  transport process, NIF on a dirty scheduler, frames, RTP.
- Receive path: RTP, frame buffer, plugin, header check, NIF, `decoded`
  event, owner, sink.
- Who owns what: which process owns the port, the socket, the native
  context.

## 13. Questions for you

1. Should 0.1.0 depend on erlang_webrtc `v0.1.0`? I assume yes; it has to be
   built and tested against it first, and the two issues in
   `behaviour-gaps.md` rechecked.
2. With the stack not on Hex, is 0.1.0 a tag and a GitHub release only?
3. The fixes under Unreleased: fold them into one "Added" section for 0.1.0,
   since nothing was released before, or keep the history as it is?
4. Are `frame_size/2`, `superframe/1`, `nal_units/1`, `sps_info/1`,
   `obu_types/1`, `compress/2` and `expand/2` public API you want to keep
   stable, or internals exported for tests?
5. The codec guides use `webrtc_jsep_caps:default_codecs/1`, a private
   module of erlang_webrtc, to pick a codec. Is there, or will there be, a
   public way?
6. Windows: keep the untested code paths, or say plainly it is unsupported?
7. Does 0.1.0 stay labelled experimental?
8. Can I record your Safari run with a real camera and microphone as a
   tested configuration?
9. Code blocks in the guides are not checked by a test, as erlang_quic's
   are. Do you want a drift check here?

## 14. Suggested order

1. The release blockers you confirm: dependency on `v0.1.0` and a full test
   run on the three systems, `LICENSE`, `SECURITY.md`, CHANGELOG shape,
   README status.
2. `docs/glossary.md` and `docs/architecture.md` with the two diagrams.
3. `docs/module-map.md`, and `AGENTS.md` pointing to it.
4. The "If you want to..." guides in `CONTRIBUTING.md`.
5. Trim the repeated install commands in the codec guides.
6. Split `behaviour-gaps.md` after rechecking the issues upstream.
7. After the release: the capture split, the shared C helpers, a docs drift
   check.
