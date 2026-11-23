-module(webrtc_codecs_tests).
-include_lib("eunit/include/eunit.hrl").

available_test() ->
    Names = [
        N
     || #{name := N, kind := audio, decode := true, encode := true} <- webrtc_codecs:available()
    ],
    ?assert(lists:member(<<"PCMU">>, Names)),
    ?assert(lists:member(<<"PCMA">>, Names)).

module_test() ->
    ?assertEqual({ok, webrtc_codecs_g711}, webrtc_codecs:module(<<"pcmu">>)),
    ?assertEqual(error, webrtc_codecs:module(<<"speex">>)).

%% The plugin runs the module of the negotiated codec.
dispatch_test() ->
    {ok, St} = webrtc_codecs:init(audio, #{name => <<"PCMA">>, clock_rate => 8000}, #{}),
    Raw = webrtc_codecs_pattern:tone(440, 20, #{sample_rate => 8000, channels => 1}, 0),
    {ok, [#{data := Data} = Frame], _, St1} = webrtc_codecs:encode(Raw, St),
    ?assertEqual(160, byte_size(Data)),
    {ok, [#{samples := Pcm, timestamp := 0}], #{totalSamplesReceived := 160}, _} = webrtc_codecs:decode(
        Frame, St1
    ),
    ?assertEqual(320, byte_size(Pcm)),
    ?assertMatch(#{implementation := <<_/binary>>}, webrtc_codecs:info(St1)).

unsupported_test() ->
    ?assertEqual(
        {error, {unsupported_codec, <<"speex">>}},
        webrtc_codecs:init(audio, #{name => <<"speex">>}, #{})
    ),
    ?assertEqual({error, {bad_codec, #{}}}, webrtc_codecs:init(audio, #{}, #{})).

%% What erlang_webrtc tells a plugin goes to the module of the codec
%% when it listens, and is accepted when it does not.
control_and_terminate_test() ->
    {ok, G711} = webrtc_codecs:init(audio, #{name => <<"PCMU">>, clock_rate => 8000}, #{}),
    ?assertEqual({ok, G711}, webrtc_codecs:control({target_bitrate, 32000}, G711)),
    ?assertEqual(ok, webrtc_codecs:terminate(G711)),
    ?assertMatch({error, bad_raw_audio, G711}, webrtc_codecs:encode(pcm, G711)),
    case webrtc_codecs_vpx_nif:loaded() of
        true ->
            {ok, Vp8} = webrtc_codecs:init(video, #{name => <<"VP8">>}, #{}),
            Picture = webrtc_codecs_pattern:picture(64, 48, 0),
            {ok, [#{keyframe := true}], _, St1} = webrtc_codecs:encode(Picture, Vp8),
            {ok, St2} = webrtc_codecs:control(keyframe_request, St1),
            {ok, [#{keyframe := true} = Frame], _, St3} = webrtc_codecs:encode(Picture, St2),
            %% A decoder that starts on a frame it cannot use asks for a
            %% key frame through the plugin.
            {ok, [#{dropped := _}], #{framesDropped := 1}, _, [keyframe_request]} =
                webrtc_codecs:decode(Frame#{data := <<0:80>>}, Vp8),
            ?assertEqual(ok, webrtc_codecs:terminate(St3));
        false ->
            ok
    end.
