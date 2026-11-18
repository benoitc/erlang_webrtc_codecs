# Changelog

## Unreleased

### Added

- A plugin, `webrtc_codecs`, that you set once on a peer connection or a
  transceiver and that uses the codec that was negotiated.
- VP8 and VP9 (profile 0) decoding and encoding with libvpx. The encoder
  works in real time, follows the bitrate you pass it and makes a key frame
  on request. The decoder refuses pictures larger than a limit you set and
  waits for a key frame after a frame it cannot decode.
- Opus decoding and encoding with libopus. Lost frames are recovered from
  in-band FEC or concealed, and the encoder follows the bitrate and the
  packet loss you pass it.
- G.711 (PCMU and PCMA) decoding and encoding, with no native library.
- A test picture and a test tone to feed an encoder without a camera or a
  microphone, and PSNR and SNR to compare what comes back.
