# How it works

This page gives you the mental model of the package: what runs where, and
the path media takes in each direction. Read it before you change anything,
or when you want to know why a limit or a rule exists. It does not list
functions; [the module map](module-map.md) tells you which file to open.

## The three places code runs

Everything about blocking, limits and crashes follows from where code runs.

| Place | What runs there | What a failure costs |
|---|---|---|
| The transport process of a connection (erlang_webrtc) | The plugin's Erlang code: checks, state, statistics | A plugin that raises is turned off for its transceiver |
| A dirty scheduler of the VM | The codec library, through a NIF | A defect in a library can crash the whole node |
| An external program | FFmpeg and ffplay, for devices and files | The program ends; the node goes on |

A plugin is called by erlang_webrtc inside the transport process, the one
that handles every packet of the connection. So each call has to be short,
and has to come back. The codec work itself is native code, which cannot be
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
  frame that cannot be decoded comes back as a dropped output, and the
  plugin waits for the next key frame.
- **The plugin cannot ask for a key frame.** It has no handle on the
  connection. Your process sees the dropped output and calls
  `webrtc:request_keyframe/2`.

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

- **Your process is in the middle on purpose.** It is the one that receives
  `{keyframe_request, Mid}` and `{bandwidth_estimate, Bps}` from the
  connection. The plugin behaviour has no callback for either, so you pass
  them on inside the next raw map (`keyframe => true`, `bitrate => Bps`).
- **A slow reader loses frames, not memory.** The capture process reads
  FFmpeg one socket message at a time, and drops what your process leaves
  waiting. Nothing queues without a bound.
- **There is a second way that skips the plugin:** FFmpeg can encode what it
  captures, and you give the frames to `webrtc:send_frame/4`. You then lose
  bitrate changes and key frames on request.

## Who owns what

| Thing | Owner | Ends when |
|---|---|---|
| A native decoder or encoder | The plugin state, held by the transport process | That state is garbage collected |
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
