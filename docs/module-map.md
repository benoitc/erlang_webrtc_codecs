# Module map

This page tells you which file to open for a behaviour, and which test
covers it. Use it when you want to change something and do not know where
it lives. Read [How it works](architecture.md) first for why the pieces are
split this way.

## What is public and what is not

You call these: `webrtc_codecs`, the codec modules as plugins,
`webrtc_codecs_capture`, `webrtc_codecs_playback`, `webrtc_codecs_file`,
`webrtc_codecs_pattern`.

These are internal and may change without notice: `webrtc_codecs_video`,
`webrtc_codecs_exec`, `webrtc_codecs_nif` and every `webrtc_codecs_*_nif`
module.

## Where things live

| You want to change | Module | Tests |
|---|---|---|
| Which codec the plugin picks, the list of codecs | `src/webrtc_codecs.erl` | `test/webrtc_codecs_tests.erl` |
| What every video plugin does around its library: size limit, waiting for a key frame, bitrate, key frame requests, statistics | `src/webrtc_codecs_video.erl` | `test/webrtc_codecs_video_checks.erl`, run by each video codec's tests |
| VP8 or VP9: options, header and superframe reading | `src/webrtc_codecs_vpx.erl` | `test/webrtc_codecs_vpx_tests.erl` |
| H.264: options, NAL units, parameter sets | `src/webrtc_codecs_h264.erl` | `test/webrtc_codecs_h264_tests.erl` |
| AV1: options, OBU reading | `src/webrtc_codecs_av1.erl` | `test/webrtc_codecs_av1_tests.erl` |
| Opus: options, lost frames, bitrate | `src/webrtc_codecs_opus.erl` | `test/webrtc_codecs_opus_tests.erl` |
| G.711 | `src/webrtc_codecs_g711.erl` | `test/webrtc_codecs_g711_tests.erl` |
| A call into a codec library | `c_src/webrtc_codecs_<lib>_nif.c`, declared in `src/webrtc_codecs_<lib>_nif.erl` | the codec's tests, `test/webrtc_codecs_lifecycle_SUITE.erl`, `scripts/test-sanitizers.sh` |
| What the NIFs share | `c_src/webrtc_codecs_nif.h` | all of the above |
| How FFmpeg is started, watched and ended | `src/webrtc_codecs_exec.erl` | the capture and playback tests, with `test/fake_ffmpeg.escript` |
| Capture: sources, device listing, encoded capture, the drop policy | `src/webrtc_codecs_capture.erl` | `test/webrtc_codecs_capture_tests.erl` |
| Sinks: window, speaker, file | `src/webrtc_codecs_playback.erl` | `test/webrtc_codecs_playback_tests.erl` |
| IVF and WAV files | `src/webrtc_codecs_file.erl` | `test/webrtc_codecs_file_tests.erl` |
| The test picture and tone, PSNR, SNR | `src/webrtc_codecs_pattern.erl` | `test/webrtc_codecs_pattern_tests.erl` |
| The build of native code | `c_src/CMakeLists.txt`, `c_src/build_nif.sh`, the hooks in `rebar.config` | CI, `scripts/test-linux.sh`, `scripts/test-freebsd.sh` |
| The demo | `examples/browser_media/` | by hand, see [the demo](demo.md) |

## Tests that cross modules

| Test | What it shows |
|---|---|
| `test/webrtc_codecs_peer_SUITE.erl` | The plugins and the captures inside two erlang_webrtc peer connections on loopback |
| `test/webrtc_codecs_browser_SUITE.erl` | The video plugins against headless Chromium, both ways. Skips itself without the browser peer of erlang_webrtc |
| `test/webrtc_codecs_lifecycle_SUITE.erl` | Native contexts shared, left by killed owners, fed bad media for long, created and dropped in numbers |
| `test/corpus/` | Twelve encoded frames per codec, decoded and compared with FFmpeg |

## Inside the largest module

`src/webrtc_codecs_capture.erl` holds five things. Find the one you need by
its functions:

| Part | Functions |
|---|---|
| Listing devices, per system | `devices/0`, `avfoundation_devices/1`, `dshow_devices/1`, `v4l2_name/1` |
| FFmpeg's command line: what to read | `input/3`, `device_input/3`, `generated/3`, `pace/1` |
| FFmpeg's command line: what to write | `output/3`, `raw_output/2`, `default_encoder/2`, `encoder_options/1`, `container/1` |
| The process and its socket | `init/1`, `handle_info/2`, `accept/1`, `ended/1`, `terminate/2` |
| Cutting the stream and the drop policy | `deliver/2`, `encoded/3`, `keyframe/2`, `behind/1`, `raw/3` |

## Change with care

- **The header readers** (`frame_size/2`, `superframe/1`, `sps_info/1`,
  `obu_types/1`, and each module's `frame_info/2`) are what the size limit
  rests on. A reader that lets something through hands a library input
  nobody checked. Change them with a test that declares too much.
- **A constructor in C** must not read a resource after releasing it. Run
  `scripts/test-sanitizers.sh` after any change there.
- **`stop/2` in `webrtc_codecs_exec`** is why no program outlives its owner.
