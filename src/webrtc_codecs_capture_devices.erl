-module(webrtc_codecs_capture_devices).
-moduledoc false.

%% The cameras and microphones of this machine, for
%% webrtc_codecs_capture:devices/0. No system has a call for it that
%% FFmpeg exposes everywhere, so this reads what FFmpeg prints on macOS
%% and Windows, and the device files on the other systems.

-export([list/0]).

-spec list() ->
    {ok, #{video := [webrtc_codecs_capture:device()], audio := [webrtc_codecs_capture:device()]}}
    | {error, term()}.
list() ->
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
%% It is ended after ten seconds, whatever it is doing.
run(Exe, Args) ->
    {_Ended, Out} = webrtc_codecs_exec:run(Exe, Args, #{timeout => 10000, max_bytes => 1048576}),
    Out.
