# Opus

Opus is the audio codec every browser sends and the one erlang_webrtc offers
first. Use this plugin to get the audio of a peer as samples, or to send
audio you produce. It runs on libopus, so the library has to be there when
you build.

## Build with libopus

[Set up on your system](install.md) has the packages to install for each
system. Then:

```sh
rebar3 compile
```

Check that the codec is there:

```erlang
[#{name := <<"opus">>, implementation := <<"libopus ", _/binary>>} | _] = webrtc_codecs:available().
```

To make the build fail when libopus is missing, rather than leave Opus out:

```sh
WEBRTC_CODECS_REQUIRE=opus rebar3 compile
```

## Receive

```erlang
{ok, Pc} = webrtc:new_peer_connection(#{
    frames => true,
    codec_plugins => #{audio => {webrtc_codecs, #{}}}
}),

receive
    {webrtc, Pc, {decoded, Mid, #{sample_rate := 48000, channels := Channels, samples := Pcm}}} ->
        play(Pcm, Channels)
end.
```

Decoded audio is at 48 kHz, in stereo when `stereo=1` was negotiated and
mono otherwise. Ask for another format with options:

```erlang
codec_plugins => #{audio => {webrtc_codecs, #{sample_rate => 16000, channels => 1}}}
```

## Send

Give 20 ms at a time, at 8, 12, 16, 24 or 48 kHz, one or two channels:

```erlang
ok = webrtc:send_media(Pc, Mid, #{
    format => s16le,
    sample_rate => 48000,
    channels => 1,
    samples => Pcm
}).
```

## Follow the network

Pass the audio share of the bandwidth estimate, and the loss the peer
reports, in a raw map. Both apply from the next frame.

```erlang
ok = webrtc:send_media(Pc, Mid, #{bitrate => 24000}),
ok = webrtc:send_media(Pc, Mid, #{packet_loss => 10}).
```

`packet_loss` is a percentage. With in-band FEC negotiated
(`useinbandfec=1`, which erlang_webrtc offers), the encoder adds redundancy
only when it is above 0.

## Options

Each defaults to what the negotiated `fmtp` says.

| Option | Default | Meaning |
|---|---|---|
| `sample_rate` | `48000` | Rate of decoded audio |
| `channels` | 2 with `stereo=1`, else 1 | Channels of decoded audio |
| `bitrate` | chosen by libopus | Bitrate of the encoder at start, in bits per second |
| `fec` | `useinbandfec` | Add redundancy for the previous frame |
| `dtx` | `usedtx` | Send nothing during silence |
| `packet_loss` | `0` | Loss expected at start, in percent |
| `max_playback_rate` | `maxplaybackrate`, else `48000` | Highest rate the peer plays, 8000 to 48000: the encoder sends no audio bandwidth above it |
| `application` | `voip` | `voip`, `audio` (music) or `lowdelay` |
| `complexity` | chosen by libopus | 0 (fastest) to 10 (best) |

## Notes

- When frames were lost, the next frame first gives the audio that fills the
  hole, up to 120 ms: the last lost frame recovered from the redundancy in
  the packet, the earlier ones synthesized. `concealedSamples` counts the
  synthesized ones. A packet without redundancy gets synthesized audio too,
  which is then not counted.
- A longer hole is taken as a pause and nothing is made up for it.
- A packet that is not valid Opus gives `#{dropped => invalid_packet,
  timestamp => Ts}`.
- The bitrate is kept between 6000 and 510000, under `maxaveragebitrate`
  when the peer gave one, and under the limit the peer puts on the stream
  while it has one. `webrtc:set_target_bitrate/3` sets it, as `bitrate` in
  the raw map does.
- Frames of 2.5, 5, 10, 20, 40 and 60 ms are accepted; another duration or
  sample rate makes `webrtc:send_media/3` return an error; that audio is
  lost and the plugin keeps running.
- With `dtx`, a call may send nothing; timestamps keep counting.
- RTP timestamps are at 48 kHz whatever the rate of your samples.
