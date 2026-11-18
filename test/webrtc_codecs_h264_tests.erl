-module(webrtc_codecs_h264_tests).
-include_lib("eunit/include/eunit.hrl").

-define(M, webrtc_codecs_h264).
-define(T, webrtc_codecs_test_media).
-define(C, webrtc_codecs_video_checks).

ctx() ->
    #{
        mod => ?M,
        codec => h264,
        name => <<"H264">>,
        implementation => <<"OpenH264 ">>,
        qp => false,
        odd_sizes => false
    }.

h264_test_() ->
    case webrtc_codecs_openh264_nif:loaded() of
        false -> {"skipped: built without OpenH264", []};
        true -> [{timeout, 60, {"corpus H264", fun corpus/0}} | ?C:all(ctx())]
    end.

without_openh264_test() ->
    case webrtc_codecs_openh264_nif:loaded() of
        true ->
            ?assertMatch(
                [#{name := <<"H264">>, kind := video, implementation := <<"OpenH264 ", _/binary>>}],
                ?M:codecs()
            );
        false ->
            ?assertEqual([], ?M:codecs()),
            ?assertEqual({error, {not_built, openh264}}, ?M:init(video, #{name => <<"H264">>}, #{}))
    end.

%% The access units of an Annex B file whose pictures have one slice
%% each: the units before a slice go with it.
access_units(Data) ->
    {Units, _} = lists:foldl(
        fun({Type, Unit}, {Done, Pending}) ->
            Nal = <<0, 0, 0, 1, Unit/binary>>,
            case Type =:= 1 orelse Type =:= 5 of
                true -> {[iolist_to_binary(lists:reverse([Nal | Pending])) | Done], []};
                false -> {Done, [Nal | Pending]}
            end
        end,
        {[], []},
        ?M:nal_units(Data)
    ),
    lists:reverse(Units).

%% The H.264 corpus of erlang_webrtc, made by x264 with a size that
%% needs cropping, decodes to its twelve pictures, two of them key
%% frames, the same samples FFmpeg gets.
corpus() ->
    case ?T:corpus("h264.h264") of
        false ->
            ok;
        Path ->
            {ok, File} = file:read_file(Path),
            Frames = ?T:frames(access_units(File), ?C:is_key(ctx())),
            ?assertEqual(
                [true, false, false, false, false, false, true, false, false, false, false, false],
                [K || #{keyframe := K} <- Frames]
            ),
            %% Shown as 174 x 130, coded as whole macroblocks.
            ?assertEqual({key, 176, 144}, ?M:frame_info(h264, maps:get(data, hd(Frames)))),
            {Pictures, Stats, _} = ?T:decode_all(?M, Frames, ?C:init(ctx(), #{})),
            ?assertMatch(#{framesDecoded := 12, keyFramesDecoded := 2}, Stats),
            ?assertEqual([I * 3000 || I <- lists:seq(0, 11)], [T || #{timestamp := T} <- Pictures]),
            ?assert(
                lists:all(fun(#{format := i420, width := 174, height := 130}) -> true end, Pictures)
            ),
            case ?T:reference(Path, 174, 130) of
                false -> ok;
                Reference -> ?assertEqual(Reference, [maps:remove(timestamp, P) || P <- Pictures])
            end
    end.

%% A key frame carries its parameter sets, so a decoder can start there.
key_frame_test() ->
    case webrtc_codecs_openh264_nif:loaded() of
        true ->
            {[#{data := Key}, #{data := Inter}], _, _} = ?C:encode(
                ctx(), 320, 240, [0, 1], ?C:init(ctx(), #{})
            ),
            ?assertEqual([7, 8, 5], [T || {T, _} <- ?M:nal_units(Key)]),
            ?assertEqual({key, 320, 240}, ?M:frame_info(h264, Key)),
            ?assertEqual([1], [T || {T, _} <- ?M:nal_units(Inter)]),
            ?assertEqual(inter, ?M:frame_info(h264, Inter)),
            %% Constrained baseline: profile_idc 66 with constraint_set1.
            {7, <<_, 66, _:1, 1:1, _:6, _/binary>>} = lists:keyfind(7, 1, ?M:nal_units(Key));
        false ->
            ok
    end.

nal_units_test() ->
    ?assertEqual([], ?M:nal_units(<<>>)),
    ?assertEqual([], ?M:nal_units(<<1, 2, 3, 4>>)),
    ?assertEqual({error, invalid_frame}, ?M:frame_info(h264, <<1, 2, 3, 4>>)),
    %% Three and four byte start codes, an empty unit in between.
    Data = <<0, 0, 0, 1, 16#67, 1, 2, 0, 0, 1, 0, 0, 1, 16#65, 9>>,
    ?assertEqual([{7, <<16#67, 1, 2>>}, {5, <<16#65, 9>>}], ?M:nal_units(Data)),
    %% Its parameter set is not one that can be read.
    ?assertEqual({error, unsupported_parameter_set}, ?M:frame_info(h264, Data)),
    ?assertEqual(key, ?M:frame_info(h264, <<0, 0, 1, 16#65, 9>>)),
    ?assertEqual(inter, ?M:frame_info(h264, <<0, 0, 1, 16#41, 9>>)).

%% A baseline parameter set: Id, a size in macroblocks, lines cropped
%% at the bottom in units of two.
sps(Id, WidthMbs, HeightMbs, CropBottom) ->
    sps(66, Id, WidthMbs, HeightMbs, CropBottom).

sps(Profile, Id, WidthMbs, HeightMbs, CropBottom) ->
    Bits = <<
        (ue(Id))/bits,
        (ue(0))/bits,
        (ue(0))/bits,
        (ue(0))/bits,
        (ue(1))/bits,
        0:1,
        (ue(WidthMbs - 1))/bits,
        (ue(HeightMbs - 1))/bits,
        1:1,
        0:1,
        1:1,
        (ue(0))/bits,
        (ue(0))/bits,
        (ue(0))/bits,
        (ue(CropBottom))/bits,
        0:1,
        1:1
    >>,
    Pad = (8 - bit_size(Bits) rem 8) rem 8,
    <<16#67, Profile, 16#C0, 40, Bits/bits, 0:Pad>>.

nal(Unit) -> <<0, 0, 0, 1, Unit/binary>>.

sps_info_test() ->
    ?assertEqual(error, ?M:sps_info(<<>>)),
    ?assertEqual(error, ?M:sps_info(<<16#67>>)),
    ?assertEqual(error, ?M:sps_info(<<16#67, 66, 0, 30, 0, 0, 0>>)),
    %% 1920 x 1080: 120 x 68 macroblocks, 8 lines cropped at the bottom.
    ?assertEqual(
        {ok, #{id => 3, profile => 66, coded => {1920, 1088}, cropped => {1920, 1080}}},
        ?M:sps_info(sps(3, 120, 68, 4))
    ),
    %% More cropped than there is.
    ?assertEqual(error, ?M:sps_info(sps(0, 2, 2, 40))).

%% The limit holds for every parameter set a peer can get into the
%% decoder, and on the size the decoder allocates. None of these units
%% reaches OpenH264: the plugin state never gets a decoder.
parameter_set_limits_test() ->
    Small = sps(0, 20, 15, 0),
    Huge = sps(1, 1024, 1024, 0),
    Idr = <<16#65, 16#88, 16#84>>,
    Slice = <<16#41, 16#9A, 16#02>>,
    %% Alone, without a slice.
    ?assertEqual({inter, 16384, 16384}, ?M:frame_info(h264, nal(Huge))),
    %% A second set, with another id, behind a small one; either order.
    ?assertEqual(
        {key, 16384, 16384},
        ?M:frame_info(h264, <<(nal(Small))/binary, (nal(Huge))/binary, (nal(Idr))/binary>>)
    ),
    ?assertEqual(
        {key, 16384, 16384},
        ?M:frame_info(h264, <<(nal(Huge))/binary, (nal(Small))/binary, (nal(Idr))/binary>>)
    ),
    %% With a slice that is not a key frame.
    ?assertEqual(
        {inter, 16384, 16384}, ?M:frame_info(h264, <<(nal(Huge))/binary, (nal(Slice))/binary>>)
    ),
    %% Shown small, coded large: the coded size counts.
    ?assertEqual(
        {key, 4096, 4096},
        ?M:frame_info(h264, <<(nal(sps(0, 256, 256, 2000)))/binary, (nal(Idr))/binary>>)
    ),
    %% A set that cannot be read, of another profile, or of an extension.
    Refused = {error, unsupported_parameter_set},
    ?assertEqual(
        Refused, ?M:frame_info(h264, <<(nal(<<16#67, 66, 0>>))/binary, (nal(Idr))/binary>>)
    ),
    ?assertEqual(
        Refused, ?M:frame_info(h264, <<(nal(sps(244, 0, 20, 15, 0)))/binary, (nal(Idr))/binary>>)
    ),
    ?assertEqual(
        Refused, ?M:frame_info(h264, <<(nal(Small))/binary, (nal(<<16#6F, 1, 2, 3>>))/binary>>)
    ),
    case webrtc_codecs_openh264_nif:loaded() of
        true ->
            St0 = ?C:init(ctx(), #{max_pixels => 1280 * 720}),
            lists:foldl(
                fun({Data, Reason}, St) ->
                    {ok, [#{dropped := Reason}], Stats, St1} =
                        ?M:decode(#{data => Data, timestamp => 0, keyframe => false}, St),
                    ?assertEqual(#{}, Stats),
                    %% Still no decoder: nothing was given to the library.
                    ?assertEqual(undefined, element(5, St1)),
                    St1
                end,
                St0,
                [
                    {nal(Huge), too_large},
                    {<<(nal(Small))/binary, (nal(Huge))/binary, (nal(Idr))/binary>>, too_large},
                    {<<(nal(Huge))/binary, (nal(Slice))/binary>>, too_large},
                    {<<(nal(sps(0, 256, 256, 2000)))/binary, (nal(Idr))/binary>>, too_large},
                    {
                        <<(nal(<<16#67, 66, 0>>))/binary, (nal(Idr))/binary>>,
                        unsupported_parameter_set
                    }
                ]
            );
        false ->
            ok
    end.

ue(V) ->
    Bits = bit_width(V + 1),
    <<0:(Bits - 1), (V + 1):Bits>>.

bit_width(N) when N < 2 -> 1;
bit_width(N) -> 1 + bit_width(N bsr 1).

options_test() ->
    case webrtc_codecs_openh264_nif:loaded() of
        true ->
            H264 = #{name => <<"H264">>, fmtp => [{<<"profile-level-id">>, <<"42e01f">>}]},
            ?assertMatch({ok, _}, ?M:init(video, H264, #{})),
            ?assertMatch({error, {badarg, _}}, ?M:init(video, H264, #{bitrate => 0})),
            ?assertMatch({error, {badarg, _}}, ?M:init(audio, H264, #{})),
            ?assertEqual(
                {error, {unsupported_codec, <<"VP8">>}}, ?M:init(video, #{name => <<"VP8">>}, #{})
            );
        false ->
            ok
    end.
