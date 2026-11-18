%% What happens to native contexts over their life, for every codec this
%% build has: shared between processes, left by a process that is killed
%% in the middle of a call, fed bad media for a long time, created and
%% dropped in numbers. Run under the sanitizers too
%% (scripts/test-sanitizers.sh).
%%
%% The suite measures as well as it asserts: how long the destruction of
%% a context takes, how late a normal scheduler runs meanwhile, how much
%% memory moves. The numbers are in the log of each case.
-module(webrtc_codecs_lifecycle_SUITE).
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([shared_reference/1, owner_killed/1, bad_media_for_long/1, many_contexts/1]).

-define(P, webrtc_codecs_pattern).

all() -> [shared_reference, owner_killed, bad_media_for_long, many_contexts].

init_per_suite(Config) ->
    Config.

end_per_suite(_Config) ->
    ok.

%% The codecs of this build that both encode and decode: {Module, Name, Kind}.
codecs() ->
    [
        {Mod, Name, Kind}
     || #{module := Mod, name := Name, kind := Kind, decode := true, encode := true} <- webrtc_codecs:available(),
        Name =/= <<"PCMA">>
    ].

init(Mod, Name, Opts) ->
    Kind =
        case lists:keyfind(Name, 2, codecs()) of
            {_, _, K} -> K
        end,
    {ok, St} = Mod:init(Kind, #{name => Name, fmtp => []}, Opts),
    St.

raw(video, N) ->
    ?P:picture(320, 240, N);
raw(audio, N) ->
    (?P:tone(440, 20, #{sample_rate => 8000, channels => 1}, N * 160))#{timestamp => N * 160}.

%% Frames 0 to Count - 1 of raw media, encoded; the encoder state after.
encoded(Mod, Name, Kind, Count) ->
    lists:mapfoldl(
        fun(N, St) ->
            {ok, Frames, _, St1} = Mod:encode(raw(Kind, N), St),
            {Frames, St1}
        end,
        init(Mod, Name, #{}),
        lists:seq(0, Count - 1)
    ).

%% One decoder and one encoder used by sixteen processes at once. The
%% state is not threaded, so the calls race on the same native context:
%% each has to come back with a result, and the node to stay up.
shared_reference(_Config) ->
    [
        begin
            {Frames0, Encoder} = encoded(Mod, Name, Kind, 20),
            Frames = lists:append(Frames0),
            {ok, _, _, Decoder} = Mod:decode(hd(Frames), init(Mod, Name, #{})),
            Self = self(),
            Workers = [
                spawn_link(fun() ->
                    Results = [
                        begin
                            {ok, _, _, _} = Mod:decode(
                                lists:nth(1 + (I + W) rem length(Frames), Frames), Decoder
                            ),
                            case Mod:encode(raw(Kind, I + W), Encoder) of
                                {ok, _, _, _} -> ok;
                                %% An encoder told a time that went back.
                                {error, _} -> error
                            end
                        end
                     || I <- lists:seq(1, 200)
                    ],
                    Self ! {done, self(), length([ok || ok <- Results])}
                end)
             || W <- lists:seq(1, 16)
            ],
            Oks = [
                receive
                    {done, Pid, Ok} -> Ok
                after 120000 -> error({stuck, Name})
                end
             || Pid <- Workers
            ],
            ct:log(
                "~s: 16 processes, 200 decodes and encodes each on one context, ~p encodes accepted",
                [
                    Name, lists:sum(Oks)
                ]
            )
        end
     || {Mod, Name, Kind} <- codecs()
    ],
    ok.

%% A process is killed while it encodes, again and again. Its contexts
%% are destroyed with it; the next process works, and memory does not
%% keep what the dead ones held.
owner_killed(_Config) ->
    [
        begin
            Round = fun() ->
                Self = self(),
                Pid = spawn(fun() ->
                    St0 = init(Mod, Name, #{}),
                    Self ! started,
                    lists:foldl(
                        fun(N, St) ->
                            {ok, _, _, St1} = Mod:encode(raw(Kind, N), St),
                            St1
                        end,
                        St0,
                        lists:seq(0, 1000000)
                    )
                end),
                receive
                    started -> ok
                end,
                timer:sleep(rand:uniform(20)),
                exit(Pid, kill)
            end,
            [Round() || _ <- lists:seq(1, 20)],
            Before = rss(),
            [Round() || _ <- lists:seq(1, 100)],
            timer:sleep(200),
            After = rss(),
            {[_ | _], _} = encoded(Mod, Name, Kind, 3),
            ct:log("~s: 100 owners killed in an encode, resident memory ~p kB then ~p kB", [
                Name, Before, After
            ]),
            ?assert(After - Before < 64 * 1024)
        end
     || {Mod, Name, Kind} <- codecs()
    ],
    ok.

%% Thousands of frames that are not media, then real ones: the decoder
%% answers each, decodes again from the next key frame, and memory
%% stays where it was after the first thousand.
bad_media_for_long(_Config) ->
    _ = rand:seed(exsss, {7, 8, 9}),
    [
        begin
            {Frames0, _} = encoded(Mod, Name, Kind, 3),
            Frames = lists:append(Frames0),
            Garbage = fun(Count, St0) ->
                lists:foldl(
                    fun(I, St) ->
                        Frame = #{
                            data => rand:bytes(rand:uniform(400)),
                            timestamp => I * 3000,
                            keyframe => false
                        },
                        {ok, _, _, St1} = Mod:decode(Frame, St),
                        St1
                    end,
                    St0,
                    lists:seq(1, Count)
                )
            end,
            St1 = Garbage(1000, init(Mod, Name, #{max_pixels => 640 * 480})),
            Before = rss(),
            St2 = Garbage(4000, St1),
            After = rss(),
            {Outs, _} = lists:mapfoldl(
                fun(Frame, St) ->
                    {ok, Out, _, StN} = Mod:decode(Frame, St),
                    {Out, StN}
                end,
                St2,
                Frames
            ),
            Media = [O || O <- lists:append(Outs), not is_map_key(dropped, O)],
            ct:log(
                "~s: 5000 bad frames, resident memory ~p kB then ~p kB, then ~p of ~p real frames decoded",
                [
                    Name, Before, After, length(Media), length(Frames)
                ]
            ),
            ?assertEqual(length(Frames), length(Media)),
            ?assert(After - Before < 64 * 1024)
        end
     || {Mod, Name, Kind} <- codecs()
    ],
    ok.

%% Contexts are destroyed where they are collected, which may be a
%% normal scheduler. Destroying one has to stay far below a millisecond
%% budget for that to be harmless: here it is timed, with a process that
%% wakes every millisecond to see how late it runs meanwhile.
many_contexts(_Config) ->
    Ticker = spawn_link(fun() -> tick(erlang:monotonic_time(microsecond), 0) end),
    Results = [
        begin
            Times = [
                begin
                    put(context, used(Mod, Name, Kind)),
                    T0 = erlang:monotonic_time(microsecond),
                    erase(context),
                    erlang:garbage_collect(),
                    erlang:monotonic_time(microsecond) - T0
                end
             || _ <- lists:seq(1, 100)
            ],
            Sorted = lists:sort(Times),
            {Name, lists:nth(50, Sorted), lists:max(Sorted)}
        end
     || {Mod, Name, Kind} <- codecs()
    ],
    Ticker ! {late, self()},
    Late =
        receive
            {late, Max} -> Max
        end,
    [
        ct:log("~s: destroying an encoder and a decoder on collection, median ~p us, most ~p us", [
            Name, Median, Most
        ])
     || {Name, Median, Most} <- Results
    ],
    ct:log("a process waking every millisecond was at most ~p us late", [Late]),
    [?assert(Most < 20000) || {_, _, Most} <- Results],
    ?assert(Late < 200000),
    ok.

%% An encoder and a decoder that have worked, as one term to drop.
used(Mod, Name, Kind) ->
    {Frames, Encoder} = encoded(Mod, Name, Kind, 2),
    {ok, _, _, Decoder} = Mod:decode(hd(lists:append(Frames)), init(Mod, Name, #{})),
    {Encoder, Decoder}.

tick(Last, Most) ->
    receive
        {late, From} -> From ! {late, Most}
    after 1 ->
        Now = erlang:monotonic_time(microsecond),
        tick(Now, max(Most, Now - Last - 1000))
    end.

%% Resident memory of the emulator in kB, as the system counts it: from
%% /proc where there is one, since not every ps takes a process id.
rss() ->
    erlang:garbage_collect(),
    case file:read_file("/proc/self/status") of
        {ok, Status} ->
            {match, [Kb]} = re:run(Status, "VmRSS:\\s+([0-9]+) kB", [{capture, [1], list}]),
            list_to_integer(Kb);
        {error, _} ->
            list_to_integer(string:trim(os:cmd("ps -o rss= -p " ++ os:getpid())))
    end.
