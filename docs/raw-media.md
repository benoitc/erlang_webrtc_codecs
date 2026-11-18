# Raw media

Raw media is what a decoder gives you and what you give an encoder: pictures
and audio samples as Erlang maps. You need this page when you write the code
that produces or consumes them, whatever the codec.

## Pictures

A picture is three I420 planes without padding. Width and height are even;
`y` is `width * height` bytes, `u` and `v` are a quarter of that each.

```erlang
Picture = #{
    format => i420,
    width => 640,
    height => 480,
    y => Y,
    u => U,
    v => V,
    timestamp => Ts
}.
```

`timestamp` is in 90 kHz units. A decoded picture keeps the RTP timestamp of
the frame it came from.

## Audio

Audio is signed 16 bit little endian samples, interleaved by channel.

```erlang
Audio = #{
    format => s16le,
    sample_rate => 48000,
    channels => 2,
    samples => Pcm
}.
```

Give an encoder 10 or 20 ms at a time. `timestamp` is optional when you
encode: the encoder counts samples from the last timestamp it was given, or
from 0. Decoded audio carries the RTP timestamp of its frame.

## Send raw media

```erlang
{ok, _} = webrtc:add_transceiver(Pc, video, #{frames => true, codec_plugin => {webrtc_codecs, #{}}}),
ok = webrtc:send_media(Pc, Mid, Picture).
```

## Follow the bitrate and key frame requests

The owner of the peer connection gets both events; pass them on in the next
raw map.

```erlang
receive
    {webrtc, Pc, {bandwidth_estimate, Bps}} ->
        ok = webrtc:send_media(Pc, Mid, #{bitrate => Bps});
    {webrtc, Pc, {keyframe_request, Mid}} ->
        ok = webrtc:send_media(Pc, Mid, NextPicture#{keyframe => true})
end.
```

A map without a picture or samples changes the encoder and sends nothing.
`bitrate` is the target for this transceiver, so share the estimate between
audio and video yourself.

## Receive raw media

```erlang
receive
    {webrtc, Pc, {decoded, Mid, #{format := i420} = Picture}} -> show(Picture);
    {webrtc, Pc, {decoded, Mid, #{format := s16le} = Audio}} -> play(Audio);
    {webrtc, Pc, {decoded, Mid, #{dropped := _Reason}}} -> webrtc:request_keyframe(Pc, Mid)
end.
```

## Notes

- A frame the decoder cannot decode is dropped and reported as
  `#{dropped => Reason, timestamp => Ts}`; the plugin keeps running.
- Raw media in the wrong format (for example 48 kHz audio for G.711) is an
  error. erlang_webrtc then turns the plugin off for that transceiver and
  sends you `{codec_plugin_error, Mid, Reason}`.
- Encoding and decoding run in the transport process of the connection, so
  each call delays its packets by the time the codec takes.
- `webrtc_codecs_pattern:picture/3` and `tone/4` make raw media for tests.
