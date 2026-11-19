# Encoded video for the decoder tests

Twelve frames of FFmpeg's `testsrc`, a key frame every six, one file per
codec. They are the frame corpus of erlang_webrtc 0.1.0
(`test/corpora/frames`), copied here because the Hex package of erlang_webrtc
does not carry its tests. They were made with:

```sh
ffmpeg -f lavfi -i testsrc=size=176x144:rate=30 -frames:v 12 -c:v libvpx -g 6 -b:v 100k vp8.ivf
ffmpeg -f lavfi -i testsrc=size=176x144:rate=30 -frames:v 12 -c:v libvpx-vp9 -g 6 -b:v 100k vp9.ivf
ffmpeg -f lavfi -i testsrc=size=174x130:rate=30 -frames:v 12 -pix_fmt yuv420p -c:v libx264 -profile:v baseline -g 6 -bf 0 -b:v 100k -f h264 h264.h264
ffmpeg -f lavfi -i testsrc=size=176x144:rate=30 -frames:v 12 -c:v libsvtav1 -g 6 -b:v 100k -pix_fmt yuv420p av1.ivf
```

The H.264 size is not a multiple of 16, so its parameter set crops. The VP9
file is profile 1 (4:4:4), since it was encoded without `-pix_fmt yuv420p`:
the VP9 plugin refuses it, which is what its test checks.
