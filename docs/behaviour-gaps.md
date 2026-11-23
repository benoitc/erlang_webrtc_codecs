# What the codec behaviour lacks

This page lists what `webrtc_media_codec` in erlang_webrtc does not let a
plugin do, and how this package works within it. You need it when you wonder
why a plugin behaves as it does, or when you plan a change to the behaviour.

Nothing is missing today for what the plugins do. One thing the behaviour
offers is not used yet:

| Offered by erlang_webrtc 0.3.0 | Here |
|---|---|
| A plugin that runs its codec in a process of its own and delivers later (`init/4`) | Not used: every call is synchronous, so the transport process waits for the codec. To keep it free today, run the plugin module in your own process and use `webrtc:send_frame/4` and `webrtc:report_media_stats/4` |

## What was missing before 0.3.0

Each of these was worked around in versions 0.1 of this package, and is
now done through the behaviour.

| Was missing | Now |
|---|---|
| A way to tell the encoder the bitrate changed | `control/2` gets the target set with `webrtc:set_target_bitrate/3` and the limit of the peer. `bitrate` in the raw map still works |
| A way to tell the encoder a key frame is wanted | `control/2` gets the request of the peer. `keyframe => true` in the raw map still works |
| A way for a decoder to ask the sender for a key frame | `decode/2` returns `keyframe_request` with a frame it drops |
| A recoverable error | Raw media in the wrong format returns an error with the state: one picture is lost, the plugin stays on |
| A count of frames the decoder dropped | The video plugins report `framesDropped` |
| A callback when the transceiver stops | `terminate/1` destroys the native codecs |

## Issues met in erlang_webrtc

Found while testing the plugins.

- **AV1 and H.264 frames were dropped after padding on the media stream.**
  Fixed in erlang_webrtc 0.2.0. In 0.1.0, between two peers that negotiated
  AV1 or H.264 without its `rtx` format, 1 frame of 60 was decoded: padding
  sent on the media stream was read as a loss by the frame buffer. This
  package requires 0.3.0, and `webrtc_codecs_peer_SUITE` has a case that
  fails if it comes back.
- **No public way to put a codec first.** Fixed in 0.2.0 with
  `webrtc:default_codecs/1` and `webrtc:prefer_codec/2`, which the guides
  now use.
- **H.264 `packetization-mode=0` was packetized like mode 1.** Fixed in
  erlang_webrtc 0.3.0: each mode gets the packet types it allows, and in
  mode 0 a frame with a NAL unit too large for one packet is refused. The
  H.264 plugin keeps every unit it writes under that size in mode 0.
- **The VP9 file of the frame corpus is profile 1.**
  `test/corpora/frames/vp9.ivf` was encoded from RGB without `-pix_fmt
  yuv420p`, so it is 4:4:4, which the VP9 plugin does not decode. This
  package keeps a copy in `test/corpus`: the tests check that it is refused,
  and decode the same pictures encoded in profile 0 by FFmpeg.
