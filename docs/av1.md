# AV1

AV1 gives better quality than VP9 at the same bitrate, for more CPU when
encoding. Use this plugin to get the AV1 video of a peer as pictures, or to
send pictures you produce. Decoding runs on dav1d and encoding on libaom;
each is optional.

## Build with dav1d and libaom

```sh
brew install dav1d aom cmake pkg-config        # macOS
sudo apt-get install libdav1d-dev libaom-dev cmake pkg-config   # Debian, Ubuntu
rebar3 compile
```

[Set up on your system](install.md) has the other systems.

Check what this build can do:

```erlang
[#{decode := true, encode := true}] = [C || #{name := <<"AV1">>} = C <- webrtc_codecs:available()].
```

With only dav1d the plugin decodes and `encode` is `false`; with only libaom
it is the other way round.

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

erlang_webrtc offers VP8 first. To send AV1, put it first in the codecs you
offer, with its retransmission format:

```erlang
Video = webrtc_jsep_caps:default_codecs(video),
[#{pt := Pt} = Av1] = [C || #{name := <<"AV1">>} = C <- Video],
Rtx = [C || #{name := <<"rtx">>, fmtp := [{<<"apt">>, Apt}]} = C <- Video, Apt =:= integer_to_binary(Pt)],
{ok, Pc} = webrtc:new_peer_connection(#{codecs => #{video => [Av1 | Rtx]}}),
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

## Options

| Option | Default | Meaning |
|---|---|---|
| `bitrate` | from the picture size | Bitrate of the encoder at start, in bits per second |
| `min_bitrate` | `30000` | Lowest bitrate the encoder is given |
| `max_bitrate` | none | Highest bitrate the encoder is given |
| `keyframe_interval` | `3000` | Most frames between two key frames |
| `threads` | from the picture size (encoder), `1` (decoder) | Threads the library uses |
| `cpu_used` | `9` | libaom speed setting, 0 to 11: higher is faster and coarser |
| `max_pixels` | `8294400` (3840 x 2160) | Largest picture the decoder accepts |

## Notes

- Main profile only: 8 bit, 4:2:0 or monochrome. Another `profile` in the
  negotiated `fmtp` fails `init/3`; a picture in another format is dropped
  (`unsupported_format`).
- A frame is a temporal unit in the low overhead format, as erlang_webrtc
  delivers and sends it. A unit with a sequence header is taken as a key
  frame.
- A frame that cannot be decoded gives `#{dropped => Reason, timestamp =>
  Ts}`, and so does every frame after it until a key frame
  (`waiting_for_keyframe`).
- A picture larger than `max_pixels` is refused by dav1d before it takes
  memory for it (`too_large`).
- The encoder works in real time at a constant bitrate and holds no frame
  back. Pictures of another size start a new stream with a key frame.
- Keep the `rtx` format next to AV1 when you narrow the codecs. Without it,
  see "Issues met in erlang_webrtc" in
  [What the codec behaviour lacks](behaviour-gaps.md).
