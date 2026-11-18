-module(webrtc_codecs_vpx).
-moduledoc """
VP8 and VP9 codec plugin, on libvpx.

```erlang
webrtc:add_transceiver(Pc, video, #{frames => true, codec_plugin => {webrtc_codecs_vpx, #{}}}).
```

`decode/2` gives one `t:webrtc_codecs:picture/0` per frame shown, with
the RTP timestamp of the frame. After a frame it cannot decode it drops
frames until the next key frame.

`encode/2` takes `t:webrtc_codecs:picture/0` and encodes in real time at
a constant bitrate. It follows `bitrate` (bits per second) and makes a
key frame for `keyframe => true`. Pictures of another size start a new
stream with a key frame.

VP9 is profile 0 only: 8 bit 4:2:0.

Options:

- `bitrate`: of the encoder at start, default from the picture size
- `min_bitrate`, `max_bitrate`: bounds for the bitrate, default 30000
  and none
- `keyframe_interval`: most frames between two key frames, default 3000
- `threads`: of the encoder, default from the picture size and the
  number of schedulers, and of the decoder, default 1
- `cpu_used`: libvpx speed setting, default -6 for VP8 and 7 for VP9
- `max_pixels`: largest picture the decoder accepts, default 3840 x 2160
""".
-behaviour(webrtc_media_codec).

-export([codecs/0]).
-export([init/3, decode/2, encode/2, info/1]).
-export([frame_size/2]).

-define(MIN_BITRATE, 30000).
-define(MAX_PIXELS, 3840 * 2160).
%% Duration given to the rate control when the timestamps do not tell.
-define(FRAME, 3000).

-record(st, {
    codec :: vp8 | vp9,
    opts :: map(),
    decoder :: undefined | webrtc_codecs_vpx_nif:decoder(),
    %% Frames are dropped until a key frame comes.
    need_key = true :: boolean(),
    encoder :: undefined | {webrtc_codecs_vpx_nif:encoder(), pos_integer(), pos_integer()},
    bitrate :: undefined | pos_integer(),
    %% The bitrate the encoder has.
    applied :: undefined | pos_integer(),
    force_key = false :: boolean(),
    %% Presentation time of the last picture given to libvpx, which wants
    %% it to grow, and the RTP timestamp it was made from.
    pts = 0 :: non_neg_integer(),
    last_ts :: undefined | non_neg_integer()
}).

-doc false.
codecs() ->
    case webrtc_codecs_vpx_nif:loaded() of
        true ->
            Implementation = implementation(),
            [
                #{
                    name => N,
                    kind => video,
                    decode => true,
                    encode => true,
                    implementation => Implementation
                }
             || N <- [<<"VP8">>, <<"VP9">>]
            ];
        false ->
            []
    end.

implementation() ->
    <<"libvpx ", (webrtc_codecs_vpx_nif:version())/binary>>.

-doc false.
init(video, #{name := Name} = Codec, Opts) when is_map(Opts) ->
    case {string:lowercase(Name), webrtc_codecs_vpx_nif:loaded()} of
        {_, false} -> {error, {not_built, vpx}};
        {<<"vp8">>, true} -> init(vp8, Opts);
        {<<"vp9">>, true} -> vp9_profile(maps:get(fmtp, Codec, []), Opts);
        _ -> {error, {unsupported_codec, Name}}
    end;
init(Kind, _Codec, Opts) ->
    {error, {badarg, {Kind, Opts}}}.

%% RFC 9628 section 6: profile-id defaults to 0.
vp9_profile(Fmtp, Opts) ->
    Pairs =
        case is_list(Fmtp) of
            true -> [P || {_, _} = P <- Fmtp];
            false -> []
        end,
    case lists:keyfind(<<"profile-id">>, 1, Pairs) of
        false -> init(vp9, Opts);
        {_, <<"0">>} -> init(vp9, Opts);
        {_, Profile} -> {error, {unsupported_profile, Profile}}
    end.

init(Codec, Opts) ->
    Positive = [bitrate, min_bitrate, max_bitrate, keyframe_interval, threads, max_pixels],
    Valid =
        lists:all(fun(K) -> positive(maps:get(K, Opts, 1)) end, Positive) andalso
            maps:get(threads, Opts, 1) =< 64 andalso
            is_integer(maps:get(cpu_used, Opts, 0)) andalso
            abs(maps:get(cpu_used, Opts, 0)) =< 16,
    case Valid of
        true ->
            St = #st{codec = Codec, opts = Opts},
            {ok, St#st{bitrate = clamp(maps:get(bitrate, Opts, undefined), St)}};
        false ->
            {error, {badarg, Opts}}
    end.

positive(V) -> is_integer(V) andalso V > 0.

clamp(undefined, _St) ->
    undefined;
clamp(Bitrate, #st{opts = Opts}) ->
    Min = maps:get(min_bitrate, Opts, ?MIN_BITRATE),
    max(Min, min(Bitrate, maps:get(max_bitrate, Opts, Bitrate))).

%% One thread up to VGA, then one more per step, as far as the node has
%% schedulers.
threads(Pixels, #st{opts = Opts}) ->
    maps:get(threads, Opts, min(default_threads(Pixels), erlang:system_info(schedulers_online))).

default_threads(Pixels) when Pixels =< 640 * 480 -> 1;
default_threads(Pixels) when Pixels =< 1280 * 720 -> 2;
default_threads(_Pixels) -> 4.

%% Decoding

-doc false.
decode(#{data := Data, timestamp := Ts}, #st{codec = Codec, opts = Opts, need_key = NeedKey} = St) ->
    Max = maps:get(max_pixels, Opts, ?MAX_PIXELS),
    case frame_size(Codec, Data) of
        {error, Reason} -> dropped(Reason, Ts, St);
        {_, W, H} when W * H > Max -> dropped(too_large, Ts, St);
        {key, _, _} -> decode1(Data, Ts, true, St#st{need_key = false});
        _ when NeedKey -> dropped(waiting_for_keyframe, Ts, St);
        _ -> decode1(Data, Ts, false, St)
    end.

decode1(Data, Ts, Key, #st{decoder = undefined, codec = Codec, opts = Opts} = St) ->
    Max = maps:get(max_pixels, Opts, ?MAX_PIXELS),
    case webrtc_codecs_vpx_nif:decoder_new(Codec, maps:get(threads, Opts, 1), Max) of
        {ok, Decoder} -> decode1(Data, Ts, Key, St#st{decoder = Decoder});
        {error, Reason} -> {error, {vpx, Reason}}
    end;
decode1(Data, Ts, Key, #st{decoder = Decoder} = St) ->
    T0 = erlang:monotonic_time(),
    case webrtc_codecs_vpx_nif:decode(Decoder, Data) of
        {ok, Pictures, Qp} ->
            Stats = #{
                framesDecoded => length(Pictures),
                keyFramesDecoded => key_count(Key andalso Pictures =/= []),
                totalDecodeTime => seconds(T0),
                qpSum => Qp * length(Pictures)
            },
            {ok, [picture(P, Ts) || P <- Pictures], Stats, St};
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

seconds(T0) ->
    erlang:convert_time_unit(erlang:monotonic_time() - T0, native, microsecond) / 1000000.

-doc """
The size a frame declares, read from its header without decoding it:
`{key, Width, Height}` for a key frame, `{inter, Width, Height}` for
another frame that sets its size, `inter` for one that takes the size
of a frame before it.
""".
-spec frame_size(vp8 | vp9, binary()) ->
    {key | inter, pos_integer(), pos_integer()}
    | inter
    | {error, invalid_frame | unsupported_profile}.
%% RFC 6386 section 9.1: a 3 byte frame tag whose first bit is 0 for a
%% key frame, then the start code and 14 bit sizes.
frame_size(vp8, <<_:7, 0:1, _:16, 16#9D, 16#01, 16#2A, W:16/little, H:16/little, _/binary>>) when
    W band 16#3FFF > 0, H band 16#3FFF > 0
->
    {key, W band 16#3FFF, H band 16#3FFF};
frame_size(vp8, <<_:7, 1:1, _:16, _/binary>>) ->
    inter;
frame_size(vp8, _) ->
    {error, invalid_frame};
%% VP9 bitstream section 6.2, uncompressed header. Profile 0 only.
frame_size(vp9, <<2:2, 0:2, 1:1, _/bits>>) ->
    %% show_existing_frame
    inter;
frame_size(
    vp9, <<2:2, 0:2, 0:1, 0:1, _Show:1, _Resilient:1, 16#498342:24, Space:3, _Range:1, Rest/bits>>
) when
    Space =/= 7
->
    vp9_size(key, Rest);
frame_size(vp9, <<2:2, 0:2, 0:1, 1:1, Show:1, Resilient:1, Rest/bits>>) ->
    %% intra_only is there when the frame is not shown, reset_frame_context
    %% when it is not error resilient.
    IntraBits = 1 - Show,
    ResetBits = 2 * (1 - Resilient),
    case Rest of
        <<1:IntraBits, _:ResetBits, 16#498342:24, _Refresh:8, Size/bits>> when IntraBits =:= 1 ->
            vp9_size(inter, Size);
        <<0:IntraBits, _:ResetBits, _Refresh:8, _Refs:12, 0:3, Size/bits>> ->
            %% No reference gives the size: it is written out.
            vp9_size(inter, Size);
        <<0:IntraBits, _:ResetBits, _Refresh:8, _Refs:12, _:3, _/bits>> ->
            inter;
        _ ->
            {error, invalid_frame}
    end;
frame_size(vp9, <<2:2, Profile:2, _/bits>>) when Profile =/= 0 ->
    {error, unsupported_profile};
frame_size(vp9, _) ->
    {error, invalid_frame}.

vp9_size(Kind, <<W:16, H:16, _/bits>>) -> {Kind, W + 1, H + 1};
vp9_size(_Kind, _) -> {error, invalid_frame}.

%% Encoding

-doc false.
encode(
    #{format := i420, width := W, height := H, y := Y, u := U, v := V, timestamp := Ts} = Raw, St0
) when
    is_integer(W), is_integer(H), is_binary(Y), is_binary(U), is_binary(V), is_integer(Ts), Ts >= 0
->
    Cw = (W + 1) div 2,
    Ch = (H + 1) div 2,
    Fits =
        W >= 2 andalso H >= 2 andalso W =< 16384 andalso H =< 16384 andalso
            byte_size(Y) =:= W * H andalso byte_size(U) =:= Cw * Ch andalso
            byte_size(V) =:= Cw * Ch,
    case Fits andalso encoder(W, H, control(Raw, St0)) of
        false ->
            {error, {bad_raw_picture, describe(Raw)}};
        {ok, #st{encoder = {Encoder, _, _}} = St} ->
            {Pts, Duration} = pts(Ts, St),
            T0 = erlang:monotonic_time(),
            case webrtc_codecs_vpx_nif:encode(Encoder, Y, U, V, Pts, Duration, St#st.force_key) of
                {ok, Packets, Qp} ->
                    Frames = [#{data => D, timestamp => Ts, keyframe => K} || {D, K} <- Packets],
                    Stats = #{
                        framesEncoded => length(Frames),
                        keyFramesEncoded => length([K || {_, true = K} <- Packets]),
                        totalEncodeTime => seconds(T0),
                        qpSum => Qp * length(Frames),
                        targetBitrate => St#st.applied
                    },
                    {ok, Frames, Stats, St#st{force_key = false, pts = Pts, last_ts = Ts}};
                {error, Reason} ->
                    {error, {vpx, Reason}}
            end;
        {error, _} = Error ->
            Error
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
encoder(W, H, #st{codec = Codec, opts = Opts} = St0) ->
    %% About 0.1 bit per pixel at 30 pictures per second.
    Bitrate =
        case St0#st.bitrate of
            undefined -> clamp(W * H * 3, St0);
            Given -> Given
        end,
    Settings = maps:merge(
        maps:with([keyframe_interval, cpu_used], Opts),
        #{bitrate => Bitrate, threads => threads(W * H, St0)}
    ),
    case webrtc_codecs_vpx_nif:encoder_new(Codec, W, H, Settings) of
        {ok, Encoder} ->
            {ok, St0#st{
                encoder = {Encoder, W, H}, bitrate = Bitrate, applied = Bitrate, last_ts = undefined
            }};
        {error, Reason} ->
            {error, {vpx, Reason}}
    end.

apply_bitrate(#st{encoder = undefined} = St) ->
    {ok, St};
apply_bitrate(#st{bitrate = Bitrate, applied = Bitrate} = St) ->
    {ok, St};
apply_bitrate(#st{encoder = {Encoder, _, _}, bitrate = Bitrate} = St) ->
    case webrtc_codecs_vpx_nif:encoder_bitrate(Encoder, Bitrate) of
        ok -> {ok, St#st{applied = Bitrate}};
        {error, Reason} -> {error, {vpx, Reason}}
    end.

%% libvpx wants a presentation time that grows. It follows the RTP
%% timestamps while they move forward by less than ten seconds, and
%% steps by one frame otherwise.
pts(_Ts, #st{last_ts = undefined, pts = Pts}) ->
    {Pts + ?FRAME, ?FRAME};
pts(Ts, #st{last_ts = Last, pts = Pts}) ->
    case (Ts - Last) band 16#FFFFFFFF of
        Delta when Delta > 0, Delta < 900000 -> {Pts + Delta, Delta};
        _ -> {Pts + ?FRAME, ?FRAME}
    end.

-doc false.
info(_St) ->
    #{implementation => implementation(), power_efficient => false}.
