%% The camera and the microphone of this machine in a browser, and the
%% browser's microphone on this machine's speaker: capture, the codec
%% plugins and playback together, with HTTP as the signaling channel.
%% See docs/demo.md.
%%
%%   $ rebar3 shell
%%   1> c("examples/browser_media/browser_media").
%%   2> browser_media:start(8080).
%%   then open http://localhost:8080/ and press Start
%%
%% start/2 takes what to send:
%%
%%   browser_media:start(8080, #{video => {camera, 0}, audio => {microphone, 0}}).
%%   browser_media:start(8080, #{video => {test, video}, audio => {test, audio}}).
%%   browser_media:start(8080, #{audio => none}).
-module(browser_media).

-export([start/1, start/2, stop/0, do/1, session/2]).

-include_lib("inets/include/httpd.hrl").

-define(SESSION, browser_media_session).
-define(AUDIO, <<"0">>).
-define(VIDEO, <<"1">>).

start(Port) ->
    start(Port, #{}).

%% Serve the page and the signaling on localhost. Opts: `video` and
%% `audio`, each a source of webrtc_codecs_capture or `none`; `width`,
%% `height`, `frame_rate` of the pictures.
start(Port, Opts0) ->
    Opts = maps:merge(
        #{video => {camera, 0}, audio => {microphone, 0}, width => 640, height => 480, frame_rate => 30}, Opts0
    ),
    {ok, _} = application:ensure_all_started(inets),
    {ok, _} = application:ensure_all_started(webrtc),
    persistent_term:put(?MODULE, Opts),
    Dir = dir(),
    {ok, _} = inets:start(httpd, [
        {port, Port},
        {bind_address, {127, 0, 0, 1}},
        {server_name, "localhost"},
        {server_root, Dir},
        {document_root, Dir},
        {modules, [?MODULE]}
    ]),
    io:format("open http://localhost:~b/ and press Start~n", [Port]).

stop() ->
    stop_session(),
    [inets:stop(httpd, P) || {httpd, P} <- inets:services()],
    ok.

%% Where this file and the page are.
dir() ->
    filename:dirname(proplists:get_value(source, module_info(compile))).

%% httpd callback: the page, an offer from us, the answer of the page.
do(#mod{method = "GET", request_uri = "/"}) ->
    {ok, Page} = file:read_file(filename:join(dir(), "index.html")),
    reply("text/html", Page);
do(#mod{method = "GET", request_uri = "/offer"}) ->
    %% One browser at a time: a camera has one reader.
    stop_session(),
    Self = self(),
    Pid = spawn(fun() -> session(Self, persistent_term:get(?MODULE)) end),
    receive
        {offer, Pid, Offer} -> reply("application/sdp", Offer)
    after 10000 ->
        exit(Pid, kill),
        {proceed, [{response, {500, "no offer"}}]}
    end;
do(#mod{method = "POST", request_uri = "/answer", entity_body = Body}) ->
    case whereis(?SESSION) of
        undefined ->
            {proceed, [{response, {409, "no session"}}]};
        Pid ->
            Pid ! {answer, list_to_binary(Body)},
            reply("text/plain", <<"ok">>)
    end;
do(_) ->
    {proceed, [{response, {404, "not found"}}]}.

reply(Type, Body) ->
    Head = [{code, 200}, {content_type, Type}, {content_length, integer_to_list(byte_size(Body))}],
    {proceed, [{response, {response, Head, binary_to_list(Body)}}]}.

stop_session() ->
    case whereis(?SESSION) of
        undefined ->
            ok;
        Pid ->
            Ref = monitor(process, Pid),
            Pid ! stop,
            receive
                {'DOWN', Ref, process, Pid, _} -> ok
            after 10000 -> exit(Pid, kill)
            end
    end.

%% One process owns the peer connection, the captures and the speaker.
%% It offers an audio and a video transceiver that send and receive,
%% each with the plugin that picks the codec the browser answers with.
session(From, Opts) ->
    register(?SESSION, self()),
    Plugin = {webrtc_codecs, #{}},
    {ok, Pc} = webrtc:new_peer_connection(#{}),
    {ok, _} = webrtc:add_transceiver(Pc, audio, #{frames => true, codec_plugin => Plugin}),
    {ok, _} = webrtc:add_transceiver(Pc, video, #{frames => true, codec_plugin => Plugin}),
    {ok, Offer} = webrtc:create_offer(Pc, #{}),
    ok = webrtc:set_local_description(Pc, offer, Offer),
    receive
        {webrtc, Pc, {ice_gathering_state, complete}} -> ok
    after 5000 -> ok
    end,
    %% The local description now carries every candidate gathered.
    From ! {offer, self(), webrtc:local_description(Pc)},
    receive
        {answer, Answer} ->
            ok = webrtc:set_remote_description(Pc, answer, Answer),
            loop(#{pc => Pc, opts => Opts, captures => #{}, speaker => undefined, pictures => 0});
        stop ->
            webrtc:close(Pc)
    after 60000 ->
        webrtc:close(Pc)
    end.

loop(#{pc := Pc, captures := Captures} = St) ->
    receive
        {webrtc, Pc, {connection_state, connected}} ->
            io:format("connected~n"),
            loop(St#{captures := start_captures(St)});
        {webrtc, Pc, {connection_state, State}} when State =:= closed; State =:= failed ->
            io:format("connection ~s~n", [State]),
            finish(St);
        %% What we capture goes to the plugin of its transceiver.
        {webrtc_capture, Pid, #{format := _} = Raw} when is_map_key(Pid, Captures) ->
            _ = webrtc:send_media(Pc, maps:get(Pid, Captures), Raw),
            loop(St);
        {webrtc_capture, Pid, Ended} when is_map_key(Pid, Captures) ->
            io:format("capture on ~s ended: ~p~n", [maps:get(Pid, Captures), Ended]),
            loop(St#{captures := maps:remove(Pid, Captures)});
        %% The browser lost a frame, or the network changed.
        {webrtc, Pc, {keyframe_request, ?VIDEO}} ->
            _ = webrtc:send_media(Pc, ?VIDEO, #{keyframe => true}),
            loop(St);
        {webrtc, Pc, {bandwidth_estimate, Bps}} ->
            _ = webrtc:send_media(Pc, ?VIDEO, #{bitrate => max(100000, Bps - 40000)}),
            loop(St);
        %% What the browser sends, decoded: its microphone on our speaker.
        {webrtc, Pc, {decoded, ?AUDIO, #{format := s16le} = Audio}} ->
            loop(play(Audio, St));
        {webrtc, Pc, {codec_plugin_error, Mid, Reason}} ->
            io:format("codec plugin off on ~s: ~p~n", [Mid, Reason]),
            loop(St);
        {webrtc, Pc, _} ->
            loop(St);
        stop ->
            finish(St)
    end.

%% Capture starts once connected, so that nothing is encoded for nobody.
start_captures(#{opts := Opts}) ->
    #{video := Video, audio := Audio, width := W, height := H, frame_rate := Fps} = Opts,
    Started = [
        {start_capture(Video, #{width => W, height => H, frame_rate => Fps}), ?VIDEO},
        {start_capture(Audio, #{sample_rate => 48000, channels => 1, frame_ms => 20}), ?AUDIO}
    ],
    maps:from_list([{Pid, Mid} || {{ok, Pid}, Mid} <- Started]).

start_capture(none, _Opts) ->
    none;
start_capture(Source, Opts) ->
    process_flag(trap_exit, true),
    case webrtc_codecs_capture:start(Source, Opts) of
        {ok, Pid} ->
            io:format("capturing ~p~n", [Source]),
            {ok, Pid};
        {error, Reason} ->
            io:format("cannot capture ~p: ~p~n", [Source, Reason]),
            none
    end.

%% The speaker is started for the format of the first audio decoded.
play(Audio, #{speaker := undefined} = St) ->
    #{sample_rate := Rate, channels := Channels} = Audio,
    case webrtc_codecs_playback:start(speaker, #{sample_rate => Rate, channels => Channels}) of
        {ok, Speaker} ->
            io:format("playing the browser's microphone~n"),
            play(Audio, St#{speaker := Speaker});
        {error, Reason} ->
            io:format("no speaker: ~p~n", [Reason]),
            St#{speaker := none}
    end;
play(_Audio, #{speaker := none} = St) ->
    St;
play(Audio, #{speaker := Speaker} = St) ->
    _ = webrtc_codecs_playback:play(Speaker, Audio),
    St.

finish(#{pc := Pc, captures := Captures, speaker := Speaker}) ->
    [webrtc_codecs_capture:stop(Pid) || Pid <- maps:keys(Captures)],
    _ = is_pid(Speaker) andalso webrtc_codecs_playback:stop(Speaker),
    webrtc:close(Pc).
