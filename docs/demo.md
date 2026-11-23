# Try it: your camera and microphone in a browser

This demo shows the camera of your machine in a browser tab and plays its
microphone there, through capture, the codec plugins and erlang_webrtc. It
can also play the browser's microphone on your speaker. Use it to check
with your own eyes and ears that the package works on your machine, which
the automated tests cannot do.

## Run it

You need FFmpeg, libvpx and libopus installed, see
[Set up on your system](install.md).

```sh
rebar3 shell
```

```erlang
1> c("examples/browser_media/browser_media").
2> browser_media:start(8080).
open http://localhost:8080/ and press Start
```

Open the page in Chrome, Firefox or Safari and press **Start**. On macOS
the first run asks to let your terminal use the camera and the microphone:
allow both, then press Start again.

You should see yourself, and hear your microphone when "play the sound" is
ticked. Use headphones, or the sound of the speaker goes back into the
microphone.

## Without a camera

FFmpeg's generated picture and tone stand in for the devices:

```erlang
browser_media:start(8080, #{video => {test, video}, audio => {test, audio}}).
```

## Choose the devices

```erlang
{ok, #{video := Cameras, audio := Microphones}} = webrtc_codecs_capture:devices().
browser_media:start(8080, #{video => {camera, 1}, audio => {microphone, <<"MacBook Pro Microphone">>}}).
```

| Option | Default | Meaning |
|---|---|---|
| `video` | `{camera, 0}` | A source of `webrtc_codecs_capture`, or `none` |
| `audio` | `{microphone, 0}` | A source of `webrtc_codecs_capture`, or `none` |
| `width`, `height` | `640`, `480` | Size of the pictures |
| `frame_rate` | `30` | Pictures per second |

## Play the browser's microphone on your speaker

Tick "send this browser's microphone to Erlang" before you press Start. The
browser asks for its own permission, Erlang decodes what it sends and plays
it with `webrtc_codecs_playback`. On one machine this loops the sound
(speaker to microphone and back): use headphones, or start with
`audio => none`.

## Stop

```erlang
browser_media:stop().
```

Reloading the page starts a new session and ends the previous one: a camera
has one reader.

## What it does

`examples/browser_media/browser_media.erl` is about 200 lines:

1. Erlang offers an audio and a video transceiver, each with the
   `webrtc_codecs` plugin; the page answers. Signaling is two HTTP requests.
2. Once connected, it starts one capture per source and passes every picture
   and chunk of audio to `webrtc:send_media/3`.
3. It gives the video encoder its share of `{bandwidth_estimate, Bps}` with
   `webrtc:set_target_bitrate/3`. Key frame requests of the browser reach
   the encoder without it.
4. Audio the browser sends comes back as `{decoded, Mid, Audio}` and goes to
   a speaker sink.

## When it does not work

- **"cannot capture" or "capture ended" in the shell**, with what FFmpeg
  said. The usual causes on macOS: the terminal has no camera or microphone
  permission (System Settings, Privacy & Security), or the camera does not
  offer 640 x 480 at 30. List what it offers with
  `ffmpeg -f avfoundation -framerate 30 -video_size 640x480 -i 0 -t 1 -f null -`
  and pass a size and rate it lists.
- **The page stays on "connecting".** The browser and Erlang have to reach
  each other directly: a VPN or a firewall on the loopback or the local
  network can prevent it.
- **Black video, sound works**, or the other way round: look for "codec
  plugin off" in the shell, and check `webrtc_codecs:available()`.
- **No sound.** Browsers only play sound after a click on the page, which
  Start is; check the "play the sound" box and the tab's mute state.

The page title shows what the browser decodes: the picture size, the frames
decoded and the audio samples received.

## Notes

- The demo serves on 127.0.0.1 only, without authentication: it is a way to
  try the package, not something to expose.
- Verified with FFmpeg's generated sources and headless Chromium: 640 x 480
  at 30 frames per second and 48 kHz audio, no frame dropped. With a real
  camera, a real microphone and the browser's microphone it was tried by
  hand on macOS with Safari.
