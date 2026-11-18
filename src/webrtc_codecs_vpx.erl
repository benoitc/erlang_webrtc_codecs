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
-behaviour(webrtc_codecs_video).

-export([codecs/0]).
-export([init/3, decode/2, encode/2, info/1]).
-export([frame_size/2, superframe/1]).
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
        {<<"vp8">>, true} -> webrtc_codecs_video:init(?MODULE, vp8, Opts);
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
        false -> webrtc_codecs_video:init(?MODULE, vp9, Opts);
        {_, <<"0">>} -> webrtc_codecs_video:init(?MODULE, vp9, Opts);
        {_, Profile} -> {error, {unsupported_profile, Profile}}
    end.

-doc false.
decode(Frame, St) -> webrtc_codecs_video:decode(Frame, St).

-doc false.
encode(Raw, St) -> webrtc_codecs_video:encode(Raw, St).

-doc false.
info(St) -> webrtc_codecs_video:info(St).

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

%% webrtc_codecs_video callbacks

-doc false.
frame_info(vp8, Frame) ->
    frame_size(vp8, Frame);
frame_info(vp9, Frame) ->
    %% libvpx decodes every frame of a superframe in one call, the ones
    %% that are not shown included: each has to be within the limit.
    case superframe(Frame) of
        {ok, Frames} -> largest([frame_size(vp9, F) || F <- Frames]);
        none -> frame_size(vp9, Frame);
        error -> {error, invalid_frame}
    end.

%% What a superframe is as a whole: a key frame when its first frame is
%% one, the largest size any of its frames sets, an error when any of
%% them is one.
largest([First | _] = Infos) ->
    Kind =
        case First of
            {key, _, _} -> key;
            _ -> inter
        end,
    Errors = [E || {error, _} = E <- Infos],
    Sizes = [{W * H, W, H} || {_, W, H} <- Infos],
    case {Errors, Sizes} of
        {[Error | _], _} ->
            Error;
        {[], []} ->
            Kind;
        {[], _} ->
            {_, W, H} = lists:max(Sizes),
            {Kind, W, H}
    end.

-doc false.
decoder_new(Codec, Threads, MaxPixels) ->
    case webrtc_codecs_vpx_nif:decoder_new(Codec, Threads, MaxPixels) of
        {ok, Decoder} -> {ok, {Codec, Decoder}};
        {error, _} = Error -> Error
    end.

-doc false.
decoder_decode({vp8, Decoder}, Frame) ->
    webrtc_codecs_vpx_nif:decode(Decoder, Frame);
decoder_decode({vp9, Decoder}, Frame) ->
    %% Given a buffer without a superframe index, libvpx decodes one
    %% frame and goes on with whatever follows it, which nothing has
    %% checked. An index that declares a single frame makes it stop
    %% after the one whose header was read.
    case superframe(Frame) of
        {ok, _} ->
            webrtc_codecs_vpx_nif:decode(Decoder, Frame);
        none ->
            webrtc_codecs_vpx_nif:decode(
                Decoder, <<Frame/binary, (single_index(byte_size(Frame)))/binary>>
            );
        error ->
            {error, invalid_frame}
    end.

%% A superframe index for one frame of Size bytes, with sizes on four bytes.
single_index(Size) ->
    Marker = 2#11011000,
    <<Marker, Size:32/little, Marker>>.

-doc """
The frames of a VP9 superframe (VP9 bitstream annex B): `none` when the
data has no superframe index, `error` when it has one that does not fit
the data. The index is at the end: a marker byte `110` with the number
of bytes per size and the number of frames, the sizes, and the marker
again.
""".
-spec superframe(binary()) -> {ok, [binary()]} | none | error.
superframe(<<>>) ->
    none;
superframe(Data) ->
    Size = byte_size(Data),
    case binary:last(Data) of
        Marker when Marker bsr 5 =:= 2#110 ->
            Frames = (Marker band 7) + 1,
            Bytes = ((Marker bsr 3) band 3) + 1,
            IndexSize = 2 + Bytes * Frames,
            case Size >= IndexSize andalso binary:at(Data, Size - IndexSize) =:= Marker of
                true ->
                    Sizes = [
                        S
                     || <<S:Bytes/little-unit:8>> <= binary:part(
                            Data, Size - IndexSize + 1, Bytes * Frames
                        )
                    ],
                    split(Sizes, binary:part(Data, 0, Size - IndexSize), []);
                false ->
                    none
            end;
        _ ->
            none
    end.

split([], _Rest, Acc) ->
    {ok, lists:reverse(Acc)};
split([Size | Sizes], Rest, Acc) when Size > 0, Size =< byte_size(Rest) ->
    <<Frame:Size/binary, Rest1/binary>> = Rest,
    split(Sizes, Rest1, [Frame | Acc]);
split(_, _, _) ->
    error.

-doc false.
encoder_new(Codec, Width, Height, Settings) ->
    webrtc_codecs_vpx_nif:encoder_new(Codec, Width, Height, Settings).

-doc false.
encoder_bitrate(Encoder, Bitrate) -> webrtc_codecs_vpx_nif:encoder_bitrate(Encoder, Bitrate).

-doc false.
encoder_encode(Encoder, Y, U, V, Pts, Duration, ForceKey) ->
    webrtc_codecs_vpx_nif:encode(Encoder, Y, U, V, Pts, Duration, ForceKey).

-doc false.
implementation(_Codec, _Side) -> implementation().
