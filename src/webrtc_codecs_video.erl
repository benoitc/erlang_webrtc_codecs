-module(webrtc_codecs_video).
-moduledoc false.

%% What the video plugins share: a decoder that refuses oversized
%% pictures and waits for a key frame after a frame it could not decode,
%% an encoder that follows the bitrate and key frame requests of the raw
%% map, and the statistics of both. A plugin module gives the library
%% calls through the callbacks below and delegates init/3, decode/2,
%% encode/2, info/1, control/2 and terminate/1 here.

-export([init/3, decode/2, encode/2, info/1, control/2, terminate/1]).
-export([fmtp/3]).

-export_type([planes/0, frame_info/0, settings/0]).

%% Width, height and the Y, U and V planes without padding.
-type planes() :: {pos_integer(), pos_integer(), binary(), binary(), binary()}.
%% What a frame says of itself before it is decoded: a key frame or not,
%% with the picture size when the frame declares one.
-type frame_info() ::
    {key | inter, pos_integer(), pos_integer()} | key | inter | {error, term()}.
-type settings() :: #{
    bitrate := pos_integer(),
    threads := pos_integer(),
    cpu_used => integer(),
    keyframe_interval => pos_integer(),
    max_nal_size => pos_integer()
}.

-callback frame_info(Codec :: atom(), Frame :: binary()) -> frame_info().
-callback decoder_new(Codec :: atom(), Threads :: pos_integer(), MaxPixels :: pos_integer()) ->
    {ok, Decoder :: term()} | {error, term()}.
%% The pictures of a frame (none for a frame that is not shown) and its
%% quantizer when the library tells.
-callback decoder_decode(Decoder :: term(), Frame :: binary()) ->
    {ok, [planes()], Qp :: non_neg_integer() | undefined} | {error, term()}.
-callback encoder_new(Codec :: atom(), Width :: pos_integer(), Height :: pos_integer(), settings()) ->
    {ok, Encoder :: term()} | {error, term()}.
-callback encoder_bitrate(Encoder :: term(), Bitrate :: pos_integer()) -> ok | {error, term()}.
%% Pts and Duration in 90 kHz units; Pts grows from one call to the next.
-callback encoder_encode(
    Encoder :: term(),
    Y :: binary(),
    U :: binary(),
    V :: binary(),
    Pts :: non_neg_integer(),
    Duration :: pos_integer(),
    ForceKey :: boolean()
) ->
    {ok, [{Frame :: binary(), Key :: boolean()}], Qp :: non_neg_integer() | undefined}
    | {error, term()}.
-callback implementation(Codec :: atom(), decoder | encoder) -> binary().
%% Destroy the codec now, not when the reference is collected.
-callback decoder_close(Decoder :: term()) -> ok.
-callback encoder_close(Encoder :: term()) -> ok.

-define(MIN_BITRATE, 30000).
%% The least an encoder is given, whatever the peer allows.
-define(FLOOR_BITRATE, 1000).
%% Frames dropped between two key frame requests while the decoder
%% waits for a key frame: about a second of video.
-define(REQUEST_EVERY, 30).
%% Drops a key frame would not repair.
-define(HOPELESS, [too_large, unsupported_parameter_set, unsupported_profile]).
-define(MAX_PIXELS, 3840 * 2160).
-define(MAX_DIMENSION, 16384).
%% Duration given to the rate control when the timestamps do not tell.
-define(FRAME, 3000).

-record(st, {
    impl :: module(),
    codec :: atom(),
    opts :: map(),
    decoder :: term(),
    %% Frames are dropped until a key frame comes.
    need_key = true :: boolean(),
    %% Frames dropped since the last picture.
    drops = 0 :: non_neg_integer(),
    encoder :: undefined | {term(), pos_integer(), pos_integer()},
    bitrate :: undefined | pos_integer(),
    %% The most the peer allows (TMMBR).
    peer_max = infinity :: infinity | non_neg_integer(),
    %% The bitrate the encoder has.
    applied :: undefined | pos_integer(),
    force_key = false :: boolean(),
    %% Presentation time of the last picture given to the encoder, which
    %% wants it to grow, and the RTP timestamp it was made from.
    pts = 0 :: non_neg_integer(),
    last_ts :: undefined | non_neg_integer()
}).

-spec init(module(), atom(), map()) -> {ok, #st{}} | {error, term()}.
init(Impl, Codec, Opts) ->
    Positive = [bitrate, min_bitrate, max_bitrate, keyframe_interval, threads, max_pixels],
    Valid =
        lists:all(fun(K) -> positive(maps:get(K, Opts, 1)) end, Positive) andalso
            maps:get(threads, Opts, 1) =< 64 andalso
            is_boolean(maps:get(request_keyframes, Opts, true)) andalso
            is_integer(maps:get(cpu_used, Opts, 0)) andalso
            abs(maps:get(cpu_used, Opts, 0)) =< 16,
    case Valid of
        true ->
            St = #st{impl = Impl, codec = Codec, opts = Opts},
            {ok, St#st{bitrate = clamp(maps:get(bitrate, Opts, undefined), St)}};
        false ->
            {error, {badarg, Opts}}
    end.

positive(V) -> is_integer(V) andalso V > 0.

%% A parameter of the negotiated fmtp, a list of {Name, Value} binaries;
%% anything else in it is skipped.
-spec fmtp(binary(), map(), Default) -> binary() | Default.
fmtp(Key, Codec, Default) ->
    case maps:get(fmtp, Codec, []) of
        Fmtp when is_list(Fmtp) ->
            case lists:keyfind(Key, 1, [P || {_, _} = P <- Fmtp]) of
                {_, Value} -> Value;
                false -> Default
            end;
        _ ->
            Default
    end.

clamp(undefined, _St) ->
    undefined;
clamp(Bitrate, #st{opts = Opts}) ->
    Min = maps:get(min_bitrate, Opts, ?MIN_BITRATE),
    max(Min, min(Bitrate, maps:get(max_bitrate, Opts, Bitrate))).

%% One thread up to VGA, then more by steps, as far as the node has
%% schedulers.
threads(Pixels, #st{opts = Opts}) ->
    maps:get(threads, Opts, min(default_threads(Pixels), erlang:system_info(schedulers_online))).

default_threads(Pixels) when Pixels =< 640 * 480 -> 1;
default_threads(Pixels) when Pixels =< 1280 * 720 -> 2;
default_threads(_Pixels) -> 4.

max_pixels(#st{opts = Opts}) ->
    maps:get(max_pixels, Opts, ?MAX_PIXELS).

%% Decoding

-spec decode(webrtc_media_codec:frame(), #st{}) ->
    {ok, [map()], map(), #st{}}
    | {ok, [map()], map(), #st{}, [keyframe_request]}
    | {error, term()}.
decode(#{data := Data, timestamp := Ts}, #st{impl = Impl, codec = Codec, need_key = NeedKey} = St) ->
    Max = max_pixels(St),
    case Impl:frame_info(Codec, Data) of
        %% A frame that is not decoded leaves the frames after it without
        %% their reference.
        {error, Reason} -> dropped(Reason, Ts, St#st{need_key = true});
        {_, W, H} when W * H > Max -> dropped(too_large, Ts, St#st{need_key = true});
        {key, _, _} -> decode1(Data, Ts, true, St#st{need_key = false});
        key -> decode1(Data, Ts, true, St#st{need_key = false});
        _ when NeedKey -> dropped(waiting_for_keyframe, Ts, St);
        _ -> decode1(Data, Ts, false, St)
    end.

decode1(Data, Ts, Key, #st{decoder = undefined, impl = Impl, codec = Codec, opts = Opts} = St) ->
    case Impl:decoder_new(Codec, maps:get(threads, Opts, 1), max_pixels(St)) of
        {ok, Decoder} -> decode1(Data, Ts, Key, St#st{decoder = Decoder});
        {error, Reason} -> {error, {Codec, Reason}}
    end;
decode1(Data, Ts, Key, #st{decoder = Decoder, impl = Impl} = St) ->
    T0 = erlang:monotonic_time(),
    case Impl:decoder_decode(Decoder, Data) of
        {ok, Pictures, Qp} ->
            Count = length(Pictures),
            Stats = #{
                framesDecoded => Count,
                keyFramesDecoded => key_count(Key andalso Count > 0),
                totalDecodeTime => seconds(T0)
            },
            {ok, [picture(P, Ts) || P <- Pictures], qp(Qp, Count, Stats), St#st{drops = 0}};
        {error, Reason} ->
            %% What the decoder holds may be damaged or oversized: start
            %% again from a new one at the next key frame.
            ok = Impl:decoder_close(Decoder),
            dropped(Reason, Ts, St#st{decoder = undefined, need_key = true})
    end.

%% Bad media from the peer: the frame is dropped and counted, the plugin
%% goes on. The sender is asked for a key frame at the first frame
%% dropped and then once in a while, unless a key frame would not help.
dropped(Reason, Ts, #st{drops = Drops, opts = Opts} = St0) ->
    St = St0#st{drops = Drops + 1},
    Outs = [#{dropped => Reason, timestamp => Ts}],
    Ask =
        maps:get(request_keyframes, Opts, true) andalso Drops rem ?REQUEST_EVERY =:= 0 andalso
            not lists:member(Reason, ?HOPELESS),
    case Ask of
        true -> {ok, Outs, #{framesDropped => 1}, St, [keyframe_request]};
        false -> {ok, Outs, #{framesDropped => 1}, St}
    end.

picture({W, H, Y, U, V}, Ts) ->
    #{format => i420, width => W, height => H, y => Y, u => U, v => V, timestamp => Ts}.

key_count(true) -> 1;
key_count(false) -> 0.

qp(undefined, _Count, Stats) -> Stats;
qp(Qp, Count, Stats) -> Stats#{qpSum => Qp * Count}.

seconds(T0) ->
    erlang:convert_time_unit(erlang:monotonic_time() - T0, native, microsecond) / 1000000.

%% Encoding

%% An error leaves the plugin on: the picture is lost, the next one is
%% tried.
-spec encode(term(), #st{}) ->
    {ok, [webrtc_media_codec:frame()], map(), #st{}} | {error, term(), #st{}}.
encode(
    #{format := i420, width := W, height := H, y := Y, u := U, v := V, timestamp := Ts} = Raw, St0
) when
    is_integer(W), is_integer(H), is_binary(Y), is_binary(U), is_binary(V), is_integer(Ts), Ts >= 0
->
    Cw = (W + 1) div 2,
    Ch = (H + 1) div 2,
    Fits =
        W >= 2 andalso H >= 2 andalso W =< ?MAX_DIMENSION andalso H =< ?MAX_DIMENSION andalso
            byte_size(Y) =:= W * H andalso byte_size(U) =:= Cw * Ch andalso
            byte_size(V) =:= Cw * Ch,
    case Fits of
        true -> encode1(Raw, encoder(W, H, raw_control(Raw, St0)));
        false -> {error, {bad_raw_picture, describe(Raw)}, St0}
    end;
encode(#{} = Raw, St0) when not is_map_key(y, Raw), not is_map_key(format, Raw) ->
    case apply_bitrate(raw_control(Raw, St0)) of
        {ok, #st{applied = undefined} = St} -> {ok, [], #{}, St};
        {ok, St} -> {ok, [], #{targetBitrate => St#st.applied}, St};
        {error, _, _} = Error -> Error
    end;
encode(#{} = Raw, St) ->
    {error, {bad_raw_picture, describe(Raw)}, St};
encode(_Raw, St) ->
    {error, bad_raw_picture, St}.

encode1(_Raw, {error, _, _} = Error) ->
    Error;
encode1(#{y := Y, u := U, v := V, timestamp := Ts}, {ok, St}) ->
    #st{impl = Impl, codec = Codec, encoder = {Encoder, _, _}} = St,
    {Pts, Duration} = pts(Ts, St),
    T0 = erlang:monotonic_time(),
    case Impl:encoder_encode(Encoder, Y, U, V, Pts, Duration, St#st.force_key) of
        {ok, Packets, Qp} ->
            Frames = [#{data => D, timestamp => Ts, keyframe => K} || {D, K} <- Packets],
            Stats = #{
                framesEncoded => length(Frames),
                keyFramesEncoded => length([D || {D, true} <- Packets]),
                totalEncodeTime => seconds(T0),
                targetBitrate => St#st.applied
            },
            {ok, Frames, qp(Qp, length(Frames), Stats), St#st{
                force_key = false, pts = Pts, last_ts = Ts
            }};
        {error, Reason} ->
            %% Not known to be usable any more: the next picture starts a
            %% new encoder, with a key frame.
            ok = Impl:encoder_close(Encoder),
            {error, {Codec, Reason}, St#st{encoder = undefined, applied = undefined}}
    end.

%% The raw map without its planes, for an error a person reads.
describe(Raw) ->
    maps:map(
        fun
            (_, V) when is_binary(V) -> {bytes, byte_size(V)};
            (_, V) -> V
        end,
        Raw
    ).

%% What the raw map asks of the encoder.
raw_control(Raw, St0) ->
    St =
        case Raw of
            #{keyframe := true} -> St0#st{force_key = true};
            _ -> St0
        end,
    case Raw of
        #{bitrate := B} when is_integer(B), B > 0 -> St#st{bitrate = clamp(B, St)};
        _ -> St
    end.

encoder(W, H, #st{encoder = {_, W, H}} = St) ->
    apply_bitrate(St);
encoder(W, H, #st{impl = Impl, codec = Codec, opts = Opts} = St0) ->
    St1 = close_encoder(St0),
    %% About 0.1 bit per pixel at 30 pictures per second.
    Bitrate =
        case St1#st.bitrate of
            undefined -> clamp(W * H * 3, St1);
            Given -> Given
        end,
    St = St1#st{bitrate = Bitrate},
    Target = target(St),
    Settings = maps:merge(
        maps:with([keyframe_interval, cpu_used, max_nal_size], Opts),
        #{bitrate => Target, threads => threads(W * H, St)}
    ),
    case Impl:encoder_new(Codec, W, H, Settings) of
        {ok, Encoder} ->
            {ok, St#st{encoder = {Encoder, W, H}, applied = Target, last_ts = undefined}};
        {error, Reason} ->
            {error, {Codec, Reason}, St1}
    end.

%% What the encoder is given: what was asked for, within what the peer
%% allows.
target(#st{bitrate = Bitrate, peer_max = infinity}) -> Bitrate;
target(#st{bitrate = Bitrate, peer_max = Max}) -> max(?FLOOR_BITRATE, min(Bitrate, Max)).

apply_bitrate(#st{encoder = undefined} = St) ->
    {ok, St};
apply_bitrate(#st{impl = Impl, codec = Codec, encoder = {Encoder, _, _}, applied = Applied} = St) ->
    case target(St) of
        Applied ->
            {ok, St};
        Target ->
            case Impl:encoder_bitrate(Encoder, Target) of
                ok -> {ok, St#st{applied = Target}};
                {error, Reason} -> {error, {Codec, Reason}, St}
            end
    end.

close_encoder(#st{encoder = undefined} = St) ->
    St;
close_encoder(#st{impl = Impl, encoder = {Encoder, _, _}} = St) ->
    ok = Impl:encoder_close(Encoder),
    St#st{encoder = undefined, applied = undefined}.

%% What erlang_webrtc tells the encoder: the peer wants a key frame, the
%% most the peer allows, what the application asks for. They take effect
%% at the next picture.
-spec control(webrtc_media_codec:control_event() | term(), #st{}) -> {ok, #st{}}.
control(keyframe_request, St) ->
    {ok, St#st{force_key = true}};
control({target_bitrate, Bps}, St) when is_integer(Bps), Bps > 0 ->
    {ok, St#st{bitrate = clamp(Bps, St)}};
control({max_bitrate, infinity}, St) ->
    {ok, St#st{peer_max = infinity}};
control({max_bitrate, Bps}, St) when is_integer(Bps), Bps >= 0 ->
    {ok, St#st{peer_max = Bps}};
control(_Event, St) ->
    {ok, St}.

%% The stream ended: the codecs are destroyed now.
-spec terminate(#st{}) -> ok.
terminate(#st{impl = Impl, decoder = Decoder} = St) ->
    _ = close_encoder(St),
    case Decoder of
        undefined -> ok;
        _ -> Impl:decoder_close(Decoder)
    end.

%% An encoder wants a presentation time that grows. It follows the RTP
%% timestamps while they move forward by less than ten seconds, and
%% steps by one frame otherwise.
pts(_Ts, #st{last_ts = undefined, pts = Pts}) ->
    {Pts + ?FRAME, ?FRAME};
pts(Ts, #st{last_ts = Last, pts = Pts}) ->
    case (Ts - Last) band 16#FFFFFFFF of
        Delta when Delta > 0, Delta < 900000 -> {Pts + Delta, Delta};
        _ -> {Pts + ?FRAME, ?FRAME}
    end.

%% erlang_webrtc asks after a decode or an encode, so the state tells
%% which side it serves.
-spec info(#st{}) -> #{implementation := binary(), power_efficient := boolean()}.
info(#st{impl = Impl, codec = Codec, encoder = Encoder}) ->
    Side =
        case Encoder of
            undefined -> decoder;
            _ -> encoder
        end,
    #{implementation => Impl:implementation(Codec, Side), power_efficient => false}.
