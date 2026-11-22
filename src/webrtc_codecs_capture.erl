-module(webrtc_codecs_capture).
-moduledoc """
Capture raw pictures or audio from a camera, a microphone, a file or a
test source, through the `ffmpeg` executable running as a port.

```erlang
{ok, Cam} = webrtc_codecs_capture:start({camera, 0}, #{width => 640, height => 480, frame_rate => 30}),
receive
    {webrtc_capture, Cam, #{format := i420} = Picture} -> webrtc:send_media(Pc, Mid, Picture)
end.
```

The capture process owns the device. It sends each picture
(`t:webrtc_codecs:picture/0`) or chunk of audio (`t:webrtc_codecs:audio/0`,
without a timestamp) to its owner as `{webrtc_capture, Pid, Raw}`, then
`{webrtc_capture, Pid, eof}` or `{webrtc_capture, Pid, {error, Reason}}`
when the source ends, and stops. It stops with its owner.

When the owner has more than `max_queue` messages waiting, what is
captured is dropped and counted, so a slow owner costs frames, not
memory.

With the `encode` option FFmpeg also encodes the video, and the owner
gets encoded frames to pass to `webrtc:send_frame/4`, with no codec
plugin:

```erlang
{ok, Cam} = webrtc_codecs_capture:start({camera, 0}, #{encode => #{codec => vp8, bitrate => 1000000}}),
receive
    {webrtc_capture, Cam, #{data := Frame, timestamp := Ts, keyframe := Key}} ->
        webrtc:send_frame(Pc, Mid, Frame, #{timestamp => Ts, keyframe => Key})
end.
```
""".
-behaviour(gen_server).

-export([devices/0, devices/1, start/2, stop/1, stats/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-export_type([source/0, options/0, encode/0, encoded_frame/0, device/0]).

-doc """
What to capture: a device by its index or its name in `devices/0`, a
file FFmpeg can read, or a source FFmpeg generates (a moving test
picture, a 440 Hz tone).
""".
-type source() ::
    {camera, non_neg_integer() | binary()}
    | {microphone, non_neg_integer() | binary()}
    | {file, video | audio, file:filename_all()}
    | {test, video | audio}.

-doc """
- `owner`: the process that gets the media, default the caller
- `width`, `height`, `frame_rate`: of pictures, default 640, 480, 30;
  width and height are even
- `sample_rate`, `channels`, `frame_ms`: of audio, default 48000, 1, 20
- `max_queue`: messages the owner may have waiting before capture drops,
  default 10
- `realtime`: pace a file or a test source at its own rate, default
  `true`; with `false` FFmpeg reads as fast as it can, and what the owner
  does not take in time is dropped
- `encode`: have FFmpeg encode the video and give encoded frames, see
  `t:encode/0`
- `input_options`: FFmpeg options placed before the input, to replace the
  ones this module derives for a device
- `ffmpeg`: path of the executable, default the one in `PATH`
- `audio_backend`: the FFmpeg input device for a microphone on Linux and
  the BSDs, `pulse`, `alsa`, `oss` or `sndio`, default the first of them
  FFmpeg was built with
""".
-type options() :: #{
    owner => pid(),
    width => pos_integer(),
    height => pos_integer(),
    frame_rate => pos_integer(),
    sample_rate => pos_integer(),
    channels => pos_integer(),
    frame_ms => pos_integer(),
    max_queue => non_neg_integer(),
    realtime => boolean(),
    encode => encode(),
    input_options => [string()],
    ffmpeg => file:filename_all(),
    audio_backend => pulse | alsa | oss | sndio
}.

-doc """
- `codec`: `vp8`, `vp9`, `av1` or `h264`
- `bitrate`: in bits per second, default 1000000
- `keyframe_interval`: frames between two key frames, default 60. FFmpeg
  cannot be asked for a key frame while it runs, so a peer that loses a
  frame waits for the next one.
- `encoder`: the FFmpeg encoder, default `libvpx`, `libvpx-vp9`,
  `libsvtav1`, and for H.264 `h264_videotoolbox` on macOS and
  `libopenh264` elsewhere
- `encoder_options`: FFmpeg options for the encoder, replacing the real
  time ones this module sets for the default encoders
""".
-type encode() :: #{
    codec := vp8 | vp9 | av1 | h264,
    bitrate => pos_integer(),
    keyframe_interval => pos_integer(),
    encoder => string(),
    encoder_options => [string()]
}.

-doc "An encoded frame, as `webrtc:send_frame/4` takes it: `timestamp` is in 90 kHz units.".
-type encoded_frame() :: #{
    codec := vp8 | vp9 | av1 | h264,
    data := binary(),
    timestamp := non_neg_integer(),
    keyframe := boolean()
}.

-doc """
A camera or a microphone: `name` is what `start/2` takes, `description`
what the system calls it when that differs.
""".
-type device() :: #{index := non_neg_integer(), name := binary(), description => binary()}.

-record(st, {
    %% FFmpeg, until it has been ended.
    exec :: undefined | webrtc_codecs_exec:exec(),
    %% Where FFmpeg connects to write the media, then the connection:
    %% a socket, read one message at a time, so that a capture process
    %% that is behind holds FFmpeg back instead of filling its mailbox.
    listen :: undefined | webrtc_codecs_exec:endpoint(),
    socket :: undefined | gen_tcp:socket() | closed,
    owner :: pid(),
    %% What FFmpeg writes, cut and sent to the owner.
    cut :: webrtc_codecs_capture_stream:cut()
}).

%% How often a connection from FFmpeg is looked for, how long FFmpeg may
%% live after closing it, and how long it is given to end when capture
%% stops, before it is made to.
-define(ACCEPT_MS, 20).
-define(LINGER_MS, 2000).
-define(STOP_MS, 1000).
%% What is asked of the socket at once.
-define(SOCKET_BUFFER, 1048576).

-doc """
The cameras and microphones FFmpeg sees. On macOS the terminal or the
application needs the camera and microphone permissions to open them; on
Linux the user has to be in the `video` and `audio` groups.
""".
-spec devices() -> {ok, #{video := [device()], audio := [device()]}} | {error, term()}.
devices() ->
    devices(#{}).

-doc """
The same with options: `ffmpeg` and `audio_backend` of `t:options/0`. On
Linux and the BSDs the microphones are the sources of one backend, the
default source first.
""".
-spec devices(#{ffmpeg => file:filename_all(), audio_backend => pulse | alsa | oss | sndio}) ->
    {ok, #{video := [device()], audio := [device()]}} | {error, term()}.
devices(Opts) when is_map(Opts) ->
    webrtc_codecs_capture_devices:list(Opts).

-doc "Start capturing. The process is linked to the caller.".
-spec start(source(), options()) -> {ok, pid()} | {error, term()}.
start(Source, Opts) when is_map(Opts) ->
    gen_server:start_link(?MODULE, {Source, maps:merge(#{owner => self()}, Opts)}, []).

-doc "Stop capturing and release the device.".
-spec stop(pid()) -> ok.
stop(Pid) ->
    gen_server:stop(Pid).

-doc "Pictures, chunks of audio or encoded frames captured so far, and how many of them were dropped.".
-spec stats(pid()) -> #{captured := non_neg_integer(), dropped := non_neg_integer()}.
stats(Pid) ->
    gen_server:call(Pid, stats).

-doc false.
init({Source, Opts0}) ->
    Opts = maps:merge(defaults(), Opts0),
    maybe
        ok ?= valid(Opts),
        {ok, Ffmpeg} ?= ffmpeg(Opts),
        {ok, Device, Resolved} ?=
            webrtc_codecs_capture_devices:resolve(Source, os:type(), Ffmpeg, Opts),
        {ok, Kind, Input} ?= webrtc_codecs_capture_command:input(Device, os:type(), Resolved),
        {ok, Format, Codec, Output} ?=
            webrtc_codecs_capture_command:output(Kind, maps:get(encode, Opts, undefined), Opts),
        {ok, #{url := Url} = Listen} ?= webrtc_codecs_exec:listen(),
        %% FFmpeg ending is told to the owner, not a reason to die.
        process_flag(trap_exit, true),
        Args = ["-nostdin", "-hide_banner", "-loglevel", "error"] ++ Input ++ Output ++ [Url],
        {ok, Exec} ?= open(Ffmpeg, Args, Listen),
        Owner = maps:get(owner, Opts),
        _ = monitor(process, Owner),
        self() ! accept,
        {ok, #st{
            exec = Exec,
            listen = Listen,
            owner = Owner,
            cut = webrtc_codecs_capture_stream:new(Owner, Kind, Format, Codec, Opts)
        }}
    else
        {error, Reason} -> {stop, Reason}
    end.

%% An executable that is not there raises.
open(Ffmpeg, Args, Listen) ->
    try
        {ok, webrtc_codecs_exec:open(Ffmpeg, Args)}
    catch
        error:Reason ->
            ok = webrtc_codecs_exec:close_listen(Listen),
            {error, {ffmpeg, Reason}}
    end.

defaults() ->
    #{
        width => 640,
        height => 480,
        frame_rate => 30,
        sample_rate => 48000,
        channels => 1,
        frame_ms => 20,
        max_queue => 10,
        realtime => true
    }.

valid(
    #{
        width := W,
        height := H,
        frame_rate := Fps,
        sample_rate := Rate,
        channels := Ch,
        frame_ms := Ms
    } = Opts
) ->
    Ok =
        lists:all(fun(V) -> is_integer(V) andalso V > 0 end, [W, H, Fps, Rate, Ch, Ms]) andalso
            W rem 2 =:= 0 andalso H rem 2 =:= 0 andalso W =< 16384 andalso H =< 16384 andalso
            Rate * Ms rem 1000 =:= 0 andalso
            is_pid(maps:get(owner, Opts)) andalso
            is_integer(maps:get(max_queue, Opts)) andalso
            is_boolean(maps:get(realtime, Opts)) andalso
            is_list(maps:get(input_options, Opts, [])),
    case Ok of
        true -> ok;
        false -> {error, {badarg, maps:remove(owner, Opts)}}
    end.

ffmpeg(#{ffmpeg := Path}) ->
    {ok, Path};
ffmpeg(_Opts) ->
    case os:find_executable("ffmpeg") of
        false -> {error, no_ffmpeg};
        Path -> {ok, Path}
    end.

-doc false.
handle_call(stats, _From, #st{cut = Cut} = St) ->
    {Count, Dropped} = webrtc_codecs_capture_stream:counts(Cut),
    {reply, #{captured => Count, dropped => Dropped}, St}.

-doc false.
handle_cast(_Msg, St) ->
    {noreply, St}.

-doc false.
handle_info(accept, #st{listen = Listen, socket = undefined} = St) when Listen =/= undefined ->
    case accept(St) of
        {ok, St1} ->
            {noreply, St1};
        none ->
            %% Polled, so that stop and the end of the owner are served
            %% while a device takes its time to open.
            _ = erlang:send_after(?ACCEPT_MS, self(), accept),
            {noreply, St};
        {error, Reason} ->
            finish({error, {socket, Reason}}, St)
    end;
handle_info(accept, St) ->
    {noreply, St};
handle_info({tcp, Socket, Data}, #st{socket = Socket, cut = Cut} = St) ->
    case webrtc_codecs_capture_stream:push(Data, Cut) of
        {ok, Cut1} ->
            %% The next message is asked for once this one is dealt with.
            _ = inet:setopts(Socket, [{active, once}]),
            {noreply, St#st{cut = Cut1}};
        bad_stream ->
            %% What FFmpeg writes is not the stream that was asked for.
            finish({error, bad_stream}, St)
    end;
handle_info({tcp_closed, Socket}, #st{socket = Socket} = St) ->
    ended(St#st{socket = closed});
handle_info({tcp_error, Socket, _Reason}, #st{socket = Socket} = St) ->
    _ = gen_tcp:close(Socket),
    ended(St#st{socket = closed});
handle_info(linger, #st{exec = Exec} = St) when Exec =/= undefined ->
    %% FFmpeg closed its output and is still there: it is ended.
    finish(result(webrtc_codecs_exec:stop(Exec, 0)), St#st{exec = undefined});
handle_info({'DOWN', _, process, Owner, _}, #st{owner = Owner} = St) ->
    {stop, normal, St};
handle_info(Msg, #st{exec = Exec} = St) when Exec =/= undefined ->
    case webrtc_codecs_exec:handle(Msg, Exec) of
        {ok, Exec1} -> {noreply, St#st{exec = Exec1}};
        {exited, Exec1} -> ended(St#st{exec = Exec1});
        ignore -> {noreply, St}
    end;
handle_info(_Info, St) ->
    {noreply, St}.

%% The capture is over when FFmpeg has ended and everything it wrote has
%% been read. What it wrote may still be on its way when its end is
%% known, and it may close its output before it ends.
ended(#st{exec = Exec, socket = undefined, listen = Listen} = St) when Listen =/= undefined ->
    %% FFmpeg may have connected, written and ended before its
    %% connection was taken: what it wrote is still to read.
    case {webrtc_codecs_exec:exited(Exec), accept(St)} of
        {_, {ok, St1}} -> {noreply, St1};
        {{true, _}, _} -> finish(result(webrtc_codecs_exec:stop(Exec, 0)), St#st{exec = undefined});
        {false, _} -> {noreply, St}
    end;
ended(#st{exec = Exec, socket = Socket} = St) ->
    case {webrtc_codecs_exec:exited(Exec), Socket} of
        {{true, _}, closed} ->
            finish(result(webrtc_codecs_exec:stop(Exec, 0)), St#st{exec = undefined});
        {{true, _}, _} ->
            {noreply, St};
        {false, _} ->
            _ = erlang:send_after(?LINGER_MS, self(), linger),
            {noreply, St}
    end.

%% Take the connection of FFmpeg if it has made it.
accept(#st{listen = #{socket := Listening} = Listen} = St) ->
    case gen_tcp:accept(Listening, 0) of
        {ok, Socket} ->
            ok = webrtc_codecs_exec:close_listen(Listen),
            _ = inet:setopts(Socket, [
                {recbuf, ?SOCKET_BUFFER}, {buffer, ?SOCKET_BUFFER}, {active, once}
            ]),
            {ok, St#st{listen = undefined, socket = Socket}};
        {error, timeout} ->
            none;
        {error, _} = Error ->
            Error
    end.

result({exited, 0, _Said}) -> eof;
result({exited, Status, Said}) -> {error, {ffmpeg, Status, Said}};
result({killed, Said}) -> {error, {ffmpeg, killed, Said}}.

finish(Result, #st{owner = Owner} = St) ->
    Owner ! {webrtc_capture, self(), Result},
    {stop, normal, St}.

%% Closing the socket makes FFmpeg fail on its next write and end. One
%% that does not, because it waits on a device, is made to.
-doc false.
terminate(_Reason, #st{exec = Exec, listen = Listen, socket = Socket}) ->
    _ = is_port(Socket) andalso gen_tcp:close(Socket),
    _ = Listen =/= undefined andalso webrtc_codecs_exec:close_listen(Listen),
    _ = Exec =/= undefined andalso webrtc_codecs_exec:stop(Exec, ?STOP_MS),
    ok.
