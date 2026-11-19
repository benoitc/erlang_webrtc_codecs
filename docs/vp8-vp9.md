# VP8 and VP9

VP8 is the video codec every WebRTC peer has; VP9 gives the same quality at
a lower bitrate for more CPU. Use this plugin to get the video of a peer as
pictures, or to send pictures you produce. It runs on libvpx, so the library
has to be there when you build.

## Build with libvpx

[Set up on your system](install.md) has the packages to install for each
system. Then:

```sh
rebar3 compile
```

Check that the codecs are there:

```erlang
[<<"VP8">>, <<"VP9">>] = [N || #{name := N, kind := video} <- webrtc_codecs:available()].
```

## Receive

```erlang
{ok, Pc} = webrtc:new_peer_connection(#{
    frames => true,
    codec_plugins => #{video => {webrtc_codecs, #{}}}
}),

receive
    {webrtc, Pc, {decoded, Mid, #{format := i420, width := W, height := H} = Picture}} ->
        show(Picture);
    {webrtc, Pc, {decoded, Mid, #{dropped := _Reason}}} ->
        webrtc:request_keyframe(Pc, Mid)
end.
```

## Send

Give one picture at a time, with its timestamp in 90 kHz units:

```erlang
{ok, _} = webrtc:add_transceiver(Pc, video, #{frames => true, codec_plugin => {webrtc_codecs, #{}}}),
ok = webrtc:send_media(Pc, Mid, #{
    format => i420,
    width => 640,
    height => 480,
    y => Y,
    u => U,
    v => V,
    timestamp => Ts
}).
```

## Follow the network

```erlang
receive
    {webrtc, Pc, {bandwidth_estimate, Bps}} ->
        ok = webrtc:send_media(Pc, Mid, #{bitrate => Bps});
    {webrtc, Pc, {keyframe_request, Mid}} ->
        ok = webrtc:send_media(Pc, Mid, #{keyframe => true})
end.
```

Both apply to the next picture. You can also put `bitrate` and `keyframe`
in the picture itself.

## Options

| Option | Default | Meaning |
|---|---|---|
| `bitrate` | from the picture size | Bitrate of the encoder at start, in bits per second |
| `min_bitrate` | `30000` | Lowest bitrate the encoder is given |
| `max_bitrate` | none | Highest bitrate the encoder is given |
| `keyframe_interval` | `3000` | Most frames between two key frames |
| `threads` | from the picture size (encoder), `1` (decoder) | Threads libvpx uses |
| `cpu_used` | `-6` (VP8), `7` (VP9) | libvpx speed setting: higher is faster and coarser |
| `max_pixels` | `8294400` (3840 x 2160) | Largest picture the decoder accepts |

```erlang
codec_plugin => {webrtc_codecs, #{bitrate => 800000, max_bitrate => 2500000}}
```

## Notes

- The encoder works in real time at a constant bitrate and holds no frame
  back: one picture in, one frame out.
- The default bitrate is 0.1 bit per pixel at 30 pictures per second: about
  230 kbit/s at 320 x 240, 920 kbit/s at 640 x 480.
- Pictures of another size start a new stream with a key frame.
- Width and height may be odd; the chroma planes are then rounded up.
- A frame that cannot be decoded gives `#{dropped => Reason, timestamp =>
  Ts}`, and so does every frame after it until a key frame
  (`waiting_for_keyframe`). Ask for one with `webrtc:request_keyframe/2`.
- A frame that declares a picture larger than `max_pixels` is dropped
  (`too_large`) before any memory is taken for it. For VP9 that is every
  frame of a superframe, the ones not shown included; a superframe index
  that does not fit its data is dropped as `invalid_frame`.
- VP9 is profile 0 only (8 bit, 4:2:0), which is what erlang_webrtc and
  browsers negotiate by default. Another `profile-id` fails `init/3`, and a
  frame of another profile is dropped (`unsupported_profile`).
- `qpSum` counts the quantizer index of each frame: 0 to 127 for VP8, 0 to
  255 for VP9.
