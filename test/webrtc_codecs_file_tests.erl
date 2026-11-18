-module(webrtc_codecs_file_tests).
-include_lib("eunit/include/eunit.hrl").

-define(F, webrtc_codecs_file).
-define(P, webrtc_codecs_pattern).

tmp(Extension) ->
    string:trim(os:cmd("mktemp")) ++ Extension.

%% Frames written come back with their timestamps and the header.
ivf_round_trip_test() ->
    File = tmp(".ivf"),
    Frames = [
        #{data => <<I, I, I>>, timestamp => I * 3000, keyframe => I =:= 0}
     || I <- lists:seq(0, 4)
    ],
    try
        ok = ?F:write_ivf(File, #{fourcc => <<"VP80">>, width => 320, height => 240}, Frames),
        {ok, #{
            fourcc := <<"VP80">>,
            width := 320,
            height := 240,
            time_base := {1, 90000},
            frames := Read
        }} =
            ?F:read_ivf(File),
        ?assertEqual([maps:with([data, timestamp], F) || F <- Frames], Read)
    after
        file:delete(File)
    end.

%% The corpus of erlang_webrtc reads as twelve frames of 176 x 144.
ivf_corpus_test() ->
    case webrtc_codecs_test_media:corpus("vp8.ivf") of
        false ->
            ok;
        Path ->
            {ok, #{fourcc := <<"VP80">>, width := 176, height := 144, frames := Frames}} = ?F:read_ivf(
                Path
            ),
            ?assertEqual(12, length(Frames)),
            ?assertEqual(webrtc_codecs_test_media:ivf(Path), [D || #{data := D} <- Frames])
    end.

%% FFmpeg reads the IVF we write from encoded frames.
ivf_for_ffmpeg_test_() ->
    case webrtc_codecs_vpx_nif:loaded() andalso os:find_executable("ffmpeg") =/= false of
        false ->
            {"skipped: needs libvpx and ffmpeg", []};
        true ->
            {timeout, 30, fun() ->
                {ok, St0} = webrtc_codecs_vpx:init(video, #{name => <<"VP8">>}, #{}),
                {Frames, _} = lists:mapfoldl(
                    fun(N, St) ->
                        {ok, [Frame], _, St1} = webrtc_codecs_vpx:encode(
                            ?P:picture(176, 144, N), St
                        ),
                        {Frame, St1}
                    end,
                    St0,
                    lists:seq(0, 9)
                ),
                File = tmp(".ivf"),
                try
                    ok = ?F:write_ivf(
                        File, #{fourcc => <<"VP80">>, width => 176, height => 144}, Frames
                    ),
                    Pictures = webrtc_codecs_test_media:reference(File, 176, 144),
                    ?assertEqual(10, length(Pictures)),
                    [
                        ?assert(?P:psnr(?P:picture(176, 144, N), Picture) > 30)
                     || {N, Picture} <- lists:enumerate(0, Pictures)
                    ]
                after
                    file:delete(File)
                end
            end}
    end.

ivf_errors_test() ->
    File = tmp(".ivf"),
    try
        ?assertEqual({error, enoent}, ?F:read_ivf("/nonexistent/file.ivf")),
        ok = ?F:write_ivf(File, #{fourcc => <<"VP80">>, width => 2, height => 2}, [
            #{data => <<1, 2, 3>>, timestamp => 0}
        ]),
        ?assertEqual({error, too_large}, ?F:read_ivf(File, #{max_bytes => 40})),
        ?assertMatch({ok, _}, ?F:read_ivf(File, #{max_bytes => 47})),
        ok = file:write_file(File, <<"RIFF and not IVF at all, but long enough to be one">>),
        ?assertEqual({error, not_ivf}, ?F:read_ivf(File)),
        ok = ?F:write_ivf(File, #{fourcc => <<"VP80">>, width => 2, height => 2}, [
            #{data => <<1, 2, 3>>, timestamp => 0}
        ]),
        {ok, Whole} = file:read_file(File),
        ok = file:write_file(File, binary:part(Whole, 0, byte_size(Whole) - 1)),
        ?assertEqual({error, truncated}, ?F:read_ivf(File))
    after
        file:delete(File)
    end.

wav_round_trip_test() ->
    File = tmp(".wav"),
    Format = #{sample_rate => 16000, channels => 2},
    Chunks = [maps:remove(timestamp, ?P:tone(440, 20, Format, I * 320)) || I <- lists:seq(0, 4)],
    try
        ok = ?F:write_wav(File, Chunks),
        {ok, #{format := s16le, sample_rate := 16000, channels := 2, samples := Pcm}} = ?F:read_wav(
            File
        ),
        ?assertEqual(iolist_to_binary([S || #{samples := S} <- Chunks]), Pcm),
        ok = ?F:write_wav(File, hd(Chunks)),
        ?assertEqual({ok, hd(Chunks)}, ?F:read_wav(File))
    after
        file:delete(File)
    end.

%% A WAV made by FFmpeg, which adds a LIST chunk before the data.
wav_from_ffmpeg_test_() ->
    case os:find_executable("ffmpeg") of
        false ->
            {"skipped: no ffmpeg", []};
        _ ->
            {timeout, 30, fun() ->
                File = tmp(".wav"),
                Cmd =
                    "ffmpeg -v error -y -f lavfi -i sine=frequency=440:sample_rate=8000 -t 0.5 -ac 1 '",
                "" = os:cmd(Cmd ++ File ++ "' 2>&1"),
                try
                    {ok, #{sample_rate := 8000, channels := 1, samples := Pcm}} = ?F:read_wav(File),
                    ?assertEqual(8000, byte_size(Pcm))
                after
                    file:delete(File)
                end
            end}
    end.

wav_errors_test() ->
    File = tmp(".wav"),
    Audio = ?P:tone(440, 20, #{sample_rate => 8000, channels => 1}, 0),
    try
        ?assertEqual({error, enoent}, ?F:read_wav("/nonexistent/file.wav")),
        ok = ?F:write_wav(File, Audio),
        ?assertEqual({error, too_large}, ?F:read_wav(File, #{max_bytes => 100})),
        ok = file:write_file(File, <<"DKIF is not a WAV">>),
        ?assertEqual({error, not_wav}, ?F:read_wav(File)),
        %% 8 bit PCM is not read.
        Fmt =
            <<1:16/little, 1:16/little, 8000:32/little, 8000:32/little, 1:16/little, 8:16/little>>,
        ok = file:write_file(
            File,
            <<"RIFF", 40:32/little, "WAVE", "fmt ", 16:32/little, Fmt/binary, "data", 4:32/little,
                1, 2, 3, 4>>
        ),
        ?assertEqual({error, unsupported_format}, ?F:read_wav(File)),
        ?assertEqual(
            {error, mixed_formats}, ?F:write_wav(File, [Audio, Audio#{sample_rate := 16000}])
        ),
        ?assertEqual({error, badarg}, ?F:write_wav(File, []))
    after
        file:delete(File)
    end.
