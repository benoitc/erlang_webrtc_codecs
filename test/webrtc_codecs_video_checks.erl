%% Checks every video plugin has to pass, run by the tests of each one
%% with a context: #{mod, codec, name, implementation}, where codec is
%% what the module's frame_info/2 takes and implementation the start of
%% the name info/1 gives.
-module(webrtc_codecs_video_checks).
-include_lib("eunit/include/eunit.hrl").

-export([all/1, init/2, encode/5, is_key/1, decodes_like_ffmpeg/2]).

-define(P, webrtc_codecs_pattern).
-define(T, webrtc_codecs_test_media).

%% The EUnit tests of a codec.
all(#{name := Name} = Ctx) ->
    [
        {timeout, 60, {lists:flatten(io_lib:format("~s ~s", [Title, Name])), fun() -> Fun(Ctx) end}}
     || {Title, Fun} <- [
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
    ].

init(#{mod := Mod, name := Name}, Opts) ->
    {ok, St} = Mod:init(video, #{name => Name, clock_rate => 90000, fmtp => []}, Opts),
    St.

is_key(#{mod := Mod, codec := Codec}) ->
    fun(Data) ->
        case Mod:frame_info(Codec, Data) of
            key -> true;
            {key, _, _} -> true;
            _ -> false
        end
    end.

%% The pictures Ns of the pattern, encoded: frames, statistics, state.
encode(#{mod := Mod}, W, H, Ns, St0) ->
    {Frames, {Stats, St}} = lists:mapfoldl(
        fun(N, {Acc, StA}) ->
            {ok, [Frame], Stats, StB} = Mod:encode(?P:picture(W, H, N), StA),
            {Frame, {?T:sum(Acc, Stats), StB}}
        end,
        {#{}, St0},
        Ns
    ),
    {Frames, Stats, St}.

%% The pattern with a little noise on luma: pictures that cost bits at
%% any quality, to see the rate control at work.
noise(W, H, N) ->
    #{y := Y} = Picture = ?P:picture(W, H, N),
    Mask = <<<<(B band 15)>> || <<B>> <= rand:bytes(W * H)>>,
    Picture#{y := crypto:exor(Y, Mask)}.

%% A file of twelve 176 x 144 frames, a key frame every six, decodes to
%% the same samples FFmpeg gets from it.
decodes_like_ffmpeg(#{mod := Mod} = Ctx, Path) ->
    Frames = ?T:frames(?T:ivf(Path), is_key(Ctx)),
    ?assertEqual(
        [true, false, false, false, false, false, true, false, false, false, false, false],
        [K || #{keyframe := K} <- Frames]
    ),
    {Pictures, Stats, _} = ?T:decode_all(Mod, Frames, init(Ctx, #{})),
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
round_trip(#{mod := Mod, implementation := Implementation} = Ctx) ->
    {Frames, EncStats, Enc} = encode(
        Ctx, 320, 240, lists:seq(0, 29), init(Ctx, #{bitrate => 500000})
    ),
    ?assertEqual([true | lists:duplicate(29, false)], [K || #{keyframe := K} <- Frames]),
    ?assertEqual([N * 3000 || N <- lists:seq(0, 29)], [T || #{timestamp := T} <- Frames]),
    ?assertMatch(#{framesEncoded := 30, keyFramesEncoded := 1, targetBitrate := 500000}, EncStats),
    ?assert(maps:get(totalEncodeTime, EncStats) > 0),
    %% Not every library tells the quantizer.
    ?assertEqual(maps:get(qp, Ctx, true), maps:get(qpSum, EncStats, 0) > 0),
    {Pictures, DecStats, Dec} = ?T:decode_all(Mod, Frames, init(Ctx, #{})),
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
    Size = byte_size(Implementation),
    ?assertMatch(
        #{implementation := <<Implementation:Size/binary, _/binary>>, power_efficient := false},
        Mod:info(Enc)
    ),
    ?assertMatch(#{implementation := <<_/binary>>}, Mod:info(Dec)).

%% keyframe => true, in a picture or in a map of its own before it,
%% makes the next frame a key frame.
keyframe_request(#{mod := Mod} = Ctx) ->
    {_, _, St1} = encode(Ctx, 176, 144, [0, 1, 2], init(Ctx, #{})),
    {ok, [#{keyframe := true}], #{keyFramesEncoded := 1}, St2} =
        Mod:encode((?P:picture(176, 144, 3))#{keyframe => true}, St1),
    {ok, [#{keyframe := false}], #{keyFramesEncoded := 0}, St3} = Mod:encode(
        ?P:picture(176, 144, 4), St2
    ),
    {ok, [], _, St4} = Mod:encode(#{keyframe => true}, St3),
    {ok, [#{keyframe := true}], _, _} = Mod:encode(?P:picture(176, 144, 5), St4).

%% The encoder follows the bitrate given in the raw map, within the
%% bounds of the options, and reports it.
follows_bitrate(#{mod := Mod} = Ctx) ->
    Bytes = fun(Ns, St0) ->
        {Sizes, {Target, St}} = lists:mapfoldl(
            fun(N, {_, StA}) ->
                {ok, [#{data := D}], #{targetBitrate := T}, StB} = Mod:encode(
                    noise(320, 240, N), StA
                ),
                {byte_size(D), {T, StB}}
            end,
            {undefined, St0},
            Ns
        ),
        {lists:sum(Sizes), Target, St}
    end,
    St0 = init(Ctx, #{bitrate => 100000, max_bitrate => 1500000}),
    {_, 100000, St1} = Bytes(lists:seq(0, 29), St0),
    {Low, 100000, St2} = Bytes(lists:seq(30, 89), St1),
    {ok, [], #{targetBitrate := 1000000}, St3} = Mod:encode(#{bitrate => 1000000}, St2),
    {_, 1000000, St4} = Bytes(lists:seq(90, 119), St3),
    {High, 1000000, St5} = Bytes(lists:seq(120, 179), St4),
    ?assert(High > 3 * Low),
    {ok, [_], #{targetBitrate := 1500000}, St6} = Mod:encode(
        (?P:picture(320, 240, 180))#{bitrate => 9000000}, St5
    ),
    {ok, [_], #{targetBitrate := 30000}, _} = Mod:encode(
        (?P:picture(320, 240, 181))#{bitrate => 1}, St6
    ).

%% Pictures of another size start again with a key frame.
new_size(#{mod := Mod} = Ctx) ->
    {_, _, St1} = encode(Ctx, 320, 240, [0, 1], init(Ctx, #{})),
    {ok, [#{keyframe := true} = Frame], _, St2} = Mod:encode(?P:picture(176, 144, 2), St1),
    {ok, [#{keyframe := false}], _, _} = Mod:encode(?P:picture(176, 144, 3), St2),
    {ok, [#{width := 176, height := 144}], _, _} = Mod:decode(Frame, init(Ctx, #{})).

%% Odd sizes round the chroma planes up. A library that only takes even
%% sizes refuses the picture rather than cut it.
odd_size(#{mod := Mod} = Ctx) ->
    Picture = #{
        format => i420,
        width => 33,
        height => 17,
        y => binary:copy(<<100>>, 33 * 17),
        u => binary:copy(<<90>>, 17 * 9),
        v => binary:copy(<<160>>, 17 * 9),
        timestamp => 0
    },
    case maps:get(odd_sizes, Ctx, true) of
        true ->
            {ok, [Frame], _, _} = Mod:encode(Picture, init(Ctx, #{})),
            {ok, [#{width := 33, height := 17, y := Y, u := U, v := V}], _, _} = Mod:decode(
                Frame, init(Ctx, #{})
            ),
            ?assertEqual({33 * 17, 17 * 9, 17 * 9}, {byte_size(Y), byte_size(U), byte_size(V)});
        false ->
            ?assertMatch({error, {_, odd_size}}, Mod:encode(Picture, init(Ctx, #{})))
    end.

%% A frame cut short is dropped and said so, then frames are dropped
%% until a key frame, which decodes.
damaged_frame(#{mod := Mod} = Ctx) ->
    {[F0, F1, F2, F3], _, St} = encode(Ctx, 176, 144, [0, 1, 2, 3], init(Ctx, #{})),
    {ok, [F4], _, _} = Mod:encode((?P:picture(176, 144, 4))#{keyframe => true}, St),
    Cut = F1#{data := binary:part(maps:get(data, F1), 0, 12)},
    {Outs, Stats, _} = ?T:decode_all(Mod, [F0, Cut, F2, F3, F4], init(Ctx, #{})),
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

starts_on_key(#{mod := Mod} = Ctx) ->
    {[_Key, Inter], _, _} = encode(Ctx, 176, 144, [0, 1], init(Ctx, #{})),
    {ok, [#{dropped := waiting_for_keyframe}], Stats, _} = Mod:decode(Inter, init(Ctx, #{})),
    ?assertEqual(#{}, Stats).

%% A key frame larger than max_pixels is refused, and what follows it
%% waits for a key frame that fits.
too_large(#{mod := Mod} = Ctx) ->
    {[Key, Inter], _, _} = encode(Ctx, 320, 240, [0, 1], init(Ctx, #{})),
    St0 = init(Ctx, #{max_pixels => 176 * 144}),
    {ok, [#{dropped := too_large, timestamp := 0}], _, St1} = Mod:decode(Key, St0),
    {ok, [#{dropped := waiting_for_keyframe}], _, _} = Mod:decode(Inter, St1),
    {ok, [#{width := 320}], _, _} = Mod:decode(Key, init(Ctx, #{max_pixels => 320 * 240})).

%% Whatever bytes a peer sends, decode/2 answers ok with pictures within
%% the size limit or a dropped frame: random bytes, and real frames with
%% bytes changed.
garbage(#{mod := Mod} = Ctx) ->
    _ = rand:seed(exsss, {4, 5, 6}),
    {Real, _, _} = encode(Ctx, 176, 144, lists:seq(0, 9), init(Ctx, #{})),
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
            {ok, Outs, _, St1} = Mod:decode(
                #{data => Data, timestamp => I * 3000, keyframe => false}, St
            ),
            %% None for a frame that decodes and shows nothing.
            ?assert(length(Outs) =< 8),
            ?assert(
                lists:all(
                    fun
                        (#{dropped := _}) ->
                            true;
                        (#{width := W, height := H, y := Y}) ->
                            byte_size(Y) =:= W * H andalso W * H =< 640 * 480
                    end,
                    Outs
                )
            ),
            St1
        end,
        init(Ctx, #{max_pixels => 640 * 480}),
        lists:seq(1, 1500)
    ).

%% A picture whose planes do not match its size is the application's
%% mistake: an error.
bad_raw(#{mod := Mod} = Ctx) ->
    St = init(Ctx, #{}),
    Picture = ?P:picture(176, 144, 0),
    ?assertMatch(
        {error, {bad_raw_picture, #{width := 320, y := {bytes, 25344}}}},
        Mod:encode(Picture#{width := 320}, St)
    ),
    ?assertMatch({error, {bad_raw_picture, _}}, Mod:encode(Picture#{u := <<>>}, St)),
    ?assertMatch({error, {bad_raw_picture, _}}, Mod:encode(Picture#{format := nv12}, St)),
    ?assertMatch({error, {bad_raw_picture, _}}, Mod:encode(maps:remove(timestamp, Picture), St)),
    ?assertEqual({error, bad_raw_picture}, Mod:encode(picture, St)).
