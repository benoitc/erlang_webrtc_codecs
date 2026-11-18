-module(webrtc_codecs_playback_tests).
-include_lib("eunit/include/eunit.hrl").

-define(M, webrtc_codecs_playback).
-define(P, webrtc_codecs_pattern).

%% Sinks run FFmpeg. Files are checked here; the window and the speaker
%% need a person to look and listen.
playback_test_() ->
    case os:find_executable("ffmpeg") of
        false ->
            {"skipped: no ffmpeg", []};
        _ ->
            [
                {timeout, 60, {Title, Fun}}
             || {Title, Fun} <- [
                    {"pictures to a lossless file and back", fun pictures_to_file/0},
                    {"pictures to a compressed file", fun pictures_to_mkv/0},
                    {"audio to a file and back", fun audio_to_file/0},
                    {"another format is refused", fun bad_format/0},
                    {"FFmpeg ending by itself is told", fun ended/0},
                    {"bad options", fun bad_options/0}
                ]
            ]
    end.

tmp(Extension) ->
    string:trim(os:cmd("mktemp")) ++ Extension.

%% What a file holds, read back through capture.
read_back(Kind, File, Opts, Count) ->
    {ok, Pid} = webrtc_codecs_capture:start({file, Kind, File}, Opts#{
        realtime => false, max_queue => 1000
    }),
    Raws = [
        receive
            {webrtc_capture, Pid, #{format := _} = Raw} -> Raw
        after 10000 -> error({timeout, I})
        end
     || I <- lists:seq(1, Count)
    ],
    receive
        {webrtc_capture, Pid, eof} -> Raws
    after 10000 -> error(no_eof)
    end.

%% Every picture given is in the file when stop/1 returns, sample for sample.
pictures_to_file() ->
    File = tmp(".y4m"),
    Pictures = [?P:picture(64, 48, N) || N <- lists:seq(0, 29)],
    try
        {ok, Sink} = ?M:start({file, video, File}, #{width => 64, height => 48, frame_rate => 30}),
        [?assertEqual(ok, ?M:play(Sink, P)) || P <- Pictures],
        ?assertEqual(#{played => 30, dropped => 0}, ?M:stats(Sink)),
        ok = ?M:stop(Sink),
        Read = read_back(video, File, #{width => 64, height => 48, frame_rate => 30}, 30),
        ?assertEqual(
            [maps:with([y, u, v], P) || P <- Pictures], [maps:with([y, u, v], P) || P <- Read]
        )
    after
        file:delete(File)
    end.

%% FFmpeg picks the container from the extension and the codec from the options.
pictures_to_mkv() ->
    File = tmp(".mkv"),
    Pictures = [?P:picture(176, 144, N) || N <- lists:seq(0, 14)],
    try
        {ok, Sink} = ?M:start({file, video, File}, #{
            width => 176,
            height => 144,
            frame_rate => 30,
            output_options => ["-c:v", "mpeg4", "-q:v", "2"]
        }),
        [ok = ?M:play(Sink, P) || P <- Pictures],
        ok = ?M:stop(Sink),
        Read = read_back(video, File, #{width => 176, height => 144, frame_rate => 30}, 15),
        [?assert(?P:psnr(Sent, Got) > 30) || {Sent, Got} <- lists:zip(Pictures, Read)]
    after
        file:delete(File)
    end.

audio_to_file() ->
    File = tmp(".wav"),
    Format = #{sample_rate => 16000, channels => 2},
    Chunks = [?P:tone(440, 20, Format, I * 320) || I <- lists:seq(0, 24)],
    try
        {ok, Sink} = ?M:start({file, audio, File}, Format),
        [ok = ?M:play(Sink, C) || C <- Chunks],
        %% More than a second at once is refused, and nothing of it is written.
        ?assertEqual({error, bad_format}, ?M:play(Sink, ?P:tone(440, 1020, Format, 0))),
        ok = ?M:stop(Sink),
        {ok, #{sample_rate := 16000, channels := 2, samples := Pcm}} = webrtc_codecs_file:read_wav(
            File
        ),
        ?assertEqual(iolist_to_binary([S || #{samples := S} <- Chunks]), Pcm)
    after
        file:delete(File)
    end.

bad_format() ->
    File = tmp(".y4m"),
    try
        {ok, Sink} = ?M:start({file, video, File}, #{width => 64, height => 48}),
        ?assertEqual({error, bad_format}, ?M:play(Sink, ?P:picture(32, 32, 0))),
        ?assertEqual({error, bad_format}, ?M:play(Sink, (?P:picture(64, 48, 0))#{u := <<>>})),
        ?assertEqual(
            {error, bad_format},
            ?M:play(Sink, ?P:tone(440, 20, #{sample_rate => 8000, channels => 1}, 0))
        ),
        ?assertEqual({error, bad_format}, ?M:play(Sink, picture)),
        ?assertEqual(#{played => 0, dropped => 0}, ?M:stats(Sink)),
        ok = ?M:stop(Sink),
        ?assertEqual({error, closed}, ?M:play(Sink, ?P:picture(64, 48, 0)))
    after
        file:delete(File)
    end.

%% A file that cannot be written: play/2 says what FFmpeg said.
ended() ->
    {ok, Sink} = ?M:start({file, video, "/nonexistent/dir/out.y4m"}, #{width => 64, height => 48}),
    Picture = ?P:picture(64, 48, 0),
    Result = until_ended(Sink, Picture, 200),
    ?assertMatch({error, {ended, Status, <<_/binary>>}} when Status =/= 0, Result),
    {error, {ended, _, Said}} = Result,
    ?assertNotEqual(nomatch, binary:match(Said, <<"No such file">>)),
    ok = ?M:stop(Sink).

until_ended(_Sink, _Picture, 0) ->
    timeout;
until_ended(Sink, Picture, Tries) ->
    case ?M:play(Sink, Picture) of
        {error, {ended, _, _}} = Ended ->
            Ended;
        _ ->
            timer:sleep(20),
            until_ended(Sink, Picture, Tries - 1)
    end.

bad_options() ->
    process_flag(trap_exit, true),
    [
        ?assertMatch({error, {badarg, _}}, ?M:start(Sink, Opts))
     || {Sink, Opts} <- [
            {window, #{width => 33}},
            {speaker, #{channels => 3}},
            {{file, video, "x.y4m"}, #{frame_rate => 0}},
            {{file, text, "x.txt"}, #{}},
            {printer, #{}}
        ]
    ],
    process_flag(trap_exit, false).
