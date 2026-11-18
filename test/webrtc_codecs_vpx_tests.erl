-module(webrtc_codecs_vpx_tests).
-include_lib("eunit/include/eunit.hrl").

-define(M, webrtc_codecs_vpx).
-define(P, webrtc_codecs_pattern).
-define(T, webrtc_codecs_test_media).

%% Every test needs libvpx and runs for VP8 and VP9.
vpx_test_() ->
    case webrtc_codecs_vpx_nif:loaded() of
        false ->
            {"skipped: built without libvpx", []};
        true ->
            [
                {timeout, 60,
                    {lists:flatten(io_lib:format("~s ~s", [Name, Codec])), fun() -> Fun(Codec) end}}
             || Codec <- [vp8, vp9],
                {Name, Fun} <- [
                    {"corpus", fun corpus/1},
                    {"round trip", fun round_trip/1},
                    {"key frame on request", fun keyframe_request/1},
                    {"follows bitrate", fun follows_bitrate/1},
                    {"new size", fun new_size/1},
                    {"odd size", fun odd_size/1},
                    {"damaged frame", fun damaged_frame/1},
                    {"starts on a key frame", fun starts_on_key/1},
                    {"too large", fun too_large/1},
                    {"garbage", fun garbage/1},
                    {"bad raw", fun bad_raw/1}
                ]
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

name(vp8) -> <<"VP8">>;
name(vp9) -> <<"VP9">>.

init(Codec, Opts) ->
    {ok, St} = ?M:init(video, #{name => name(Codec), clock_rate => 90000, fmtp => []}, Opts),
    St.

is_key(Codec) ->
    fun(Data) ->
        case ?M:frame_size(Codec, Data) of
            {key, _, _} -> true;
            _ -> false
        end
    end.

%% The pattern with a little noise on luma: pictures that cost bits at
%% any quality, to see the rate control at work.
noise(W, H, N) ->
    #{y := Y} = Picture = ?P:picture(W, H, N),
    Mask = <<<<(B band 15)>> || <<B>> <= rand:bytes(W * H)>>,
    Picture#{y := crypto:exor(Y, Mask)}.

%% Pictures First to Last of the pattern, encoded.
encode(W, H, Ns, St0) ->
    {Frames, {Stats, St}} = lists:mapfoldl(
        fun(N, {Acc, StA}) ->
            {ok, [Frame], Stats, StB} = ?M:encode(?P:picture(W, H, N), StA),
            {Frame, {?T:sum(Acc, Stats), StB}}
        end,
        {#{}, St0},
        Ns
    ),
    {Frames, Stats, St}.

%% The VP8 corpus of erlang_webrtc decodes to its twelve pictures, two
%% of them key frames, the same samples FFmpeg gets. The VP9 one is
%% profile 1 (4:4:4), which is refused frame by frame; the same pictures
%% encoded in profile 0 by FFmpeg stand in for it.
corpus(vp8) ->
    case ?T:corpus("vp8.ivf") of
        false -> ok;
        Path -> decodes_like_ffmpeg(vp8, Path)
    end;
corpus(vp9) ->
    case ?T:corpus("vp9.ivf") of
        false ->
            ok;
        Path ->
            Frames = ?T:frames(?T:ivf(Path), is_key(vp9)),
            {Outs, Stats, _} = ?T:decode_all(?M, Frames, init(vp9, #{})),
            ?assertEqual(lists:duplicate(12, unsupported_profile), [R || #{dropped := R} <- Outs]),
            ?assertEqual(#{}, Stats)
    end,
    case os:find_executable("ffmpeg") of
        false ->
            ok;
        Ffmpeg ->
            File = string:trim(os:cmd("mktemp")) ++ ".ivf",
            Cmd = io_lib:format(
                "'~ts' -v error -y -f lavfi -i testsrc=size=176x144:rate=30 -frames:v 12 -pix_fmt yuv420p"
                " -c:v libvpx-vp9 -g 6 -b:v 100k '~ts' 2>&1",
                [Ffmpeg, File]
            ),
            "" = os:cmd(lists:flatten(Cmd)),
            try
                decodes_like_ffmpeg(vp9, File)
            after
                file:delete(File)
            end
    end.

decodes_like_ffmpeg(Codec, Path) ->
    Frames = ?T:frames(?T:ivf(Path), is_key(Codec)),
    ?assertEqual(
        [true, false, false, false, false, false, true, false, false, false, false, false],
        [K || #{keyframe := K} <- Frames]
    ),
    {Pictures, Stats, _} = ?T:decode_all(?M, Frames, init(Codec, #{})),
    ?assertMatch(
        #{framesDecoded := 12, keyFramesDecoded := 2, totalDecodeTime := T} when T > 0, Stats
    ),
    ?assert(maps:get(qpSum, Stats) > 0),
    ?assertEqual([I * 3000 || I <- lists:seq(0, 11)], [T || #{timestamp := T} <- Pictures]),
    ?assert(lists:all(fun(#{format := i420, width := 176, height := 144}) -> true end, Pictures)),
    case ?T:reference(Path, 176, 144) of
        false -> ok;
        Reference -> ?assertEqual(Reference, [maps:remove(timestamp, P) || P <- Pictures])
    end.

%% Thirty pictures come back close to what went in, with their
%% timestamps, and the statistics count them.
round_trip(Codec) ->
    {Frames, EncStats, Enc} = encode(320, 240, lists:seq(0, 29), init(Codec, #{bitrate => 500000})),
    ?assertEqual([true | lists:duplicate(29, false)], [K || #{keyframe := K} <- Frames]),
    ?assertEqual([N * 3000 || N <- lists:seq(0, 29)], [T || #{timestamp := T} <- Frames]),
    ?assertMatch(#{framesEncoded := 30, keyFramesEncoded := 1, targetBitrate := 500000}, EncStats),
    ?assert(maps:get(totalEncodeTime, EncStats) > 0),
    ?assert(maps:get(qpSum, EncStats) > 0),
    {Pictures, DecStats, Dec} = ?T:decode_all(?M, Frames, init(Codec, #{})),
    ?assertMatch(#{framesDecoded := 30, keyFramesDecoded := 1}, DecStats),
    [
        begin
            ?assertMatch(
                #{width := 320, height := 240, timestamp := T} when T =:= N * 3000, Picture
            ),
            ?assert(?P:psnr(?P:picture(320, 240, N), Picture) > 30)
        end
     || {N, Picture} <- lists:enumerate(0, Pictures)
    ],
    ?assertMatch(
        #{implementation := <<"libvpx v", _/binary>>, power_efficient := false}, ?M:info(Enc)
    ),
    ?assertMatch(#{implementation := <<"libvpx v", _/binary>>}, ?M:info(Dec)).

%% keyframe => true, in a picture or in a map of its own before it,
%% makes the next frame a key frame.
keyframe_request(Codec) ->
    {_, _, St1} = encode(176, 144, [0, 1, 2], init(Codec, #{})),
    {ok, [#{keyframe := true}], #{keyFramesEncoded := 1}, St2} =
        ?M:encode((?P:picture(176, 144, 3))#{keyframe => true}, St1),
    {ok, [#{keyframe := false}], #{keyFramesEncoded := 0}, St3} = ?M:encode(
        ?P:picture(176, 144, 4), St2
    ),
    {ok, [], _, St4} = ?M:encode(#{keyframe => true}, St3),
    {ok, [#{keyframe := true}], _, _} = ?M:encode(?P:picture(176, 144, 5), St4).

%% The encoder follows the bitrate given in the raw map, within the
%% bounds of the options, and reports it.
follows_bitrate(Codec) ->
    Bytes = fun(Ns, St0) ->
        {Sizes, {Target, St}} = lists:mapfoldl(
            fun(N, {_, StA}) ->
                {ok, [#{data := D}], #{targetBitrate := T}, StB} = ?M:encode(
                    noise(320, 240, N), StA
                ),
                {byte_size(D), {T, StB}}
            end,
            {undefined, St0},
            Ns
        ),
        {lists:sum(Sizes), Target, St}
    end,
    St0 = init(Codec, #{bitrate => 100000, max_bitrate => 1500000}),
    {_, 100000, St1} = Bytes(lists:seq(0, 29), St0),
    {Low, 100000, St2} = Bytes(lists:seq(30, 89), St1),
    {ok, [], #{targetBitrate := 1000000}, St3} = ?M:encode(#{bitrate => 1000000}, St2),
    {_, 1000000, St4} = Bytes(lists:seq(90, 119), St3),
    {High, 1000000, St5} = Bytes(lists:seq(120, 179), St4),
    ?assert(High > 3 * Low),
    {ok, [_], #{targetBitrate := 1500000}, St6} = ?M:encode(
        (?P:picture(320, 240, 180))#{bitrate => 9000000}, St5
    ),
    {ok, [_], #{targetBitrate := 30000}, _} = ?M:encode(
        (?P:picture(320, 240, 181))#{bitrate => 1}, St6
    ).

%% Pictures of another size start again with a key frame.
new_size(Codec) ->
    {_, _, St1} = encode(320, 240, [0, 1], init(Codec, #{})),
    {ok, [#{keyframe := true, data := Data} = Frame], _, St2} = ?M:encode(
        ?P:picture(176, 144, 2), St1
    ),
    ?assertEqual({key, 176, 144}, ?M:frame_size(Codec, Data)),
    {ok, [#{keyframe := false}], _, _} = ?M:encode(?P:picture(176, 144, 3), St2),
    {ok, [#{width := 176, height := 144}], _, _} = ?M:decode(Frame, init(Codec, #{})).

%% Odd sizes round the chroma planes up.
odd_size(Codec) ->
    Picture = #{
        format => i420,
        width => 33,
        height => 17,
        y => binary:copy(<<100>>, 33 * 17),
        u => binary:copy(<<90>>, 17 * 9),
        v => binary:copy(<<160>>, 17 * 9),
        timestamp => 0
    },
    {ok, [Frame], _, _} = ?M:encode(Picture, init(Codec, #{})),
    {ok, [#{width := 33, height := 17, y := Y, u := U, v := V}], _, _} = ?M:decode(
        Frame, init(Codec, #{})
    ),
    ?assertEqual({33 * 17, 17 * 9, 17 * 9}, {byte_size(Y), byte_size(U), byte_size(V)}).

%% A frame cut short is dropped and said so, then frames are dropped
%% until a key frame, which decodes.
damaged_frame(Codec) ->
    {[F0, F1, F2, F3], _, St} = encode(176, 144, [0, 1, 2, 3], init(Codec, #{})),
    {ok, [F4], _, _} = ?M:encode((?P:picture(176, 144, 4))#{keyframe => true}, St),
    Cut = F1#{data := binary:part(maps:get(data, F1), 0, 12)},
    {Outs, Stats, _} = ?T:decode_all(?M, [F0, Cut, F2, F3, F4], init(Codec, #{})),
    ?assertMatch(
        [
            #{format := i420, timestamp := 0},
            #{dropped := _, timestamp := 3000},
            #{dropped := waiting_for_keyframe, timestamp := 6000},
            #{dropped := waiting_for_keyframe, timestamp := 9000},
            #{format := i420, timestamp := 12000}
        ],
        Outs
    ),
    ?assertMatch(#{framesDecoded := 2, keyFramesDecoded := 2}, Stats).

starts_on_key(Codec) ->
    {[_Key, Inter], _, _} = encode(176, 144, [0, 1], init(Codec, #{})),
    {ok, [#{dropped := waiting_for_keyframe}], Stats, _} = ?M:decode(Inter, init(Codec, #{})),
    ?assertEqual(#{}, Stats).

%% A key frame larger than max_pixels is refused before it is decoded.
too_large(Codec) ->
    {[Key, Inter], _, _} = encode(320, 240, [0, 1], init(Codec, #{})),
    St0 = init(Codec, #{max_pixels => 176 * 144}),
    {ok, [#{dropped := too_large, timestamp := 0}], _, St1} = ?M:decode(Key, St0),
    {ok, [#{dropped := waiting_for_keyframe}], _, _} = ?M:decode(Inter, St1),
    {ok, [#{width := 320}], _, _} = ?M:decode(Key, init(Codec, #{max_pixels => 320 * 240})).

%% Whatever bytes a peer sends, decode/2 answers ok with pictures or a
%% dropped frame: random bytes, and real frames with bytes changed.
garbage(Codec) ->
    _ = rand:seed(exsss, {4, 5, 6}),
    {Real, _, _} = encode(176, 144, lists:seq(0, 9), init(Codec, #{})),
    Damage = fun(Data) ->
        lists:foldl(
            fun(_, D) ->
                At = rand:uniform(byte_size(D)) - 1,
                <<Before:At/binary, _, After/binary>> = D,
                <<Before/binary, (rand:uniform(256) - 1), After/binary>>
            end,
            Data,
            lists:seq(1, rand:uniform(4))
        )
    end,
    lists:foldl(
        fun(I, St) ->
            Data =
                case I rem 3 of
                    0 -> rand:bytes(rand:uniform(200));
                    _ -> Damage(maps:get(data, lists:nth(1 + I rem 10, Real)))
                end,
            {ok, Outs, _, St1} = ?M:decode(
                #{data => Data, timestamp => I * 3000, keyframe => false}, St
            ),
            ?assert(length(Outs) =< 2),
            ?assert(
                lists:all(
                    fun
                        (#{dropped := _}) -> true;
                        (#{width := W, height := H, y := Y}) -> byte_size(Y) =:= W * H
                    end,
                    Outs
                )
            ),
            St1
        end,
        init(Codec, #{max_pixels => 640 * 480}),
        lists:seq(1, 1500)
    ).

%% A picture whose planes do not match its size is the application's
%% mistake: an error.
bad_raw(Codec) ->
    St = init(Codec, #{}),
    Picture = ?P:picture(176, 144, 0),
    ?assertMatch(
        {error, {bad_raw_picture, #{width := 320, y := {bytes, 25344}}}},
        ?M:encode(Picture#{width := 320}, St)
    ),
    ?assertMatch({error, {bad_raw_picture, _}}, ?M:encode(Picture#{u := <<>>}, St)),
    ?assertMatch({error, {bad_raw_picture, _}}, ?M:encode(Picture#{format := nv12}, St)),
    ?assertMatch({error, {bad_raw_picture, _}}, ?M:encode(maps:remove(timestamp, Picture), St)),
    ?assertEqual({error, bad_raw_picture}, ?M:encode(picture, St)).

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
