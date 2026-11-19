# Changelog

## Unreleased

Experimental: nothing has been released yet, and anything below may change.

### Fixed

- Opus: a decoder or encoder that failed to start read memory it had just
  released. It now reports the error cleanly.
- H.264: the picture size limit only looked at the first parameter set of a
  key frame, at the size shown rather than the size decoded, and let a set
  it could not read through. Every parameter set is now checked, and one
  that cannot be read is refused.
- VP9: the picture size limit only looked at the first frame of a buffer,
  while the library decodes all of them. Every frame is now checked.
- Capture kept growing memory when the program wrote something that was not
  the expected stream, or wrote faster than it was read. It now stops with
  an error in the first case and holds the program back in the second.
- Recording to a file could block for ever when FFmpeg stopped reading, and
  stopping could return before the file was finished or with FFmpeg still
  running. Writes now have a deadline, stopping tells whether the file was
  finished, and the program is always ended.
- Messages of FFmpeg were written to a file with no size limit. Only their
  end is kept, in memory.
- Listing devices could wait for ever on a program that kept writing.
- The H.264 encoder ignored some errors of the library.

### Changed

- `webrtc_codecs_playback:stop/1` returns `{error, {not_finalized, _, _}}`
  when a file was not finished, and `play/2` can return `{error, stalled}`.
- Errors of capture and playback carry the end of what the program said,
  and `killed` in place of an exit status when it had to be killed.
- `webrtc_codecs_h264:sps_size/1` is replaced by `sps_info/1`, which gives
  the size as coded and as shown.
- An H.264 frame with a parameter set of a profile OpenH264 does not decode
  is dropped instead of tried.

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
