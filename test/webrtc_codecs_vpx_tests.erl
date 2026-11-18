-module(webrtc_codecs_vpx_tests).
-include_lib("eunit/include/eunit.hrl").

-define(M, webrtc_codecs_vpx).
-define(T, webrtc_codecs_test_media).
-define(C, webrtc_codecs_video_checks).

ctx(vp8) -> #{mod => ?M, codec => vp8, name => <<"VP8">>, implementation => <<"libvpx v">>};
ctx(vp9) -> #{mod => ?M, codec => vp9, name => <<"VP9">>, implementation => <<"libvpx v">>}.

%% Every test needs libvpx and runs for VP8 and VP9.
vpx_test_() ->
    case webrtc_codecs_vpx_nif:loaded() of
        false ->
            {"skipped: built without libvpx", []};
        true ->
            [
                [
                    {timeout, 60, {"corpus " ++ atom_to_list(Codec), fun() -> corpus(Codec) end}}
                    | ?C:all(ctx(Codec))
                ]
             || Codec <- [vp8, vp9]
            ]
    end.

without_libvpx_test() ->
    case webrtc_codecs_vpx_nif:loaded() of
        true ->
            ?assertMatch(
                [
                    #{name := <<"VP8">>, kind := video},
                    #{name := <<"VP9">>, implementation := <<"libvpx v", _/binary>>}
                ],
                ?M:codecs()
            );
        false ->
            ?assertEqual([], ?M:codecs()),
            ?assertEqual({error, {not_built, vpx}}, ?M:init(video, #{name => <<"VP8">>}, #{}))
    end.

%% The VP8 corpus of erlang_webrtc decodes to its twelve pictures, two
%% of them key frames, the same samples FFmpeg gets. The VP9 one is
%% profile 1 (4:4:4), which is refused frame by frame; the same pictures
%% encoded in profile 0 by FFmpeg stand in for it.
corpus(vp8) ->
    case ?T:corpus("vp8.ivf") of
        false -> ok;
        Path -> ?C:decodes_like_ffmpeg(ctx(vp8), Path)
    end;
corpus(vp9) ->
    case ?T:corpus("vp9.ivf") of
        false ->
            ok;
        Path ->
            Frames = ?T:frames(?T:ivf(Path), ?C:is_key(ctx(vp9))),
            {Outs, Stats, _} = ?T:decode_all(?M, Frames, ?C:init(ctx(vp9), #{})),
            ?assertEqual(lists:duplicate(12, unsupported_profile), [R || #{dropped := R} <- Outs]),
            ?assertEqual(#{}, Stats)
    end,
    case ?T:ffmpeg_encode("-pix_fmt yuv420p -c:v libvpx-vp9 -g 6 -b:v 100k", ".ivf") of
        false ->
            ok;
        File ->
            try
                ?C:decodes_like_ffmpeg(ctx(vp9), File)
            after
                file:delete(File)
            end
    end.

%% A new size shows in the header of the key frame that starts it.
new_size_header_test() ->
    case webrtc_codecs_vpx_nif:loaded() of
        true ->
            [
                begin
                    {[#{data := Data}], _, _} = ?C:encode(
                        ctx(Codec), 176, 144, [0], ?C:init(ctx(Codec), #{})
                    ),
                    ?assertEqual({key, 176, 144}, ?M:frame_size(Codec, Data))
                end
             || Codec <- [vp8, vp9]
            ];
        false ->
            ok
    end.

frame_size_test() ->
    ?assertEqual({error, invalid_frame}, ?M:frame_size(vp8, <<>>)),
    ?assertEqual({error, invalid_frame}, ?M:frame_size(vp8, <<0, 0, 0, 1, 2, 3, 4, 5, 6, 7>>)),
    ?assertEqual(inter, ?M:frame_size(vp8, <<1, 0, 0>>)),
    ?assertEqual(
        {key, 176, 144},
        ?M:frame_size(vp8, <<0, 0, 0, 16#9D, 1, 16#2A, 176:16/little, 144:16/little>>)
    ),
    ?assertEqual({error, invalid_frame}, ?M:frame_size(vp9, <<>>)),
    ?assertEqual({error, unsupported_profile}, ?M:frame_size(vp9, <<2:2, 1:1, 0:1, 0:4, 0:64>>)),
    %% Key frame, then an intra-only frame, both of 65536 x 65536.
    ?assertEqual(
        {key, 65536, 65536},
        ?M:frame_size(vp9, <<2:2, 0:2, 0:1, 0:1, 1:1, 0:1, 16#498342:24, 2:3, 0:1, -1:32, 0:4>>)
    ),
    ?assertEqual(
        {inter, 65536, 65536},
        ?M:frame_size(vp9, <<2:2, 0:2, 0:1, 1:1, 0:1, 1:1, 1:1, 16#498342:24, 0:8, -1:32, 0:7>>)
    ),
    %% An inter frame that writes its size out, and one that takes it from a reference.
    ?assertEqual(
        {inter, 2, 3},
        ?M:frame_size(vp9, <<2:2, 0:2, 0:1, 1:1, 1:1, 1:1, 0:8, 0:12, 0:3, 1:16, 2:16, 0:5>>)
    ),
    ?assertEqual(
        inter, ?M:frame_size(vp9, <<2:2, 0:2, 0:1, 1:1, 1:1, 1:1, 0:8, 0:12, 1:1, 0:2, 0:5>>)
    ),
    ?assertEqual(inter, ?M:frame_size(vp9, <<2:2, 0:2, 1:1, 0:3>>)).

options_test() ->
    case webrtc_codecs_vpx_nif:loaded() of
        true ->
            Vp9 = #{name => <<"VP9">>},
            ?assertMatch({ok, _}, ?M:init(video, Vp9#{fmtp => [{<<"profile-id">>, <<"0">>}]}, #{})),
            ?assertEqual(
                {error, {unsupported_profile, <<"2">>}},
                ?M:init(video, Vp9#{fmtp => [{<<"profile-id">>, <<"2">>}]}, #{})
            ),
            [
                ?assertMatch({error, {badarg, _}}, ?M:init(video, Vp9, Opts))
             || Opts <- [
                    #{bitrate => 0}, #{threads => 65}, #{cpu_used => fast}, #{max_pixels => -1}, []
                ]
            ],
            ?assertMatch({error, {badarg, _}}, ?M:init(audio, Vp9, #{})),
            ?assertEqual(
                {error, {unsupported_codec, <<"H264">>}}, ?M:init(video, #{name => <<"H264">>}, #{})
            );
        false ->
            ok
    end.

%% An intra-only VP9 frame header that declares 65536 x 65536.
oversized() ->
    <<2:2, 0:2, 0:1, 1:1, 0:1, 1:1, 1:1, 16#498342:24, 0:8, -1:32, 0:7, 0:64>>.

%% A superframe: the frames, then an index of sizes on two bytes.
superframe(Frames) ->
    Marker = 2#11001000 bor (length(Frames) - 1),
    Sizes = <<<<(byte_size(F)):16/little>> || F <- Frames>>,
    <<(iolist_to_binary(Frames))/binary, Marker, Sizes/binary, Marker>>.

superframe_index_test() ->
    A = <<1, 2, 3>>,
    B = <<4, 5>>,
    ?assertEqual({ok, [A, B]}, ?M:superframe(superframe([A, B]))),
    ?assertEqual(none, ?M:superframe(<<>>)),
    ?assertEqual(none, ?M:superframe(<<1, 2, 3, 4>>)),
    %% A last byte that looks like a marker without its twin: no index.
    ?assertEqual(none, ?M:superframe(<<1, 2, 3, 2#11001001>>)),
    %% An index whose sizes run past the data, or are zero.
    Marker = 2#11001000,
    ?assertEqual(error, ?M:superframe(<<1, 2, Marker, 9:16/little, Marker>>)),
    ?assertEqual(error, ?M:superframe(<<1, 2, Marker, 0:16/little, Marker>>)),
    ?assertEqual({error, invalid_frame}, ?M:frame_info(vp9, <<1, 2, Marker, 9:16/little, Marker>>)).

%% Every frame of a superframe counts for the limit, not only the first:
%% a small key frame followed by a frame that declares a huge picture is
%% refused before libvpx sees it.
superframe_limit_test() ->
    case webrtc_codecs_vpx_nif:loaded() of
        true ->
            {[#{data := Key} = Frame], _, _} = ?C:encode(
                ctx(vp9), 176, 144, [0], ?C:init(ctx(vp9), #{})
            ),
            ?assertEqual({key, 176, 144}, ?M:frame_info(vp9, Key)),
            Bad = superframe([Key, oversized()]),
            ?assertEqual({key, 65536, 65536}, ?M:frame_info(vp9, Bad)),
            St0 = ?C:init(ctx(vp9), #{}),
            {ok, [#{dropped := too_large}], Stats, St1} = ?M:decode(Frame#{data := Bad}, St0),
            ?assertEqual(#{}, Stats),
            %% No decoder was made: nothing was given to the library.
            ?assertEqual(undefined, element(5, St1)),
            %% A superframe whose frames all fit decodes.
            {ok, [#{width := 176, height := 144}], _, _} = ?M:decode(
                Frame#{data := superframe([Key])}, St0
            );
        false ->
            ok
    end.

%% Without an index, libvpx would decode the frame and go on with what
%% follows it. It is given the first frame only, so bytes after it are
%% never read as a frame.
trailing_frame_test() ->
    case webrtc_codecs_vpx_nif:loaded() of
        true ->
            {[#{data := Key} = Frame, Next], _, _} = ?C:encode(
                ctx(vp9), 176, 144, [0, 1], ?C:init(ctx(vp9), #{})
            ),
            Bad = <<Key/binary, (oversized())/binary>>,
            ?assertEqual({key, 176, 144}, ?M:frame_info(vp9, Bad)),
            {ok, [#{width := 176, height := 144}], #{framesDecoded := 1}, St} =
                ?M:decode(Frame#{data := Bad}, ?C:init(ctx(vp9), #{})),
            %% And the stream goes on.
            {ok, [#{width := 176, height := 144}], _, _} = ?M:decode(Next, St);
        false ->
            ok
    end.
