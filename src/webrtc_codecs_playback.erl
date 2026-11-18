-module(webrtc_codecs_playback).
-moduledoc """
Show decoded pictures in a window, play decoded audio on the speaker, or
write either to a file, through the `ffplay` and `ffmpeg` executables
running as ports.

```erlang
{ok, Window} = webrtc_codecs_playback:start(window, #{width => 640, height => 480}),
receive
    {webrtc, Pc, {decoded, Mid, #{format := i420} = Picture}} -> webrtc_codecs_playback:play(Window, Picture)
end.
```

The window and the speaker are for trying things by hand. A file is for
tests: FFmpeg picks the container and the codec from the extension
(`.mp4`, `.mkv`, `.y4m`, `.wav`, ...), and `stop/1` returns once the
file is complete.

A sink takes one format, given at start. A window or the speaker that
cannot keep up drops what `play/2` gives it and says so, rather than
queue it. A file takes everything: `play/2` returns when FFmpeg has
taken it, and fails with `stalled` when FFmpeg has not within
`write_timeout`.

Whatever the program does, `stop/1` returns and the program is gone: it
is asked to end, then killed.
""".
-behaviour(gen_server).

-export([start/2, play/2, stop/1, stats/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-export_type([sink/0, options/0]).

-type sink() :: window | speaker | {file, video | audio, file:filename_all()}.

-doc """
- `width`, `height`, `frame_rate`: of the pictures, default 640, 480, 30
- `sample_rate`, `channels`: of the audio, default 48000, 1
- `output_options`: FFmpeg options placed before the name of a file, for
  example `["-c:v", "libvpx"]`
- `title`: of the window
- `write_timeout`: how long a file sink may take to accept what `play/2`
  gives it, in milliseconds, default 5000
- `finish_timeout`: how long `stop/1` gives FFmpeg to finish a file,
  default 15000
- `ffmpeg`, `ffplay`: paths of the executables, default those in `PATH`
""".
-type options() :: #{
    width => pos_integer(),
    height => pos_integer(),
    frame_rate => pos_integer(),
    sample_rate => pos_integer(),
    channels => pos_integer(),
    output_options => [string()],
    title => string(),
    write_timeout => pos_integer(),
    finish_timeout => pos_integer(),
    ffmpeg => file:filename_all(),
    ffplay => file:filename_all()
}.

-record(st, {
    %% The program, until it has been ended.
    exec :: undefined | webrtc_codecs_exec:exec(),
    kind :: video | audio,
    opts :: map(),
    %% How the media gets to the program. A window or the speaker reads
    %% its standard input, which takes a write whole or not at all, so
    %% that a dropped picture never leaves half of one behind. FFmpeg
    %% writing a file reads a socket, which can be closed for writing
    %% alone: the end of input it needs to finish the file.
    listen :: undefined | webrtc_codecs_exec:endpoint(),
    socket :: undefined | gen_tcp:socket(),
    %% Why the sink takes nothing any more: the program ended by itself
    %% with a status and last words, or stopped reading and was killed.
    failed :: undefined | {ended, integer(), binary()} | stalled,
    %% How the program ended when it was ended before stop/1.
    how :: undefined | webrtc_codecs_exec:ended(),
    played = 0 :: non_neg_integer(),
    dropped = 0 :: non_neg_integer()
}).

-define(WRITE_MS, 5000).
-define(FINISH_MS, 15000).
%% How long accept waits between looks at what the program says.
-define(ACCEPT_MS, 50).

-doc "Start a sink. The process is linked to the caller.".
-spec start(sink(), options()) -> {ok, pid()} | {error, term()}.
start(Sink, Opts) when is_map(Opts) ->
    gen_server:start_link(?MODULE, {Sink, Opts}, []).

-doc """
Give a picture or audio to the sink. `dropped` when a window or the
speaker is behind, `{error, bad_format}` when the media is not in the
format the sink was started with, `{error, {ended, Status, Text}}` when
the program has ended by itself, with what it said, `{error, stalled}`
when a file sink did not take the media in time: the program is then
killed and the sink takes nothing more.
""".
-spec play(pid(), webrtc_codecs:picture() | webrtc_codecs:audio()) ->
    ok | dropped | {error, term()}.
play(Pid, Raw) ->
    try
        %% The sink answers within twice write_timeout; this is for a
        %% sink that is itself busy.
        gen_server:call(Pid, {play, Raw}, 60000)
    catch
        exit:{noproc, _} -> {error, closed};
        exit:{normal, _} -> {error, closed}
    end.

-doc """
Close the sink and end its program. For a file, `ok` means FFmpeg
finished writing it; `{error, {not_finalized, Status | killed, Text}}`
means it ended with an error or had to be killed, and the file may be
incomplete.
""".
-spec stop(pid()) -> ok | {error, {not_finalized, integer() | killed, binary()}}.
stop(Pid) ->
    try
        gen_server:call(Pid, stop, infinity)
    catch
        exit:{noproc, _} -> ok;
        exit:{normal, _} -> ok
    end.

-doc "Pictures or chunks of audio given to the sink, and how many it dropped.".
-spec stats(pid()) -> #{played := non_neg_integer(), dropped := non_neg_integer()}.
stats(Pid) ->
    gen_server:call(Pid, stats).

-doc false.
init({Sink, Opts0}) ->
    Opts = maps:merge(
        #{
            width => 640,
            height => 480,
            frame_rate => 30,
            sample_rate => 48000,
            channels => 1,
            write_timeout => ?WRITE_MS,
            finish_timeout => ?FINISH_MS
        },
        Opts0
    ),
    maybe
        ok ?= valid(Opts),
        {ok, Kind, Program} ?= kind(Sink),
        {ok, Exe} ?= executable(Program, Opts),
        {ok, Listen, Input} ?= input(Sink),
        %% A program that ends closes the port under us: that is told to
        %% play/2, not a reason to die.
        process_flag(trap_exit, true),
        {ok, Exec} ?= open(Exe, command(Sink, Input, Opts), Listen),
        {ok, #st{exec = Exec, kind = Kind, opts = Opts, listen = Listen}}
    else
        {error, Reason} -> {stop, Reason}
    end.

valid(
    #{width := W, height := H, frame_rate := Fps, sample_rate := Rate, channels := Channels} = Opts
) ->
    #{write_timeout := Write, finish_timeout := Finish} = Opts,
    Ok =
        lists:all(fun(V) -> is_integer(V) andalso V > 0 end, [
            W, H, Fps, Rate, Channels, Write, Finish
        ]) andalso
            W rem 2 =:= 0 andalso H rem 2 =:= 0 andalso W =< 16384 andalso H =< 16384 andalso
            (Channels =:= 1 orelse Channels =:= 2) andalso
            is_list(maps:get(output_options, Opts, [])),
    case Ok of
        true -> ok;
        false -> {error, {badarg, Opts}}
    end.

kind(window) -> {ok, video, ffplay};
kind(speaker) -> {ok, audio, ffplay};
kind({file, Kind, _Path}) when Kind =:= video; Kind =:= audio -> {ok, Kind, ffmpeg};
kind(Sink) -> {error, {badarg, Sink}}.

executable(Program, Opts) ->
    case maps:find(Program, Opts) of
        {ok, Path} ->
            {ok, Path};
        error ->
            case os:find_executable(atom_to_list(Program)) of
                false -> {error, {not_found, Program}};
                Path -> {ok, Path}
            end
    end.

%% Where the program reads the media: a socket for a file, its standard
%% input for a window or the speaker.
input({file, _, _}) ->
    case webrtc_codecs_exec:listen() of
        {ok, #{url := Url} = Listen} -> {ok, Listen, Url};
        {error, _} = Error -> Error
    end;
input(_Sink) ->
    {ok, undefined, "pipe:0"}.

%% An executable that is not there raises.
open(Exe, Args, Listen) ->
    try
        {ok, webrtc_codecs_exec:open(Exe, Args)}
    catch
        error:Reason ->
            _ = Listen =/= undefined andalso webrtc_codecs_exec:close_listen(Listen),
            {error, {not_started, Reason}}
    end.

%% The arguments of the program.
command(window, Input, Opts) ->
    Title = maps:get(title, Opts, "webrtc_codecs"),
    Args = [
        "-autoexit",
        "-fflags",
        "nobuffer",
        "-flags",
        "low_delay",
        "-framedrop",
        "-window_title",
        Title
    ],
    quiet() ++ Args ++ raw_input(ffplay, video, Input, Opts);
command(speaker, Input, Opts) ->
    quiet() ++ ["-autoexit", "-nodisp", "-fflags", "nobuffer"] ++
        raw_input(ffplay, audio, Input, Opts);
command({file, Kind, Path}, Input, Opts) ->
    Output = maps:get(output_options, Opts, []) ++ [unicode:characters_to_list(Path)],
    quiet() ++ ["-nostdin", "-y"] ++ raw_input(ffmpeg, Kind, Input, Opts) ++ Output.

quiet() ->
    ["-hide_banner", "-loglevel", "error"].

raw_input(_Program, video, Input, #{width := W, height := H, frame_rate := Fps}) ->
    Size = integer_to_list(W) ++ "x" ++ integer_to_list(H),
    Format = ["-f", "rawvideo", "-pixel_format", "yuv420p", "-video_size", Size],
    Format ++ ["-framerate", integer_to_list(Fps), "-i", Input];
raw_input(Program, audio, Input, #{sample_rate := Rate, channels := Channels}) ->
    %% ffplay names the channels, ffmpeg counts them.
    Layout =
        case {Program, Channels} of
            {ffplay, 1} -> ["-ch_layout", "mono"];
            {ffplay, 2} -> ["-ch_layout", "stereo"];
            {ffmpeg, _} -> ["-ac", integer_to_list(Channels)]
        end,
    ["-f", "s16le", "-ar", integer_to_list(Rate)] ++ Layout ++ ["-i", Input].

-doc false.
handle_call({play, _Raw}, _From, #st{failed = Failed} = St) when Failed =/= undefined ->
    {reply, {error, Failed}, St};
handle_call({play, Raw}, _From, #st{played = Played, dropped = Dropped} = St0) ->
    case payload(Raw, St0) of
        {ok, Data} ->
            case write(Data, St0) of
                {ok, St} ->
                    {reply, ok, St#st{played = Played + 1}};
                {dropped, St} ->
                    {reply, dropped, St#st{played = Played + 1, dropped = Dropped + 1}};
                {failed, St} ->
                    {reply, {error, St#st.failed}, St}
            end;
        error ->
            {reply, {error, bad_format}, St0}
    end;
handle_call(stats, _From, #st{played = Played, dropped = Dropped} = St) ->
    {reply, #{played => Played, dropped => Dropped}, St};
handle_call(stop, _From, St) ->
    {Result, St1} = finish(St),
    {stop, normal, Result, St1}.

%% A window or the speaker: a busy port means the program is behind,
%% and the media is dropped, not waited for.
write(Data, #st{listen = undefined, socket = undefined, exec = Exec} = St) ->
    case webrtc_codecs_exec:write(Exec, Data) of
        true -> {ok, St};
        false -> {dropped, St};
        closed -> {failed, gone(St)}
    end;
%% A file: all of it, within write_timeout.
write(Data, #st{opts = #{write_timeout := Timeout}} = St0) ->
    case connected(St0, erlang:monotonic_time(millisecond) + Timeout) of
        {ok, #st{socket = Socket} = St} ->
            case gen_tcp:send(Socket, Data) of
                ok -> {ok, St};
                {error, timeout} -> {failed, stalled(St)};
                {error, _} -> {failed, gone(St)}
            end;
        {failed, St} ->
            {failed, St}
    end.

%% The connection of the program, which it makes when it starts. The
%% wait is cut in slices to notice a program that ended instead.
connected(#st{socket = Socket} = St, _Deadline) when Socket =/= undefined ->
    {ok, St};
connected(#st{listen = #{socket := Listening} = Listen, exec = Exec0, opts = Opts} = St, Deadline) ->
    case gen_tcp:accept(Listening, ?ACCEPT_MS) of
        {ok, Socket} ->
            ok = webrtc_codecs_exec:close_listen(Listen),
            #{write_timeout := Timeout} = Opts,
            _ = inet:setopts(Socket, [{send_timeout, Timeout}, {send_timeout_close, true}]),
            {ok, St#st{listen = undefined, socket = Socket}};
        {error, timeout} ->
            Exec = webrtc_codecs_exec:poll(Exec0),
            case
                {webrtc_codecs_exec:exited(Exec), erlang:monotonic_time(millisecond) >= Deadline}
            of
                {{true, _}, _} -> {failed, gone(St#st{exec = Exec})};
                {false, true} -> {failed, stalled(St#st{exec = Exec})};
                {false, false} -> connected(St#st{exec = Exec}, Deadline)
            end;
        {error, _} ->
            {failed, gone(St)}
    end.

%% The program did not take the media in time. Part of a picture may be
%% written, so the sink cannot go on: the program is killed.
stalled(#st{exec = Exec} = St) ->
    How = webrtc_codecs_exec:stop(Exec, 0),
    release(St#st{exec = undefined, failed = stalled, how = How}).

%% The program is gone, or going: a closed window, or an error.
gone(#st{exec = Exec} = St) ->
    How = webrtc_codecs_exec:stop(Exec, 1000),
    Failed =
        case How of
            {exited, Status, Said} -> {ended, Status, Said};
            {killed, Said} -> {ended, -1, Said}
        end,
    release(St#st{exec = undefined, failed = Failed, how = How}).

release(#st{listen = Listen, socket = Socket} = St) ->
    _ = Socket =/= undefined andalso gen_tcp:close(Socket),
    _ = Listen =/= undefined andalso webrtc_codecs_exec:close_listen(Listen),
    St#st{listen = undefined, socket = undefined}.

%% End the program and say whether a file was finished.
finish(#st{exec = undefined, how = How} = St) ->
    {finished(How, St), St};
finish(#st{listen = undefined, socket = undefined, exec = Exec} = St) ->
    %% A window or the speaker: nothing to finish, the program is ended.
    _ = webrtc_codecs_exec:stop(Exec, 0),
    {ok, St#st{exec = undefined}};
finish(#st{opts = #{finish_timeout := Timeout}} = St0) ->
    %% Closing our side for writing is the end of input FFmpeg waits for
    %% to finish the file; its exit status says whether it did.
    case connected(St0, erlang:monotonic_time(millisecond) + Timeout) of
        {ok, #st{socket = Socket, exec = Exec} = St} ->
            _ = gen_tcp:shutdown(Socket, write),
            How = webrtc_codecs_exec:stop(Exec, Timeout),
            St1 = release(St#st{exec = undefined, how = How}),
            {finished(How, St1), St1};
        {failed, #st{how = How} = St} ->
            {finished(How, St), St}
    end.

finished({exited, 0, _Said}, _St) -> ok;
finished({exited, Status, Said}, _St) -> {error, {not_finalized, Status, Said}};
finished({killed, Said}, _St) -> {error, {not_finalized, killed, Said}};
finished(undefined, _St) -> ok.

%% The bytes of raw media in the format of the sink, or error.
payload(
    #{format := i420, width := W, height := H, y := Y, u := U, v := V}, #st{
        kind = video, opts = Opts
    }
) ->
    case Opts of
        #{width := W, height := H} when
            byte_size(Y) =:= W * H, byte_size(U) =:= W * H div 4, byte_size(V) =:= W * H div 4
        ->
            {ok, [Y, U, V]};
        _ ->
            error
    end;
payload(
    #{format := s16le, sample_rate := Rate, channels := Channels, samples := Pcm},
    #st{kind = audio, opts = Opts}
) ->
    case Opts of
        %% At most a second per call: what a sink is given at once is bounded.
        #{sample_rate := Rate, channels := Channels} when
            is_binary(Pcm), byte_size(Pcm) =< Rate * Channels * 2
        ->
            {ok, Pcm};
        _ ->
            error
    end;
payload(_Raw, _St) ->
    error.

-doc false.
handle_cast(_Msg, St) ->
    {noreply, St}.

-doc false.
handle_info(Msg, #st{exec = Exec} = St) when Exec =/= undefined ->
    case webrtc_codecs_exec:handle(Msg, Exec) of
        {ok, Exec1} ->
            {noreply, St#st{exec = Exec1}};
        {exited, Exec1} ->
            %% The program ended by itself: a closed window, or an error.
            %% The process stays to tell play/2 why, until stop/1.
            {noreply, gone(St#st{exec = Exec1})};
        ignore ->
            {noreply, St}
    end;
handle_info(_Info, St) ->
    {noreply, St}.

%% When the sink goes without stop/1, with its owner or its supervisor,
%% the program is ended at once and a file is left as it is.
-doc false.
terminate(_Reason, #st{exec = Exec} = St) ->
    _ = Exec =/= undefined andalso webrtc_codecs_exec:stop(Exec, 0),
    _ = release(St),
    ok.
