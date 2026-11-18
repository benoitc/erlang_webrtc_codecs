-module(webrtc_codecs).
-moduledoc """
Codec plugins for erlang_webrtc, and the plugin that picks one of them
from the negotiated codec.

Set it on a transceiver, or for every transceiver a remote offer creates:

```erlang
webrtc:add_transceiver(Pc, audio, #{frames => true, codec_plugin => {webrtc_codecs, #{}}}),
webrtc:new_peer_connection(#{frames => true, codec_plugins => #{audio => {webrtc_codecs, #{}}}}).
```

`Opts` go unchanged to the module of the negotiated codec; see each
module for the options it reads. `available/0` lists the codecs this
build can decode and encode.

Raw media, what `decode/2` gives and `encode/2` takes, is described by
`t:picture/0` and `t:audio/0`. Timestamps are in the RTP clock of the
negotiated codec in both directions.
""".
-behaviour(webrtc_media_codec).

-export([available/0, module/1]).
-export([init/3, decode/2, encode/2, info/1]).

-export_type([picture/0, audio/0, control/0, dropped/0, codec_info/0]).

-doc """
A raw picture: I420 planes without padding, so `y` is `width * height`
bytes and `u` and `v` are `(width div 2) * (height div 2)` each. Width
and height are even. `timestamp` is in 90 kHz units.

To an encoder, `keyframe => true` asks for a key frame (set it after
`{keyframe_request, Mid}`) and `bitrate` sets the target in bits per
second (set it after `{bandwidth_estimate, Bps}`).
""".
-type picture() :: #{
    format := i420,
    width := pos_integer(),
    height := pos_integer(),
    y := binary(),
    u := binary(),
    v := binary(),
    timestamp := non_neg_integer(),
    keyframe => boolean(),
    bitrate => pos_integer()
}.

-doc """
Raw audio: signed 16 bit little endian samples, interleaved by channel.

To an encoder, `samples` holds 10 or 20 ms, `timestamp` is optional (the
encoder counts samples from the last one it was given, or from 0) and
`bitrate` sets the target in bits per second.
""".
-type audio() :: #{
    format := s16le,
    sample_rate := pos_integer(),
    channels := pos_integer(),
    samples := binary(),
    timestamp => non_neg_integer(),
    bitrate => pos_integer()
}.

-doc "Raw media without a picture or samples: changes the encoder and sends nothing.".
-type control() :: #{bitrate => pos_integer(), keyframe => boolean()}.

-doc """
What a decoder gives in place of a picture or samples for a frame it
could not decode. The frame is dropped; for video, ask the sender for a
key frame with `webrtc:request_keyframe/2`.
""".
-type dropped() :: #{dropped := term(), timestamp := non_neg_integer()}.

-type codec_info() :: #{
    name := binary(),
    kind := audio | video,
    decode := boolean(),
    encode := boolean(),
    implementation := binary(),
    module := module()
}.

%% One module per codec family. Each exports codecs/0, the codecs it can
%% run in this build (none when its native library is missing).
-define(MODULES, [webrtc_codecs_g711]).

-doc "The codecs this build can decode or encode.".
-spec available() -> [codec_info()].
available() ->
    [C#{module => M} || M <- ?MODULES, C <- M:codecs()].

-doc "The plugin module for a codec name as SDP gives it (`<<\"PCMU\">>`, `<<\"VP8\">>`), whatever its case.".
-spec module(binary()) -> {ok, module()} | error.
module(Name) when is_binary(Name) ->
    Lower = string:lowercase(Name),
    case [M || #{name := N, module := M} <- available(), string:lowercase(N) =:= Lower] of
        [M | _] -> {ok, M};
        [] -> error
    end.

-doc false.
init(Kind, #{name := Name} = Codec, Opts) ->
    case module(Name) of
        {ok, Mod} ->
            case Mod:init(Kind, Codec, Opts) of
                {ok, St} -> {ok, {Mod, St}};
                {error, _} = E -> E
            end;
        error ->
            {error, {unsupported_codec, Name}}
    end;
init(_Kind, Codec, _Opts) ->
    {error, {bad_codec, Codec}}.

-doc false.
decode(Frame, {Mod, St}) ->
    wrap(Mod, Mod:decode(Frame, St)).

-doc false.
encode(Raw, {Mod, St}) ->
    wrap(Mod, Mod:encode(Raw, St)).

-doc false.
info({Mod, St}) ->
    Mod:info(St).

wrap(Mod, {ok, Out, Stats, St}) -> {ok, Out, Stats, {Mod, St}};
wrap(_Mod, {error, _} = E) -> E.
