%% The plugins inside erlang_webrtc: two peer connections on loopback,
%% one encoding with send_media/3, the other decoding what it receives.
-module(webrtc_codecs_peer_SUITE).
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([
    pcmu/1,
    pcma/1,
    opus/1,
    vp8/1,
    vp9/1,
    av1/1,
    h264/1,
    h264_mode_0/1,
    control/1,
    without_rtx/1,
    capture/1,
    capture_encoded/1
]).

all() ->
    [
        pcmu,
        pcma,
        opus,
        vp8,
        vp9,
        av1,
        h264,
        h264_mode_0,
        control,
        without_rtx,
        capture,
        capture_encoded
    ].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(webrtc),
    Config.

end_per_suite(_Config) ->
    ok.

pcmu(_Config) ->
    {Sent, Received} = audio(<<"PCMU">>, 8000, <<"webrtc_codecs G.711">>, 64000),
    ?assert(webrtc_codecs_pattern:snr(Sent, Received) > 30).

pcma(_Config) ->
    {Sent, Received} = audio(<<"PCMA">>, 8000, <<"webrtc_codecs G.711">>, 64000),
    ?assert(webrtc_codecs_pattern:snr(Sent, Received) > 30).

%% Opus is what two peers negotiate by default. The encoder is told the
%% bitrate before the first samples.
opus(_Config) ->
    case webrtc_codecs_opus_nif:loaded() of
        true ->
            _ = audio(<<"opus">>, 48000, webrtc_codecs_opus_nif:version(), 24000),
            ok;
        false ->
            {skip, "built without libopus"}
    end.

%% A sends a second of tone in 20 ms frames with send_media/3; B decodes
%% as many samples with the same timestamps, and both report the
%% plugin's members. Returns the audio sent and received.
audio(Name, Rate, Implementation, Bitrate) ->
    Plugin = {webrtc_codecs, #{}},
    Codecs = #{
        audio => [C || #{name := N} = C <- webrtc:default_codecs(audio), N =:= Name]
    },
    {ok, A} = webrtc:new_peer_connection(#{loopback => true, codecs => Codecs}),
    {ok, B} = webrtc:new_peer_connection(#{
        loopback => true, codecs => Codecs, frames => true, codec_plugins => #{audio => Plugin}
    }),
    {ok, _} = webrtc:add_transceiver(A, audio, #{frames => true, codec_plugin => Plugin}),
    ok = connect(A, B),
    Format = #{sample_rate => Rate, channels => 1},
    Frame = Rate div 50,
    Count = 50,
    ok = webrtc:send_media(A, <<"0">>, #{bitrate => Bitrate}),
    [
        begin
            ok = webrtc:send_media(
                A, <<"0">>, webrtc_codecs_pattern:tone(440, 20, Format, I * Frame)
            ),
            timer:sleep(20)
        end
     || I <- lists:seq(0, Count - 1)
    ],
    Decoded = collect(
        B,
        fun
            ({decoded, <<"0">>, _}) -> true;
            (_) -> false
        end,
        Count,
        5000
    ),
    ?assertEqual(
        [I * Frame || I <- lists:seq(0, Count - 1)],
        [
            T
         || {decoded, _, #{sample_rate := R, channels := 1, timestamp := T}} <- Decoded, R =:= Rate
        ]
    ),
    Received = #{samples => iolist_to_binary([S || {decoded, _, #{samples := S}} <- Decoded])},
    ?assertEqual(Count * Frame * 2, byte_size(maps:get(samples, Received))),
    timer:sleep(200),
    [#{targetBitrate := Bitrate, encoderImplementation := Implementation}] =
        [
            O
         || _ := #{type := <<"outbound-rtp">>, kind := <<"audio">>} = O <- webrtc:get_stats(A, #{
                format => w3c
            })
        ],
    Total = Count * Frame,
    [#{totalSamplesReceived := Total, decoderImplementation := Implementation}] =
        [
            O
         || _ := #{type := <<"inbound-rtp">>, kind := <<"audio">>} = O <- webrtc:get_stats(B, #{
                format => w3c
            })
        ],
    ok = webrtc:close(A),
    ok = webrtc:close(B),
    {webrtc_codecs_pattern:tone(440, 20 * Count, Format, 0), Received}.

vp8(_Config) -> vpx(<<"VP8">>).

vp9(_Config) -> vpx(<<"VP9">>).

vpx(Name) ->
    case webrtc_codecs_vpx_nif:loaded() of
        true ->
            Implementation = <<"libvpx ", (webrtc_codecs_vpx_nif:version())/binary>>,
            video(Name, Implementation, Implementation);
        false ->
            {skip, "built without libvpx"}
    end.

h264(_Config) ->
    case webrtc_codecs_openh264_nif:loaded() of
        true ->
            Implementation = <<"OpenH264 ", (webrtc_codecs_openh264_nif:version())/binary>>,
            video(<<"H264">>, Implementation, Implementation);
        false ->
            {skip, "built without OpenH264"}
    end.

av1(_Config) ->
    case webrtc_codecs_aom_nif:loaded() andalso webrtc_codecs_dav1d_nif:loaded() of
        true ->
            video(
                <<"AV1">>,
                <<"libaom ", (webrtc_codecs_aom_nif:version())/binary>>,
                <<"dav1d ", (webrtc_codecs_dav1d_nif:version())/binary>>
            );
        false ->
            {skip, "built without libaom or dav1d"}
    end.

%% With packetization-mode=0 a packet holds one NAL unit and
%% erlang_webrtc refuses a frame with a larger one: the encoder has to
%% cut its pictures to fit, or nothing is sent.
h264_mode_0(_Config) ->
    case webrtc_codecs_openh264_nif:loaded() of
        true ->
            Implementation = <<"OpenH264 ", (webrtc_codecs_openh264_nif:version())/binary>>,
            Mode0 = fun
                (#{name := <<"H264">>, fmtp := Fmtp} = Codec) ->
                    Codec#{
                        fmtp := lists:keystore(
                            <<"packetization-mode">>,
                            1,
                            Fmtp,
                            {<<"packetization-mode">>, <<"0">>}
                        )
                    };
                (Codec) ->
                    Codec
            end,
            video(<<"H264">>, Implementation, Implementation, Mode0, {1280, 720});
        false ->
            {skip, "built without OpenH264"}
    end.

%% A encodes a second of the test pattern with send_media/3; B decodes
%% every picture, close to what was sent, and the frames encoded and
%% decoded agree in the statistics of both.
video(Name, Encoder, Decoder) ->
    video(Name, Encoder, Decoder, fun(Codec) -> Codec end, {320, 240}).

%% The same, the negotiated codec changed by Change first, with pictures
%% of that size.
video(Name, Encoder, Decoder, Change, {W, H}) ->
    Plugin = {webrtc_codecs, #{bitrate => 400000}},
    Codecs = #{video => [Change(C) || C <- only(Name, webrtc:default_codecs(video))]},
    {ok, A} = webrtc:new_peer_connection(#{loopback => true, codecs => Codecs}),
    {ok, B} = webrtc:new_peer_connection(#{
        loopback => true, codecs => Codecs, frames => true, codec_plugins => #{video => Plugin}
    }),
    {ok, _} = webrtc:add_transceiver(A, video, #{frames => true, codec_plugin => Plugin}),
    ok = connect(A, B),
    Count = 30,
    [
        begin
            ok = webrtc:send_media(A, <<"0">>, webrtc_codecs_pattern:picture(W, H, I)),
            timer:sleep(33)
        end
     || I <- lists:seq(0, Count - 1)
    ],
    Decoded = collect(
        B,
        fun
            ({decoded, <<"0">>, _}) -> true;
            (_) -> false
        end,
        Count,
        5000
    ),
    ?assertEqual(
        [I * 3000 || I <- lists:seq(0, Count - 1)],
        [
            T
         || {decoded, _, #{format := i420, width := W1, height := H1, timestamp := T}} <- Decoded,
            {W1, H1} =:= {W, H}
        ]
    ),
    [
        ?assert(
            webrtc_codecs_pattern:psnr(webrtc_codecs_pattern:picture(W, H, T div 3000), Picture) >
                30
        )
     || {decoded, _, #{timestamp := T} = Picture} <- Decoded
    ],
    timer:sleep(200),
    [
        #{
            framesEncoded := Count,
            keyFramesEncoded := 1,
            targetBitrate := 400000,
            encoderImplementation := Encoder
        }
    ] =
        [
            O
         || _ := #{type := <<"outbound-rtp">>, kind := <<"video">>} = O <- webrtc:get_stats(A, #{
                format => w3c
            })
        ],
    [
        #{
            framesDecoded := Count,
            keyFramesDecoded := 1,
            framesReceived := Count,
            decoderImplementation := Decoder
        }
    ] =
        [
            O
         || _ := #{type := <<"inbound-rtp">>, kind := <<"video">>} = O <- webrtc:get_stats(B, #{
                format => w3c
            })
        ],
    ok = webrtc:close(A),
    ok = webrtc:close(B).

%% What erlang_webrtc 0.3.0 tells the encoder without the application
%% relaying it: the bitrate set with webrtc:set_target_bitrate/3, and
%% the key frame the receiving peer asks for.
control(_Config) ->
    case webrtc_codecs_vpx_nif:loaded() of
        true -> control();
        false -> {skip, "built without libvpx"}
    end.

control() ->
    Plugin = {webrtc_codecs, #{bitrate => 400000}},
    Codecs = #{video => only(<<"VP8">>, webrtc:default_codecs(video))},
    {ok, A} = webrtc:new_peer_connection(#{loopback => true, codecs => Codecs}),
    {ok, B} = webrtc:new_peer_connection(#{
        loopback => true, codecs => Codecs, frames => true, codec_plugins => #{video => Plugin}
    }),
    {ok, _} = webrtc:add_transceiver(A, video, #{frames => true, codec_plugin => Plugin}),
    ok = connect(A, B),
    Send = fun(Ns) ->
        [
            begin
                ok = webrtc:send_media(A, <<"0">>, webrtc_codecs_pattern:picture(320, 240, I)),
                timer:sleep(33)
            end
         || I <- Ns
        ]
    end,
    Outbound = fun() ->
        [O] = [
            O
         || _ := #{type := <<"outbound-rtp">>, kind := <<"video">>} = O <- webrtc:get_stats(A, #{
                format => w3c
            })
        ],
        O
    end,
    Send(lists:seq(0, 9)),
    #{targetBitrate := 400000, keyFramesEncoded := 1} = Outbound(),
    ok = webrtc:set_target_bitrate(A, <<"0">>, 250000),
    ok = webrtc:request_keyframe(B, <<"0">>),
    timer:sleep(300),
    Send(lists:seq(10, 19)),
    #{targetBitrate := 250000, keyFramesEncoded := 2, framesEncoded := 20} = Outbound(),
    ok = webrtc:close(A),
    ok = webrtc:close(B).

%% AV1 and H.264 have no picture ID, so the frame buffer of erlang_webrtc
%% relies on sequence numbers for them. Before erlang_webrtc 0.2.0 the
%% padding a sender adds when RTX is not negotiated was read as a loss
%% and all but the first frame were dropped. Every frame has to arrive
%% without RTX too.
without_rtx(_Config) ->
    Built = [
        {<<"AV1">>, webrtc_codecs_aom_nif:loaded() andalso webrtc_codecs_dav1d_nif:loaded()},
        {<<"H264">>, webrtc_codecs_openh264_nif:loaded()}
    ],
    case [Name || {Name, true} <- Built] of
        [] ->
            {skip, "built without the libraries of AV1 and H.264"};
        Names ->
            [frames_without_rtx(Name) || Name <- Names],
            ok
    end.

frames_without_rtx(Name) ->
    Plugin = {webrtc_codecs, #{bitrate => 400000}},
    Codecs = #{video => [C || #{name := N} = C <- webrtc:default_codecs(video), N =:= Name]},
    {ok, A} = webrtc:new_peer_connection(#{loopback => true, codecs => Codecs}),
    {ok, B} = webrtc:new_peer_connection(#{
        loopback => true, codecs => Codecs, frames => true, codec_plugins => #{video => Plugin}
    }),
    {ok, _} = webrtc:add_transceiver(A, video, #{frames => true, codec_plugin => Plugin}),
    ok = connect(A, B),
    Count = 60,
    [
        begin
            ok = webrtc:send_media(A, <<"0">>, webrtc_codecs_pattern:picture(320, 240, I)),
            timer:sleep(33)
        end
     || I <- lists:seq(0, Count - 1)
    ],
    Decoded = collect(
        B,
        fun
            ({decoded, <<"0">>, _}) -> true;
            (_) -> false
        end,
        Count,
        5000
    ),
    ?assertEqual(
        [I * 3000 || I <- lists:seq(0, Count - 1)],
        [T || {decoded, _, #{format := i420, timestamp := T}} <- Decoded]
    ),
    ok = webrtc:close(A),
    ok = webrtc:close(B).

%% Capture to a peer: pictures and audio from FFmpeg's test sources go
%% to send_media/3 as they come, are encoded by the plugins (VP8 and
%% G.711, which needs no library) and decoded by the other peer.
capture(_Config) ->
    case {os:find_executable("ffmpeg"), webrtc_codecs_vpx_nif:loaded()} of
        {false, _} -> {skip, "no ffmpeg"};
        {_, false} -> {skip, "built without libvpx"};
        _ -> capture()
    end.

capture() ->
    Plugin = {webrtc_codecs, #{}},
    Codecs = #{
        audio => only(<<"PCMU">>, webrtc:default_codecs(audio)),
        video => only(<<"VP8">>, webrtc:default_codecs(video))
    },
    {ok, A} = webrtc:new_peer_connection(#{loopback => true, codecs => Codecs}),
    {ok, B} = webrtc:new_peer_connection(#{
        loopback => true,
        codecs => Codecs,
        frames => true,
        codec_plugins => #{audio => Plugin, video => Plugin}
    }),
    {ok, _} = webrtc:add_transceiver(A, audio, #{frames => true, codec_plugin => Plugin}),
    {ok, _} = webrtc:add_transceiver(A, video, #{frames => true, codec_plugin => Plugin}),
    ok = connect(A, B),
    {ok, Camera} = webrtc_codecs_capture:start({test, video}, #{
        width => 320, height => 240, frame_rate => 30
    }),
    {ok, Microphone} = webrtc_codecs_capture:start({test, audio}, #{sample_rate => 8000}),
    Mids = #{Microphone => <<"0">>, Camera => <<"1">>},
    %% Until that much was captured, however long the programs take to
    %% start on this machine.
    Wanted = #{Camera => 20, Microphone => 40},
    Deadline = {Wanted, erlang:monotonic_time(millisecond) + 30000},
    {Sent, Decoded0} = forward(A, B, Mids, #{Camera => 0, Microphone => 0}, [], Deadline),
    ok = webrtc_codecs_capture:stop(Camera),
    ok = webrtc_codecs_capture:stop(Microphone),
    #{Camera := Pictures, Microphone := Chunks} = Sent,
    ?assert(Pictures >= 20),
    ?assert(Chunks >= 40),
    Decoded =
        Decoded0 ++
            collect(
                B,
                fun
                    ({decoded, _, _}) -> true;
                    (_) -> false
                end,
                Pictures + Chunks - length(Decoded0),
                3000
            ),
    ?assertEqual(
        Pictures,
        length([
            P
         || {decoded, <<"1">>, #{format := i420, width := 320, height := 240} = P} <- Decoded
        ])
    ),
    ?assertEqual(
        Chunks,
        length([C || {decoded, <<"0">>, #{format := s16le, sample_rate := 8000} = C} <- Decoded])
    ),
    ok = webrtc:close(A),
    ok = webrtc:close(B).

%% Give what the captures send to send_media/3 until each has given what
%% is wanted of it, or the deadline, and
%% read the events of the peers as they come: a capture drops what its
%% owner leaves waiting. Returns the count per capture and what B
%% decoded so far.
forward(A, B, Mids, Counts, Decoded, {Wanted, Until} = Deadline) ->
    Enough = maps:fold(
        fun(Pid, Count, Ok) -> Ok andalso maps:get(Pid, Counts) >= Count end, true, Wanted
    ),
    forward(Enough, A, B, Mids, Counts, Decoded, Deadline, Until).

forward(true, _A, _B, _Mids, Counts, Decoded, _Deadline, _Until) ->
    {Counts, lists:reverse(Decoded)};
forward(false, A, B, Mids, Counts, Decoded, Deadline, Until) ->
    receive
        {webrtc_capture, Pid, #{format := _} = Raw} when is_map_key(Pid, Mids) ->
            ok = webrtc:send_media(A, maps:get(Pid, Mids), Raw),
            forward(
                A, B, Mids, maps:update_with(Pid, fun(N) -> N + 1 end, Counts), Decoded, Deadline
            );
        {webrtc, B, {decoded, _, _} = Event} ->
            forward(A, B, Mids, Counts, [Event | Decoded], Deadline);
        {webrtc, _, _} ->
            forward(A, B, Mids, Counts, Decoded, Deadline)
    after max(0, Until - erlang:monotonic_time(millisecond)) ->
        {Counts, lists:reverse(Decoded)}
    end.

%% Capture and encode in FFmpeg, then send_frame/4: no plugin on the
%% sending side. The other peer decodes the frames with its plugin.
capture_encoded(_Config) ->
    Vp8 = string:find(os:cmd("ffmpeg -hide_banner -encoders 2>/dev/null"), " libvpx ") =/= nomatch,
    case {Vp8, webrtc_codecs_vpx_nif:loaded()} of
        {false, _} -> {skip, "no ffmpeg with libvpx"};
        {_, false} -> {skip, "built without libvpx"};
        _ -> capture_encoded()
    end.

capture_encoded() ->
    Codecs = #{video => only(<<"VP8">>, webrtc:default_codecs(video))},
    {ok, A} = webrtc:new_peer_connection(#{loopback => true, codecs => Codecs}),
    {ok, B} = webrtc:new_peer_connection(#{
        loopback => true,
        codecs => Codecs,
        frames => true,
        codec_plugins => #{video => {webrtc_codecs, #{}}}
    }),
    {ok, _} = webrtc:add_transceiver(A, video, #{}),
    ok = connect(A, B),
    {ok, Camera} = webrtc_codecs_capture:start({test, video}, #{
        width => 320, height => 240, frame_rate => 30, encode => #{codec => vp8, bitrate => 400000}
    }),
    %% Thirty frames, however long FFmpeg takes to start on this machine.
    {Sent, Decoded0} = send_frames(
        A, B, Camera, [], [], erlang:monotonic_time(millisecond) + 30000
    ),
    ok = webrtc_codecs_capture:stop(Camera),
    ?assert(length(Sent) >= 20),
    Decoded =
        Decoded0 ++
            collect(
                B,
                fun
                    ({decoded, _, _}) -> true;
                    (_) -> false
                end,
                length(Sent) - length(Decoded0),
                3000
            ),
    %% Every frame given to send_frame/4 is decoded, in order. On a slow
    %% machine the capture drops frames while this process is behind,
    %% up to a key frame, so the timestamps are those sent, not a run
    %% without holes.
    ?assertEqual(
        Sent,
        [
            T
         || {decoded, <<"0">>, #{format := i420, width := 320, height := 240, timestamp := T}} <-
                Decoded
        ]
    ),
    ok = webrtc:close(A),
    ok = webrtc:close(B).

send_frames(_A, _B, _Camera, Sent, Decoded, _Deadline) when length(Sent) >= 30 ->
    {lists:reverse(Sent), lists:reverse(Decoded)};
send_frames(A, B, Camera, Sent, Decoded, Deadline) ->
    receive
        {webrtc_capture, Camera, #{data := Data, timestamp := Ts, keyframe := Key}} ->
            ok = webrtc:send_frame(A, <<"0">>, Data, #{timestamp => Ts, keyframe => Key}),
            send_frames(A, B, Camera, [Ts | Sent], Decoded, Deadline);
        {webrtc, B, {decoded, _, _} = Event} ->
            send_frames(A, B, Camera, Sent, [Event | Decoded], Deadline);
        {webrtc, _, _} ->
            send_frames(A, B, Camera, Sent, Decoded, Deadline)
    after max(0, Deadline - erlang:monotonic_time(millisecond)) ->
        {lists:reverse(Sent), lists:reverse(Decoded)}
    end.

%% One codec of a list, with its retransmission format (RFC 4588).
only(Name, Codecs) ->
    [#{pt := Pt} = Codec] = [C || #{name := N} = C <- Codecs, N =:= Name],
    Apt = integer_to_binary(Pt),
    [Codec | [C || #{name := <<"rtx">>, fmtp := [{<<"apt">>, A}]} = C <- Codecs, A =:= Apt]].

%% Offer from A, answer from B, candidates relayed until both connect.
connect(A, B) ->
    {ok, Offer} = webrtc:create_offer(A, #{}),
    ok = webrtc:set_local_description(A, offer, Offer),
    ok = webrtc:set_remote_description(B, offer, Offer),
    {ok, Answer} = webrtc:create_answer(B, #{}),
    ok = webrtc:set_local_description(B, answer, Answer),
    ok = webrtc:set_remote_description(A, answer, Answer),
    relay(#{A => B, B => A}, [], erlang:monotonic_time(millisecond) + 10000).

relay(Peer, Done, _Deadline) when length(Done) =:= map_size(Peer) ->
    ok;
relay(Peer, Done, Deadline) ->
    receive
        {webrtc, P, {ice_candidate, C, Mid}} when is_map_key(P, Peer) ->
            ok = webrtc:add_ice_candidate(maps:get(P, Peer), C, Mid),
            relay(Peer, Done, Deadline);
        {webrtc, P, {connection_state, connected}} when is_map_key(P, Peer) ->
            relay(Peer, [P | Done], Deadline);
        {webrtc, P, {connection_state, failed}} when is_map_key(P, Peer) ->
            {error, {failed, P}}
    after max(0, Deadline - erlang:monotonic_time(millisecond)) ->
        {error, timeout}
    end.

%% The first Count events of Pc that satisfy Pred, or those that came
%% within Timeout ms.
collect(Pc, Pred, Count, Timeout) ->
    collect(Pc, Pred, Count, erlang:monotonic_time(millisecond) + Timeout, []).

collect(_Pc, _Pred, 0, _Deadline, Got) ->
    lists:reverse(Got);
collect(Pc, Pred, Count, Deadline, Got) ->
    receive
        {webrtc, Pc, E} ->
            case Pred(E) of
                true -> collect(Pc, Pred, Count - 1, Deadline, [E | Got]);
                false -> collect(Pc, Pred, Count, Deadline, Got)
            end
    after max(0, Deadline - erlang:monotonic_time(millisecond)) ->
        lists:reverse(Got)
    end.
