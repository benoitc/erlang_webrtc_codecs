%% The plugins against a browser: headless Chromium, driven by the peer
%% adapter of erlang_webrtc's interop suite (interop/browser/peer.js,
%% newline-delimited JSON on its standard input and output).
%%
%% Chromium sends its fake camera and the plugin decodes it; the plugin
%% encodes the test pattern and Chromium decodes it.
%%
%% The adapter and Playwright are not part of this package: the suite
%% looks for them in $WEBRTC_CODECS_BROWSER_PEER, then in
%% ../erlang_webrtc/interop/browser, and skips with the reason when
%% they are not there.
-module(webrtc_codecs_browser_SUITE).
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([vp8/1, vp9/1, av1/1]).

-define(MID, <<"0">>).

all() -> [vp8, vp9, av1].

init_per_suite(Config) ->
    case adapter() of
        {ok, Command} ->
            {ok, _} = application:ensure_all_started(webrtc),
            [{adapter, Command} | Config];
        {skip, Reason} ->
            {skip, Reason}
    end.

end_per_suite(_Config) ->
    ok.

adapter() ->
    Dirs =
        [D || D <- [os:getenv("WEBRTC_CODECS_BROWSER_PEER")], D =/= false] ++
            [filename:join([root(), "..", "erlang_webrtc", "interop", "browser"])],
    Found = [
        D
     || D <- Dirs,
        filelib:is_regular(filename:join(D, "peer.js")),
        filelib:is_dir(filename:join([D, "node_modules", "playwright"]))
    ],
    case {os:find_executable("node"), Found} of
        {false, _} ->
            {skip, "node is not installed"};
        {_, []} ->
            {skip,
                "no browser peer: run npm ci in erlang_webrtc/interop/browser and set WEBRTC_CODECS_BROWSER_PEER to it"};
        {Node, [Dir | _]} ->
            {ok, {Node, [filename:join(Dir, "peer.js"), "chromium"]}}
    end.

%% The directory of this package, from wherever the suite runs.
root() ->
    {ok, Cwd} = file:get_cwd(),
    up(Cwd).

up("/") ->
    "/";
up(Dir) ->
    case
        filelib:is_dir(filename:join(Dir, "c_src")) andalso
            filelib:is_regular(filename:join(Dir, "rebar.config"))
    of
        true -> Dir;
        false -> up(filename:dirname(Dir))
    end.

vp8(Config) -> both_ways(Config, <<"VP8">>, webrtc_codecs_vpx_nif:loaded()).

vp9(Config) -> both_ways(Config, <<"VP9">>, webrtc_codecs_vpx_nif:loaded()).

av1(Config) ->
    both_ways(
        Config, <<"AV1">>, webrtc_codecs_dav1d_nif:loaded() andalso webrtc_codecs_aom_nif:loaded()
    ).

both_ways(_Config, Codec, false) ->
    {skip, "built without the library of " ++ binary_to_list(Codec)};
both_ways(Config, Codec, true) ->
    Port = start(proplists:get_value(adapter, Config)),
    %% We offer this codec alone, with its retransmission format, and a
    %% transceiver that sends as well as receives.
    Plugin = {webrtc_codecs, #{bitrate => 500000}},
    Video = webrtc_jsep_caps:default_codecs(video),
    [#{pt := Pt} = Wanted] = [C || #{name := N} = C <- Video, N =:= Codec],
    Rtx = [
        C
     || #{name := <<"rtx">>, fmtp := [{<<"apt">>, A}]} = C <- Video, A =:= integer_to_binary(Pt)
    ],
    {ok, Pc} = webrtc:new_peer_connection(#{codecs => #{video => [Wanted | Rtx]}}),
    try
        {ok, _} = webrtc:add_transceiver(Pc, video, #{frames => true, codec_plugin => Plugin}),
        command(Port, #{cmd => init, media => [<<"video">>], codec => Codec}),
        case event(Port, <<"codec">>, 20000) of
            #{<<"supported">> := true} -> exchange(Port, Pc, Codec);
            _ -> {skip, "the browser does not send " ++ binary_to_list(Codec)}
        end
    after
        webrtc:close(Pc),
        stop(Port)
    end.

exchange(Port, Pc, Codec) ->
    %% We offer, the browser answers with its camera, and both connect.
    {ok, Offer} = webrtc:create_offer(Pc, #{}),
    ok = webrtc:set_local_description(Pc, offer, Offer),
    command(Port, #{cmd => remote_description, type => offer, sdp => Offer}),
    #{<<"sdp">> := Answer} = event(Port, <<"local_description">>, 20000),
    ok = webrtc:set_remote_description(Pc, answer, Answer),
    ok = connect(Port, Pc, erlang:monotonic_time(millisecond) + 20000),

    %% Three seconds: we send a picture of the pattern every 33 ms and
    %% decode what the browser sends.
    Pictures = run(Port, Pc, 0, [], erlang:monotonic_time(millisecond) + 3000),
    ct:log("~s: ~b pictures decoded from the browser, first ~p", [
        Codec, length(Pictures), [maps:with([width, height], P) || P <- lists:sublist(Pictures, 1)]
    ]),
    ?assert(length(Pictures) >= 20),
    [
        ?assertMatch(
            #{format := i420, width := W, height := H, y := Y} when byte_size(Y) =:= W * H, P
        )
     || P <- Pictures
    ],
    %% A camera picture is not one flat colour.
    #{y := Luma} = lists:last(Pictures),
    ?assert(lists:max(binary_to_list(Luma)) - lists:min(binary_to_list(Luma)) > 16),

    [In] = [
        O
     || _ := #{type := <<"inbound-rtp">>, kind := <<"video">>} = O <- webrtc:get_stats(Pc, #{
            format => w3c
        })
    ],
    [Out] = [
        O
     || _ := #{type := <<"outbound-rtp">>, kind := <<"video">>} = O <- webrtc:get_stats(Pc, #{
            format => w3c
        })
    ],
    ?assert(maps:get(framesDecoded, In) >= 20),
    ?assert(maps:get(keyFramesDecoded, In) >= 1),
    ?assertMatch(#{decoderImplementation := <<_/binary>>}, In),
    ?assert(maps:get(framesEncoded, Out) >= 60),
    ?assertMatch(#{encoderImplementation := <<_/binary>>}, Out),

    %% And the browser decoded what we encoded.
    command(Port, #{cmd => stats}),
    #{<<"stats">> := Stats} = event(Port, <<"stats">>, 20000),
    [Theirs] = [
        S
     || _ := #{<<"type">> := <<"inbound-rtp">>, <<"kind">> := <<"video">>} = S <- Stats
    ],
    ct:log("~s: the browser decoded ~p frames of ~p encoded, ~p key", [
        Codec,
        maps:get(<<"framesDecoded">>, Theirs, 0),
        maps:get(framesEncoded, Out),
        maps:get(<<"keyFramesDecoded">>, Theirs, 0)
    ]),
    ?assert(maps:get(<<"framesDecoded">>, Theirs, 0) >= 30),
    ?assertEqual(320, maps:get(<<"frameWidth">>, Theirs)),
    ?assertEqual(240, maps:get(<<"frameHeight">>, Theirs)),
    ok.

%% Send the pattern and keep what is decoded, until the deadline. A key
%% frame request from the browser goes in the next picture.
run(Port, Pc, N, Pictures, Deadline) ->
    Now = erlang:monotonic_time(millisecond),
    case Now >= Deadline of
        true ->
            lists:reverse(Pictures);
        false ->
            Picture = webrtc_codecs_pattern:picture(320, 240, N),
            ok = webrtc:send_media(Pc, ?MID, Picture),
            run_until(Port, Pc, N + 1, Pictures, Deadline, Now + 33)
    end.

run_until(Port, Pc, N, Pictures, Deadline, Next) ->
    receive
        {webrtc, Pc, {decoded, ?MID, #{format := i420} = Picture}} ->
            run_until(Port, Pc, N, [Picture | Pictures], Deadline, Next);
        {webrtc, Pc, {keyframe_request, ?MID}} ->
            ok = webrtc:send_media(Pc, ?MID, #{keyframe => true}),
            run_until(Port, Pc, N, Pictures, Deadline, Next);
        {webrtc, Pc, {codec_plugin_error, _, Reason}} ->
            error({codec_plugin_error, Reason});
        {webrtc, Pc, _} ->
            run_until(Port, Pc, N, Pictures, Deadline, Next);
        {Port, {data, _}} ->
            run_until(Port, Pc, N, Pictures, Deadline, Next)
    after max(0, Next - erlang:monotonic_time(millisecond)) ->
        run(Port, Pc, N, Pictures, Deadline)
    end.

%% Trickle candidates both ways until we are connected.
connect(Port, Pc, Deadline) ->
    receive
        {webrtc, Pc, {ice_candidate, end_of_candidates, Mid}} ->
            command(Port, #{cmd => remote_candidate, candidate => <<>>, mid => Mid}),
            connect(Port, Pc, Deadline);
        {webrtc, Pc, {ice_candidate, Candidate, Mid}} ->
            command(Port, #{cmd => remote_candidate, candidate => Candidate, mid => Mid}),
            connect(Port, Pc, Deadline);
        {webrtc, Pc, {connection_state, connected}} ->
            ok;
        {webrtc, Pc, {connection_state, failed}} ->
            {error, failed};
        {webrtc, Pc, _} ->
            connect(Port, Pc, Deadline);
        {Port, {data, {eol, Line}}} ->
            case json:decode(Line) of
                #{<<"event">> := <<"local_candidate">>, <<"candidate">> := <<>>} = Event ->
                    ok = webrtc:add_ice_candidate(
                        Pc, end_of_candidates, maps:get(<<"mid">>, Event, undefined)
                    );
                #{<<"event">> := <<"local_candidate">>, <<"candidate">> := C} = Event ->
                    ok = webrtc:add_ice_candidate(Pc, C, maps:get(<<"mid">>, Event, undefined));
                #{<<"event">> := <<"error">>} = Error ->
                    error({browser, Error});
                _ ->
                    ok
            end,
            connect(Port, Pc, Deadline);
        {Port, {exit_status, Status}} ->
            {error, {browser_exited, Status}}
    after max(0, Deadline - erlang:monotonic_time(millisecond)) ->
        {error, timeout}
    end.

%% The adapter

start({Node, Args}) ->
    Port = open_port({spawn_executable, Node}, [
        {args, Args}, binary, {line, 1 bsl 22}, exit_status, use_stdio
    ]),
    #{} = event(Port, <<"ready">>, 60000),
    Port.

command(Port, Map) ->
    true = port_command(Port, [json:encode(Map), $\n]),
    ok.

%% The next event of this name; an error event or the end of the
%% browser fails the test.
event(Port, Name, Timeout) ->
    event(Port, Name, erlang:monotonic_time(millisecond) + Timeout, <<>>).

event(Port, Name, Deadline, Partial) ->
    receive
        {Port, {data, {noeol, Part}}} ->
            event(Port, Name, Deadline, <<Partial/binary, Part/binary>>);
        {Port, {data, {eol, Line}}} ->
            case json:decode(<<Partial/binary, Line/binary>>) of
                #{<<"event">> := Name} = Event -> Event;
                #{<<"event">> := <<"error">>} = Error -> error({browser, Error});
                _ -> event(Port, Name, Deadline, <<>>)
            end;
        {Port, {exit_status, Status}} ->
            error({browser_exited, Status})
    after max(0, Deadline - erlang:monotonic_time(millisecond)) ->
        error({timeout, Name})
    end.

stop(Port) ->
    try
        command(Port, #{cmd => close}),
        receive
            {Port, {exit_status, _}} -> ok
        after 3000 ->
            port_close(Port)
        end
    catch
        error:badarg -> ok
    end,
    flush(Port).

flush(Port) ->
    receive
        {Port, _} -> flush(Port);
        {webrtc, _, _} -> flush(Port)
    after 0 -> ok
    end.
