# What the codec behaviour lacks

This page lists what `webrtc_media_codec` in erlang_webrtc does not let a
plugin do, and how this package works within it. You need it when you wonder
why a plugin behaves as it does, or when you plan a change to the behaviour.

| Missing | What the plugins do instead |
|---|---|
| A way to tell the encoder the bitrate changed (`{bandwidth_estimate, Bps}` goes to the owner only) | You pass `bitrate => Bps` in the raw map given to `webrtc:send_media/3` |
| A way to tell the encoder a key frame is wanted (`{keyframe_request, Mid}` goes to the owner only) | You pass `keyframe => true` in the next raw picture |
| A way for a decoder to ask the sender for a key frame | `decode/2` gives `#{dropped => Reason, timestamp => Ts}` and you call `webrtc:request_keyframe/2` |
| A recoverable error: `{error, _}` from `decode/2` or `encode/2` turns the plugin off until the connection ends | Bad media is reported as a dropped output; `{error, _}` is kept for raw media in the wrong format and for a codec that cannot start |
| A count of frames the decoder dropped: `framesDropped` is not a member a plugin may report | The dropped output is the only trace |
| A callback when the transceiver stops | Native contexts are freed when the plugin state is garbage collected |
| Outputs delivered later than the call that produced them | Every call is synchronous, so the transport waits for the codec. To keep the transport free, run the plugin module in your own process and use `webrtc:send_frame/4` and `webrtc:report_media_stats/4` |

## Issues met in erlang_webrtc

Found while testing the plugins, on `feature/webrtc-stack` at `a09466e`.
They are not worked around in erlang_webrtc; each says what this package
does meanwhile.

- **AV1 and H.264 frames are dropped after padding on the media stream.**
  A padding-only RTP packet received on the media SSRC is counted
  (`webrtc_media_in`, the `padding_received` clause) but is not given to
  `webrtc_frame_buffer:padding/3`, so the frame buffer sees its sequence
  number as a loss. VP8 and VP9 are told apart by their picture IDs; codecs
  without one get every later frame dropped and a key frame asked for again
  and again. It showed between two erlang_webrtc peers on loopback that
  negotiated AV1 without its `rtx` format: no packet was lost, the receiver
  counted more packets than the media packets sent, and 29 frames of 30 were
  dropped. With `rtx` negotiated it does not happen, so the tests and the
  guides keep `rtx`.
- **The VP9 file of the frame corpus is profile 1.**
  `test/corpora/frames/vp9.ivf` was encoded from RGB without `-pix_fmt
  yuv420p`, so it is 4:4:4, which the VP9 plugin does not decode. The tests
  check that it is refused, and decode the same pictures encoded in profile 0
  by FFmpeg.
