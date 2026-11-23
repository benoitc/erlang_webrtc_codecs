# Changelog

## 0.2.0 (2026-11-23)

### Added

- `webrtc_codecs_async` runs the codecs in a process of their own, so a slow
  codec no longer holds up the rest of the connection, data channels
  included. Name it where you named `webrtc_codecs`. When the codec is
  behind, pictures to encode are refused and frames to decode are dropped,
  instead of piling up.
- The plugins use what erlang_webrtc 0.3.0 gives them, so your application
  has less to relay:
  - A key frame the peer asks for reaches the encoder by itself.
  - A bitrate limit from the peer is applied to the encoder, and
    `webrtc:set_target_bitrate/3` sets its target.
  - A video decoder that drops a frame asks the sender for a key frame
    itself, and counts the frame in `framesDropped`. Set
    `request_keyframes => false` to keep doing it yourself.
  - The codecs of a stream are freed when it ends, instead of at some later
    time.
- H.264 follows what was negotiated. With `packetization-mode=0` the encoder
  cuts each picture into pieces that fit one packet, as that mode requires;
  the `max_nal_size` option sets their size.
- On Linux and FreeBSD, `webrtc_codecs_capture:devices/0` lists the real
  microphones, and `{microphone, Index}` opens the one you picked. PulseAudio,
  ALSA, OSS and sndio are used, whichever your FFmpeg has, or the one you
  name with `audio_backend`. `devices/1` takes options.
- Opus sends no more audio bandwidth than the peer said it plays
  (`maxplaybackrate`), or than the `max_playback_rate` option.

### Changed

These can require a change in your application.

- Raw media in the wrong format no longer turns the plugin off.
  `webrtc:send_media/3` returns an error for that picture or audio, and the
  next one is encoded.
- `bitrate` and `keyframe` in the raw map still work, but you no longer need
  them to follow the peer. An application that still asks for a key frame
  after each dropped frame now sends the request twice, which is harmless.
- Requires erlang_webrtc 0.3.0 or a later 0.3 version. It sends H.264 in
  the packetization mode that was negotiated, which the H.264 change above
  relies on.
- The H.264 plugin refuses to start when the peer negotiated a profile it
  cannot serve, instead of sending video the peer may not decode.
- On Linux and FreeBSD a microphone index used to mean the PulseAudio
  default whatever its value. It now means the entry of `devices/0` with
  that index; index 0 is still the default microphone.
- Windows is stated as not supported. Its capture and playback code is
  kept but has never been run.

## 0.1.1 (2026-11-19)

### Changed

- Requires erlang_webrtc 0.2.0 or a later 0.2 version. erlang_webrtc 0.1.0
  dropped AV1 and H.264 frames when RTX was not negotiated; with 0.2.0 they
  all arrive. Version 0.1.0 of this package required exactly erlang_webrtc
  0.1.0, so it could not be used with the fixed stack.
- The guides put a codec first with `webrtc:prefer_codec/2`, which
  erlang_webrtc 0.2.0 adds.

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
