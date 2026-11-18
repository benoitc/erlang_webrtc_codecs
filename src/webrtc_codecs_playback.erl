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
room for more.
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
    ffmpeg => file:filename_all(),
    ffplay => file:filename_all()
}.

-record(st, {
    port :: port(),
    os_pid :: undefined | non_neg_integer(),
    kind :: video | audio,
    opts :: map(),
    %% A file takes everything, at its pace; a window or the speaker
    %% drops what comes while it is behind.
    wait :: boolean(),
    %% Set when the program ended by itself: its status and last words.
    ended :: undefined | {integer(), binary()},
    played = 0 :: non_neg_integer(),
    dropped = 0 :: non_neg_integer(),
    %% Where the program writes what it has to say.
    log :: file:filename_all()
}).

%% How long stop/1 waits for FFmpeg to finish a file.
-define(FINISH_MS, 15000).

-doc "Start a sink. The process is linked to the caller.".
-spec start(sink(), options()) -> {ok, pid()} | {error, term()}.
start(Sink, Opts) when is_map(Opts) ->
    gen_server:start_link(?MODULE, {Sink, Opts}, []).

-doc """
Give a picture or audio to the sink. `dropped` when a window or the
speaker is behind, `{error, bad_format}` when the media is not in the
format the sink was started with, `{error, {ended, Status, Text}}` when
the program has ended by itself, with what it said.
""".
-spec play(pid(), webrtc_codecs:picture() | webrtc_codecs:audio()) ->
    ok | dropped | {error, term()}.
play(Pid, Raw) ->
    try
        gen_server:call(Pid, {play, Raw}, infinity)
    catch
        exit:{noproc, _} -> {error, closed};
        exit:{normal, _} -> {error, closed}
    end.

-doc "Close the sink. For a file, returns when FFmpeg has finished writing it.".
-spec stop(pid()) -> ok.
stop(Pid) ->
    gen_server:stop(Pid, normal, ?FINISH_MS + 5000).

-doc "Pictures or chunks of audio given to the sink, and how many it dropped.".
-spec stats(pid()) -> #{played := non_neg_integer(), dropped := non_neg_integer()}.
stats(Pid) ->
    gen_server:call(Pid, stats).

-doc false.
init({Sink, Opts0}) ->
    Opts = maps:merge(
        #{width => 640, height => 480, frame_rate => 30, sample_rate => 48000, channels => 1}, Opts0
    ),
    maybe
        ok ?= valid(Opts),
        {ok, Kind, Program, Args} ?= command(Sink, Opts),
        {ok, Exe} ?= executable(Program, Opts),
        Log = filename:join(
            tmp_dir(),
            "webrtc_codecs_playback-" ++ integer_to_list(erlang:unique_integer([positive]))
        ),
        %% A program that ends closes the port under us: that is told to
        %% play/2, not a reason to die.
        process_flag(trap_exit, true),
        Port = open(Exe, Args, Log),
        OsPid =
            case erlang:port_info(Port, os_pid) of
                {os_pid, Pid} -> Pid;
                undefined -> undefined
            end,
        Wait = is_tuple(Sink),
        {ok, #st{port = Port, os_pid = OsPid, kind = Kind, opts = Opts, wait = Wait, log = Log}}
    else
        {error, Reason} -> {stop, Reason}
    end.

valid(
    #{width := W, height := H, frame_rate := Fps, sample_rate := Rate, channels := Channels} = Opts
) ->
    Ok =
        lists:all(fun(V) -> is_integer(V) andalso V > 0 end, [W, H, Fps, Rate, Channels]) andalso
            W rem 2 =:= 0 andalso H rem 2 =:= 0 andalso W =< 16384 andalso H =< 16384 andalso
            (Channels =:= 1 orelse Channels =:= 2) andalso
            is_list(maps:get(output_options, Opts, [])),
    case Ok of
        true -> ok;
        false -> {error, {badarg, Opts}}
    end.

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

tmp_dir() ->
    case os:getenv("TMPDIR") of
        false -> "/tmp";
        Dir -> Dir
    end.

%% The kind of media, the program and its arguments. Raw media comes on
%% the standard input in both cases.
command(window, Opts) ->
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
    {ok, video, ffplay, quiet() ++ Args ++ raw_input(ffplay, video, Opts)};
command(speaker, Opts) ->
    {ok, audio, ffplay,
        quiet() ++ ["-autoexit", "-nodisp", "-fflags", "nobuffer"] ++
            raw_input(ffplay, audio, Opts)};
command({file, Kind, Path}, Opts) when Kind =:= video; Kind =:= audio ->
    Output = maps:get(output_options, Opts, []) ++ [unicode:characters_to_list(Path)],
    {ok, Kind, ffmpeg, quiet() ++ ["-y"] ++ raw_input(ffmpeg, Kind, Opts) ++ Output};
command(Sink, _Opts) ->
    {error, {badarg, Sink}}.

quiet() ->
    ["-hide_banner", "-loglevel", "error"].

raw_input(_Program, video, #{width := W, height := H, frame_rate := Fps}) ->
    Size = integer_to_list(W) ++ "x" ++ integer_to_list(H),
    Format = ["-f", "rawvideo", "-pixel_format", "yuv420p", "-video_size", Size],
    Format ++ ["-framerate", integer_to_list(Fps), "-i", "pipe:0"];
raw_input(Program, audio, #{sample_rate := Rate, channels := Channels}) ->
    %% ffplay names the channels, ffmpeg counts them.
    Layout =
        case {Program, Channels} of
            {ffplay, 1} -> ["-ch_layout", "mono"];
            {ffplay, 2} -> ["-ch_layout", "stereo"];
            {ffmpeg, _} -> ["-ac", integer_to_list(Channels)]
        end,
    ["-f", "s16le", "-ar", integer_to_list(Rate)] ++ Layout ++ ["-i", "pipe:0"].

%% The program's messages go to a file, read if it ends by itself.
open(Exe, Args, Log) ->
    case os:type() of
        {unix, _} ->
            Sh = os:find_executable("sh"),
            ShArgs = ["-c", "exec \"$0\" \"$@\" >\"$WEBRTC_CODECS_PLAYBACK_LOG\" 2>&1", Exe | Args],
            Env = {env, [{"WEBRTC_CODECS_PLAYBACK_LOG", unicode:characters_to_list(Log)}]},
            open_port({spawn_executable, Sh}, [{args, ShArgs}, Env, binary, stream, exit_status]);
        _ ->
            open_port({spawn_executable, Exe}, [{args, Args}, binary, stream, exit_status, hide])
    end.

-doc false.
handle_call({play, _Raw}, _From, #st{ended = {Status, Said}} = St) ->
    {reply, {error, {ended, Status, Said}}, St};
handle_call({play, Raw}, _From, #st{played = Played, dropped = Dropped} = St) ->
    case payload(Raw, St) of
        {ok, Data} ->
            case write(Data, St) of
                true -> {reply, ok, St#st{played = Played + 1}};
                false -> {reply, dropped, St#st{played = Played + 1, dropped = Dropped + 1}};
                closed -> {reply, {error, closed}, St}
            end;
        error ->
            {reply, {error, bad_format}, St}
    end;
handle_call(stats, _From, #st{played = Played, dropped = Dropped} = St) ->
    {reply, #{played => Played, dropped => Dropped}, St}.

%% A file waits for room. For a window or the speaker a busy port means
%% the program is behind: drop, do not wait. The port is gone when the
%% program has just ended.
write(Data, #st{port = Port, wait = Wait}) ->
    Options =
        case Wait of
            true -> [];
            false -> [nosuspend]
        end,
    try
        erlang:port_command(Port, Data, Options)
    catch
        error:badarg -> closed
    end.

%% The bytes of raw media in the format of the sink, or error.
payload(#{format := i420, width := W, height := H, y := Y, u := U, v := V}, #st{
    kind = video, opts = Opts
}) ->
    case Opts of
        #{width := W, height := H} when
            byte_size(Y) =:= W * H, byte_size(U) =:= W * H div 4, byte_size(V) =:= W * H div 4
        ->
            {ok, [Y, U, V]};
        _ ->
            error
    end;
payload(#{format := s16le, sample_rate := Rate, channels := Channels, samples := Pcm}, #st{
    kind = audio, opts = Opts
}) ->
    case Opts of
        #{sample_rate := Rate, channels := Channels} when is_binary(Pcm) -> {ok, Pcm};
        _ -> error
    end;
payload(_Raw, _St) ->
    error.

-doc false.
handle_cast(_Msg, St) ->
    {noreply, St}.

-doc false.
handle_info({Port, {exit_status, Status}}, #st{port = Port} = St) ->
    %% The program ended by itself: a closed window, or an error. The
    %% process stays to tell play/2 why, until stop/1.
    {noreply, ended(Status, St)};
handle_info({'EXIT', Port, _Reason}, #st{port = Port, ended = undefined} = St) ->
    %% The port went before it told the status, on a write to a program
    %% that was gone.
    {noreply, ended(-1, St)};
handle_info(_Info, St) ->
    {noreply, St}.

ended(Status, #st{log = Log} = St) ->
    Said =
        case file:read_file(Log) of
            {ok, Text} -> string:trim(Text);
            {error, _} -> <<>>
        end,
    St#st{ended = {Status, Said}, os_pid = undefined}.

%% Closing the port closes the program's input: ffplay ends, FFmpeg
%% finishes the file. The port tells nothing after that, so wait for
%% the program itself to be gone.
-doc false.
terminate(_Reason, #st{port = Port, os_pid = OsPid, log = Log}) ->
    try
        port_close(Port)
    catch
        error:badarg -> true
    end,
    wait_exit(OsPid, erlang:monotonic_time(millisecond) + ?FINISH_MS),
    _ = file:delete(Log),
    ok.

wait_exit(undefined, _Deadline) ->
    ok;
wait_exit(OsPid, Deadline) ->
    case os:type() of
        {unix, _} ->
            Alive = os:cmd("kill -0 " ++ integer_to_list(OsPid) ++ " 2>/dev/null && echo alive"),
            case {Alive, erlang:monotonic_time(millisecond) < Deadline} of
                {"alive" ++ _, true} ->
                    timer:sleep(20),
                    wait_exit(OsPid, Deadline);
                _ ->
                    ok
            end;
        _ ->
            ok
    end.
