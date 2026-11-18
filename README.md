# erlang_webrtc_codecs

Codec plugins for [erlang_webrtc](https://github.com/benoitc/erlang_webrtc).
erlang_webrtc moves encoded frames and does no media coding; this package
decodes the frames a transceiver receives and encodes the raw pictures and
audio you send. Use it when your application has to look at or produce the
media itself, rather than forward it.

| Codec | Decode | Encode | Needs |
|---|---|---|---|
| Opus | yes | yes | libopus |
| VP8, VP9 (profile 0) | yes | yes | libvpx |
| AV1 (main profile) | yes | yes | dav1d (decode), libaom (encode) |
| G.711 (PCMU, PCMA) | yes | yes | nothing, pure Erlang |

H.264 and device capture are not there yet.

## Build and test

You need Erlang/OTP 29 or later and rebar3. For the native codecs you also
need CMake, pkg-config, a C compiler and the library of each codec; a codec
whose library is missing is left out of the build.

```sh
rebar3 compile
rebar3 eunit
rebar3 ct
```

## Add it to your project

```erlang
{deps, [
    {webrtc_codecs, {git, "https://github.com/benoitc/erlang_webrtc_codecs.git", {branch, "main"}}}
]}.
```

## Decode what a peer sends

```erlang
{ok, Pc} = webrtc:new_peer_connection(#{
    frames => true,
    codec_plugins => #{audio => {webrtc_codecs, #{}}}
}),

receive
    {webrtc, Pc, {decoded, Mid, #{format := s16le, samples := Pcm}}} -> play(Pcm)
end.
```

`webrtc_codecs` picks the plugin of the codec that was negotiated.

## Encode what you send

```erlang
{ok, _} = webrtc:add_transceiver(Pc, audio, #{frames => true, codec_plugin => {webrtc_codecs, #{}}}),
ok = webrtc:send_media(Pc, Mid, #{format => s16le, sample_rate => 8000, channels => 1, samples => Pcm}).
```

## See which codecs this build has

```erlang
[#{name := <<"opus">>, kind := audio, decode := true, encode := true} | _] = webrtc_codecs:available().
```

## Documentation

- [Raw media](docs/raw-media.md): the pictures and audio you exchange with a plugin, bitrate and key frame requests
- [VP8 and VP9](docs/vp8-vp9.md)
- [AV1](docs/av1.md)
- [Opus](docs/opus.md)
- [G.711](docs/g711.md)
- [What the codec behaviour lacks](docs/behaviour-gaps.md), and issues met in erlang_webrtc
- [Contributing](CONTRIBUTING.md)

## License

Apache-2.0
