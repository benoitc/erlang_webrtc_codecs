# Play, show or record decoded media

`webrtc_codecs_playback` takes the pictures and audio a plugin decodes and
shows them in a window, plays them on the speaker, or writes them to a file.
Use the window and the speaker to check a call by eye and ear, and files in
automated tests. It runs the `ffplay` and `ffmpeg` executables as ports.
`webrtc_codecs_file` reads and writes IVF and WAV files in Erlang.

## Show the video of a peer

```erlang
{ok, Window} = webrtc_codecs_playback:start(window, #{width => 640, height => 480, frame_rate => 30}),

loop(Pc, Window) ->
    receive
        {webrtc, Pc, {decoded, _Mid, #{format := i420} = Picture}} ->
            _ = webrtc_codecs_playback:play(Window, Picture),
            loop(Pc, Window);
        {webrtc, Pc, _Event} ->
            loop(Pc, Window)
    end.
```

## Play the audio of a peer

```erlang
{ok, Speaker} = webrtc_codecs_playback:start(speaker, #{sample_rate => 48000, channels => 1}),
receive
    {webrtc, Pc, {decoded, _Mid, #{format := s16le} = Audio}} -> webrtc_codecs_playback:play(Speaker, Audio)
end.
```

## Record to a file

FFmpeg picks the container from the extension. `stop/1` returns when the
file is complete.

```erlang
{ok, File} = webrtc_codecs_playback:start({file, video, "call.mkv"}, #{width => 640, height => 480}),
ok = webrtc_codecs_playback:play(File, Picture),
case webrtc_codecs_playback:stop(File) of
    ok -> finished;
    {error, {not_finalized, _Status, Text}} -> {incomplete, Text}
end.
```

`stop/1` returns `ok` only when FFmpeg ended normally after the end of your
media, which is when the file is whole.

Choose the codec with `output_options`:

```erlang
#{width => 640, height => 480, output_options => ["-c:v", "libvpx", "-b:v", "1M"]}
```

A `.y4m` file keeps the pictures as they are, which lets a test compare them
sample for sample. Read a file back as raw media with
`webrtc_codecs_capture:start({file, video, Path}, Opts)`.

## Read and write IVF and WAV

IVF holds encoded video frames, the ones `encode/2` gives and `decode/2`
takes:

```erlang
ok = webrtc_codecs_file:write_ivf("out.ivf", #{fourcc => <<"VP80">>, width => 640, height => 480}, Frames),
{ok, #{fourcc := <<"VP80">>, frames := [#{data := Data, timestamp := Ts} | _]}} =
    webrtc_codecs_file:read_ivf("out.ivf").
```

WAV holds 16 bit PCM:

```erlang
ok = webrtc_codecs_file:write_wav("out.wav", [Audio1, Audio2]),
{ok, #{format := s16le, sample_rate := Rate, samples := Pcm}} = webrtc_codecs_file:read_wav("out.wav").
```

## Options

| Option | Default | Meaning |
|---|---|---|
| `width`, `height` | `640`, `480` | Size of the pictures, both even |
| `frame_rate` | `30` | Pictures per second |
| `sample_rate` | `48000` | Audio sample rate |
| `channels` | `1` | Audio channels, 1 or 2 |
| `output_options` | none | FFmpeg options before the name of a file |
| `title` | `"webrtc_codecs"` | Title of the window |
| `write_timeout` | `5000` | Milliseconds a file sink may take to accept what `play/2` gives it |
| `finish_timeout` | `15000` | Milliseconds `stop/1` gives FFmpeg to finish a file |
| `ffmpeg`, `ffplay` | from `PATH` | Paths of the executables |

## Notes

- Windows is not supported: the code for it has never been run.
- A sink takes one format. Media of another size or rate gets `{error,
  bad_format}`: start another sink when the size of the video changes.
- A window or the speaker that is behind makes `play/2` return `dropped`;
  nothing is queued. A file takes everything, and `play/2` waits for it, up
  to `write_timeout`. Past it, `play/2` returns `{error, stalled}`, FFmpeg
  is killed, and the sink takes nothing more.
- When the program ends by itself (the window was closed, the file cannot
  be written), `play/2` returns `{error, {ended, Status, Text}}` with the
  end of what it said.
- `stop/1` always returns and the program is always gone after it: one that
  does not end is sent SIGTERM, then SIGKILL. A sink that goes with its
  owner, without `stop/1`, ends its program at once and leaves the file as
  it is.
- At most one second of audio per call.
- The window and the speaker are not covered by the tests, since they need
  a person; files are.
- The fourcc of an IVF file is `VP80`, `VP90` or `AV01`. With the default
  time base of 1/90000 the timestamps are RTP timestamps.
