-module(webrtc_codecs_capture_devices).
-moduledoc false.

%% The cameras and microphones of this machine, for
%% webrtc_codecs_capture:devices/0. No system has a call for it that
%% FFmpeg exposes everywhere, so this reads what FFmpeg prints, and the
%% device files of cameras on Linux and the BSDs.

-export([list/1, resolve/4]).

%% The FFmpeg input devices for a microphone on Linux and the BSDs, in
%% the order they are tried.
-define(BACKENDS, [pulse, alsa, oss, sndio]).

-spec list(map()) ->
    {ok, #{video := [webrtc_codecs_capture:device()], audio := [webrtc_codecs_capture:device()]}}
    | {error, term()}.
list(Opts) ->
    maybe
        ok ?= valid(Opts),
        {ok, Ffmpeg} ?= ffmpeg(Opts),
        {ok, devices(os:type(), Ffmpeg, Opts)}
    end.

valid(Opts) ->
    case lists:member(maps:get(audio_backend, Opts, pulse), ?BACKENDS) of
        true -> ok;
        false -> {error, {badarg, maps:with([audio_backend], Opts)}}
    end.

ffmpeg(#{ffmpeg := Path}) ->
    {ok, Path};
ffmpeg(_Opts) ->
    case os:find_executable("ffmpeg") of
        false -> {error, no_ffmpeg};
        Path -> {ok, Path}
    end.

devices({unix, darwin}, Ffmpeg, _Opts) ->
    Out = run(Ffmpeg, ["-hide_banner", "-f", "avfoundation", "-list_devices", "true", "-i", ""]),
    avfoundation_devices(Out);
devices({unix, _}, Ffmpeg, Opts) ->
    Video = [
        #{index => list_to_integer(N), name => v4l2_name(N)}
     || "/dev/video" ++ N <- lists:sort(filelib:wildcard("/dev/video*")),
        N =/= "",
        lists:all(fun is_digit/1, N)
    ],
    #{video => Video, audio => sources(backend(Ffmpeg, Opts), Ffmpeg)};
%% Never run: Windows is not supported.
devices({win32, _}, Ffmpeg, _Opts) ->
    Out = run(Ffmpeg, ["-hide_banner", "-f", "dshow", "-list_devices", "true", "-i", "dummy"]),
    dshow_devices(Out).

%% What a capture needs to open a microphone on Linux and the BSDs: the
%% input device of FFmpeg, and the name of the source an index stands
%% for. Other sources and systems are left as they are.
-spec resolve(Source, {atom(), atom()}, file:filename_all(), map()) ->
    {ok, Source, map()} | {error, term()}
when
    Source :: term().
resolve({microphone, Device}, {unix, Os}, Ffmpeg, Opts) when
    Os =/= darwin andalso (is_integer(Device) andalso Device >= 0 orelse is_binary(Device))
->
    maybe
        ok ?= valid(Opts),
        Backend = backend(Ffmpeg, Opts),
        {ok, Name} ?= source_name(Device, Backend, Ffmpeg),
        {ok, {microphone, Name}, Opts#{audio_backend => Backend}}
    end;
resolve(Source, _Os, _Ffmpeg, Opts) ->
    {ok, Source, Opts}.

source_name(Name, _Backend, _Ffmpeg) when is_binary(Name) ->
    {ok, Name};
source_name(Index, Backend, Ffmpeg) ->
    case [Name || #{index := I, name := Name} <- sources(Backend, Ffmpeg), I =:= Index] of
        [Name] -> {ok, Name};
        [] -> {error, {no_device, {microphone, Index}}}
    end.

%% The first input device for audio this FFmpeg was built with. Lines
%% such as " D  alsa            ALSA audio input", the D for an input.
backend(_Ffmpeg, #{audio_backend := Backend}) ->
    Backend;
backend(Ffmpeg, _Opts) ->
    Out = run(Ffmpeg, ["-hide_banner", "-devices"]),
    Built = [
        Name
     || Line <- lines(Out),
        {match, [Name]} <- [
            re:run(Line, "^\\s*D[E.]?\\s+(?:d\\s+)?([a-z0-9_]+)\\s", [{capture, [1], binary}])
        ]
    ],
    case [B || B <- ?BACKENDS, lists:member(atom_to_binary(B), Built)] of
        [Backend | _] -> Backend;
        [] -> pulse
    end.

%% The sources of a backend, the default one first. FFmpeg lists them
%% for PulseAudio and ALSA, as lines such as
%% "* alsa_input.pci-0000_00_1f.3.analog-stereo [Built-in Audio]", the
%% star on the default. When it lists none (no sound server, a backend
%% it cannot list) the default source is the one entry.
sources(oss, _Ffmpeg) ->
    case lists:sort(filelib:wildcard("/dev/dsp*")) of
        [] -> [#{index => 0, name => <<"/dev/dsp">>}];
        Files -> [#{index => I, name => list_to_binary(F)} || {I, F} <- lists:enumerate(0, Files)]
    end;
sources(sndio, _Ffmpeg) ->
    [#{index => 0, name => <<"default">>}];
sources(Backend, Ffmpeg) ->
    Out = run(Ffmpeg, ["-hide_banner", "-sources", atom_to_list(Backend)]),
    Found = [
        {Star =/= <<"*">>, Name, Description}
     || Line <- lines(Out),
        {match, [Star, Name, Description]} <- [
            re:run(Line, "^([* ]) (\\S+) \\[(.*)\\](?: \\([a-z, ]*\\))?\\s*$", [
                {capture, [1, 2, 3], binary}, unicode
            ])
        ]
    ],
    case lists:keysort(1, Found) of
        [] ->
            [#{index => 0, name => <<"default">>}];
        Sorted ->
            [
                #{index => I, name => Name, description => Description}
             || {I, {_, Name, Description}} <- lists:enumerate(0, Sorted)
            ]
    end.

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
%% It is ended after ten seconds, whatever it is doing.
run(Exe, Args) ->
    {_Ended, Out} = webrtc_codecs_exec:run(Exe, Args, #{timeout => 10000, max_bytes => 1048576}),
    Out.
