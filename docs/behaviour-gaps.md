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
