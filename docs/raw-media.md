# Raw media

Raw media is what a decoder gives you and what you give an encoder: pictures
and audio samples as Erlang maps. You need this page when you write the code
that produces or consumes them, whatever the codec.

## Pictures

A picture is three I420 planes without padding: `y` is `width * height`
bytes, `u` and `v` are a quarter of that each. When the width or the height
is odd, the chroma planes round it up.

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

A key frame the peer asks for reaches the encoder without you, and so does
a limit the peer puts on the stream. The bandwidth estimate is for the whole
connection, so you give each encoder its share:

```erlang
receive
    {webrtc, Pc, {bandwidth_estimate, Bps}} ->
        ok = webrtc:set_target_bitrate(Pc, VideoMid, Bps - 40000)
end.
```

You can also change the encoder in the raw map: `bitrate => Bps` and
`keyframe => true`, in a picture or in a map of their own, which sends
nothing. The encoder is given the lower of what you ask and what the peer
allows.

## Receive raw media

```erlang
receive
    {webrtc, Pc, {decoded, Mid, #{format := i420} = Picture}} -> show(Picture);
    {webrtc, Pc, {decoded, Mid, #{format := s16le} = Audio}} -> play(Audio);
    {webrtc, Pc, {decoded, Mid, #{dropped := Reason}}} -> logger:info("frame dropped: ~p", [Reason])
end.
```

## Notes

- A frame the decoder cannot decode is dropped and reported as
  `#{dropped => Reason, timestamp => Ts}`; the plugin keeps running. A video
  decoder counts it in `framesDropped` and asks the sender for a key frame
  itself; the `request_keyframes => false` option leaves that to you.
- Raw media in the wrong format (for example 48 kHz audio for G.711) makes
  `webrtc:send_media/3` return `{error, {encode, Reason}}`. That picture or
  audio is lost and the plugin keeps running.
- A codec that cannot start turns the plugin off for that transceiver, and
  you get `{codec_plugin_error, Mid, Reason}`.
- The codecs of a transceiver are destroyed when its stream ends or the
  connection closes.
- Encoding and decoding run in the transport process of the connection, so
  each call delays its packets by the time the codec takes.
- `webrtc_codecs_pattern:picture/3` and `tone/4` make raw media for tests.
