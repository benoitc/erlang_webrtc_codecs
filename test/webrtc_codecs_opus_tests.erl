-module(webrtc_codecs_opus_tests).
-include_lib("eunit/include/eunit.hrl").

-define(M, webrtc_codecs_opus).
-define(P, webrtc_codecs_pattern).
-define(MONO, #{sample_rate => 48000, channels => 1}).

%% Every test needs libopus; without it they are skipped with the reason.
opus_test_() ->
    case webrtc_codecs_opus_nif:loaded() of
        false ->
            {"skipped: built without libopus", []};
        true ->
            [
                {"round_trip", fun round_trip/0},
                {"timestamps", fun timestamps/0},
                {"stereo", fun stereo/0},
                {"follows_bitrate", fun follows_bitrate/0},
                {"one_lost_frame", fun one_lost_frame/0},
                {"two_lost_frames", fun two_lost_frames/0},
                {"long_gap", fun long_gap/0},
                {"bad_packet", fun bad_packet/0},
                {"garbage", fun garbage/0},
                {"bad_raw", fun bad_raw/0},
                {"dtx", fun dtx/0},
                {"bad_options", fun bad_options/0}
            ]
    end.

without_libopus_test() ->
    case webrtc_codecs_opus_nif:loaded() of
        true ->
            ?assertMatch(
                [#{name := <<"opus">>, implementation := <<"libopus ", _/binary>>}], ?M:codecs()
            );
        false ->
            ?assertEqual([], ?M:codecs()),
            ?assertEqual({error, {not_built, opus}}, ?M:init(audio, #{name => <<"opus">>}, #{}))
    end.

init(Fmtp, Opts) ->
    {ok, St} = ?M:init(
        audio, #{name => <<"opus">>, clock_rate => 48000, channels => 2, fmtp => Fmtp}, Opts
    ),
    St.

%% N frames of 20 ms of tone, encoded.
encode(N, St0) ->
    lists:mapfoldl(
        fun(I, St) ->
            {ok, [Frame], _, St1} = ?M:encode(?P:tone(440, 20, ?MONO, I * 960), St),
            {Frame, St1}
        end,
        St0,
        lists:seq(0, N - 1)
    ).

decode(Frames, St0) ->
    {Outs, {Stats, St}} = lists:mapfoldl(
        fun(Frame, {Acc, StA}) ->
            {ok, Out, Stats, StB} = ?M:decode(Frame, StA),
            {Out, {maps:merge_with(fun(_, A, B) -> A + B end, Acc, Stats), StB}}
        end,
        {#{}, St0},
        Frames
    ),
    {lists:append(Outs), Stats, St}.

energy(Pcm) ->
    lists:sum([S * S || <<S:16/little-signed>> <= Pcm]) / max(1, byte_size(Pcm) div 2).

%% A second of tone comes back with as many samples, the same
%% timestamps and the same loudness.
round_trip() ->
    {Frames, Enc} = encode(50, init([], #{})),
    {Outs, Stats, Dec} = decode(Frames, init([], #{})),
    ?assertEqual(50, length(Outs)),
    ?assertEqual([I * 960 || I <- lists:seq(0, 49)], [T || #{timestamp := T} <- Outs]),
    ?assert(
        lists:all(fun(#{format := s16le, sample_rate := 48000, channels := 1}) -> true end, Outs)
    ),
    ?assertEqual(#{totalSamplesReceived => 48000}, Stats),
    Decoded = iolist_to_binary([S || #{samples := S} <- Outs]),
    ?assertEqual(48000 * 2, byte_size(Decoded)),
    #{samples := Sent} = ?P:tone(440, 1000, ?MONO, 0),
    %% Past the first frames, where the codec starts from silence.
    Ratio = energy(binary:part(Decoded, 9600, 80000)) / energy(binary:part(Sent, 9600, 80000)),
    ?assert(Ratio > 0.8 andalso Ratio < 1.25),
    ?assertMatch(
        #{implementation := <<"libopus ", _/binary>>, power_efficient := false}, ?M:info(Enc)
    ),
    ?assertMatch(#{implementation := <<"libopus ", _/binary>>}, ?M:info(Dec)).

%% The RTP clock is 48 kHz whatever the rate of the raw audio.
timestamps() ->
    Wide = #{sample_rate => 16000, channels => 1},
    St0 = init([], #{}),
    {ok, [#{timestamp := 0, keyframe := true}], _, St1} = ?M:encode(?P:tone(440, 20, Wide, 0), St0),
    {ok, [#{timestamp := 960}], _, St2} = ?M:encode(
        maps:remove(timestamp, ?P:tone(440, 20, Wide, 320)), St1
    ),
    {ok, [#{timestamp := 5000}], _, St3} = ?M:encode(
        (?P:tone(440, 10, Wide, 0))#{timestamp => 5000}, St2
    ),
    {ok, [#{timestamp := 5480} = Frame], _, _} = ?M:encode(
        maps:remove(timestamp, ?P:tone(440, 20, Wide, 0)), St3
    ),
    %% And decoded audio comes at the rate asked for.
    {ok, [#{sample_rate := 16000, samples := Pcm, timestamp := 5480}],
        #{totalSamplesReceived := 320},
        _} =
        ?M:decode(Frame, init([], #{sample_rate => 16000})),
    ?assertEqual(640, byte_size(Pcm)).

%% stereo=1 in the negotiated fmtp gives two decoded channels; the
%% channels option overrides it.
stereo() ->
    Stereo = #{sample_rate => 48000, channels => 2},
    {ok, [Frame], _, _} = ?M:encode(?P:tone(440, 20, Stereo, 0), init([], #{})),
    {ok, [#{channels := 2, samples := Two}], #{totalSamplesReceived := 960}, _} =
        ?M:decode(Frame, init([{<<"stereo">>, <<"1">>}], #{})),
    ?assertEqual(960 * 4, byte_size(Two)),
    {ok, [#{channels := 1, samples := One}], _, _} =
        ?M:decode(Frame, init([{<<"stereo">>, <<"1">>}], #{channels => 1})),
    ?assertEqual(960 * 2, byte_size(One)).

%% The encoder follows the bitrate given in the raw map, within what the
%% peer accepts (maxaveragebitrate), and reports it.
follows_bitrate() ->
    Raw = fun(I) -> ?P:tone(440, 20, ?MONO, I * 960) end,
    Size = fun(St0, Bitrate) ->
        {ok, [], #{targetBitrate := Target}, St1} = ?M:encode(#{bitrate => Bitrate}, St0),
        {Sizes, St2} = lists:mapfoldl(
            fun(I, St) ->
                {ok, [#{data := D}], #{targetBitrate := Target}, StN} = ?M:encode(Raw(I), St),
                {byte_size(D), StN}
            end,
            St1,
            lists:seq(1, 25)
        ),
        {lists:sum(Sizes), Target, St2}
    end,
    {ok, _, _, St} = ?M:encode(
        Raw(0), init([{<<"maxaveragebitrate">>, <<"40000">>}], #{bitrate => 24000})
    ),
    {Low, 8000, StLow} = Size(St, 8000),
    {High, 32000, StHigh} = Size(StLow, 32000),
    ?assert(High > 2 * Low),
    {_, 40000, _} = Size(StHigh, 128000),
    %% A bitrate given before the first samples is the one the encoder starts with.
    {ok, [], #{}, Early} = ?M:encode(#{bitrate => 16000}, init([], #{})),
    {ok, [_], #{targetBitrate := 16000}, _} = ?M:encode(Raw(0), Early).

fec_frames(N) ->
    {Frames, _} = encode(
        N, init([{<<"useinbandfec">>, <<"1">>}], #{packet_loss => 20, bitrate => 32000})
    ),
    Frames.

%% One frame lost: its audio comes with the next frame, recovered from
%% the redundancy that frame carries, so nothing is missing.
one_lost_frame() ->
    Frames = fec_frames(10),
    {Before, [_Lost | After]} = lists:split(5, Frames),
    {Outs, Stats, _} = decode(Before ++ After, init([], #{})),
    ?assertEqual([I * 960 || I <- lists:seq(0, 9)], [T || #{timestamp := T} <- Outs]),
    ?assert(lists:all(fun(#{samples := S}) -> byte_size(S) =:= 1920 end, Outs)),
    ?assertEqual(
        #{totalSamplesReceived => 9600, concealedSamples => 0, concealmentEvents => 1}, Stats
    ).

%% Two lost: the first is synthesized and counted as concealed.
two_lost_frames() ->
    Frames = fec_frames(10),
    {Before, [_, _ | After]} = lists:split(4, Frames),
    {Outs, Stats, _} = decode(Before ++ After, init([], #{})),
    ?assertEqual([I * 960 || I <- lists:seq(0, 9)], [T || #{timestamp := T} <- Outs]),
    ?assertEqual(
        #{totalSamplesReceived => 9600, concealedSamples => 960, concealmentEvents => 1}, Stats
    ).

%% A hole of more than 120 ms is a pause: nothing is made up for it.
long_gap() ->
    Frames = fec_frames(12),
    {Outs, Stats, _} = decode([hd(Frames), lists:last(Frames)], init([], #{})),
    ?assertEqual([0, 11 * 960], [T || #{timestamp := T} <- Outs]),
    ?assertEqual(#{totalSamplesReceived => 1920}, Stats).

%% A packet that is not Opus is dropped and said so; the next one decodes.
bad_packet() ->
    {[Good, Next], _} = encode(2, init([], #{})),
    {ok, [_], _, St1} = ?M:decode(Good, init([], #{})),
    %% Code 3 packet announcing zero frames (RFC 6716 section 3.2.5).
    Bad = Next#{data := <<3, 0>>},
    {ok, [#{dropped := invalid_packet, timestamp := 960}], Stats, St2} = ?M:decode(Bad, St1),
    ?assertEqual(#{totalSamplesReceived => 0}, Stats),
    {ok, [#{dropped := invalid_packet}], _, St3} = ?M:decode(Next#{data := <<>>}, St2),
    {ok, [#{dropped := invalid_packet}], _, St4} = ?M:decode(
        Next#{data := binary:copy(<<255>>, 10000)}, St3
    ),
    {ok, [#{samples := Pcm, timestamp := 960}], #{totalSamplesReceived := 960}, _} = ?M:decode(
        Next, St4
    ),
    ?assertEqual(1920, byte_size(Pcm)).

%% Whatever bytes and timestamps a peer sends, decode/2 answers ok with
%% audio or a dropped frame, never more than the gap it fills plus one
%% frame.
garbage() ->
    _ = rand:seed(exsss, {1, 2, 3}),
    lists:foldl(
        fun(_, St) ->
            Frame = #{
                data => rand:bytes(rand:uniform(300)),
                timestamp => rand:uniform(16#100000000) - 1,
                keyframe => false
            },
            {ok, Outs, #{totalSamplesReceived := Total}, St1} = ?M:decode(Frame, St),
            ?assert(length(Outs) >= 1 andalso length(Outs) =< 50),
            ?assert(Total =< 2 * 5760),
            St1
        end,
        init([], #{}),
        lists:seq(1, 3000)
    ).

%% Raw audio libopus cannot take is the application's mistake: an error.
bad_raw() ->
    St = init([], #{}),
    ?assertMatch(
        {error, {bad_raw_audio, #{sample_rate := 44100}}},
        ?M:encode(?P:tone(440, 20, #{sample_rate => 44100, channels => 1}, 0), St)
    ),
    ?assertMatch(
        {error, {bad_raw_audio, #{bytes := 1440}}}, ?M:encode(?P:tone(440, 15, ?MONO, 0), St)
    ),
    ?assertMatch(
        {error, {bad_raw_audio, _}},
        ?M:encode((?P:tone(440, 20, ?MONO, 0))#{samples := <<1, 2, 3>>}, St)
    ),
    ?assertMatch(
        {error, {bad_raw_audio, _}}, ?M:encode((?P:tone(440, 20, ?MONO, 0))#{format := f32}, St)
    ),
    ?assertEqual({error, bad_raw_audio}, ?M:encode(pcm, St)).

%% With usedtx, silence is mostly not sent, and timestamps keep counting.
dtx() ->
    Silence = #{
        format => s16le, sample_rate => 48000, channels => 1, samples => binary:copy(<<0>>, 1920)
    },
    {Sent, _} = lists:foldl(
        fun(_, {Acc, St}) ->
            {ok, Frames, _, St1} = ?M:encode(Silence, St),
            {Acc ++ Frames, St1}
        end,
        {[], init([{<<"usedtx">>, <<"1">>}], #{})},
        lists:seq(1, 100)
    ),
    ?assert(length(Sent) < 50),
    ?assert(maps:get(timestamp, lists:last(Sent)) > 50 * 960).

bad_options() ->
    Codec = #{name => <<"opus">>},
    [
        ?assertMatch({error, {badarg, _}}, ?M:init(audio, Codec, Opts))
     || Opts <- [
            #{sample_rate => 44100},
            #{channels => 3},
            #{application => music},
            #{bitrate => fast},
            #{complexity => 11},
            #{fec => 1},
            #{packet_loss => 101},
            []
        ]
    ],
    ?assertMatch({error, {badarg, _}}, ?M:init(video, Codec, #{})),
    ?assertEqual(
        {error, {unsupported_codec, <<"PCMU">>}}, ?M:init(audio, #{name => <<"PCMU">>}, #{})
    ),
    %% fmtp that is not a list of pairs is ignored.
    ?assertMatch({ok, _}, ?M:init(audio, Codec#{fmtp => [<<"x">>, {<<"stereo">>, <<"y">>}]}, #{})).
