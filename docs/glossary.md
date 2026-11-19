# Glossary

The words the other pages use, each in a line or two. Come here when a guide
uses a term it does not explain.

## WebRTC and erlang_webrtc

| Term | Meaning |
|---|---|
| peer connection | One WebRTC session with one peer. In erlang_webrtc it is a process you own, which sends you `{webrtc, Pc, Event}` messages. |
| transceiver | One audio or video line of a peer connection, which sends, receives or both. |
| mid | The name of a transceiver in the session description, a binary such as `<<"0">>`. You pass it to `send_media/3`. |
| transport process | The erlang_webrtc process that handles every packet of one connection. Codec plugins run inside it. |
| codec plugin | A module with the `webrtc_media_codec` behaviour, which erlang_webrtc calls to decode what a transceiver receives and encode what you send. This package is a set of them. |
| negotiated codec | The codec both peers agreed on for a transceiver, with its `fmtp` parameters. |
| `fmtp` | The parameters of a codec in the session description, such as `profile-level-id` or `useinbandfec`. |
| `rtx` | The retransmission format that goes with a video codec. Keep it when you narrow the codecs you offer. |
| frame buffer | The part of erlang_webrtc that puts packets back into whole frames, in order, before a plugin sees them. |

## Media

| Term | Meaning |
|---|---|
| frame | What `decode/2` gets and `encode/2` gives: one encoded picture, or one packet of encoded audio, as a map with `data`, `timestamp` and `keyframe`. |
| key frame | A frame that decodes on its own. A decoder that missed a frame needs one to start again. |
| raw media | Media that is not encoded: a picture or audio samples as an Erlang map. See [Raw media](raw-media.md). |
| picture | One raw image: three I420 planes. |
| I420 | A picture as a full-size brightness plane (Y) and two quarter-size colour planes (U, V). |
| `s16le` | Audio as signed 16 bit little endian samples, channels interleaved. |
| control map | A raw map with no picture and no samples, only `bitrate` or `keyframe`: it changes the encoder and sends nothing. |
| dropped output | What `decode/2` gives for a frame it could not decode: `#{dropped => Reason, timestamp => Ts}`. |
| RTP timestamp | The time of a frame in the clock of its codec: 90000 per second for video, 48000 for Opus, 8000 for G.711. |

## Per codec

| Term | Codec | Meaning |
|---|---|---|
| access unit | H.264 | The NAL units of one picture: what a frame is for H.264. |
| NAL unit | H.264 | One piece of an H.264 stream: a parameter set, a slice of a picture, and so on. |
| Annex B | H.264 | The format in which NAL units follow each other, each after a start code. |
| parameter set (SPS) | H.264 | The NAL unit that declares, among other things, the picture size. |
| temporal unit | AV1 | The OBUs of one instant: what a frame is for AV1. |
| OBU | AV1 | One piece of an AV1 stream. A sequence header OBU starts a new sequence, which is how a key frame is told. |
| superframe | VP9 | Several VP9 frames in one buffer, with an index at the end. Some of them are not shown. |
| profile | all | A subset of a codec's features. The plugins say which they take. |
| in-band FEC | Opus | A coarse copy of the previous packet carried in the current one, used when the previous one is lost. |
| DTX | Opus | Sending nothing during silence. |

## Inside this package

| Term | Meaning |
|---|---|
| NIF | A function written in C that the Erlang VM calls directly. Each codec library is reached through one. A defect in it can crash the VM. |
| resource | The object in which a NIF keeps a native decoder or encoder. The VM frees it when no process holds it any more. |
| dirty scheduler | A VM thread for native calls that take time. Codec calls run there so that ordinary Erlang code is not held up. |
| port | An external program the VM starts and talks to. FFmpeg and ffplay run as ports, so that they cannot crash the VM. |
| header reader | The Erlang code that reads a frame's header to learn its size and whether it is a key frame, before any library is called. |
| owner | The process that gets the media of a capture, or that started a sink. |
