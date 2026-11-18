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
