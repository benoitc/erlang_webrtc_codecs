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

Found while testing the plugins.

- **AV1 and H.264 frames were dropped after padding on the media stream.**
  Fixed in erlang_webrtc 0.2.0. In 0.1.0, between two peers that negotiated
  AV1 or H.264 without its `rtx` format, 1 frame of 60 was decoded: padding
  sent on the media stream was read as a loss by the frame buffer. This
  package requires 0.2.0, and `webrtc_codecs_peer_SUITE` has a case that
  fails if it comes back.
- **No public way to put a codec first.** Fixed in 0.2.0 with
  `webrtc:default_codecs/1` and `webrtc:prefer_codec/2`, which the guides
  now use.
- **H.264 `packetization-mode=0` is packetized like mode 1.** erlang_webrtc
  0.2.0 groups small NAL units in one packet and cuts large ones whatever
  mode was negotiated, where mode 0 allows one whole unit per packet only.
  The H.264 plugin keeps every unit it writes under the size of a packet in
  mode 0, so none is cut; the parameter sets of a key frame may still be
  grouped. Its own offer is mode 1, so this shows only with a peer that
  offers mode 0 alone.
- **The VP9 file of the frame corpus is profile 1.**
  `test/corpora/frames/vp9.ivf` was encoded from RGB without `-pix_fmt
  yuv420p`, so it is 4:4:4, which the VP9 plugin does not decode. This
  package keeps a copy in `test/corpus`: the tests check that it is refused,
  and decode the same pictures encoded in profile 0 by FFmpeg.
