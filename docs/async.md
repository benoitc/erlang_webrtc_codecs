# Run the codec outside the transport process

The plugins of this package run their codec inside the transport process of
the peer connection: while a picture is encoded or decoded, every other
packet of that connection waits, data channels included.
`webrtc_codecs_async` runs the same plugins in a process of its own. Use it
when a codec call takes more than a few milliseconds: large pictures, AV1,
a busy machine, or a connection that also carries data channels.

## Use it

Name `webrtc_codecs_async` where you named `webrtc_codecs`. The options of
the codec go with it:

```erlang
{ok, Pc} = webrtc:new_peer_connection(#{
    frames => true,
    codec_plugins => #{video => {webrtc_codecs_async, #{}}}
}),
{ok, _} = webrtc:add_transceiver(Pc, video, #{
    frames => true,
    codec_plugin => {webrtc_codecs_async, #{bitrate => 800000}}
}).
```

What you send and what you receive is the same as with `webrtc_codecs`:

```erlang
ok = webrtc:send_media(Pc, Mid, Picture),

receive
    {webrtc, Pc, {decoded, Mid, #{format := i420} = Decoded}} -> show(Decoded)
end.
```

## When the codec is behind

The process works on one frame or picture at a time and holds a few more.
When it has no room:

```erlang
case webrtc:send_media(Pc, Mid, Picture) of
    ok -> ok;
    %% The encoder is behind: this picture is not sent.
    {error, {encode, busy}} -> skipped
end.
```

- A picture or audio to encode is refused, as above. Nothing is sent for it.
- A video frame to decode is dropped: you get `#{dropped => busy, timestamp
  => Ts}`, the sender is asked for a key frame, and frames are dropped until
  that key frame comes.
- An audio frame to decode is dropped; Opus fills the hole from the next
  frame.

## Options

| Option | Default | Meaning |
|---|---|---|
| `plugin` | `webrtc_codecs` | The plugin module to run |
| `max_in_flight` | `4` for video, `16` for audio | Frames or raw media the process may have waiting |
| any other | | Passed to the plugin it runs |

## Notes

- `webrtc:send_media/3` returns before the picture is encoded. An encoder
  error for it cannot be returned any more: it is logged, once for a run of
  them. Raw media in the wrong format is such an error.
- A codec that cannot start, or a plugin that raises, ends the process. The
  next frame or picture then turns the plugin off for the transceiver, and
  you get `{codec_plugin_error, Mid, worker_down}`.
- The process ends with the stream and with the connection, and closes its
  codecs.
- A map that only changes the encoder (`bitrate`, `keyframe`) is taken when
  a picture would be refused, up to four times `max_in_flight`.
- Measured between two peers on one machine, with an encoder made to take
  60 ms a picture at 30 pictures a second: a data channel message of the
  same connection took 26 to 41 ms with the codec in the transport process,
  and under 1 ms with this plugin. `webrtc_codecs_peer_SUITE` logs the
  figures of your machine.
- The codec still runs on the dirty schedulers of the node: this frees the
  connection, not the machine.
