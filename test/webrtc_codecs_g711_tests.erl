-module(webrtc_codecs_g711_tests).
-include_lib("eunit/include/eunit.hrl").

-define(M, webrtc_codecs_g711).

init(Name, Opts) ->
    {ok, St} = ?M:init(audio, #{name => Name, clock_rate => 8000, channels => 1}, Opts),
    St.

pcm(Samples) -> <<<<S:16/little-signed>> || S <- Samples>>.

raw(Pcm) -> #{format => s16le, sample_rate => 8000, channels => 1, samples => Pcm}.

%% ITU-T G.711 tables 1a to 2b: the ends of the range and both zeros.
known_bytes_test() ->
    ?assertEqual(<<16#FF, 16#7F, 16#80, 16#00>>, ?M:compress(ulaw, pcm([0, -1, 32767, -32768]))),
    ?assertEqual(<<16#D5, 16#55, 16#AA, 16#2A>>, ?M:compress(alaw, pcm([0, -1, 32767, -32768]))),
    ?assertEqual(pcm([0, 0, 32124, -32124]), ?M:expand(ulaw, <<16#FF, 16#7F, 16#80, 16#00>>)),
    ?assertEqual(pcm([8, -8, 32256, -32256]), ?M:expand(alaw, <<16#D5, 16#55, 16#AA, 16#2A>>)).

%% Every byte expands to a level that compresses back to it. Mu-law has
%% two zeros; the negative one comes back as the positive one.
every_byte_round_trips_test() ->
    All = list_to_binary(lists:seq(0, 255)),
    ?assertEqual(All, ?M:compress(alaw, ?M:expand(alaw, All))),
    ?assertEqual(
        binary:replace(All, <<16#7F>>, <<16#FF>>), ?M:compress(ulaw, ?M:expand(ulaw, All))
    ).

%% Companding keeps a tone well above 30 dB.
tone_quality_test_() ->
    Tone = webrtc_codecs_pattern:tone(440, 200, #{sample_rate => 8000, channels => 1}, 0),
    [
        fun() ->
            Decoded = Tone#{samples := ?M:expand(Law, ?M:compress(Law, maps:get(samples, Tone)))},
            ?assert(webrtc_codecs_pattern:snr(Tone, Decoded) > 30)
        end
     || Law <- [ulaw, alaw]
    ].

%% Our bytes against FFmpeg's G.711, both ways, over every 16 bit level.
ffmpeg_test_() ->
    case os:find_executable("ffmpeg") of
        false ->
            {"skipped: no ffmpeg", []};
        Ffmpeg ->
            {timeout, 60, [
                fun() -> against_ffmpeg(Ffmpeg, Law, Fmt) end
             || {Law, Fmt} <- [{ulaw, "mulaw"}, {alaw, "alaw"}]
            ]}
    end.

against_ffmpeg(Ffmpeg, Law, Fmt) ->
    Dir = string:trim(os:cmd("mktemp -d")),
    try
        Bytes = list_to_binary(lists:seq(0, 255)),
        ?assertEqual(convert(Ffmpeg, Dir, Fmt, "s16le", Bytes), ?M:expand(Law, Bytes)),
        %% FFmpeg picks the nearest level where G.711 truncates, so a
        %% few inputs next to a decision threshold get the neighbouring
        %% level: the input then lies between the two.
        Pcm = pcm(lists:seq(-32768, 32767)),
        Theirs = ?M:expand(Law, convert(Ffmpeg, Dir, "s16le", Fmt, Pcm)),
        Ours = ?M:expand(Law, ?M:compress(Law, Pcm)),
        Differ = [
            {S, A, B}
         || {S, A, B} <- lists:zip3(samples(Pcm), samples(Ours), samples(Theirs)), A =/= B
        ],
        ?assert(length(Differ) < 65536 div 50),
        ?assertEqual([], [D || {S, A, B} = D <- Differ, abs(S - A) > abs(A - B)])
    after
        os:cmd("rm -rf '" ++ Dir ++ "'")
    end.

samples(Pcm) -> [S || <<S:16/little-signed>> <= Pcm].

convert(Ffmpeg, Dir, From, To, Data) ->
    In = filename:join(Dir, "in." ++ From),
    Out = filename:join(Dir, "out." ++ To),
    ok = file:write_file(In, Data),
    Cmd = io_lib:format(
        "'~ts' -v error -y -f ~s -ar 8000 -ac 1 -i '~ts' -f ~s -ar 8000 -ac 1 '~ts' 2>&1",
        [Ffmpeg, From, In, To, Out]
    ),
    "" = os:cmd(lists:flatten(Cmd)),
    {ok, Converted} = file:read_file(Out),
    Converted.

%% decode/2 keeps the RTP timestamp and counts the samples.
decode_test() ->
    St = init(<<"PCMU">>, #{}),
    {ok, [Out], Stats, St} = ?M:decode(
        #{data => <<16#FF, 16#80>>, timestamp => 4000, keyframe => true}, St
    ),
    ?assertEqual(
        #{
            format => s16le,
            sample_rate => 8000,
            channels => 1,
            samples => pcm([0, 32124]),
            timestamp => 4000
        },
        Out
    ),
    ?assertEqual(#{totalSamplesReceived => 2}, Stats).

%% encode/2 cuts what it is given in frames of ptime and numbers them in
%% the 8 kHz RTP clock, from the timestamp given or where it stopped.
encode_frames_test() ->
    St0 = init(<<"pcma">>, #{}),
    Pcm = binary:copy(<<0, 0>>, 400),
    {ok, Frames, #{targetBitrate := 64000}, St1} = ?M:encode(raw(Pcm), St0),
    ?assertEqual([{160, 0}, {160, 160}, {80, 320}], [
        {byte_size(D), T}
     || #{data := D, timestamp := T} <- Frames
    ]),
    ?assert(lists:all(fun(#{keyframe := K}) -> K end, Frames)),
    {ok, [#{timestamp := 400}], _, St2} = ?M:encode(raw(binary:copy(<<0, 0>>, 80)), St1),
    {ok, [#{timestamp := 16#FFFFFFF0}, #{timestamp := 144}], _, St3} =
        ?M:encode((raw(binary:copy(<<0, 0>>, 320)))#{timestamp => 16#FFFFFFF0}, St2),
    {ok, [#{timestamp := 304}], _, _} = ?M:encode(raw(<<0, 0>>), St3).

ptime_test() ->
    {ok, [#{data := D}, _], _, _} = ?M:encode(
        raw(binary:copy(<<0, 0>>, 160)), init(<<"PCMU">>, #{ptime => 10})
    ),
    ?assertEqual(80, byte_size(D)),
    ?assertEqual(
        {error, {badarg, {ptime, 500}}}, ?M:init(audio, #{name => <<"PCMU">>}, #{ptime => 500})
    ).

%% A map without samples changes nothing and sends nothing; audio in
%% another format is an error, which turns the plugin off.
control_and_bad_input_test() ->
    St = init(<<"PCMU">>, #{}),
    ?assertEqual({ok, [], #{}, St}, ?M:encode(#{bitrate => 32000}, St)),
    ?assertMatch(
        {error, {bad_raw_audio, #{sample_rate := 48000}}},
        ?M:encode((raw(<<0, 0>>))#{sample_rate := 48000}, St)
    ),
    ?assertMatch({error, {bad_raw_audio, _}}, ?M:encode(raw(<<0>>), St)),
    ?assertEqual({error, bad_raw_audio}, ?M:encode(pcm, St)),
    ?assertMatch({error, {badarg, _}}, ?M:init(video, #{name => <<"PCMU">>}, #{})),
    ?assertEqual(
        {error, {unsupported_codec, <<"opus">>}}, ?M:init(audio, #{name => <<"opus">>}, #{})
    ).
