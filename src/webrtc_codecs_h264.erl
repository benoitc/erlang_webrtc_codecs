-module(webrtc_codecs_h264).
-moduledoc """
H.264 codec plugin, on OpenH264.

```erlang
webrtc:add_transceiver(Pc, video, #{frames => true, codec_plugin => {webrtc_codecs_h264, #{}}}).
```

`decode/2` takes an access unit in Annex B and gives one
`t:webrtc_codecs:picture/0` per picture, with the RTP timestamp of the
frame. It decodes the baseline, main and high profiles. After a frame it
cannot decode it drops frames until the next key frame.

`encode/2` takes `t:webrtc_codecs:picture/0` and encodes constrained
baseline in real time, which every negotiated `profile-level-id` of
those three profiles can decode. It follows `bitrate` (bits per second)
and makes a key frame, with its parameter sets, for `keyframe => true`.
Pictures of another size start a new stream with a key frame. Width
and height have to be even.

Options:

- `bitrate`: of the encoder at start, default from the picture size
- `min_bitrate`, `max_bitrate`: bounds for the bitrate, default 30000
  and none
- `keyframe_interval`: most frames between two key frames, default 3000
- `threads`: of the encoder, default from the picture size and the
  number of schedulers
- `max_pixels`: largest picture the decoder accepts, default 3840 x 2160
""".
-behaviour(webrtc_media_codec).
-behaviour(webrtc_codecs_video).

-export([codecs/0]).
-export([init/3, decode/2, encode/2, info/1]).
-export([nal_units/1, sps_size/1]).
%% webrtc_codecs_video callbacks
-export([
    frame_info/2,
    decoder_new/3,
    decoder_decode/2,
    encoder_new/4,
    encoder_bitrate/2,
    encoder_encode/7
]).
-export([implementation/2]).

-define(NAL_IDR, 5).
-define(NAL_SPS, 7).

-doc false.
codecs() ->
    case webrtc_codecs_openh264_nif:loaded() of
        true ->
            [
                #{
                    name => <<"H264">>,
                    kind => video,
                    decode => true,
                    encode => true,
                    implementation => implementation()
                }
            ];
        false ->
            []
    end.

implementation() ->
    <<"OpenH264 ", (webrtc_codecs_openh264_nif:version())/binary>>.

-doc false.
init(video, #{name := Name}, Opts) when is_map(Opts) ->
    case {string:lowercase(Name), webrtc_codecs_openh264_nif:loaded()} of
        {<<"h264">>, true} -> webrtc_codecs_video:init(?MODULE, h264, Opts);
        {<<"h264">>, false} -> {error, {not_built, openh264}};
        _ -> {error, {unsupported_codec, Name}}
    end;
init(Kind, _Codec, Opts) ->
    {error, {badarg, {Kind, Opts}}}.

-doc false.
decode(Frame, St) -> webrtc_codecs_video:decode(Frame, St).

-doc false.
encode(Raw, St) -> webrtc_codecs_video:encode(Raw, St).

-doc false.
info(St) -> webrtc_codecs_video:info(St).

-doc """
The NAL units of an access unit in Annex B (ITU-T H.264 annex B),
without their start codes: `{Type, Unit}` where `Type` is
`nal_unit_type`.
""".
-spec nal_units(binary()) -> [{0..31, binary()}].
nal_units(Data) ->
    Starts = [Pos + 3 || {Pos, 3} <- binary:matches(Data, <<0, 0, 1>>)],
    Ends = [Pos - 3 || Pos <- tl(Starts ++ [byte_size(Data) + 3])],
    [
        {Type, Unit}
     || {Start, End} <- lists:zip(Starts, Ends),
        End > Start,
        <<_:1, _:2, Type:5, _/binary>> = Unit <- [binary:part(Data, Start, End - Start)]
    ].

-doc """
The picture size a sequence parameter set declares (ITU-T H.264 section
7.3.2.1.1), cropping applied; `error` when it cannot be read.
""".
-spec sps_size(binary()) -> {ok, pos_integer(), pos_integer()} | error.
sps_size(<<_Header, Rbsp0/binary>>) ->
    %% Without the emulation prevention bytes (section 7.4.1).
    Rbsp = binary:replace(Rbsp0, <<0, 0, 3>>, <<0, 0>>, [global]),
    try sps(Rbsp) of
        {W, H} when W > 0, H > 0 -> {ok, W, H};
        _ -> error
    catch
        %% Cut short, or not the syntax of a parameter set.
        error:_ -> error
    end;
sps_size(_) ->
    error.

sps(<<Profile, _Constraints, _Level, B0/bits>>) ->
    {_Id, B1} = ue(B0),
    {Chroma, B2} = sps_format(Profile, B1),
    {_Log2MaxFrameNum, B3} = ue(B2),
    B4 = sps_order(ue(B3)),
    {_Refs, B5} = ue(B4),
    <<_Gaps:1, B6/bits>> = B5,
    {WidthMbs, B7} = ue(B6),
    {HeightUnits, B8} = ue(B7),
    <<FrameMbsOnly:1, B9/bits>> = B8,
    B10 =
        case FrameMbsOnly of
            1 -> B9;
            0 -> skip(1, B9)
        end,
    <<_Direct:1, Cropping:1, B11/bits>> = B10,
    {Left, Right, Top, Bottom} =
        case Cropping of
            0 ->
                {0, 0, 0, 0};
            1 ->
                {L, C1} = ue(B11),
                {R, C2} = ue(C1),
                {T, C3} = ue(C2),
                {B, _} = ue(C3),
                {L, R, T, B}
        end,
    Fields = 2 - FrameMbsOnly,
    %% Table 6-1: the crop units of each chroma format.
    {UnitX, UnitY} =
        case Chroma of
            0 -> {1, Fields};
            1 -> {2, 2 * Fields};
            2 -> {2, Fields};
            3 -> {1, Fields}
        end,
    {
        (WidthMbs + 1) * 16 - UnitX * (Left + Right),
        Fields * (HeightUnits + 1) * 16 - UnitY * (Top + Bottom)
    }.

%% The chroma format, which only the high profiles write, with their bit
%% depths and scaling lists.
sps_format(Profile, B0) when
    Profile =:= 100;
    Profile =:= 110;
    Profile =:= 122;
    Profile =:= 244;
    Profile =:= 44;
    Profile =:= 83;
    Profile =:= 86;
    Profile =:= 118;
    Profile =:= 128;
    Profile =:= 138;
    Profile =:= 139;
    Profile =:= 134;
    Profile =:= 135
->
    {Chroma, B1} = ue(B0),
    B2 =
        case Chroma of
            3 -> skip(1, B1);
            _ -> B1
        end,
    {_DepthLuma, B3} = ue(B2),
    {_DepthChroma, B4} = ue(B3),
    <<_Bypass:1, Matrix:1, B5/bits>> = B4,
    Lists =
        case {Matrix, Chroma} of
            {0, _} -> 0;
            {1, 3} -> 12;
            {1, _} -> 8
        end,
    {Chroma, scaling_lists(0, Lists, B5)};
sps_format(_Profile, B) ->
    {1, B}.

scaling_lists(N, N, B) ->
    B;
scaling_lists(I, N, <<0:1, B/bits>>) ->
    scaling_lists(I + 1, N, B);
scaling_lists(I, N, <<1:1, B/bits>>) ->
    Size =
        case I < 6 of
            true -> 16;
            false -> 64
        end,
    scaling_lists(I + 1, N, scaling_list(Size, 8, 8, B));
scaling_lists(_, _, _) ->
    error(truncated).

%% Section 7.3.2.1.1.1.
scaling_list(0, _Last, _Next, B) ->
    B;
scaling_list(Left, Last, 0, B) ->
    scaling_list(Left - 1, Last, 0, B);
scaling_list(Left, Last, _Next, B0) ->
    {Delta, B} = se(B0),
    case (Last + Delta + 256) rem 256 of
        0 -> scaling_list(Left - 1, Last, 0, B);
        Next -> scaling_list(Left - 1, Next, Next, B)
    end.

%% pic_order_cnt_type and what follows it.
sps_order({0, B0}) ->
    {_Log2MaxPocLsb, B} = ue(B0),
    B;
sps_order({1, B0}) ->
    B1 = skip(1, B0),
    {_OffsetNonRef, B2} = se(B1),
    {_OffsetTopBottom, B3} = se(B2),
    {Count, B4} = ue(B3),
    Count =< 255 orelse error(truncated),
    lists:foldl(fun(_, B) -> element(2, se(B)) end, B4, lists:seq(1, Count));
sps_order({_, B}) ->
    B.

skip(N, B) ->
    case B of
        <<_:N, Rest/bits>> -> Rest;
        _ -> error(truncated)
    end.

%% Exp-Golomb codes, section 9.1.
ue(B) -> ue(B, 0).

ue(<<0:1, B/bits>>, Zeros) when Zeros < 32 -> ue(B, Zeros + 1);
ue(<<1:1, B/bits>>, Zeros) ->
    case B of
        <<Value:Zeros, Rest/bits>> -> {(1 bsl Zeros) - 1 + Value, Rest};
        _ -> error(truncated)
    end;
ue(_, _) ->
    error(truncated).

se(B0) ->
    {K, B} = ue(B0),
    case K rem 2 of
        1 -> {(K + 1) div 2, B};
        0 -> {-(K div 2), B}
    end.

%% webrtc_codecs_video callbacks

%% A key frame is an access unit with an IDR slice. The size comes from
%% its sequence parameter set when there is one that can be read;
%% OpenH264 itself decodes nothing larger than 4096 x 2304.
-doc false.
frame_info(h264, Frame) ->
    Units = nal_units(Frame),
    case {Units, lists:keymember(?NAL_IDR, 1, Units), lists:keyfind(?NAL_SPS, 1, Units)} of
        {[], _, _} ->
            {error, invalid_frame};
        {_, true, {_, Sps}} ->
            case sps_size(Sps) of
                {ok, W, H} -> {key, W, H};
                error -> key
            end;
        {_, true, false} ->
            key;
        {_, false, _} ->
            inter
    end.

-doc false.
decoder_new(h264, _Threads, MaxPixels) -> webrtc_codecs_openh264_nif:decoder_new(MaxPixels).

-doc false.
decoder_decode(Decoder, Frame) ->
    case webrtc_codecs_openh264_nif:decode(Decoder, Frame) of
        {ok, Pictures} -> {ok, Pictures, undefined};
        {error, _} = Error -> Error
    end.

-doc false.
encoder_new(h264, Width, Height, _Settings) when Width rem 2 =:= 1; Height rem 2 =:= 1 ->
    %% OpenH264 would encode the picture without its last column or line.
    {error, odd_size};
encoder_new(h264, Width, Height, Settings) ->
    webrtc_codecs_openh264_nif:encoder_new(Width, Height, Settings).

-doc false.
encoder_bitrate(Encoder, Bitrate) -> webrtc_codecs_openh264_nif:encoder_bitrate(Encoder, Bitrate).

-doc false.
encoder_encode(Encoder, Y, U, V, Pts, _Duration, ForceKey) ->
    case webrtc_codecs_openh264_nif:encode(Encoder, Y, U, V, Pts, ForceKey) of
        {ok, Frames} -> {ok, Frames, undefined};
        {error, _} = Error -> Error
    end.

-doc false.
implementation(h264, _Side) -> implementation().
