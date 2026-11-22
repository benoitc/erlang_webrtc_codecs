-module(webrtc_codecs_av1).
-moduledoc """
AV1 codec plugin: dav1d decodes, libaom encodes.

```erlang
webrtc:add_transceiver(Pc, video, #{frames => true, codec_plugin => {webrtc_codecs_av1, #{}}}).
```

`decode/2` takes a temporal unit in the low overhead format and gives
one `t:webrtc_codecs:picture/0` per picture shown, with the RTP
timestamp of the frame. After a frame it cannot decode it drops frames
until the next key frame.

`encode/2` takes `t:webrtc_codecs:picture/0` and encodes in real time at
a constant bitrate. It follows `bitrate` (bits per second) and makes a
key frame for `keyframe => true`. Pictures of another size start a new
stream with a key frame.

Main profile, 8 bit 4:2:0 only. Each library is optional: with only one
of them the plugin only decodes or only encodes.

Options:

- `bitrate`: of the encoder at start, default from the picture size
- `min_bitrate`, `max_bitrate`: bounds for the bitrate, default 30000
  and none
- `keyframe_interval`: most frames between two key frames, default 3000
- `threads`: of the encoder, default from the picture size and the
  number of schedulers, and of the decoder, default 1
- `cpu_used`: libaom speed setting, 0 to 11, default 9
- `max_pixels`: largest picture the decoder accepts, default 3840 x 2160
""".
-behaviour(webrtc_media_codec).
-behaviour(webrtc_codecs_video).

-export([codecs/0]).
-export([init/3, decode/2, encode/2, info/1]).
-export([obu_types/1]).
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

-define(OBU_SEQUENCE_HEADER, 1).

-doc false.
codecs() ->
    Decode = webrtc_codecs_dav1d_nif:loaded(),
    Encode = webrtc_codecs_aom_nif:loaded(),
    Names = [implementation(av1, Side) || {Side, true} <- [{decoder, Decode}, {encoder, Encode}]],
    case Names of
        [] ->
            [];
        _ ->
            [
                #{
                    name => <<"AV1">>,
                    kind => video,
                    decode => Decode,
                    encode => Encode,
                    implementation => iolist_to_binary(lists:join(<<", ">>, Names))
                }
            ]
    end.

-doc false.
init(video, #{name := Name} = Codec, Opts) when is_map(Opts) ->
    case {string:lowercase(Name), codecs()} of
        {<<"av1">>, []} -> {error, {not_built, av1}};
        {<<"av1">>, _} -> profile(Codec, Opts);
        _ -> {error, {unsupported_codec, Name}}
    end;
init(Kind, _Codec, Opts) ->
    {error, {badarg, {Kind, Opts}}}.

%% AV1 RTP payload format section 7.2.1: profile defaults to 0 (Main).
profile(Codec, Opts) ->
    case webrtc_codecs_video:fmtp(<<"profile">>, Codec, <<"0">>) of
        <<"0">> -> webrtc_codecs_video:init(?MODULE, av1, Opts);
        Profile -> {error, {unsupported_profile, Profile}}
    end.

-doc false.
decode(Frame, St) -> webrtc_codecs_video:decode(Frame, St).

-doc false.
encode(Raw, St) -> webrtc_codecs_video:encode(Raw, St).

-doc false.
info(St) -> webrtc_codecs_video:info(St).

-doc """
The types of the OBUs of a temporal unit in the low overhead format (AV1
bitstream section 5.3), read from their headers.
""".
-spec obu_types(binary()) -> {ok, [0..15]} | error.
obu_types(Data) ->
    obu_types(Data, []).

obu_types(<<>>, Acc) ->
    {ok, lists:reverse(Acc)};
obu_types(<<0:1, Type:4, Extension:1, HasSize:1, _:1, Rest0/binary>>, Acc) ->
    %% The extension is one byte; an OBU without a size runs to the end.
    case {Rest0, HasSize} of
        {<<_:Extension/binary, _/binary>>, 0} -> {ok, lists:reverse([Type | Acc])};
        {<<_:Extension/binary, Rest1/binary>>, 1} -> obu_payload(leb128(Rest1, 0, 0), [Type | Acc]);
        _ -> error
    end;
obu_types(_, _Acc) ->
    error.

obu_payload({Size, Rest0}, Acc) when byte_size(Rest0) >= Size ->
    <<_:Size/binary, Rest/binary>> = Rest0,
    obu_types(Rest, Acc);
obu_payload(_, _Acc) ->
    error.

%% AV1 bitstream section 4.10.5: at most 8 bytes of 7 bits, low first.
leb128(<<More:1, Bits:7, Rest/binary>>, Shift, Acc) when Shift < 56 ->
    Value = Acc bor (Bits bsl Shift),
    case More of
        0 -> {Value, Rest};
        1 -> leb128(Rest, Shift + 7, Value)
    end;
leb128(_, _, _) ->
    error.

%% webrtc_codecs_video callbacks

%% A new coded video sequence starts with a sequence header, which a
%% temporal unit only carries when it holds a key frame (AV1 RTP payload
%% format section 4.4, bitstream section 7.5). dav1d reads the picture
%% size and enforces the limit itself.
-doc false.
frame_info(av1, Frame) ->
    case obu_types(Frame) of
        {ok, []} ->
            {error, invalid_frame};
        {ok, Types} ->
            case lists:member(?OBU_SEQUENCE_HEADER, Types) of
                true -> key;
                false -> inter
            end;
        error ->
            {error, invalid_frame}
    end.

-doc false.
decoder_new(av1, Threads, MaxPixels) ->
    case webrtc_codecs_dav1d_nif:loaded() of
        true -> webrtc_codecs_dav1d_nif:decoder_new(Threads, MaxPixels);
        false -> {error, not_built}
    end.

-doc false.
decoder_decode(Decoder, Frame) -> webrtc_codecs_dav1d_nif:decode(Decoder, Frame).

-doc false.
encoder_new(av1, Width, Height, Settings) ->
    case webrtc_codecs_aom_nif:loaded() of
        true -> webrtc_codecs_aom_nif:encoder_new(Width, Height, Settings);
        false -> {error, not_built}
    end.

-doc false.
encoder_bitrate(Encoder, Bitrate) -> webrtc_codecs_aom_nif:encoder_bitrate(Encoder, Bitrate).

-doc false.
encoder_encode(Encoder, Y, U, V, Pts, Duration, ForceKey) ->
    webrtc_codecs_aom_nif:encode(Encoder, Y, U, V, Pts, Duration, ForceKey).

-doc false.
implementation(av1, decoder) -> <<"dav1d ", (webrtc_codecs_dav1d_nif:version())/binary>>;
implementation(av1, encoder) -> <<"libaom ", (webrtc_codecs_aom_nif:version())/binary>>.
