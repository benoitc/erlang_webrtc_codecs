%% Checks every video plugin has to pass, run by the tests of each one
%% with a context: #{mod, codec, name, implementation}, where codec is
%% what the module's frame_info/2 takes and implementation the start of
%% the name info/1 gives.
-module(webrtc_codecs_video_checks).
-include_lib("eunit/include/eunit.hrl").

-export([all/1, init/2, encode/5, is_key/1, noise/3, decodes_like_ffmpeg/2]).

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
            {"bad raw", fun bad_raw/1},
            {"asks for a key frame", fun asks_for_keyframe/1},
            {"control", fun control/1},
            {"goes on after an error", fun goes_on/1},
            {"terminate", fun terminate/1}
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
    {ok, [#{width := 176, height := 144}], _, _} = ?T:decode(Mod, Frame, init(Ctx, #{})).

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
            {ok, [#{width := 33, height := 17, y := Y, u := U, v := V}], _, _} = ?T:decode(
                Mod,
                Frame,
                init(Ctx, #{})
            ),
            ?assertEqual({33 * 17, 17 * 9, 17 * 9}, {byte_size(Y), byte_size(U), byte_size(V)});
        false ->
            ?assertMatch({error, {_, odd_size}, _}, Mod:encode(Picture, init(Ctx, #{})))
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
    {ok, [#{dropped := waiting_for_keyframe}], Stats, _} = ?T:decode(Mod, Inter, init(Ctx, #{})),
    ?assertEqual(#{framesDropped => 1}, Stats).

%% A key frame larger than max_pixels is refused, and what follows it
%% waits for a key frame that fits.
too_large(#{mod := Mod} = Ctx) ->
    {[Key, Inter], _, _} = encode(Ctx, 320, 240, [0, 1], init(Ctx, #{})),
    St0 = init(Ctx, #{max_pixels => 176 * 144}),
    {ok, [#{dropped := too_large, timestamp := 0}], _, St1} = ?T:decode(Mod, Key, St0),
    {ok, [#{dropped := waiting_for_keyframe}], _, _} = ?T:decode(Mod, Inter, St1),
    {ok, [#{width := 320}], _, _} = ?T:decode(Mod, Key, init(Ctx, #{max_pixels => 320 * 240})).

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
            {ok, Outs, _, St1} = ?T:decode(
                Mod,
                #{data => Data, timestamp => I * 3000, keyframe => false},
                St
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
%% mistake: an error that leaves the plugin on, with its state.
bad_raw(#{mod := Mod} = Ctx) ->
    St = init(Ctx, #{}),
    Picture = ?P:picture(176, 144, 0),
    ?assertMatch(
        {error, {bad_raw_picture, #{width := 320, y := {bytes, 25344}}}, _},
        Mod:encode(Picture#{width := 320}, St)
    ),
    ?assertMatch({error, {bad_raw_picture, _}, _}, Mod:encode(Picture#{u := <<>>}, St)),
    ?assertMatch({error, {bad_raw_picture, _}, _}, Mod:encode(Picture#{format := nv12}, St)),
    ?assertMatch({error, {bad_raw_picture, _}, _}, Mod:encode(maps:remove(timestamp, Picture), St)),
    ?assertEqual({error, bad_raw_picture, St}, Mod:encode(picture, St)).

%% A frame that cannot be decoded asks the sender for a key frame, at
%% the first one dropped and then once in thirty, not for each. A frame
%% a key frame would not repair asks nothing, and neither does a plugin
%% told not to.
asks_for_keyframe(#{mod := Mod} = Ctx) ->
    {[Key, Inter], _, _} = encode(Ctx, 320, 240, [0, 1], init(Ctx, #{})),
    Asked = fun(Count, St0) ->
        {Feedback, St} = lists:mapfoldl(
            fun(_, StA) ->
                case Mod:decode(Inter, StA) of
                    {ok, [#{dropped := _}], #{framesDropped := 1}, StB, [keyframe_request]} ->
                        {true, StB};
                    {ok, [#{dropped := _}], #{framesDropped := 1}, StB} ->
                        {false, StB}
                end
            end,
            St0,
            lists:seq(1, Count)
        ),
        {[N || {N, true} <- lists:enumerate(Feedback)], St}
    end,
    {Requests, St1} = Asked(65, init(Ctx, #{})),
    ?assertEqual([1, 31, 61], Requests),
    %% A picture, then a loss: asked again at once.
    {ok, [#{width := 320}], _, St2} = Mod:decode(Key, St1),
    {ok, [#{width := 320}], _, St3} = Mod:decode(Inter, St2),
    Damaged = Inter#{data := <<(binary:part(maps:get(data, Key), 0, 3))/binary, 0:64>>},
    case Mod:decode(Damaged#{keyframe := true}, St3) of
        {ok, [#{dropped := _}], _, St4, [keyframe_request]} ->
            ?assertMatch({[], _}, Asked(5, St4));
        {ok, _, _, _} ->
            %% Not every decoder refuses these bytes.
            ok
    end,
    ?assertMatch({[], _}, Asked(40, init(Ctx, #{request_keyframes => false}))),
    ?assertMatch(
        {ok, [#{dropped := too_large}], #{framesDropped := 1}, _},
        Mod:decode(Key, init(Ctx, #{max_pixels => 176 * 144}))
    ),
    ?assertMatch(
        {error, {badarg, _}},
        Mod:init(video, #{name => maps:get(name, Ctx)}, #{
            request_keyframes => 'maybe'
        })
    ).

%% What erlang_webrtc tells the encoder: a key frame the peer asks for,
%% the bitrate the application sets, the most the peer allows.
control(#{mod := Mod} = Ctx) ->
    Picture = fun(N) -> ?P:picture(176, 144, N) end,
    {_, _, St1} = encode(Ctx, 176, 144, [0, 1], init(Ctx, #{bitrate => 300000})),
    {ok, St2} = Mod:control(keyframe_request, St1),
    {ok, [#{keyframe := true}], #{targetBitrate := 300000}, St3} = Mod:encode(Picture(2), St2),
    {ok, St4} = Mod:control({target_bitrate, 500000}, St3),
    {ok, [#{keyframe := false}], #{targetBitrate := 500000}, St5} = Mod:encode(Picture(3), St4),
    {ok, St6} = Mod:control({max_bitrate, 200000}, St5),
    {ok, [_], #{targetBitrate := 200000}, St7} = Mod:encode(Picture(4), St6),
    %% What the application asks for stays under what the peer allows.
    {ok, [], #{targetBitrate := 200000}, St8} = Mod:encode(#{bitrate => 400000}, St7),
    {ok, St9} = Mod:control({max_bitrate, infinity}, St8),
    {ok, [_], #{targetBitrate := 400000}, St10} = Mod:encode(Picture(5), St9),
    %% Nothing, or an event of a later erlang_webrtc, changes nothing.
    ?assertEqual({ok, St10}, Mod:control({target_bitrate, 0}, St10)),
    ?assertEqual({ok, St10}, Mod:control({something, new}, St10)),
    %% Told before the first picture, they hold when the encoder starts.
    {ok, StA} = Mod:control({max_bitrate, 150000}, init(Ctx, #{bitrate => 300000})),
    {ok, StB} = Mod:control({target_bitrate, 250000}, StA),
    {ok, [#{keyframe := true}], #{targetBitrate := 150000}, _} = Mod:encode(Picture(0), StB).

%% An error of encode/2 comes with the state, and the plugin encodes the
%% next picture.
goes_on(#{mod := Mod} = Ctx) ->
    {_, _, St1} = encode(Ctx, 176, 144, [0, 1], init(Ctx, #{})),
    Picture = ?P:picture(176, 144, 2),
    {error, {bad_raw_picture, _}, St2} = Mod:encode(Picture#{u := <<>>}, St1),
    ?assertEqual(St1, St2),
    {ok, [#{keyframe := false, timestamp := 6000}], #{framesEncoded := 1}, _} = Mod:encode(
        Picture, St2
    ).

%% When the stream ends the codecs are destroyed, used or not.
terminate(#{mod := Mod} = Ctx) ->
    ?assertEqual(ok, Mod:terminate(init(Ctx, #{}))),
    {[Key | _], _, Enc} = encode(Ctx, 176, 144, [0, 1], init(Ctx, #{})),
    {ok, [_], _, Dec} = Mod:decode(Key, init(Ctx, #{})),
    ?assertEqual(ok, Mod:terminate(Enc)),
    ?assertEqual(ok, Mod:terminate(Dec)),
    %% A state used after that tells so and stays usable.
    ?assertMatch({error, {_, closed}, _}, Mod:encode(?P:picture(176, 144, 2), Enc)),
    ?assertMatch({ok, [#{dropped := closed}], _, _, _}, Mod:decode(Key, Dec)).
