-module(webrtc_codecs_capture_tests).
-include_lib("eunit/include/eunit.hrl").

-define(M, webrtc_codecs_capture).

%% Capture runs FFmpeg; its test sources stand in for a camera and a
%% microphone, so these run without a device.
capture_test_() ->
    case os:find_executable("ffmpeg") of
        false ->
            {"skipped: no ffmpeg", []};
        _ ->
            [
                %% What an earlier test left in the mailbox would count as a
                %% slow owner.
                {timeout, 30,
                    {Title, fun() ->
                        flush(),
                        Fun()
                    end}}
             || {Title, Fun} <- [
                    {"test pictures", fun pictures/0},
                    {"test audio", fun audio/0},
                    {"a file ends", fun file_ends/0},
                    {"a slow owner loses frames, not memory", fun slow_owner/0},
                    {"a missing file is an error", fun missing_file/0},
                    {"stops with its owner", fun stops_with_owner/0},
                    {"bad options", fun bad_options/0},
                    {"devices", fun devices/0},
                    {"microphones of a backend", fun microphones/0},
                    {"a microphone by its index", fun microphone_index/0},
                    {"encoded VP8", fun() -> encoded(vp8, "libvpx") end},
                    {"encoded VP9", fun() -> encoded(vp9, "libvpx-vp9") end},
                    {"encoded AV1", fun() -> encoded(av1, "libsvtav1") end},
                    {"encoded H.264", fun encoded_h264/0},
                    {"encoded frames dropped up to a key frame", fun encoded_slow_owner/0},
                    {"bad encode options", fun bad_encode/0},
                    {"bytes that are no stream end the capture", fun bad_header/0},
                    {"a program faster than the capture is held back", fun flood/0},
                    {"a program that will not end is killed", fun ignore_close/0},
                    {"what a program says is kept short", fun noisy/0},
                    {"a program that talks for ever is ended at the deadline", fun noisy_forever/0}
                ]
            ]
    end.

take(Pid, Count) ->
    [
        receive
            {webrtc_capture, Pid, Raw} -> Raw
        after 10000 -> error({timeout, I})
        end
     || I <- lists:seq(1, Count)
    ].

pictures() ->
    {ok, Pid} = ?M:start({test, video}, #{width => 160, height => 120, frame_rate => 30}),
    Pictures = take(Pid, 10),
    ?assertEqual([I * 3000 || I <- lists:seq(0, 9)], [T || #{timestamp := T} <- Pictures]),
    [
        ?assertMatch(
            #{
                format := i420,
                width := 160,
                height := 120,
                y := <<_:19200/binary>>,
                u := <<_:4800/binary>>,
                v := <<_:4800/binary>>
            },
            P
        )
     || P <- Pictures
    ],
    %% The test source moves.
    ?assertNotEqual(maps:get(y, hd(Pictures)), maps:get(y, lists:last(Pictures))),
    ?assertMatch(#{captured := C, dropped := 0} when C >= 10, ?M:stats(Pid)),
    ok = ?M:stop(Pid),
    ?assertNot(is_process_alive(Pid)).

audio() ->
    {ok, Pid} = ?M:start({test, audio}, #{sample_rate => 16000, channels => 2, frame_ms => 10}),
    Chunks = take(Pid, 10),
    [
        ?assertEqual(
            #{
                format => s16le,
                sample_rate => 16000,
                channels => 2,
                samples => maps:get(samples, C)
            },
            C
        )
     || C <- Chunks
    ],
    ?assert(lists:all(fun(#{samples := S}) -> byte_size(S) =:= 160 * 2 * 2 end, Chunks)),
    %% A tone, not silence.
    ?assert(lists:any(fun(#{samples := S}) -> S =/= binary:copy(<<0>>, byte_size(S)) end, Chunks)),
    ok = ?M:stop(Pid).

%% A file of five pictures gives them, then eof, and the process ends.
file_ends() ->
    File = string:trim(os:cmd("mktemp")) ++ ".y4m",
    "" = os:cmd(
        "ffmpeg -v error -y -f lavfi -i testsrc2=size=64x48:rate=10 -frames:v 5 -pix_fmt yuv420p '" ++
            File ++ "' 2>&1"
    ),
    try
        {ok, Pid} = ?M:start({file, video, File}, #{
            width => 64, height => 48, frame_rate => 10, realtime => false, max_queue => 100
        }),
        Ref = monitor(process, Pid),
        Pictures = take(Pid, 5),
        ?assertEqual([0, 9000, 18000, 27000, 36000], [T || #{timestamp := T} <- Pictures]),
        receive
            {webrtc_capture, Pid, eof} -> ok
        after 10000 -> error(no_eof)
        end,
        receive
            {'DOWN', Ref, process, Pid, normal} -> ok
        after 5000 -> error(still_alive)
        end
    after
        file:delete(File)
    end.

%% The owner reads nothing: its mailbox stays near max_queue and the
%% rest is counted as dropped.
slow_owner() ->
    {ok, Pid} = ?M:start({test, video}, #{
        width => 64, height => 48, frame_rate => 60, max_queue => 3
    }),
    captured(Pid, 21),
    #{captured := Captured, dropped := Dropped} = ?M:stats(Pid),
    {message_queue_len, Queued} = process_info(self(), message_queue_len),
    ok = ?M:stop(Pid),
    ?assert(Captured > 20),
    ?assert(Dropped > 0),
    ?assert(Queued =< 4),
    ?assertEqual(Captured, Dropped + Queued),
    flush().

missing_file() ->
    {ok, Pid} = ?M:start({file, audio, "/nonexistent/file.wav"}, #{}),
    receive
        {webrtc_capture, Pid, {error, {ffmpeg, Status, Said}}} ->
            ?assert(Status =/= 0),
            ?assertNotEqual(nomatch, binary:match(Said, <<"No such file">>))
    after 10000 -> error(no_error)
    end.

stops_with_owner() ->
    Parent = self(),
    Owner = spawn(fun() ->
        {ok, Pid} = ?M:start({test, video}, #{width => 64, height => 48}),
        unlink(Pid),
        Parent ! {capture, Pid},
        receive
            stop -> ok
        end
    end),
    Pid =
        receive
            {capture, P} -> P
        after 5000 -> error(not_started)
        end,
    Ref = monitor(process, Pid),
    Owner ! stop,
    receive
        {'DOWN', Ref, process, Pid, normal} -> ok
    after 5000 -> error(still_alive)
    end.

bad_options() ->
    process_flag(trap_exit, true),
    [
        ?assertMatch({error, {badarg, _}}, ?M:start(Source, Opts))
     || {Source, Opts} <- [
            {{test, video}, #{width => 161}},
            {{test, video}, #{frame_rate => 0}},
            {{test, audio}, #{sample_rate => 44100, frame_ms => 5, channels => 0}},
            {{test, audio}, #{sample_rate => 11025, frame_ms => 1}},
            {{screen, 0}, #{}},
            {{camera, -1}, #{}}
        ]
    ],
    process_flag(trap_exit, false),
    flush().

%% Listing asks nothing of the user; opening a device may, so it is not
%% done here.
devices() ->
    {ok, #{video := Video, audio := Audio}} = ?M:devices(),
    [
        ?assertMatch(#{index := I, name := <<_/binary>>} when is_integer(I), D)
     || D <- Video ++ Audio
    ].

%% On Linux and the BSDs the microphones are the sources of the first
%% audio input FFmpeg has, the default source first; with no listing
%% there is the default source alone.
microphones() ->
    Fake = fake_path(),
    List = fun(Opts) ->
        {ok, #{audio := Audio}} = webrtc_codecs_capture_devices:list(Opts#{ffmpeg => Fake}),
        Audio
    end,
    Two = [
        #{
            index => 0,
            name => <<"in.analog-stereo">>,
            description => <<"Built-in Audio [Analog] Stereo">>
        },
        #{index => 1, name => <<"out.monitor">>, description => <<"Monitor of Built-in Audio">>}
    ],
    Default = [#{index => 0, name => <<"default">>}],
    case os:type() of
        {unix, darwin} ->
            %% The listing of macOS is another one.
            ok;
        _ ->
            os:putenv("FAKE_FFMPEG_SOURCES", "two"),
            ?assertEqual(Two, List(#{audio_backend => alsa})),
            os:putenv("FAKE_FFMPEG_SOURCES", "none"),
            ?assertEqual(Default, List(#{audio_backend => pulse})),
            ?assertEqual(Default, List(#{audio_backend => sndio})),
            ?assertMatch(
                [#{index := 0, name := <<"/dev/dsp", _/binary>>} | _], List(#{audio_backend => oss})
            )
    end,
    ?assertEqual(
        {error, {badarg, #{audio_backend => jack}}},
        webrtc_codecs_capture_devices:list(#{ffmpeg => Fake, audio_backend => jack})
    ),
    os:unsetenv("FAKE_FFMPEG_SOURCES").

%% An index stands for a source of the listing, and the command names
%% the backend FFmpeg has.
microphone_index() ->
    Fake = fake_path(),
    Linux = {unix, linux},
    Input = fun(Device, Opts) ->
        maybe
            {ok, Source, Resolved} ?=
                webrtc_codecs_capture_devices:resolve({microphone, Device}, Linux, Fake, Opts),
            {ok, audio, Args} ?= webrtc_codecs_capture_command:input(Source, Linux, Resolved),
            Args
        end
    end,
    os:putenv("FAKE_FFMPEG_SOURCES", "two"),
    os:putenv("FAKE_FFMPEG_DEVICES", "alsa,oss"),
    ?assertEqual(["-f", "alsa", "-i", "in.analog-stereo"], Input(0, #{})),
    ?assertEqual(["-f", "alsa", "-i", "out.monitor"], Input(1, #{})),
    ?assertEqual({error, {no_device, {microphone, 2}}}, Input(2, #{})),
    ?assertEqual(["-f", "alsa", "-i", "hw:1"], Input(<<"hw:1">>, #{})),
    os:putenv("FAKE_FFMPEG_DEVICES", "sndio,alsa,pulse"),
    ?assertEqual(["-f", "pulse", "-i", "out.monitor"], Input(1, #{})),
    ?assertEqual(["-f", "sndio", "-i", "default"], Input(0, #{audio_backend => sndio})),
    %% An FFmpeg with none of them: PulseAudio is tried, as before.
    os:putenv("FAKE_FFMPEG_DEVICES", ""),
    ?assertEqual(["-f", "pulse", "-i", "in.analog-stereo"], Input(0, #{})),
    os:putenv("FAKE_FFMPEG_SOURCES", "none"),
    ?assertEqual(["-f", "pulse", "-i", "default"], Input(0, #{})),
    ?assertEqual({error, {no_device, {microphone, 1}}}, Input(1, #{})),
    ?assertEqual({error, {badarg, #{audio_backend => jack}}}, Input(0, #{audio_backend => jack})),
    %% A listing that does not end is ended, and what was read is used.
    os:putenv("FAKE_FFMPEG_SOURCES", "forever"),
    ?assertEqual(["-f", "alsa", "-i", "again"], Input(0, #{audio_backend => alsa})),
    %% macOS and the other sources are left as they are.
    ?assertEqual(
        {ok, {microphone, 1}, #{}},
        webrtc_codecs_capture_devices:resolve({microphone, 1}, {unix, darwin}, Fake, #{})
    ),
    ?assertEqual(
        {ok, {test, audio}, #{}},
        webrtc_codecs_capture_devices:resolve({test, audio}, Linux, Fake, #{})
    ),
    os:unsetenv("FAKE_FFMPEG_SOURCES"),
    os:unsetenv("FAKE_FFMPEG_DEVICES").

fake_path() ->
    filename:join([webrtc_codecs_test_media:root(), "test", "fake_ffmpeg.escript"]).

%% The encoders this FFmpeg has.
has_encoder(Name) ->
    Encoders = os:cmd("ffmpeg -hide_banner -encoders 2>/dev/null"),
    string:find(Encoders, " " ++ Name ++ " ") =/= nomatch.

%% FFmpeg captures and encodes: the frames come with timestamps in the
%% 90 kHz clock, start with a key frame, and decode with the plugin of
%% the codec when it is built.
encoded(Codec, Encoder) ->
    case has_encoder(Encoder) of
        false ->
            ok;
        true ->
            {ok, Pid} = ?M:start({test, video}, #{
                width => 160,
                height => 120,
                frame_rate => 30,
                encode => #{codec => Codec, bitrate => 300000}
            }),
            Frames = take(Pid, 10),
            ok = ?M:stop(Pid),
            ?assertEqual([I * 3000 || I <- lists:seq(0, 9)], [T || #{timestamp := T} <- Frames]),
            ?assertEqual([true | lists:duplicate(9, false)], [K || #{keyframe := K} <- Frames]),
            ?assert(
                lists:all(
                    fun(#{codec := C, data := D}) -> C =:= Codec andalso byte_size(D) > 0 end,
                    Frames
                )
            ),
            decodes(Codec, Frames)
    end.

decodes(Codec, Frames) ->
    {Mod, Name, Built} =
        case Codec of
            vp8 -> {webrtc_codecs_vpx, <<"VP8">>, webrtc_codecs_vpx_nif:loaded()};
            vp9 -> {webrtc_codecs_vpx, <<"VP9">>, webrtc_codecs_vpx_nif:loaded()};
            av1 -> {webrtc_codecs_av1, <<"AV1">>, webrtc_codecs_dav1d_nif:loaded()}
        end,
    case Built of
        true ->
            {ok, St} = Mod:init(video, #{name => Name}, #{}),
            {Pictures, _, _} = webrtc_codecs_test_media:decode_all(Mod, Frames, St),
            ?assertEqual(
                10, length([P || #{format := i420, width := 160, height := 120} = P <- Pictures])
            );
        false ->
            ok
    end.

%% H.264 comes as access units in Annex B, each starting with its
%% delimiter, the first holding the parameter sets and an IDR slice.
encoded_h264() ->
    Encoder =
        case os:type() of
            {unix, darwin} -> "h264_videotoolbox";
            _ -> "libopenh264"
        end,
    case has_encoder(Encoder) of
        false ->
            ok;
        true ->
            {ok, Pid} = ?M:start({test, video}, #{
                width => 320,
                height => 240,
                frame_rate => 30,
                encode => #{codec => h264, keyframe_interval => 5}
            }),
            Units = take(Pid, 10),
            ok = ?M:stop(Pid),
            ?assertEqual([I * 3000 || I <- lists:seq(0, 9)], [T || #{timestamp := T} <- Units]),
            ?assertEqual(
                [true, false, false, false, false, true, false, false, false, false], [
                    K
                 || #{keyframe := K} <- Units
                ]
            ),
            [
                begin
                    ?assertMatch(<<0, 0, 0, 1, 9, _/binary>>, Data),
                    %% One delimiter, so one access unit.
                    ?assertEqual(1, length(binary:matches(Data, <<0, 0, 1, 9>>)))
                end
             || #{codec := h264, data := Data} <- Units
            ],
            %% SPS (7) and PPS (8) come with the first key frame.
            Types = [T band 31 || T <- nal_types(maps:get(data, hd(Units)))],
            ?assert(
                lists:member(7, Types) andalso lists:member(8, Types) andalso lists:member(5, Types)
            )
    end.

nal_types(Data) ->
    [
        binary:at(Data, Pos + 3)
     || {Pos, 3} <- binary:matches(Data, <<0, 0, 1>>), Pos + 3 < byte_size(Data)
    ].

%% The owner reads nothing: frames are dropped, and what it finds
%% waiting starts with a key frame.
encoded_slow_owner() ->
    case has_encoder("libvpx") of
        false ->
            ok;
        true ->
            {ok, Pid} = ?M:start({test, video}, #{
                width => 64,
                height => 48,
                frame_rate => 60,
                max_queue => 3,
                encode => #{codec => vp8, keyframe_interval => 10}
            }),
            captured(Pid, 21),
            #{captured := Captured, dropped := Dropped} = ?M:stats(Pid),
            ?assert(Dropped > 0),
            %% What waits starts with a key frame, and a frame that is not
            %% one only ever follows the frame before it.
            Waiting = take(Pid, 4),
            ok = ?M:stop(Pid),
            ?assert(Captured > 20),
            ?assertMatch([#{keyframe := true} | _], Waiting),
            ?assert(
                lists:all(
                    fun({#{timestamp := T0}, #{timestamp := T1, keyframe := K}}) ->
                        K orelse T1 =:= T0 + 1500
                    end,
                    lists:zip(lists:droplast(Waiting), tl(Waiting))
                )
            )
    end.

bad_encode() ->
    process_flag(trap_exit, true),
    [
        ?assertMatch({error, {badarg, _}}, ?M:start(Source, #{encode => Encode}))
     || {Source, Encode} <- [
            {{test, video}, #{codec => h265}},
            {{test, video}, #{codec => vp8, bitrate => 0}},
            {{test, video}, #{codec => vp8, encoder => libvpx}},
            {{test, video}, vp8},
            {{test, audio}, #{codec => vp8}}
        ]
    ],
    process_flag(trap_exit, false),
    flush().

%% A capture of the program that stands in for FFmpeg, in a mode.
fake(Mode, Opts) ->
    Fake = filename:join([webrtc_codecs_test_media:root(), "test", "fake_ffmpeg.escript"]),
    PidFile = string:trim(os:cmd("mktemp")),
    {ok, Pid} = ?M:start({file, video, "none"}, Opts#{
        ffmpeg => Fake,
        width => 64,
        height => 48,
        input_options => ["-mode", Mode, "-pidfile", PidFile]
    }),
    {Pid, PidFile}.

%% The process id the program wrote, once it has.
os_pid(PidFile) -> os_pid(PidFile, 100).

os_pid(PidFile, Tries) ->
    case file:read_file(PidFile) of
        {ok, <<_, _/binary>> = Text} ->
            _ = file:delete(PidFile),
            binary_to_list(Text);
        _ when Tries > 0 ->
            timer:sleep(50),
            os_pid(PidFile, Tries - 1)
    end.

alive(OsPid) ->
    os:cmd("kill -0 " ++ OsPid ++ " 2>/dev/null && echo alive") =/= "".

gone(OsPid) -> gone(OsPid, 100).

gone(OsPid, Tries) ->
    case alive(OsPid) of
        false ->
            true;
        true when Tries > 0 ->
            timer:sleep(50),
            gone(OsPid, Tries - 1);
        true ->
            false
    end.

%% An encoded capture whose program writes something else: an error as
%% soon as there is enough to tell, not a buffer that grows.
bad_header() ->
    {Pid, PidFile} = fake("bad_header", #{encode => #{codec => vp8}}),
    Ref = monitor(process, Pid),
    receive
        {webrtc_capture, Pid, Result} -> ?assertEqual({error, bad_stream}, Result)
    after 10000 -> error(no_error)
    end,
    receive
        {'DOWN', Ref, process, Pid, normal} -> ok
    after 10000 -> error(still_alive)
    end,
    ?assert(gone(os_pid(PidFile))).

%% The program writes as fast as it is read and the owner reads nothing:
%% the capture drops, and neither its mailbox nor its memory grows.
flood() ->
    {Pid, PidFile} = fake("flood", #{max_queue => 3}),
    OsPid = os_pid(PidFile),
    captured(Pid, 1001),
    %% Everything past the few the owner has waiting was dropped.
    timer:sleep(100),
    #{captured := Captured, dropped := Dropped} = ?M:stats(Pid),
    {message_queue_len, Queued} = process_info(Pid, message_queue_len),
    {memory, Memory} = process_info(Pid, memory),
    ok = ?M:stop(Pid),
    ?assert(Captured > 1000),
    ?assert(Dropped > 1000),
    ?assert(Queued =< 2),
    ?assert(Memory < 8 * 1024 * 1024),
    ?assert(gone(OsPid)),
    flush().

%% The program connects, writes nothing and ignores being asked to end:
%% stop/1 returns, and the program is gone.
ignore_close() ->
    {Pid, PidFile} = fake("ignore_close", #{}),
    OsPid = os_pid(PidFile),
    timer:sleep(300),
    ?assert(alive(OsPid)),
    T0 = erlang:monotonic_time(millisecond),
    ok = ?M:stop(Pid),
    ?assert(erlang:monotonic_time(millisecond) - T0 < 8000),
    ?assertNot(alive(OsPid)).

%% 200 kB of messages, then a failure: the owner gets the end of them.
noisy() ->
    {Pid, _} = fake("noisy", #{}),
    receive
        {webrtc_capture, Pid, {error, {ffmpeg, 3, Said}}} ->
            ?assert(byte_size(Said) =< 4096),
            ?assertNotEqual(nomatch, binary:match(Said, <<"line 8000 of what went wrong">>))
    after 20000 -> error(no_error)
    end.

%% What device listing relies on: a program that never stops talking is
%% ended at the deadline, and what is kept of its output is capped.
noisy_forever() ->
    Fake = filename:join([webrtc_codecs_test_media:root(), "test", "fake_ffmpeg.escript"]),
    PidFile = string:trim(os:cmd("mktemp")),
    T0 = erlang:monotonic_time(millisecond),
    {Ended, Out} = webrtc_codecs_exec:run(Fake, ["-mode", "noisy_forever", "-pidfile", PidFile], #{
        timeout => 1500, max_bytes => 10000
    }),
    Elapsed = erlang:monotonic_time(millisecond) - T0,
    ?assertMatch({killed, _}, Ended),
    ?assertEqual(10000, byte_size(Out)),
    ?assert(Elapsed >= 1500 andalso Elapsed < 7000),
    ?assertNot(alive(os_pid(PidFile))).

%% Wait until the capture has read that many, however long its program
%% takes to start on this machine.
captured(Pid, Count) -> captured(Pid, Count, erlang:monotonic_time(millisecond) + 30000).

captured(Pid, Count, Deadline) ->
    case ?M:stats(Pid) of
        #{captured := Captured} when Captured >= Count ->
            ok;
        _ ->
            ?assert(erlang:monotonic_time(millisecond) < Deadline),
            timer:sleep(50),
            captured(Pid, Count, Deadline)
    end.

flush() ->
    receive
        _ -> flush()
    after 0 -> ok
    end.
