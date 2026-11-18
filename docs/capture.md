# Capture from a camera or a microphone

erlang_webrtc captures nothing. `webrtc_codecs_capture` gives you raw pictures
and audio from a camera, a microphone, a file or a generated test source, to
pass to `webrtc:send_media/3`. Use it when the media you send comes from the
machine the node runs on. It runs the `ffmpeg` executable as a port, so
FFmpeg has to be installed; nothing is linked into the VM.

## List the devices

```erlang
{ok, #{video := Cameras, audio := Microphones}} = webrtc_codecs_capture:devices(),
[#{index := 0, name := Name} | _] = Cameras.
```

## Capture and send

```erlang
{ok, _} = webrtc:add_transceiver(Pc, video, #{frames => true, codec_plugin => {webrtc_codecs, #{}}}),
{ok, Camera} = webrtc_codecs_capture:start({camera, 0}, #{width => 640, height => 480, frame_rate => 30}),

loop(Pc, Mid, Camera) ->
    receive
        {webrtc_capture, Camera, #{format := i420} = Picture} ->
            ok = webrtc:send_media(Pc, Mid, Picture),
            loop(Pc, Mid, Camera);
        {webrtc_capture, Camera, {error, Reason}} ->
            {error, Reason};
        {webrtc, Pc, {keyframe_request, Mid}} ->
            ok = webrtc:send_media(Pc, Mid, #{keyframe => true}),
            loop(Pc, Mid, Camera);
        {webrtc, Pc, _Event} ->
            loop(Pc, Mid, Camera)
    end.
```

A microphone works the same way and gives audio:

```erlang
{ok, Microphone} = webrtc_codecs_capture:start({microphone, <<"MacBook Pro Microphone">>}, #{
    sample_rate => 48000,
    channels => 1,
    frame_ms => 20
}),
receive
    {webrtc_capture, Microphone, #{format := s16le} = Audio} -> webrtc:send_media(Pc, AudioMid, Audio)
end.
```

## Capture without a device

For tests and machines without a camera, FFmpeg generates the media: a
moving test picture and a 440 Hz tone.

```erlang
{ok, Video} = webrtc_codecs_capture:start({test, video}, #{width => 320, height => 240}),
{ok, Audio} = webrtc_codecs_capture:start({test, audio}, #{sample_rate => 8000}).
```

A file FFmpeg can read is a source too:

```erlang
{ok, File} = webrtc_codecs_capture:start({file, video, "clip.mp4"}, #{width => 640, height => 360}),
receive
    {webrtc_capture, File, eof} -> done
end.
```

## Stop

```erlang
ok = webrtc_codecs_capture:stop(Camera).
```

The capture also stops when its owner exits, and by itself when the source
ends, after sending `eof` or `{error, Reason}`.

## Options

| Option | Default | Meaning |
|---|---|---|
| `owner` | the caller | Process that gets the media |
| `width`, `height` | `640`, `480` | Size of pictures, both even |
| `frame_rate` | `30` | Pictures per second |
| `sample_rate` | `48000` | Audio sample rate |
| `channels` | `1` | Audio channels |
| `frame_ms` | `20` | Duration of each chunk of audio |
| `max_queue` | `10` | Messages the owner may have waiting before capture drops |
| `realtime` | `true` | Pace a file or a test source at its own rate |
| `input_options` | derived | FFmpeg options before the input, replacing the derived ones |
| `ffmpeg` | from `PATH` | Path of the executable |

## Notes

- Keep reading your mailbox. When the owner has more than `max_queue`
  messages waiting, of any kind, what is captured is dropped and counted in
  `webrtc_codecs_capture:stats/1`. An owner that also owns the peer
  connection has to read its `{webrtc, Pc, _}` events too.
- A dropped picture keeps its place in the timestamps. Audio has no
  timestamp: the encoder counts the samples it is given.
- macOS asks for camera and microphone access the first time; the terminal
  or the application that runs the node needs the permission. On Linux the
  user has to be in the `video` and `audio` groups.
- A camera only opens with a size and a rate it supports. When it refuses,
  the reason FFmpeg gives comes in `{error, {ffmpeg, Status, Text}}`; pass
  the right ones in `input_options`, for example `["-framerate", "30",
  "-video_size", "1280x720"]`.
- Devices are opened with avfoundation on macOS, v4l2 and pulse on Linux and
  dshow on Windows. Only macOS listing and the generated sources are covered
  by the tests; opening a real device is not, since it needs a person to
  grant access.
- For G.711 capture at 8000 Hz; for Opus at 48000 Hz or another rate Opus
  takes.
