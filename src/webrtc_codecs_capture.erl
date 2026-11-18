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

-export([devices/0, start/2, stop/1, stats/1]).
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
    ffmpeg => file:filename_all()
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

-type device() :: #{index := non_neg_integer(), name := binary()}.

-record(st, {
    port :: port(),
    owner :: pid(),
    kind :: video | audio,
    opts :: map(),
    %% How the output of FFmpeg is cut: raw media in chunks of `size`
    %% bytes, an IVF stream (its header first, then frames whose
    %% timestamps count in units of Num/Den seconds), or H.264 access
    %% units that each start with a delimiter.
    format = raw :: raw | ivf_header | {ivf, pos_integer(), pos_integer()} | annexb,
    codec :: undefined | vp8 | vp9 | av1 | h264,
    %% Bytes of one picture or one chunk of audio.
    size :: pos_integer(),
    %% An encoded frame was dropped: those after it are of no use until
    %% a key frame.
    skip = false :: boolean(),
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
        {ok, Kind, Input} ?= input(Source, os:type(), Opts),
        Log = filename:join(
            tmp_dir(),
            "webrtc_codecs_capture-" ++ integer_to_list(erlang:unique_integer([positive]))
        ),
        {ok, Format, Codec, Output} ?= output(Kind, maps:get(encode, Opts, undefined), Opts),
        Args = ["-nostdin", "-hide_banner", "-loglevel", "error"] ++ Input ++ Output,
        %% FFmpeg ending is told to the owner, not a reason to die.
        process_flag(trap_exit, true),
        Port = open(Ffmpeg, Args, Log),
        Owner = maps:get(owner, Opts),
        _ = monitor(process, Owner),
        {ok, #st{
            port = Port,
            owner = Owner,
            kind = Kind,
            opts = Opts,
            format = Format,
            codec = Codec,
            size = size(Kind, Opts),
            log = Log
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

%% What FFmpeg writes to its standard output, and how it is cut: planes
%% or samples, or with `encode` an encoded stream.
output(Kind, undefined, Opts) ->
    {ok, raw, undefined, raw_output(Kind, Opts)};
output(video, #{codec := Codec} = Encode, Opts) when
    Codec =:= vp8; Codec =:= vp9; Codec =:= av1; Codec =:= h264
->
    Bitrate = maps:get(bitrate, Encode, 1000000),
    Interval = maps:get(keyframe_interval, Encode, 60),
    Encoder = maps:get(encoder, Encode, default_encoder(Codec, os:type())),
    Tuning = maps:get(encoder_options, Encode, encoder_options(Encoder)),
    Valid =
        is_integer(Bitrate) andalso Bitrate > 0 andalso is_integer(Interval) andalso Interval > 0 andalso
            is_list(Encoder) andalso is_list(Tuning),
    case Valid of
        true ->
            Rate = ["-b:v", integer_to_list(Bitrate), "-g", integer_to_list(Interval), "-bf", "0"],
            {Format, Container} = container(Codec),
            Args =
                picture_output(Opts) ++ ["-c:v", Encoder] ++ Tuning ++ Rate ++
                    Container,
            {ok, Format, Codec, Args ++ ["pipe:1"]};
        false ->
            {error, {badarg, Encode}}
    end;
output(_Kind, Encode, _Opts) ->
    {error, {badarg, {encode, Encode}}}.

raw_output(video, Opts) ->
    picture_output(Opts) ++ ["-f", "rawvideo", "pipe:1"];
raw_output(audio, #{sample_rate := Rate, channels := Channels}) ->
    Format = ["-ac", integer_to_list(Channels), "-ar", integer_to_list(Rate)],
    ["-map", "0:a:0", "-vn"] ++ Format ++ ["-f", "s16le", "pipe:1"].

%% The first video stream, as 4:2:0 pictures of the size and rate asked for.
picture_output(#{frame_rate := Fps} = Opts) ->
    Format = ["-pix_fmt", "yuv420p", "-s", picture_size(Opts), "-r", integer_to_list(Fps)],
    ["-map", "0:v:0", "-an"] ++ Format.

default_encoder(vp8, _Os) -> "libvpx";
default_encoder(vp9, _Os) -> "libvpx-vp9";
default_encoder(av1, _Os) -> "libsvtav1";
default_encoder(h264, {unix, darwin}) -> "h264_videotoolbox";
default_encoder(h264, _Os) -> "libopenh264".

%% Real time settings of the encoders named above; none for another one.
encoder_options("libvpx") ->
    ["-deadline", "realtime", "-cpu-used", "8", "-lag-in-frames", "0"];
encoder_options("libvpx-vp9") ->
    ["-deadline", "realtime", "-cpu-used", "8", "-lag-in-frames", "0", "-row-mt", "1"];
encoder_options("libsvtav1") ->
    ["-preset", "10", "-svtav1-params", "pred-struct=1:rc=2"];
encoder_options("h264_videotoolbox") ->
    ["-realtime", "1", "-profile:v", "constrained_baseline"];
encoder_options("libopenh264") ->
    ["-profile:v", "constrained_baseline"];
encoder_options(_Encoder) ->
    [].

%% VP8, VP9 and AV1 come as IVF, which frames them and carries their
%% timestamps. H.264 comes in Annex B with a delimiter before each
%% access unit, which is what separates them.
%% Each frame is written as soon as it is made, not when a buffer fills.
container(h264) ->
    {annexb, ["-bsf:v", "h264_metadata=aud=insert", "-flush_packets", "1", "-f", "h264"]};
container(_Codec) ->
    {ivf_header, ["-flush_packets", "1", "-f", "ivf"]}.

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
handle_info({Port, {data, Data}}, #st{port = Port, owner = Owner, buffer = Buffer} = St) ->
    case deliver(<<Buffer/binary, Data/binary>>, St) of
        #st{} = St1 ->
            {noreply, St1};
        bad_stream ->
            %% What FFmpeg writes is not the stream that was asked for.
            Owner ! {webrtc_capture, self(), {error, bad_stream}},
            {stop, normal, St}
    end;
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
handle_info({'EXIT', Port, Reason}, #st{port = Port, owner = Owner} = St) when Reason =/= normal ->
    Owner ! {webrtc_capture, self(), {error, {port, Reason}}},
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

%% An encoded frame larger than this is not one: the stream is not what
%% it should be.
-define(MAX_FRAME, 8 * 1024 * 1024).

%% Cut what was read into pictures, chunks or encoded frames and send
%% them, unless the owner is behind.
deliver(Buffer, #st{format = raw, size = Size} = St) when byte_size(Buffer) >= Size ->
    <<Chunk:Size/binary, Rest/binary>> = Buffer,
    #st{count = Count, dropped = Dropped} = St,
    case behind(St) of
        true ->
            deliver(Rest, St#st{count = Count + 1, dropped = Dropped + 1});
        false ->
            St#st.owner ! {webrtc_capture, self(), raw(Chunk, Count, St)},
            deliver(Rest, St#st{count = Count + 1})
    end;
deliver(
    <<"DKIF", _:12/binary, Den:32/little, Num:32/little, _:64, Rest/binary>>,
    #st{format = ivf_header} = St
) ->
    deliver(Rest, St#st{format = {ivf, max(Num, 1), max(Den, 1)}});
deliver(
    <<Size:32/little, Pts:64/little, Data:Size/binary, Rest/binary>>,
    #st{format = {ivf, Num, Den}} = St
) ->
    Ts = (Pts * 90000 * Num div Den) band 16#FFFFFFFF,
    deliver(Rest, encoded(Data, Ts, St));
deliver(<<Size:32/little, _/binary>>, #st{format = {ivf, _, _}}) when Size > ?MAX_FRAME ->
    bad_stream;
deliver(Buffer, #st{format = annexb, count = Count, opts = #{frame_rate := Fps}} = St) ->
    %% An access unit ends where the delimiter of the next one starts:
    %% a start code and a NAL unit of type 9, looked for past the unit's
    %% own. A start code of four bytes begins one byte earlier.
    case
        byte_size(Buffer) > 8 andalso
            binary:match(Buffer, <<0, 0, 1, 9>>, [{scope, {4, byte_size(Buffer) - 4}}])
    of
        {Found, _} ->
            Pos =
                case binary:at(Buffer, Found - 1) of
                    0 -> Found - 1;
                    _ -> Found
                end,
            <<Unit:Pos/binary, Rest/binary>> = Buffer,
            Ts = (Count * 90000 div Fps) band 16#FFFFFFFF,
            deliver(Rest, encoded(Unit, Ts, St));
        _ when byte_size(Buffer) > ?MAX_FRAME ->
            bad_stream;
        _ ->
            St#st{buffer = Buffer}
    end;
deliver(Buffer, St) ->
    St#st{buffer = Buffer}.

behind(#st{owner = Owner, opts = Opts}) ->
    case erlang:process_info(Owner, message_queue_len) of
        {message_queue_len, Len} -> Len > maps:get(max_queue, Opts);
        undefined -> true
    end.

%% Send an encoded frame. After one is dropped, the frames that depend
%% on it are dropped too, up to the next key frame.
encoded(Data, Ts, #st{codec = Codec, count = Count, dropped = Dropped, skip = Skip} = St) ->
    Key = keyframe(Codec, Data),
    case behind(St) orelse (Skip andalso not Key) of
        true ->
            St#st{count = Count + 1, dropped = Dropped + 1, skip = true};
        false ->
            St#st.owner !
                {webrtc_capture, self(), #{
                    codec => Codec, data => Data, timestamp => Ts, keyframe => Key
                }},
            St#st{count = Count + 1, skip = false}
    end.

keyframe(av1, Data) ->
    webrtc_codecs_av1:frame_info(av1, Data) =:= key;
keyframe(h264, Data) ->
    %% An IDR slice: NAL unit type 5, whatever its reference bits.
    binary:match(Data, [<<0, 0, 1, 16#65>>, <<0, 0, 1, 16#45>>, <<0, 0, 1, 16#25>>]) =/= nomatch;
keyframe(Codec, Data) ->
    case webrtc_codecs_vpx:frame_size(Codec, Data) of
        {key, _, _} -> true;
        _ -> false
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
