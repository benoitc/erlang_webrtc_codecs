-module(webrtc_codecs_video).
-moduledoc false.

%% What the video plugins share: a decoder that refuses oversized
%% pictures and waits for a key frame after a frame it could not decode,
%% an encoder that follows the bitrate and key frame requests of the raw
%% map, and the statistics of both. A plugin module gives the library
%% calls through the callbacks below and delegates init/3, decode/2,
%% encode/2 and info/1 here.

-export([init/3, decode/2, encode/2, info/1]).
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

-define(MIN_BITRATE, 30000).
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
    encoder :: undefined | {term(), pos_integer(), pos_integer()},
    bitrate :: undefined | pos_integer(),
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

-spec decode(webrtc_media_codec:frame(), #st{}) -> {ok, [map()], map(), #st{}} | {error, term()}.
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
            {ok, [picture(P, Ts) || P <- Pictures], qp(Qp, Count, Stats), St};
        {error, Reason} ->
            %% What the decoder holds may be damaged or oversized: start
            %% again from a new one at the next key frame.
            dropped(Reason, Ts, St#st{decoder = undefined, need_key = true})
    end.

%% Bad media from the peer: the frame is dropped, the plugin goes on.
dropped(Reason, Ts, St) ->
    {ok, [#{dropped => Reason, timestamp => Ts}], #{}, St}.

picture({W, H, Y, U, V}, Ts) ->
    #{format => i420, width => W, height => H, y => Y, u => U, v => V, timestamp => Ts}.

key_count(true) -> 1;
key_count(false) -> 0.

qp(undefined, _Count, Stats) -> Stats;
qp(Qp, Count, Stats) -> Stats#{qpSum => Qp * Count}.

seconds(T0) ->
    erlang:convert_time_unit(erlang:monotonic_time() - T0, native, microsecond) / 1000000.

%% Encoding

-spec encode(term(), #st{}) -> {ok, [webrtc_media_codec:frame()], map(), #st{}} | {error, term()}.
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
        true -> encode1(Raw, encoder(W, H, control(Raw, St0)));
        false -> {error, {bad_raw_picture, describe(Raw)}}
    end;
encode(#{} = Raw, St0) when not is_map_key(y, Raw), not is_map_key(format, Raw) ->
    case apply_bitrate(control(Raw, St0)) of
        {ok, #st{applied = undefined} = St} -> {ok, [], #{}, St};
        {ok, St} -> {ok, [], #{targetBitrate => St#st.applied}, St};
        {error, _} = Error -> Error
    end;
encode(#{} = Raw, _St) ->
    {error, {bad_raw_picture, describe(Raw)}};
encode(_Raw, _St) ->
    {error, bad_raw_picture}.

encode1(_Raw, {error, _} = Error) ->
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
            {error, {Codec, Reason}}
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
control(Raw, St0) ->
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
    %% About 0.1 bit per pixel at 30 pictures per second.
    Bitrate =
        case St0#st.bitrate of
            undefined -> clamp(W * H * 3, St0);
            Given -> Given
        end,
    Settings = maps:merge(
        maps:with([keyframe_interval, cpu_used, max_nal_size], Opts),
        #{bitrate => Bitrate, threads => threads(W * H, St0)}
    ),
    case Impl:encoder_new(Codec, W, H, Settings) of
        {ok, Encoder} ->
            {ok, St0#st{
                encoder = {Encoder, W, H}, bitrate = Bitrate, applied = Bitrate, last_ts = undefined
            }};
        {error, Reason} ->
            {error, {Codec, Reason}}
    end.

apply_bitrate(#st{encoder = undefined} = St) ->
    {ok, St};
apply_bitrate(#st{bitrate = Bitrate, applied = Bitrate} = St) ->
    {ok, St};
apply_bitrate(#st{impl = Impl, codec = Codec, encoder = {Encoder, _, _}, bitrate = Bitrate} = St) ->
    case Impl:encoder_bitrate(Encoder, Bitrate) of
        ok -> {ok, St#st{applied = Bitrate}};
        {error, Reason} -> {error, {Codec, Reason}}
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
