# Changelog

## Unreleased

### Changed

- Requires erlang_webrtc 0.2.0, which no longer drops AV1 and H.264 frames
  when RTX is not negotiated. The guides use its `webrtc:prefer_codec/2` to
  put a codec first.

## 0.1.0 (2026-11-19)

First release. Experimental: the API, the options and the shape of the raw
media may change.

### Added

- A plugin, `webrtc_codecs`, that you set once on a peer connection or a
  transceiver and that uses the codec that was negotiated.
- H.264 decoding (baseline, main, high) and constrained baseline encoding
  with OpenH264.
- AV1 (main profile) decoding with dav1d and encoding with libaom, with the
  same bitrate, key frame and picture size handling as VP8 and VP9. Either
  library can be left out.
- VP8 and VP9 (profile 0) decoding and encoding with libvpx. The encoder
  works in real time, follows the bitrate you pass it and makes a key frame
  on request. The decoder refuses pictures larger than a limit you set and
  waits for a key frame after a frame it cannot decode.
- Opus decoding and encoding with libopus. Lost frames are recovered from
  in-band FEC or concealed, and the encoder follows the bitrate and the
  packet loss you pass it.
- G.711 (PCMU and PCMA) decoding and encoding, with no native library.
- Capture of raw pictures and audio from a camera, a microphone, a file or
  a generated test source, by running FFmpeg outside the VM. A slow reader
  loses frames instead of growing memory.
- Capture and encoding in FFmpeg in one go, giving encoded VP8, VP9, AV1 or
  H.264 frames to send without a codec plugin, with FFmpeg's hardware
  encoders if you want. The bitrate is fixed and key frames are periodic.
- Playback of decoded pictures in a window and of decoded audio on the
  speaker, and recording of either to any file FFmpeg writes.
- Reading and writing of IVF and WAV files.
- A test picture and a test tone to feed an encoder without a camera or a
  microphone, and PSNR and SNR to compare what comes back.
- Limits on what a peer can cause: a picture over `max_pixels` is refused
  before the codec library is called, for every frame and parameter set the
  library would read, and frames that cannot be decoded are dropped and
  reported. `docs/limits.md` lists every limit and what is not covered.
- External programs are always ended: capture and playback run FFmpeg
  outside the VM with deadlines, keep only the end of what it says, and
  `webrtc_codecs_playback:stop/1` tells whether a file was finished.
- A demo that shows the camera and the microphone of the machine in a
  browser.
- Builds and tests on macOS, Linux (Debian, Alpine) and FreeBSD.
