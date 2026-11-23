-module(webrtc_codecs_async).
-moduledoc """
A codec plugin that runs the codec outside the transport process.

```erlang
webrtc:add_transceiver(Pc, video, #{frames => true, codec_plugin => {webrtc_codecs_async, #{}}}).
```

The plugins of this package run their codec inside the transport process
of the peer connection, so every packet of the connection waits while a
picture is encoded or decoded. This one hands each frame and each raw
picture or chunk of audio to a process of its own, which runs the plugin
you name and delivers the result to erlang_webrtc when it is ready. What
you send and receive is the same as with `webrtc_codecs`.

The process works on one thing at a time and holds a bounded number of
them. When it is behind:

- a video frame to decode is dropped (`#{dropped => busy}`), the sender is
  asked for a key frame, and frames are dropped until that key frame;
- an audio frame to decode is dropped;
- raw media to encode is refused: `webrtc:send_media/3` returns
  `{error, {encode, busy}}` and nothing is sent for it.

Options:

- `plugin`: the plugin module to run, default `webrtc_codecs`
- `max_in_flight`: frames or raw media the process may have waiting,
  default 4 for video and 16 for audio
- every other option goes to the plugin it runs
""".
-behaviour(webrtc_media_codec).

-export([init/4, decode/2, encode/2, info/1, control/2, terminate/1]).

%% Frames dropped between two key frame requests while the decoder waits
%% for a key frame: about a second of video.
-define(REQUEST_EVERY, 30).
%% Control maps and events are small and rare: they are let in past
%% max_in_flight, up to this many times it, so that the mailbox of the
%% worker has a bound whatever the application does.
-define(CONTROL_FACTOR, 4).

-record(st, {
    kind :: audio | video,
    worker :: pid(),
    %% What the worker has waiting or in hand; both processes count in it.
    room :: counters:counters_ref(),
    max :: pos_integer(),
    %% Video frames dropped since the last one handed to the worker; not
    %% zero means frames are dropped until a key frame.
    drops = 0 :: non_neg_integer()
}).

%% The worker.
-record(w, {
    plugin :: module(),
    inner :: term(),
    handle :: webrtc_media_codec:handle(),
    room :: counters:counters_ref(),
    kind :: audio | video,
    %% An encode error was logged and none succeeded since.
    failing = false :: boolean()
}).

-doc false.
init(Kind, Codec, Opts, Handle) when is_map(Opts) ->
    Plugin = maps:get(plugin, Opts, webrtc_codecs),
    Max = maps:get(max_in_flight, Opts, default_max(Kind)),
    Valid =
        is_atom(Plugin) andalso is_integer(Max) andalso Max > 0 andalso
            code:ensure_loaded(Plugin) =:= {module, Plugin},
    case Valid of
        true ->
            start(Kind, Codec, Plugin, Max, maps:without([plugin, max_in_flight], Opts), Handle);
        false ->
            {error, {badarg, maps:with([plugin, max_in_flight], Opts)}}
    end;
init(_Kind, _Codec, Opts, _Handle) ->
    {error, {badarg, Opts}}.

default_max(video) -> 4;
default_max(audio) -> 16.

%% The plugin starts here: a codec or an option it refuses fails now. It
%% creates no codec before its first frame, so nothing native is made in
%% this process.
start(Kind, Codec, Plugin, Max, Opts, Handle) ->
    case Plugin:init(Kind, Codec, Opts) of
        {ok, Inner} ->
            Room = counters:new(1, [atomics]),
            Transport = self(),
            W = #w{plugin = Plugin, inner = Inner, handle = Handle, room = Room, kind = Kind},
            Worker = spawn(fun() -> worker(Transport, W) end),
            {ok, #st{kind = Kind, worker = Worker, room = Room, max = Max}};
        {error, _} = Error ->
            Error
    end.

-doc false.
decode(#{timestamp := Ts} = Frame, #st{kind = Kind, drops = Drops} = St) ->
    Key = maps:get(keyframe, Frame, false),
    case alive(St) of
        false ->
            {error, worker_down};
        true when Kind =:= video, Drops > 0, not Key ->
            dropped(waiting_for_keyframe, Ts, St);
        true ->
            case hand(decode, Frame, St#st.max, St) of
                true -> {ok, [], #{}, St#st{drops = 0}};
                false -> dropped(busy, Ts, St)
            end
    end.

%% The worker is behind. A video frame that is not decoded leaves the
%% ones after it without their reference: they wait for a key frame,
%% asked for now and then once in a while.
dropped(Reason, Ts, #st{kind = audio} = St) ->
    {ok, [#{dropped => Reason, timestamp => Ts}], #{}, St};
dropped(Reason, Ts, #st{kind = video, drops = Drops} = St0) ->
    St = St0#st{drops = Drops + 1},
    Outs = [#{dropped => Reason, timestamp => Ts}],
    case Drops rem ?REQUEST_EVERY of
        0 -> {ok, Outs, #{framesDropped => 1}, St, [keyframe_request]};
        _ -> {ok, Outs, #{framesDropped => 1}, St}
    end.

-doc false.
encode(Raw, #st{max = Max} = St) ->
    %% A map that only changes the encoder is let in when a picture or
    %% audio would not be.
    Limit =
        case is_map(Raw) andalso not is_map_key(format, Raw) of
            true -> Max * ?CONTROL_FACTOR;
            false -> Max
        end,
    case alive(St) of
        false ->
            {error, worker_down};
        true ->
            case hand(encode, Raw, Limit, St) of
                true -> {ok, [], #{}, St};
                false -> {error, busy, St}
            end
    end.

%% The worker tells its implementation with the statistics it delivers.
-doc false.
info(_St) ->
    #{}.

-doc false.
control(Event, #st{max = Max} = St) ->
    _ = hand(control, Event, Max * ?CONTROL_FACTOR, St),
    {ok, St}.

%% Returns at once: the worker closes its codecs and ends by itself.
-doc false.
terminate(#st{worker = Worker}) ->
    Worker ! terminate,
    ok.

alive(#st{worker = Worker}) ->
    is_process_alive(Worker).

%% Give the worker something to do if it has fewer than Limit waiting.
hand(What, Term, Limit, #st{worker = Worker, room = Room}) ->
    case counters:get(Room, 1) < Limit of
        true ->
            counters:add(Room, 1, 1),
            Worker ! {What, Term},
            true;
        false ->
            false
    end.

%% The worker: one frame, picture or event at a time, in the order they
%% came. It ends with the transport process.

worker(Transport, W) ->
    Monitor = monitor(process, Transport),
    loop(Monitor, W).

loop(Monitor, #w{room = Room} = W) ->
    receive
        {What, Term} when What =:= decode; What =:= encode; What =:= control ->
            Next = run(What, Term, W),
            counters:sub(Room, 1, 1),
            loop(Monitor, Next);
        terminate ->
            stop(W);
        {'DOWN', Monitor, process, _, _} ->
            stop(W);
        _Other ->
            loop(Monitor, W)
    end.

-spec stop(#w{}) -> no_return().
stop(#w{plugin = Plugin, inner = Inner}) ->
    _ = erlang:function_exported(Plugin, terminate, 1) andalso Plugin:terminate(Inner),
    exit(normal).

%% An error the plugin returns without its state, or a raise, is what
%% would turn it off in the transport process: the worker ends, and the
%% next call there says so.
run(What, Term, #w{plugin = Plugin, inner = Inner} = W) ->
    try call(What, Term, Plugin, Inner) of
        Result -> done(What, Term, Result, W)
    catch
        Class:Reason:Stack ->
            fatal(What, {Class, Reason, Stack}, W)
    end.

call(decode, Frame, Plugin, Inner) ->
    Plugin:decode(Frame, Inner);
call(encode, Raw, Plugin, Inner) ->
    Plugin:encode(Raw, Inner);
call(control, Event, Plugin, Inner) ->
    case erlang:function_exported(Plugin, control, 2) of
        true -> Plugin:control(Event, Inner);
        false -> {ok, Inner}
    end.

done(decode, _Frame, {ok, Outs, Stats, Inner}, W) ->
    deliver(decoder, Outs, Stats, W#w{inner = Inner});
done(decode, _Frame, {ok, Outs, Stats, Inner, Feedback}, #w{handle = Handle} = W0) ->
    W = deliver(decoder, Outs, Stats, W0#w{inner = Inner}),
    ok = webrtc_media_codec:decoder_feedback(Handle, Feedback),
    W;
done(decode, Frame, {error, Reason, Inner}, #w{kind = Kind} = W) ->
    Stats =
        case Kind of
            video -> #{framesDropped => 1};
            audio -> #{}
        end,
    Out = #{dropped => Reason, timestamp => maps:get(timestamp, Frame, 0)},
    deliver(decoder, [Out], Stats, W#w{inner = Inner});
done(encode, _Raw, {ok, Frames, Stats, Inner}, W) ->
    deliver(encoder, Frames, Stats, W#w{inner = Inner, failing = false});
done(encode, _Raw, {error, Reason, Inner}, #w{failing = Failing} = W) ->
    %% send_media/3 has returned long ago: the log is where this shows,
    %% once for a run of them.
    _ =
        Failing orelse
            logger:warning("webrtc_codecs_async: raw media was not encoded: ~p", [Reason]),
    W#w{inner = Inner, failing = true};
done(control, _Event, {ok, Inner}, W) ->
    W#w{inner = Inner};
done(control, _Event, {error, _Reason, Inner}, W) ->
    W#w{inner = Inner};
done(What, _Term, {error, Reason}, W) ->
    fatal(What, Reason, W);
done(What, _Term, Other, W) ->
    fatal(What, {bad_return, Other}, W).

-spec fatal(atom(), term(), #w{}) -> no_return().
fatal(What, Reason, #w{plugin = Plugin}) ->
    logger:error("webrtc_codecs_async: ~s of ~s failed, the plugin stops: ~p", [
        What, Plugin, Reason
    ]),
    exit({codec_plugin, Reason}).

%% Outputs or frames with their statistics, and the name of what made
%% them, which info/1 cannot tell from the transport process.
deliver(Side, Results, Stats0, #w{plugin = Plugin, inner = Inner, handle = Handle} = W) ->
    Stats = maps:merge(Stats0, implementation(Side, Plugin:info(Inner))),
    ok =
        case Side of
            decoder -> webrtc_media_codec:decoded(Handle, Results, Stats);
            encoder -> webrtc_media_codec:encoded(Handle, Results, Stats)
        end,
    W.

implementation(Side, Info) when is_map(Info) ->
    {Name, Power} =
        case Side of
            decoder -> {decoderImplementation, powerEfficientDecoder};
            encoder -> {encoderImplementation, powerEfficientEncoder}
        end,
    maps:from_list(
        [{Name, V} || {implementation, V} <- maps:to_list(Info)] ++
            [{Power, V} || {power_efficient, V} <- maps:to_list(Info)]
    );
implementation(_Side, _Info) ->
    #{}.
