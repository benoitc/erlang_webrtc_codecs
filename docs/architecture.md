# How it works

This page gives you the mental model of the package: what runs where, and
the path media takes in each direction. Read it before you change anything,
or when you want to know why a limit or a rule exists. It does not list
functions; [the module map](module-map.md) tells you which file to open.

## The three places code runs

Everything about blocking, limits and crashes follows from where code runs.

| Place | What runs there | What a failure costs |
|---|---|---|
| The transport process of a connection (erlang_webrtc) | The plugin's Erlang code: checks, state, statistics | A plugin that raises is turned off for its transceiver; an error it returns with its state loses one frame |
| A dirty scheduler of the VM | The codec library, through a NIF | A defect in a library can crash the whole node |
| The process of `webrtc_codecs_async`, when you use it | The plugin's Erlang code and its NIF calls, in place of the transport process | The process ends and the plugin is turned off |
| An external program | FFmpeg and ffplay, for devices and files | The program ends; the node goes on |

A plugin is called by erlang_webrtc inside the transport process, the one
that handles every packet of the connection. So each call has to be short,
and has to come back; when a codec cannot be that short,
`webrtc_codecs_async` moves it to a process of its own (see below). The codec work itself is native code, which cannot be
interrupted: it runs on a dirty scheduler so that ordinary Erlang processes
keep running meanwhile. Devices are different again: opening a camera can
block for seconds or fail in ways no library reports cleanly, so that is
left to FFmpeg in its own program.

## Receiving: from packets to a picture

```
peer --RTP--> erlang_webrtc frame buffer --frame--> plugin decode/2
                                                        |
                                 header reader (Erlang): size, key frame?
                                                        |
                        too large, unreadable, or waiting for a key frame?
                               yes: dropped output          no
                                                             |
                                             NIF on a dirty scheduler
                                                             |
                                                    codec library
                                                             |
              {webrtc, Pc, {decoded, Mid, Picture}}  <-------+
                              |
                         your process --> sink (window, speaker, file)
```

Three decisions shape this path:

- **The size is read before the library is called.** A frame can declare a
  huge picture in a few bytes, and a library allocates on what it reads. The
  header reader refuses it first. See [Limits](limits.md).
- **Bad media is not an error.** erlang_webrtc turns a plugin off for good
  when it returns `{error, _}`. A peer must not be able to do that, so a
  frame that cannot be decoded comes back as a dropped output, counted in
  `framesDropped`, and the plugin waits for the next key frame.
- **The decoder asks for the key frame.** `decode/2` returns
  `keyframe_request` with the first frame it drops, and again about once a
  second while it waits, and erlang_webrtc sends it to the peer. It does
  not ask when a key frame would not help, for a picture that is too large
  for example.

## Sending: from a camera to packets

```
camera --> FFmpeg (own program) --socket--> capture process
                                                  |
                                    {webrtc_capture, Pid, Picture}
                                                  |
                                            your process
                                                  |
                                   webrtc:send_media(Pc, Mid, Picture)
                                                  |
                              plugin encode/2, in the transport process
                                                  |
                                    NIF on a dirty scheduler
                                                  |
                                           codec library
                                                  |
                         frames --> erlang_webrtc packetizes --RTP--> peer
```

- **The encoder hears the connection.** erlang_webrtc calls `control/2`
  of the plugin when the peer asks for a key frame, when the peer limits
  the bitrate of the stream, and when you call
  `webrtc:set_target_bitrate/3`. The encoder is given the lower of the
  bitrate asked for and the peer's limit, at the next picture.
- **Your process shares the bandwidth.** `{bandwidth_estimate, Bps}` is for
  the whole connection and comes to you: you decide what each encoder
  gets. `bitrate` and `keyframe => true` in a raw map still work.
- **A slow reader loses frames, not memory.** The capture process reads
  FFmpeg one socket message at a time, and drops what your process leaves
  waiting. Nothing queues without a bound.
- **There is a second way that skips the plugin:** FFmpeg can encode what it
  captures, and you give the frames to `webrtc:send_frame/4`. You then lose
  bitrate changes and key frames on request.

## With `webrtc_codecs_async`

The two paths above stay the same except for where the plugin runs.
`webrtc_codecs_async` is a plugin that wraps another one:

```
transport process                         worker (one per stream)
-----------------                         -----------------------
decode/2, encode/2, control/2
   room for one more? ----- message ----> the wrapped plugin, as above:
   yes: return at once                    header reader, NIF, library
   no:  drop or refuse                          |
                                                |
erlang_webrtc  <--- decoded/3, encoded/3 -------+
```

- **Its callbacks never wait.** They count what the worker has in flight in
  a counter both processes see, hand over the frame or the raw media, and
  return.
- **The bound is `max_in_flight`.** Past it a picture to encode is refused,
  and a video frame to decode is dropped with the frames after it, until a
  key frame, which is asked for. Nothing queues without a bound.
- **The worker owns the codecs.** They are created, used and closed there.
  It ends with the stream and with the transport process, which it
  monitors.
- **What it cannot do:** return an encoder error to `webrtc:send_media/3`,
  which has returned already. Such an error is logged.

See [Run the codec outside the transport process](async.md) for how to use
it.

## Who owns what

| Thing | Owner | Ends when |
|---|---|---|
| A native decoder or encoder | The plugin state, held by the transport process, or by the worker of `webrtc_codecs_async` | The stream ends or the connection closes (`terminate/1`); when the state is garbage collected otherwise |
| The FFmpeg of a capture | The capture process | The capture stops, or its owner dies |
| The FFmpeg or ffplay of a sink | The sink process | `stop/1`, or the process that started it dies |

An external program is always ended by its owner: waited for, asked to end,
then killed. No program outlives the process that started it.

## Why one module per codec family, and one shared for video

Each codec module answers two questions only it can answer: what does this
frame's header say, and how do I call this library. Everything a video codec
does around those (the size limit, waiting for a key frame, bitrate, key
frame requests, timestamps, statistics) is the same for all of them, and
lives once in `webrtc_codecs_video`. Audio codecs differ too much from each
other to share that way.

`webrtc_codecs` itself is a plugin that picks the module of whichever codec
was negotiated, so that you set one plugin and do not care which codec the
peer chose.

## Why a missing library is not a failed build

Each library has its own NIF, built only when the library is found. A
machine without OpenH264 still gets the other codecs, and
`webrtc_codecs:available/0` says what is there. A build that must have a
codec sets `WEBRTC_CODECS_REQUIRE`.

## Read next

- [Module map](module-map.md): which file and which test for each of these.
- [Limits and what they do not cover](limits.md).
- [What the codec behaviour lacks](behaviour-gaps.md): why some things go
  through your process.
- [Glossary](glossary.md).
