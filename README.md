# erlang_webrtc_codecs

Codec plugins for [erlang_webrtc](https://github.com/benoitc/erlang_webrtc).
erlang_webrtc moves encoded frames and does no media coding; this package
decodes the frames a transceiver receives and encodes the raw pictures and
audio you send. Use it when your application has to look at or produce the
media itself, rather than forward it.

> **Status: experimental.** This package is new.
> Its API, its options and the shape of the raw media may change without
> notice. Do not put it in front of peers you do not trust yet: see what
> is and is not tested below, and [the limits](docs/limits.md).

| Codec | Decode | Encode | Needs |
|---|---|---|---|
| Opus | yes | yes | libopus |
| VP8, VP9 (profile 0) | yes | yes | libvpx |
| H.264 (decodes baseline, main, high; encodes constrained baseline) | yes | yes | OpenH264 |
| AV1 (main profile) | yes | yes | dav1d (decode), libaom (encode) |
| G.711 (PCMU, PCMA) | yes | yes | nothing, pure Erlang |

It also captures raw pictures and audio from a camera, a microphone or a
file, and shows, plays or records what is decoded, through the `ffmpeg` and
`ffplay` executables. FFmpeg can also encode what it captures, hardware
encoders included.

## Where to start

- **You want to see it work:** [the demo](docs/demo.md) puts your camera and
  microphone in a browser.
- **You want to use a codec:** [set up your system](docs/install.md), read
  [Raw media](docs/raw-media.md), then the guide of the codec.
- **You want to understand or change it:** [How it works](docs/architecture.md),
  then the [module map](docs/module-map.md) and [CONTRIBUTING](CONTRIBUTING.md).

## Status

Experimental. What that means today:

- **Early versions.** Expect breaking changes between versions until 1.0.
- **Tested:** every codec against itself, against FFmpeg's decoders and a
  copy of the frame corpus of erlang_webrtc, between two erlang_webrtc peers, and against
  headless Chromium in both directions. Capture and recording with FFmpeg's
  generated sources and files. On macOS, Linux (Debian, Alpine) and FreeBSD,
  on arm64, and in CI.
- **Tried by hand, once:** a real camera and microphone to a browser, and
  the browser's microphone to the speaker, on macOS with Safari, through
  [the demo](docs/demo.md). No automated test covers real devices, the
  window or the speaker.
- **Not tested:** no phone, no SIP gateway, and no browser in the automated
  tests other than Chromium. No physical microphone on Linux or FreeBSD,
  only virtual ones, by hand.
- **Not supported:** Windows. The native codecs are not built there and
  its capture and playback code has never been run.
- **Native code runs inside your node.** The codec libraries are called
  through NIFs: a defect in one of them on hostile media can crash the node.
  The package bounds what it hands them, and was run under sanitizers, but
  that is not a proof. [Limits and what they do not cover](docs/limits.md)
  is the honest list.
- **It follows erlang_webrtc.** The plugins need erlang_webrtc 0.2.0 or
  later, which is itself young.

Reports of what works or breaks on your setup are welcome as issues.

## Build and test

You need Erlang/OTP 29 or later and rebar3. For the native codecs you also
need CMake, pkg-config, a C compiler and the library of each codec; a codec
whose library is missing is left out of the build. It is tested on macOS,
Linux (Debian, Alpine) and FreeBSD.

[Set up on your system](docs/install.md) has the packages to install on
macOS, Debian, Ubuntu, Alpine, Fedora and FreeBSD. On macOS:

```sh
brew install erlang rebar3 cmake pkg-config ffmpeg opus libvpx openh264 dav1d aom
```

```sh
rebar3 compile
rebar3 eunit
rebar3 ct
```

## Add it to your project


```erlang
{deps, [
    {webrtc_codecs, "0.1.1"}
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

- [Set up on your system](docs/install.md): what to install on each operating system
- [Try it: your camera and microphone in a browser](docs/demo.md)
- [Raw media](docs/raw-media.md): the pictures and audio you exchange with a plugin, bitrate and key frame requests
- [VP8 and VP9](docs/vp8-vp9.md)
- [H.264](docs/h264.md)
- [AV1](docs/av1.md)
- [Opus](docs/opus.md)
- [G.711](docs/g711.md)
- [Capture from a camera or a microphone](docs/capture.md)
- [Play, show or record decoded media](docs/playback.md)
- [How it works](docs/architecture.md): what runs where, and the path of a frame
- [Module map](docs/module-map.md): which file and which test for a behaviour
- [Glossary](docs/glossary.md)
- [Limits and what they do not cover](docs/limits.md)
- [What the codec behaviour lacks](docs/behaviour-gaps.md), and issues met in erlang_webrtc
- [Contributing](CONTRIBUTING.md)
- [Security policy](SECURITY.md): how to report a vulnerability

## License

Apache License 2.0, see [LICENSE](LICENSE).
