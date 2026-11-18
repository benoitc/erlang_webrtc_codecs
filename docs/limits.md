# Limits and what they do not cover

This page lists what bounds the work and the memory a peer, a file or an
external program can cause, and what is not bounded or not proven. You need
it when you decide whether to expose a plugin to peers you do not trust, or
when you change native code.

## Media from a peer

| Limit | Value | What happens over it |
|---|---|---|
| Picture size, option `max_pixels` | 3840 x 2160 | The frame is dropped (`too_large`) before the library is called |
| Encoded video frame | 8 MB | Dropped (`invalid_frame`) |
| Opus packet | 7680 bytes | Dropped (`invalid_packet`) |
| Opus audio made up for lost frames | 120 ms | A longer hole is left as it is |
| G.711 frame | 2 s | Dropped (`too_large`) |

The picture size is read from the media before any library sees it:

- VP8: the key frame header.
- VP9: every frame of a superframe, the ones not shown included. A buffer
  without a superframe index is given to libvpx as one frame, so it does not
  go on to bytes that were not checked.
- H.264: every sequence parameter set of every access unit, on the coded
  size (whole macroblocks). A set that cannot be read, of a profile OpenH264
  does not decode, or a subset set makes the frame dropped
  (`unsupported_parameter_set`).
- AV1: dav1d is given the limit and applies it itself.

## Your own calls

| Limit | Value | What happens over it |
|---|---|---|
| Picture given to an encoder | 16384 x 16384 | `{error, {bad_raw_picture, _}}` |
| Audio given to `webrtc_codecs_playback:play/2` | 1 s | `{error, bad_format}` |
| File read by `webrtc_codecs_file` | 256 MB, option `max_bytes` | `{error, too_large}` |

## External programs

| Limit | Value | What happens over it |
|---|---|---|
| Media read from FFmpeg | one socket message at a time | FFmpeg waits; nothing queues in the capture process |
| Encoded frame from FFmpeg | 8 MB | The capture ends with `{error, bad_stream}` |
| What a program says, kept | the last 4 kB | Older text is dropped |
| Write to a file sink, option `write_timeout` | 5 s | `{error, stalled}`, the program is killed |
| FFmpeg finishing a file, option `finish_timeout` | 15 s | `{error, {not_finalized, killed, _}}` |
| A program asked to end | 2 s, then 2 s after SIGKILL | It is killed |
| Listing devices | 10 s, 1 MB of output | The program is ended, what was read is used |

## What is not covered

- **The codec libraries run inside the VM.** A defect in libvpx, OpenH264,
  dav1d, libaom or libopus on hostile media can still crash or corrupt the
  node. The limits above keep sizes sane; they do not make the libraries
  safe. To isolate that risk, run the plugins on a node of their own.
- **Leaks are not proven absent.** The lifecycle suite checks that memory
  stays flat over thousands of bad frames, killed owners and dropped
  contexts, which would show a steady leak. A leak detector cannot be used
  under the emulator as it is built.
- **The sanitizers see part of the picture.** `scripts/test-sanitizers.sh`
  builds the NIFs with ASan and UBSan, and they watch the libraries' own
  memory and the NIF code. Memory the emulator hands to a NIF (resources,
  binaries) is managed by the emulator, and a misuse of it is not always
  seen: the one known bug of that kind was found by reading, not by ASan.
- **A context is destroyed where it is collected**, which can be a normal
  scheduler. Measured on an Apple silicon laptop, destroying an encoder and
  a decoder takes a few microseconds, with one AV1 outlier at 1.2 ms in 100.
  `webrtc_codecs_lifecycle_SUITE` logs the figures of your machine.
- **Dirty schedulers are shared.** A codec call holds one for its duration,
  and calls on the same context wait for each other.
- **Windows** has no native codecs, and its capture and playback paths have
  never been run.
