# Security policy

This page tells you how to report a vulnerability in erlang_webrtc_codecs
and what counts as one. The package decodes media from remote peers you do
not control, with native libraries that run inside your Erlang node, and
runs FFmpeg as an external program. A bug that a peer's media, a file or a
misbehaving program can trigger is a security bug.

The package is experimental. Read
[Limits and what they do not cover](docs/limits.md) before you expose it to
peers you do not trust.

## Report a vulnerability

Use GitHub's private vulnerability reporting: open the repository's
**Security** tab and choose **Report a vulnerability**. Please do not open a
public issue.

Include:

- the version or commit you tested, the operating system, the codec and the
  version of its library (`webrtc_codecs:available()` gives it);
- what a peer has to send, or what a file or a program has to do, and what
  happens (a crash of the node, memory that grows, a call that never
  returns, a program left running);
- a reproducer if you have one: the frames, a file, a test case.

Once a fix is released, the CHANGELOG says what was wrong and the advisory
credits you unless you ask otherwise.

## In scope

Anything encoded media passed to `decode/2`, a file given to the package, or
the output of the external program can cause:

- a crash or memory corruption in the code of this package, in Erlang or in
  its NIFs (`c_src/`);
- a native library given something this package should have refused: a
  picture over `max_pixels`, a frame or a parameter set it did not check;
- memory, a mailbox or a buffer that grows without a bound;
- a call that blocks a scheduler, or never returns;
- an FFmpeg or ffplay process that outlives its owner;
- a codec plugin turned off by media from a peer, rather than by a mistake
  of the application.

## Out of scope

- A defect inside libopus, libvpx, OpenH264, dav1d, libaom or FFmpeg on
  input this package was right to pass on. Report it to that project; tell
  us too if this package could reasonably refuse the input first.
- erlang_webrtc itself: transport, encryption and signaling are reported
  there.
- Raw media or options given by your own application: a wrong format is an
  error returned to you, not a vulnerability.
- The demo in `examples/`, which serves on the loopback address without
  authentication and is not meant to be exposed.
- Windows, where the native codecs are not built and nothing has been run.

## Supported versions

Fixes go to the latest release. Before the first release, they go to
`main`.

## Read next

- [docs/limits.md](docs/limits.md): every bound on what a peer, a file or a
  program can cause, and what is not covered.
- [CONTRIBUTING.md](CONTRIBUTING.md): how to run the hostile input,
  lifecycle and sanitizer tests.
