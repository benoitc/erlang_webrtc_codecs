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
""".
-behaviour(gen_server).

-export([devices/0, start/2, stop/1, stats/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-export_type([source/0, options/0, device/0]).

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
- `input_options`: FFmpeg options placed before the input, to replace the
  ones this module derives for a device
- `ffmpeg`: path of the executable, default the one in `PATH`
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
    input_options => [string()],
    ffmpeg => file:filename_all()
}.

-type device() :: #{index := non_neg_integer(), name := binary()}.

-record(st, {
    port :: port(),
    owner :: pid(),
    kind :: video | audio,
    opts :: map(),
    %% Bytes of one picture or one chunk of audio.
    size :: pos_integer(),
    buffer = <<>> :: binary(),
    %% Pictures or chunks read, and how many of them were dropped.
    count = 0 :: non_neg_integer(),
    dropped = 0 :: non_neg_integer(),
    %% Where FFmpeg writes what it has to say.
    log :: file:filename_all()
}).

-doc """
The cameras and microphones FFmpeg sees. On macOS the terminal or the
application needs the camera and microphone permissions to open them; on
Linux the user has to be in the `video` and `audio` groups.
""".
-spec devices() -> {ok, #{video := [device()], audio := [device()]}} | {error, term()}.
devices() ->
    case os:find_executable("ffmpeg") of
        false -> {error, no_ffmpeg};
        Ffmpeg -> devices(os:type(), Ffmpeg)
    end.

devices({unix, darwin}, Ffmpeg) ->
    Out = run(Ffmpeg, ["-hide_banner", "-f", "avfoundation", "-list_devices", "true", "-i", ""]),
    {ok, avfoundation_devices(Out)};
devices({unix, _}, _Ffmpeg) ->
    Video = [
        #{index => list_to_integer(N), name => v4l2_name(N)}
     || "/dev/video" ++ N <- lists:sort(filelib:wildcard("/dev/video*")),
        N =/= "",
        lists:all(fun is_digit/1, N)
    ],
    {ok, #{video => Video, audio => [#{index => 0, name => <<"default">>}]}};
devices({win32, _}, Ffmpeg) ->
    Out = run(Ffmpeg, ["-hide_banner", "-f", "dshow", "-list_devices", "true", "-i", "dummy"]),
    {ok, dshow_devices(Out)}.

%% Lines such as "[AVFoundation indev @ 0x1] [0] FaceTime HD Camera",
%% under "AVFoundation video devices:" then "AVFoundation audio devices:".
avfoundation_devices(Out) ->
    {_, Devices} = lists:foldl(
        fun(Line, {Kind, Acc}) ->
            case
                {
                    re:run(Line, "AVFoundation (video|audio) devices", [{capture, [1], binary}]),
                    re:run(Line, "\\] \\[([0-9]+)\\] (.*)$", [{capture, [1, 2], binary}, unicode])
                }
            of
                {{match, [<<"video">>]}, _} ->
                    {video, Acc};
                {{match, [<<"audio">>]}, _} ->
                    {audio, Acc};
                {_, {match, [Index, Name]}} when Kind =/= none ->
                    {Kind, add_device(Kind, Index, Name, Acc)};
                _ ->
                    {Kind, Acc}
            end
        end,
        {none, #{video => [], audio => []}},
        lines(Out)
    ),
    maps:map(fun(_, L) -> lists:reverse(L) end, Devices).

%% Lines such as `[dshow @ 0x1] "Integrated Camera" (video)`.
dshow_devices(Out) ->
    Found = [
        {binary_to_atom(Kind), Name}
     || Line <- lines(Out),
        {match, [Name, Kind]} <- [
            re:run(Line, "\"([^\"]+)\" \\((video|audio)\\)", [{capture, [1, 2], binary}, unicode])
        ]
    ],
    #{
        Kind => [
            #{index => I, name => N}
         || {I, N} <- lists:enumerate(0, [N || {K, N} <- Found, K =:= Kind])
        ]
     || Kind <- [video, audio]
    }.

add_device(Kind, Index, Name, Acc) ->
    maps:update_with(
        Kind, fun(L) -> [#{index => binary_to_integer(Index), name => Name} | L] end, Acc
    ).

v4l2_name(N) ->
    case file:read_file("/sys/class/video4linux/video" ++ N ++ "/name") of
        {ok, Name} -> string:trim(Name);
        {error, _} -> list_to_binary("/dev/video" ++ N)
    end.

is_digit(C) -> C >= $0 andalso C =< $9.

lines(Out) ->
    binary:split(Out, [<<"\n">>, <<"\r\n">>], [global, trim_all]).

%% Run a command to its end and give what it wrote, at most a megabyte.
run(Exe, Args) ->
    Port = open_port({spawn_executable, Exe}, [
        {args, Args}, binary, exit_status, stderr_to_stdout, hide
    ]),
    collect(Port, <<>>).

collect(Port, Acc) ->
    receive
        {Port, {data, Data}} when byte_size(Acc) < 1048576 ->
            collect(Port, <<Acc/binary, Data/binary>>);
        {Port, {data, _}} ->
            collect(Port, Acc);
        {Port, {exit_status, _}} ->
            Acc
    after 10000 ->
        close(Port),
        Acc
    end.

-doc "Start capturing. The process is linked to the caller.".
-spec start(source(), options()) -> {ok, pid()} | {error, term()}.
start(Source, Opts) when is_map(Opts) ->
    gen_server:start_link(?MODULE, {Source, maps:merge(#{owner => self()}, Opts)}, []).

-doc "Stop capturing and release the device.".
-spec stop(pid()) -> ok.
stop(Pid) ->
    gen_server:stop(Pid).

-doc "Pictures or chunks of audio captured so far, and how many of them were dropped.".
-spec stats(pid()) -> #{captured := non_neg_integer(), dropped := non_neg_integer()}.
stats(Pid) ->
    gen_server:call(Pid, stats).

-doc false.
init({Source, Opts0}) ->
    Opts = maps:merge(defaults(), Opts0),
    maybe
        ok ?= valid(Opts),
        {ok, Ffmpeg} ?= ffmpeg(Opts),
        {ok, Kind, Input} ?= input(Source, os:type(), Opts),
        Log = filename:join(
            tmp_dir(),
            "webrtc_codecs_capture-" ++ integer_to_list(erlang:unique_integer([positive]))
        ),
        Args = ["-nostdin", "-hide_banner", "-loglevel", "error"] ++ Input ++ output(Kind, Opts),
        Port = open(Ffmpeg, Args, Log),
        Owner = maps:get(owner, Opts),
        _ = monitor(process, Owner),
        {ok, #st{
            port = Port, owner = Owner, kind = Kind, opts = Opts, size = size(Kind, Opts), log = Log
        }}
    else
        {error, Reason} -> {stop, Reason}
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

tmp_dir() ->
    case os:getenv("TMPDIR") of
        false -> "/tmp";
        Dir -> Dir
    end.

%% The kind of media and the FFmpeg arguments up to and including the
%% input. `input_options` replaces the device options derived here.
input({test, video}, _Os, #{frame_rate := Fps} = Opts) ->
    generated(
        video, "testsrc2=size=" ++ picture_size(Opts) ++ ":rate=" ++ integer_to_list(Fps), Opts
    );
input({test, audio}, _Os, #{sample_rate := Rate} = Opts) ->
    generated(audio, "sine=frequency=440:sample_rate=" ++ integer_to_list(Rate), Opts);
input({file, Kind, Path}, _Os, Opts) when Kind =:= video; Kind =:= audio ->
    {ok, Kind,
        pace(Opts) ++ maps:get(input_options, Opts, []) ++ ["-i", unicode:characters_to_list(Path)]};
input({camera, Device}, Os, Opts) when is_integer(Device), Device >= 0; is_binary(Device) ->
    #{frame_rate := Fps} = Opts,
    Derived = ["-framerate", integer_to_list(Fps), "-video_size", picture_size(Opts)],
    device(video, Derived, device_input(Os, video, Device), Opts);
input({microphone, Device}, Os, Opts) when is_integer(Device), Device >= 0; is_binary(Device) ->
    device(audio, [], device_input(Os, audio, Device), Opts);
input(Source, _Os, _Opts) ->
    {error, {badarg, Source}}.

%% A source FFmpeg makes itself (libavfilter).
generated(Kind, Source, Opts) ->
    {ok, Kind, pace(Opts) ++ ["-f", "lavfi", "-i", Source]}.

pace(#{realtime := true}) -> ["-re"];
pace(#{realtime := false}) -> [].

picture_size(#{width := W, height := H}) ->
    integer_to_list(W) ++ "x" ++ integer_to_list(H).

device(Kind, Derived, {Format, Input}, Opts) ->
    {ok, Kind, ["-f", Format] ++ maps:get(input_options, Opts, Derived) ++ ["-i", Input]}.

%% The FFmpeg input device of each system and how it names a device.
%% On Linux a camera index is a /dev/video number and a microphone
%% index means the default source.
device_input({unix, darwin}, video, Device) ->
    {"avfoundation", device_name(Device) ++ ":none"};
device_input({unix, darwin}, audio, Device) ->
    {"avfoundation", "none:" ++ device_name(Device)};
device_input({win32, _}, Kind, Device) ->
    {"dshow", atom_to_list(Kind) ++ "=" ++ device_name(Device)};
device_input(_, video, Device) when is_integer(Device) ->
    {"v4l2", "/dev/video" ++ device_name(Device)};
device_input(_, video, Device) ->
    {"v4l2", device_name(Device)};
device_input(_, audio, Device) when is_integer(Device) -> {"pulse", "default"};
device_input(_, audio, Device) ->
    {"pulse", device_name(Device)}.

device_name(Index) when is_integer(Index) -> integer_to_list(Index);
device_name(Name) -> unicode:characters_to_list(Name).

%% What FFmpeg writes to its standard output: planes or samples, nothing
%% else.
output(video, #{frame_rate := Fps} = Opts) ->
    Format = ["-pix_fmt", "yuv420p", "-s", picture_size(Opts), "-r", integer_to_list(Fps)],
    ["-map", "0:v:0", "-an"] ++ Format ++ ["-f", "rawvideo", "pipe:1"];
output(audio, #{sample_rate := Rate, channels := Channels}) ->
    Format = ["-ac", integer_to_list(Channels), "-ar", integer_to_list(Rate)],
    ["-map", "0:a:0", "-vn"] ++ Format ++ ["-f", "s16le", "pipe:1"].

size(video, #{width := W, height := H}) ->
    W * H * 3 div 2;
size(audio, #{sample_rate := Rate, channels := Channels, frame_ms := Ms}) ->
    Rate * Ms div 1000 * Channels * 2.

%% FFmpeg's standard output is the media, so its messages go to a file,
%% read when it ends. Closing the port closes its output and ends it.
open(Ffmpeg, Args, Log) ->
    case os:type() of
        {unix, _} ->
            Sh = os:find_executable("sh"),
            ShArgs = ["-c", "exec \"$0\" \"$@\" 2>\"$WEBRTC_CODECS_CAPTURE_LOG\"", Ffmpeg | Args],
            Env = {env, [{"WEBRTC_CODECS_CAPTURE_LOG", unicode:characters_to_list(Log)}]},
            open_port({spawn_executable, Sh}, [{args, ShArgs}, Env, binary, stream, exit_status]);
        _ ->
            open_port({spawn_executable, Ffmpeg}, [{args, Args}, binary, stream, exit_status, hide])
    end.

-doc false.
handle_call(stats, _From, #st{count = Count, dropped = Dropped} = St) ->
    {reply, #{captured => Count, dropped => Dropped}, St}.

-doc false.
handle_cast(_Msg, St) ->
    {noreply, St}.

-doc false.
handle_info({Port, {data, Data}}, #st{port = Port, buffer = Buffer} = St) ->
    {noreply, deliver(<<Buffer/binary, Data/binary>>, St)};
handle_info({Port, {exit_status, Status}}, #st{port = Port, owner = Owner, log = Log} = St) ->
    Said =
        case file:read_file(Log) of
            {ok, Text} -> string:trim(Text);
            {error, _} -> <<>>
        end,
    Result =
        case {Status, Said} of
            {0, _} -> eof;
            _ -> {error, {ffmpeg, Status, Said}}
        end,
    Owner ! {webrtc_capture, self(), Result},
    {stop, normal, St};
handle_info({'DOWN', _, process, Owner, _}, #st{owner = Owner} = St) ->
    {stop, normal, St};
handle_info(_Info, St) ->
    {noreply, St}.

-doc false.
terminate(_Reason, #st{port = Port, log = Log}) ->
    close(Port),
    _ = file:delete(Log),
    ok.

%% The port may already be closed when FFmpeg ended by itself.
close(Port) ->
    try
        port_close(Port)
    catch
        error:badarg -> true
    end.

%% Cut what was read into pictures or chunks and send them, unless the
%% owner is behind.
deliver(Buffer, #st{size = Size} = St) when byte_size(Buffer) < Size ->
    St#st{buffer = Buffer};
deliver(
    Buffer, #st{size = Size, owner = Owner, count = Count, dropped = Dropped, opts = Opts} = St
) ->
    <<Chunk:Size/binary, Rest/binary>> = Buffer,
    Behind =
        case erlang:process_info(Owner, message_queue_len) of
            {message_queue_len, Len} -> Len > maps:get(max_queue, Opts);
            undefined -> true
        end,
    case Behind of
        true ->
            deliver(Rest, St#st{count = Count + 1, dropped = Dropped + 1});
        false ->
            Owner ! {webrtc_capture, self(), raw(Chunk, Count, St)},
            deliver(Rest, St#st{count = Count + 1})
    end.

%% Pictures are numbered in the 90 kHz clock from the rate asked for, so
%% a dropped picture leaves its place in the timestamps. Audio has no
%% timestamp: an encoder counts the samples it is given.
raw(Chunk, Count, #st{kind = video, opts = #{width := W, height := H, frame_rate := Fps}}) ->
    Luma = W * H,
    Chroma = Luma div 4,
    <<Y:Luma/binary, U:Chroma/binary, V:Chroma/binary>> = Chunk,
    #{
        format => i420,
        width => W,
        height => H,
        y => Y,
        u => U,
        v => V,
        timestamp => (Count * 90000 div Fps) band 16#FFFFFFFF
    };
raw(Chunk, _Count, #st{kind = audio, opts = #{sample_rate := Rate, channels := Channels}}) ->
    #{format => s16le, sample_rate => Rate, channels => Channels, samples => Chunk}.
