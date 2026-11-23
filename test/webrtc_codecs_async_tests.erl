%% webrtc_codecs_async with a plugin that takes its time: this process
%% stands in for the transport process of erlang_webrtc, calls the
%% callbacks and receives what the worker delivers.
-module(webrtc_codecs_async_tests).
-include_lib("eunit/include/eunit.hrl").

-define(M, webrtc_codecs_async).
-define(SLOW, webrtc_codecs_slow_plugin).

init(Kind, Dir, Opts) ->
    Ref = make_ref(),
    Handle = webrtc_media_codec:handle(self(), Dir, key, Ref),
    {ok, St} = ?M:init(Kind, #{name => <<"slow">>}, Opts#{plugin => ?SLOW}, Handle),
    {St, Ref}.

frame(Data, N) -> frame(Data, N, false).

frame(Data, N, Key) -> #{data => Data, timestamp => N * 3000, keyframe => Key}.

raw(Data, N) -> #{format => raw, data => Data, timestamp => N * 3000}.

%% What the worker delivers next for this instance, as the transport
%% process gets it.
delivery(Ref) -> delivery(Ref, 5000).

delivery(Ref, Timeout) ->
    receive
        {'$gen_cast', {codec_delivery, _Dir, key, Ref, Message}} -> Message
    after Timeout -> none
    end.

worker(St) -> element(3, St).

%% Wait for a process to end.
gone(Pid) ->
    Monitor = monitor(process, Pid),
    receive
        {'DOWN', Monitor, process, Pid, _Reason} -> ok
    after 5000 -> error(still_alive)
    end.

%% The callbacks return at once while the codec takes its time, and the
%% results come in order with their statistics and the name of what
%% made them.
does_not_wait_test_() ->
    {timeout, 30, fun() ->
        {Dec0, DecRef} = init(video, in, #{delay => 50}),
        T0 = erlang:monotonic_time(millisecond),
        Dec = lists:foldl(
            fun(N, St) ->
                {ok, [], #{}, St1} = ?M:decode(frame(<<N>>, N, N =:= 0), St),
                St1
            end,
            Dec0,
            [0, 1, 2]
        ),
        ?assert(erlang:monotonic_time(millisecond) - T0 < 20),
        [
            ?assertEqual(
                {decoded, [#{decoded => <<N>>, timestamp => N * 3000}], #{
                    framesDecoded => 1,
                    decoderImplementation => <<"slow">>,
                    powerEfficientDecoder => false
                }},
                delivery(DecRef)
            )
         || N <- [0, 1, 2]
        ],
        ?assert(erlang:monotonic_time(millisecond) - T0 >= 150),
        ?assertEqual(#{}, ?M:info(Dec)),
        {Enc0, EncRef} = init(video, out, #{delay => 50}),
        T1 = erlang:monotonic_time(millisecond),
        {ok, [], #{}, Enc} = ?M:encode(raw(<<"a">>, 0), Enc0),
        {ok, [], #{}, _} = ?M:encode(raw(<<"b">>, 1), Enc),
        ?assert(erlang:monotonic_time(millisecond) - T1 < 20),
        [
            ?assertEqual(
                {encoded, [#{data => Data, timestamp => N * 3000, keyframe => true}], #{
                    framesEncoded => 1,
                    encoderImplementation => <<"slow">>,
                    powerEfficientEncoder => false
                }},
                delivery(EncRef)
            )
         || {N, Data} <- [{0, <<"a">>}, {1, <<"b">>}]
        ]
    end}.

%% A video decoder that is behind drops what it has no room for, asks
%% for a key frame once, and drops frames until that key frame.
video_decoder_behind_test_() ->
    {timeout, 30, fun() ->
        {St0, Ref} = init(video, in, #{delay => 100, max_in_flight => 2}),
        {ok, [], #{}, St1} = ?M:decode(frame(<<0>>, 0, true), St0),
        {ok, [], #{}, St2} = ?M:decode(frame(<<1>>, 1), St1),
        {ok, [#{dropped := busy, timestamp := 6000}], #{framesDropped := 1}, St3, [
            keyframe_request
        ]} = ?M:decode(frame(<<2>>, 2), St2),
        %% Room comes back, but the frames after a dropped one have no
        %% reference: they wait for a key frame, without asking again.
        ?assertMatch({decoded, [#{decoded := <<0>>}], _}, delivery(Ref)),
        ?assertMatch({decoded, [#{decoded := <<1>>}], _}, delivery(Ref)),
        {ok, [#{dropped := waiting_for_keyframe}], #{framesDropped := 1}, St4} =
            ?M:decode(frame(<<3>>, 3), St3),
        {ok, [], #{}, St5} = ?M:decode(frame(<<4>>, 4, true), St4),
        {ok, [], #{}, _} = ?M:decode(frame(<<5>>, 5), St5),
        ?assertMatch({decoded, [#{decoded := <<4>>}], _}, delivery(Ref)),
        ?assertMatch({decoded, [#{decoded := <<5>>}], _}, delivery(Ref))
    end}.

%% A flood of frames leaves the worker with max_in_flight of them at
%% most, and asks for a key frame once in thirty drops.
flood_test_() ->
    {timeout, 30, fun() ->
        {St0, _Ref} = init(video, in, #{delay => 200, max_in_flight => 3}),
        {Results, St} = lists:mapfoldl(
            fun(N, StA) ->
                case ?M:decode(frame(<<N:32>>, N, true), StA) of
                    {ok, [], #{}, StB} -> {handed, StB};
                    {ok, [#{dropped := busy}], _, StB, [keyframe_request]} -> {asked, StB};
                    {ok, [#{dropped := busy}], _, StB} -> {dropped, StB}
                end
            end,
            St0,
            lists:seq(1, 1000)
        ),
        ?assertEqual(3, length([R || R <- Results, R =:= handed])),
        ?assertEqual(34, length([R || R <- Results, R =:= asked])),
        {message_queue_len, Queue} = process_info(worker(St), message_queue_len),
        ?assert(Queue =< 3)
    end}.

%% An audio decoder that is behind drops the frame and nothing more.
audio_decoder_behind_test_() ->
    {timeout, 30, fun() ->
        {St0, Ref} = init(audio, in, #{delay => 100, max_in_flight => 1}),
        {ok, [], #{}, St1} = ?M:decode(frame(<<0>>, 0), St0),
        {ok, [#{dropped := busy, timestamp := 3000}], Stats, St2} = ?M:decode(frame(<<1>>, 1), St1),
        ?assertEqual(#{}, Stats),
        ?assertMatch({decoded, [#{decoded := <<0>>}], _}, delivery(Ref)),
        {ok, [], #{}, _} = ?M:decode(frame(<<2>>, 2), St2),
        ?assertMatch({decoded, [#{decoded := <<2>>}], _}, delivery(Ref))
    end}.

%% An encoder that is behind refuses the picture, with its state, and
%% still takes a map that only changes it.
encoder_behind_test_() ->
    {timeout, 30, fun() ->
        {St0, Ref} = init(video, out, #{delay => 100, max_in_flight => 1, notify => self()}),
        {ok, [], #{}, St1} = ?M:encode(raw(<<"a">>, 0), St0),
        ?assertEqual({error, busy, St1}, ?M:encode(raw(<<"b">>, 1), St1)),
        ?assertEqual({ok, [], #{}, St1}, ?M:encode(#{bitrate => 100000}, St1)),
        ?assertMatch({encoded, [#{data := <<"a">>}], _}, delivery(Ref)),
        receive
            {slow_plugin, {control_map, #{bitrate := 100000}}} -> ok
        after 5000 -> error(no_control_map)
        end,
        %% Even those have a bound.
        Flood = [?M:encode(#{bitrate => N}, St1) || N <- lists:seq(1, 100)],
        ?assert(lists:member({error, busy, St1}, Flood)),
        {message_queue_len, Queue} = process_info(worker(St1), message_queue_len),
        ?assert(Queue =< 4)
    end}.

%% What erlang_webrtc tells the encoder reaches the plugin, in order
%% with the media, and the end of the stream too.
control_and_terminate_test_() ->
    {timeout, 30, fun() ->
        {St0, Ref} = init(video, out, #{delay => 20, notify => self()}),
        {ok, [], #{}, St1} = ?M:encode(raw(<<"a">>, 0), St0),
        {ok, St2} = ?M:control(keyframe_request, St1),
        {ok, St3} = ?M:control({target_bitrate, 250000}, St2),
        ?assertMatch({encoded, [#{data := <<"a">>}], _}, delivery(Ref)),
        ?assertEqual(
            [keyframe_request, {target_bitrate, 250000}],
            [
                receive
                    {slow_plugin, {control, Event}} -> Event
                after 5000 -> error(no_control)
                end
             || _ <- [1, 2]
            ]
        ),
        T0 = erlang:monotonic_time(millisecond),
        {ok, [], #{}, St4} = ?M:encode(raw(<<"b">>, 1), St3),
        ?assertEqual(ok, ?M:terminate(St4)),
        ?assert(erlang:monotonic_time(millisecond) - T0 < 10),
        receive
            {slow_plugin, terminated} -> ok
        after 5000 -> error(not_terminated)
        end,
        ?assertEqual(ok, gone(worker(St4))),
        ?assertEqual({error, worker_down}, ?M:encode(raw(<<"c">>, 2), St4)),
        ?assertEqual({error, worker_down}, ?M:decode(frame(<<"c">>, 2), St4))
    end}.

%% An error that comes with the state loses one frame; what would turn
%% a plugin off ends the worker, and the next call says so.
errors_test_() ->
    {timeout, 30, fun() ->
        {Dec0, DecRef} = init(video, in, #{}),
        {ok, [], #{}, Dec1} = ?M:decode(frame(<<"bad">>, 0, true), Dec0),
        ?assertEqual(
            {decoded, [#{dropped => bad, timestamp => 0}], #{
                framesDropped => 1,
                decoderImplementation => <<"slow">>,
                powerEfficientDecoder => false
            }},
            delivery(DecRef)
        ),
        {ok, [], #{}, Dec2} = ?M:decode(frame(<<"feedback">>, 1), Dec1),
        ?assertMatch({decoded, [], #{framesDropped := 1}}, delivery(DecRef)),
        ?assertEqual({decoder_feedback, [keyframe_request]}, delivery(DecRef)),
        {ok, [], #{}, Dec3} = ?M:decode(frame(<<"ok">>, 2), Dec2),
        ?assertMatch({decoded, [#{decoded := <<"ok">>}], _}, delivery(DecRef)),
        {Enc0, EncRef} = init(video, out, #{}),
        {ok, [], #{}, Enc1} = ?M:encode(raw(<<"bad">>, 0), Enc0),
        {ok, [], #{}, Enc2} = ?M:encode(raw(<<"ok">>, 1), Enc1),
        ?assertMatch({encoded, [#{data := <<"ok">>}], _}, delivery(EncRef)),
        [
            begin
                {St, Ref} = init(video, Dir, #{}),
                {ok, [], #{}, St1} = Call(St),
                ?assertEqual(ok, gone(worker(St1))),
                ?assertEqual(none, delivery(Ref, 50)),
                ?assertEqual({error, worker_down}, Call(St1))
            end
         || {Dir, Call} <- [
                {in, fun(St) -> ?M:decode(frame(<<"fatal">>, 0, true), St) end},
                {in, fun(St) -> ?M:decode(frame(<<"raise">>, 0, true), St) end},
                {out, fun(St) -> ?M:encode(raw(<<"fatal">>, 0), St) end},
                {out, fun(St) -> ?M:encode(raw(<<"raise">>, 0), St) end}
            ]
        ],
        ok = ?M:terminate(Dec3),
        ok = ?M:terminate(Enc2)
    end}.

%% The worker ends with the process that started it, and tells its
%% plugin.
ends_with_transport_test_() ->
    {timeout, 30, fun() ->
        Self = self(),
        Transport = spawn(fun() ->
            Handle = webrtc_media_codec:handle(self(), in, key, make_ref()),
            {ok, St} = ?M:init(video, #{}, #{plugin => ?SLOW, notify => Self}, Handle),
            Self ! {worker, worker(St)},
            receive
                stop -> ok
            end
        end),
        Worker =
            receive
                {worker, Pid} -> Pid
            after 5000 -> error(no_worker)
            end,
        ?assert(is_process_alive(Worker)),
        Transport ! stop,
        receive
            {slow_plugin, terminated} -> ok
        after 5000 -> error(not_terminated)
        end,
        ?assertEqual(ok, gone(Worker))
    end}.

%% What the plugin refuses fails at the start, in the caller.
bad_options_test() ->
    Handle = webrtc_media_codec:handle(self(), in, key, make_ref()),
    Init = fun(Opts) -> ?M:init(video, #{name => <<"slow">>}, Opts, Handle) end,
    ?assertEqual({error, no}, Init(#{plugin => ?SLOW, refuse => no})),
    ?assertEqual({error, {badarg, #{plugin => no_such_module}}}, Init(#{plugin => no_such_module})),
    ?assertMatch(
        {error, {badarg, #{max_in_flight := 0}}}, Init(#{plugin => ?SLOW, max_in_flight => 0})
    ),
    ?assertEqual({error, {badarg, opts}}, ?M:init(video, #{}, opts, Handle)),
    %% The default plugin is the dispatcher of this package.
    ?assertEqual(
        {error, {unsupported_codec, <<"speex">>}},
        ?M:init(audio, #{name => <<"speex">>}, #{}, Handle)
    ).
