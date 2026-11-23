%% A plugin for the tests of webrtc_codecs_async: it takes its time and
%% fails on demand. Options: `delay`, milliseconds each decode and encode
%% takes; `notify`, a process told of control events and of the end;
%% `refuse`, makes init/3 fail.
%%
%% decode/2 gives the data of the frame as its output. Data that says so
%% makes it return an error with its state (`<<"bad">>`), without it
%% (`<<"fatal">>`), raise (`<<"raise">>`) or ask for a key frame
%% (`<<"feedback">>`). encode/2 takes `#{format => raw, data => Data}`
%% the same way, and a map without `format` as a control map.
-module(webrtc_codecs_slow_plugin).
-behaviour(webrtc_media_codec).

-export([init/3, decode/2, encode/2, info/1, control/2, terminate/1]).

init(_Kind, _Codec, #{refuse := Reason}) ->
    {error, Reason};
init(Kind, _Codec, Opts) ->
    {ok, #{kind => Kind, delay => maps:get(delay, Opts, 0), notify => maps:get(notify, Opts, none)}}.

decode(#{data := Data, timestamp := Ts}, #{delay := Delay} = St) ->
    timer:sleep(Delay),
    case Data of
        <<"bad">> -> {error, bad, St};
        <<"fatal">> -> {error, fatal};
        <<"raise">> -> error(raised);
        <<"feedback">> -> {ok, [], #{framesDropped => 1}, St, [keyframe_request]};
        _ -> {ok, [#{decoded => Data, timestamp => Ts}], #{framesDecoded => 1}, St}
    end.

encode(#{format := raw, data := Data} = Raw, #{delay := Delay} = St) ->
    timer:sleep(Delay),
    case Data of
        <<"bad">> ->
            {error, bad, St};
        <<"fatal">> ->
            {error, fatal};
        <<"raise">> ->
            error(raised);
        _ ->
            Frame = #{data => Data, timestamp => maps:get(timestamp, Raw, 0), keyframe => true},
            {ok, [Frame], #{framesEncoded => 1}, St}
    end;
encode(#{} = Control, #{delay := Delay} = St) ->
    timer:sleep(Delay),
    tell({control_map, Control}, St),
    {ok, [], #{}, St}.

info(_St) ->
    #{implementation => <<"slow">>, power_efficient => false}.

control(Event, St) ->
    tell({control, Event}, St),
    {ok, St}.

terminate(St) ->
    tell(terminated, St),
    ok.

tell(_What, #{notify := none}) -> ok;
tell(What, #{notify := Pid}) -> Pid ! {slow_plugin, What}.
