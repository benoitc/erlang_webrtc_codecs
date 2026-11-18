-module(webrtc_codecs_capture_tests).
-include_lib("eunit/include/eunit.hrl").

-define(M, webrtc_codecs_capture).

%% Capture runs FFmpeg; its test sources stand in for a camera and a
%% microphone, so these run without a device.
capture_test_() ->
    case os:find_executable("ffmpeg") of
        false ->
            {"skipped: no ffmpeg", []};
        _ ->
            [
                %% What an earlier test left in the mailbox would count as a
                %% slow owner.
                {timeout, 30,
                    {Title, fun() ->
                        flush(),
                        Fun()
                    end}}
             || {Title, Fun} <- [
                    {"test pictures", fun pictures/0},
                    {"test audio", fun audio/0},
                    {"a file ends", fun file_ends/0},
                    {"a slow owner loses frames, not memory", fun slow_owner/0},
                    {"a missing file is an error", fun missing_file/0},
                    {"stops with its owner", fun stops_with_owner/0},
                    {"bad options", fun bad_options/0},
                    {"devices", fun devices/0}
                ]
            ]
    end.

take(Pid, Count) ->
    [
        receive
            {webrtc_capture, Pid, Raw} -> Raw
        after 10000 -> error({timeout, I})
        end
     || I <- lists:seq(1, Count)
    ].

pictures() ->
    {ok, Pid} = ?M:start({test, video}, #{width => 160, height => 120, frame_rate => 30}),
    Pictures = take(Pid, 10),
    ?assertEqual([I * 3000 || I <- lists:seq(0, 9)], [T || #{timestamp := T} <- Pictures]),
    [
        ?assertMatch(
            #{
                format := i420,
                width := 160,
                height := 120,
                y := <<_:19200/binary>>,
                u := <<_:4800/binary>>,
                v := <<_:4800/binary>>
            },
            P
        )
     || P <- Pictures
    ],
    %% The test source moves.
    ?assertNotEqual(maps:get(y, hd(Pictures)), maps:get(y, lists:last(Pictures))),
    ?assertMatch(#{captured := C, dropped := 0} when C >= 10, ?M:stats(Pid)),
    ok = ?M:stop(Pid),
    ?assertNot(is_process_alive(Pid)).

audio() ->
    {ok, Pid} = ?M:start({test, audio}, #{sample_rate => 16000, channels => 2, frame_ms => 10}),
    Chunks = take(Pid, 10),
    [
        ?assertEqual(
            #{
                format => s16le,
                sample_rate => 16000,
                channels => 2,
                samples => maps:get(samples, C)
            },
            C
        )
     || C <- Chunks
    ],
    ?assert(lists:all(fun(#{samples := S}) -> byte_size(S) =:= 160 * 2 * 2 end, Chunks)),
    %% A tone, not silence.
    ?assert(lists:any(fun(#{samples := S}) -> S =/= binary:copy(<<0>>, byte_size(S)) end, Chunks)),
    ok = ?M:stop(Pid).

%% A file of five pictures gives them, then eof, and the process ends.
file_ends() ->
    File = string:trim(os:cmd("mktemp")) ++ ".y4m",
    "" = os:cmd(
        "ffmpeg -v error -y -f lavfi -i testsrc2=size=64x48:rate=10 -frames:v 5 -pix_fmt yuv420p '" ++
            File ++ "' 2>&1"
    ),
    try
        {ok, Pid} = ?M:start({file, video, File}, #{
            width => 64, height => 48, frame_rate => 10, realtime => false, max_queue => 100
        }),
        Ref = monitor(process, Pid),
        Pictures = take(Pid, 5),
        ?assertEqual([0, 9000, 18000, 27000, 36000], [T || #{timestamp := T} <- Pictures]),
        receive
            {webrtc_capture, Pid, eof} -> ok
        after 10000 -> error(no_eof)
        end,
        receive
            {'DOWN', Ref, process, Pid, normal} -> ok
        after 5000 -> error(still_alive)
        end
    after
        file:delete(File)
    end.

%% The owner reads nothing: its mailbox stays near max_queue and the
%% rest is counted as dropped.
slow_owner() ->
    {ok, Pid} = ?M:start({test, video}, #{
        width => 64, height => 48, frame_rate => 60, max_queue => 3
    }),
    timer:sleep(1000),
    #{captured := Captured, dropped := Dropped} = ?M:stats(Pid),
    {message_queue_len, Queued} = process_info(self(), message_queue_len),
    ok = ?M:stop(Pid),
    ?assert(Captured > 20),
    ?assert(Dropped > 0),
    ?assert(Queued =< 4),
    ?assertEqual(Captured, Dropped + Queued),
    flush().

missing_file() ->
    {ok, Pid} = ?M:start({file, audio, "/nonexistent/file.wav"}, #{}),
    receive
        {webrtc_capture, Pid, {error, {ffmpeg, Status, Said}}} ->
            ?assert(Status =/= 0),
            ?assertNotEqual(nomatch, binary:match(Said, <<"No such file">>))
    after 10000 -> error(no_error)
    end.

stops_with_owner() ->
    Parent = self(),
    Owner = spawn(fun() ->
        {ok, Pid} = ?M:start({test, video}, #{width => 64, height => 48}),
        unlink(Pid),
        Parent ! {capture, Pid},
        receive
            stop -> ok
        end
    end),
    Pid =
        receive
            {capture, P} -> P
        after 5000 -> error(not_started)
        end,
    Ref = monitor(process, Pid),
    Owner ! stop,
    receive
        {'DOWN', Ref, process, Pid, normal} -> ok
    after 5000 -> error(still_alive)
    end.

bad_options() ->
    process_flag(trap_exit, true),
    [
        ?assertMatch({error, {badarg, _}}, ?M:start(Source, Opts))
     || {Source, Opts} <- [
            {{test, video}, #{width => 161}},
            {{test, video}, #{frame_rate => 0}},
            {{test, audio}, #{sample_rate => 44100, frame_ms => 5, channels => 0}},
            {{test, audio}, #{sample_rate => 11025, frame_ms => 1}},
            {{screen, 0}, #{}},
            {{camera, -1}, #{}}
        ]
    ],
    process_flag(trap_exit, false),
    flush().

%% Listing asks nothing of the user; opening a device may, so it is not
%% done here.
devices() ->
    {ok, #{video := Video, audio := Audio}} = ?M:devices(),
    [
        ?assertMatch(#{index := I, name := <<_/binary>>} when is_integer(I), D)
     || D <- Video ++ Audio
    ].

flush() ->
    receive
        _ -> flush()
    after 0 -> ok
    end.
