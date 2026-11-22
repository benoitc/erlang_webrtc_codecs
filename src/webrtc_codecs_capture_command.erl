-module(webrtc_codecs_capture_command).
-moduledoc false.

%% The command line of FFmpeg for webrtc_codecs_capture: what it reads
%% (a device as each system names it, a file, a generated source) and
%% what it writes (raw planes or samples, or an encoded stream), without
%% where it writes it, which the capture process adds.

-export([input/3, output/3]).

-export_type([format/0]).

%% How what FFmpeg writes is cut, see webrtc_codecs_capture_stream.
-type format() :: raw | ivf_header | annexb.

-spec input(webrtc_codecs_capture:source(), {atom(), atom()}, map()) ->
    {ok, video | audio, [string()]} | {error, term()}.
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
    device(audio, [], microphone_input(Os, Device, Opts), Opts);
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
%% On Linux and the BSDs a camera index is a /dev/video number. The
%% Windows clauses were never run: Windows is not supported.
device_input({unix, darwin}, video, Device) ->
    {"avfoundation", device_name(Device) ++ ":none"};
device_input({win32, _}, Kind, Device) ->
    {"dshow", atom_to_list(Kind) ++ "=" ++ device_name(Device)};
device_input(_, video, Device) when is_integer(Device) ->
    {"v4l2", "/dev/video" ++ device_name(Device)};
device_input(_, video, Device) ->
    {"v4l2", device_name(Device)}.

%% On Linux and the BSDs the capture process has put the input device
%% of FFmpeg in `audio_backend` and a name in place of an index
%% (webrtc_codecs_capture_devices:resolve/4). An index left here means
%% the default source.
microphone_input({unix, darwin}, Device, _Opts) ->
    {"avfoundation", "none:" ++ device_name(Device)};
microphone_input({win32, _} = Os, Device, _Opts) ->
    device_input(Os, audio, Device);
microphone_input(_Os, Device, Opts) ->
    Backend = maps:get(audio_backend, Opts, pulse),
    Name =
        case Device of
            _ when is_binary(Device) -> device_name(Device);
            _ when Backend =:= oss -> "/dev/dsp";
            _ -> "default"
        end,
    {atom_to_list(Backend), Name}.

device_name(Index) when is_integer(Index) -> integer_to_list(Index);
device_name(Name) -> unicode:characters_to_list(Name).

-spec output(video | audio, undefined | webrtc_codecs_capture:encode() | term(), map()) ->
    {ok, format(), undefined | vp8 | vp9 | av1 | h264, [string()]} | {error, term()}.
%% What FFmpeg writes, up to where it writes it, and how it is cut:
%% planes or samples, or with `encode` an encoded stream.
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
            {ok, Format, Codec, Args};
        false ->
            {error, {badarg, Encode}}
    end;
output(_Kind, Encode, _Opts) ->
    {error, {badarg, {encode, Encode}}}.

raw_output(video, Opts) ->
    picture_output(Opts) ++ ["-f", "rawvideo"];
raw_output(audio, #{sample_rate := Rate, channels := Channels}) ->
    Format = ["-ac", integer_to_list(Channels), "-ar", integer_to_list(Rate)],
    ["-map", "0:a:0", "-vn"] ++ Format ++ ["-f", "s16le"].

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
