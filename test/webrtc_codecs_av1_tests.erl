-module(webrtc_codecs_av1_tests).
-include_lib("eunit/include/eunit.hrl").

-define(M, webrtc_codecs_av1).
-define(T, webrtc_codecs_test_media).
-define(C, webrtc_codecs_video_checks).

ctx() -> #{mod => ?M, codec => av1, name => <<"AV1">>, implementation => <<"libaom ">>}.

both() ->
    webrtc_codecs_dav1d_nif:loaded() andalso webrtc_codecs_aom_nif:loaded().

%% Encoding and decoding together need libaom and dav1d.
av1_test_() ->
    case both() of
        false -> {"skipped: built without libaom or dav1d", []};
        true -> ?C:all(ctx())
    end.

%% The AV1 corpus of erlang_webrtc, made by SVT-AV1, decodes to its
%% twelve pictures, two of them key frames, the same samples FFmpeg gets.
corpus_test_() ->
    case {webrtc_codecs_dav1d_nif:loaded(), ?T:corpus("av1.ivf")} of
        {true, Path} when Path =/= false ->
            {timeout, 60, fun() -> ?C:decodes_like_ffmpeg(ctx(), Path) end};
        _ ->
            {"skipped: built without dav1d, or no corpus", []}
    end.

codecs_test() ->
    Decode = webrtc_codecs_dav1d_nif:loaded(),
    Encode = webrtc_codecs_aom_nif:loaded(),
    case Decode orelse Encode of
        true ->
            ?assertMatch(
                [#{name := <<"AV1">>, kind := video, decode := Decode, encode := Encode}],
                ?M:codecs()
            );
        false ->
            ?assertEqual([], ?M:codecs()),
            ?assertEqual({error, {not_built, av1}}, ?M:init(video, #{name => <<"AV1">>}, #{}))
    end.

%% The decoder side names dav1d, the encoder side libaom.
implementation_test() ->
    case both() of
        true ->
            {[Frame], _, Enc} = ?C:encode(ctx(), 176, 144, [0], ?C:init(ctx(), #{})),
            ?assertMatch(#{implementation := <<"libaom ", _/binary>>}, ?M:info(Enc)),
            {ok, [_], _, Dec} = ?M:decode(Frame, ?C:init(ctx(), #{})),
            ?assertMatch(#{implementation := <<"dav1d ", _/binary>>}, ?M:info(Dec));
        false ->
            ok
    end.

obu_types_test() ->
    %% Temporal delimiter, sequence header of 2 bytes, frame of 3 bytes.
    Unit = <<2#00010010, 0, 2#00001010, 2, 1, 2, 2#00110010, 3, 1, 2, 3>>,
    ?assertEqual({ok, [2, 1, 6]}, ?M:obu_types(Unit)),
    ?assertEqual(key, ?M:frame_info(av1, Unit)),
    ?assertEqual(inter, ?M:frame_info(av1, <<2#00010010, 0, 2#00110010, 1, 9>>)),
    %% An extension byte, and a last OBU without a size.
    ?assertEqual({ok, [6, 6]}, ?M:obu_types(<<2#00110110, 16#FF, 1, 9, 2#00110000, 1, 2, 3>>)),
    %% A two byte size.
    ?assertEqual({ok, [6]}, ?M:obu_types(<<2#00110010, 16#80, 16#01, 0:(128 * 8)>>)),
    %% Forbidden bit, a size past the end, a size that never ends, nothing.
    ?assertEqual(error, ?M:obu_types(<<2#10010010, 0>>)),
    ?assertEqual(error, ?M:obu_types(<<2#00110010, 5, 1, 2>>)),
    ?assertEqual(error, ?M:obu_types(<<2#00110010, (binary:copy(<<16#80>>, 9))/binary, 0>>)),
    ?assertEqual({error, invalid_frame}, ?M:frame_info(av1, <<>>)),
    ?assertEqual({error, invalid_frame}, ?M:frame_info(av1, <<255, 1, 2>>)).

options_test() ->
    case ?M:codecs() of
        [] ->
            ok;
        _ ->
            Av1 = #{name => <<"AV1">>},
            ?assertMatch({ok, _}, ?M:init(video, Av1#{fmtp => [{<<"profile">>, <<"0">>}]}, #{})),
            ?assertEqual(
                {error, {unsupported_profile, <<"1">>}},
                ?M:init(video, Av1#{fmtp => [{<<"profile">>, <<"1">>}]}, #{})
            ),
            ?assertMatch({error, {badarg, _}}, ?M:init(video, Av1, #{bitrate => 0})),
            ?assertMatch({error, {badarg, _}}, ?M:init(audio, Av1, #{})),
            ?assertEqual(
                {error, {unsupported_codec, <<"VP8">>}}, ?M:init(video, #{name => <<"VP8">>}, #{})
            )
    end.
