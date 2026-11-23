%% The failure paths of every native constructor: each allocation is
%% made to fail in turn, and the constructor has to answer an error, not
%% crash, and work again afterwards. Under the sanitizers this is also
%% where a read of freed memory would show. It needs a build with fault
%% injection (scripts/test-sanitizers.sh) and is skipped in others.
-module(webrtc_codecs_nif_tests).
-include_lib("eunit/include/eunit.hrl").

constructors() ->
    Settings = #{bitrate => 300000, threads => 1},
    [
        {webrtc_codecs_opus_nif, "opus decoder", fun() ->
            webrtc_codecs_opus_nif:decoder_new(48000, 2)
        end},
        {webrtc_codecs_opus_nif, "opus encoder", fun() ->
            webrtc_codecs_opus_nif:encoder_new(48000, 2, voip, #{})
        end},
        {webrtc_codecs_vpx_nif, "vp8 decoder", fun() ->
            webrtc_codecs_vpx_nif:decoder_new(vp8, 1, 100000)
        end},
        {webrtc_codecs_vpx_nif, "vp9 decoder", fun() ->
            webrtc_codecs_vpx_nif:decoder_new(vp9, 1, 100000)
        end},
        {webrtc_codecs_vpx_nif, "vp8 encoder", fun() ->
            webrtc_codecs_vpx_nif:encoder_new(vp8, 64, 48, Settings)
        end},
        {webrtc_codecs_vpx_nif, "vp9 encoder", fun() ->
            webrtc_codecs_vpx_nif:encoder_new(vp9, 64, 48, Settings)
        end},
        {webrtc_codecs_dav1d_nif, "av1 decoder", fun() ->
            webrtc_codecs_dav1d_nif:decoder_new(1, 100000)
        end},
        {webrtc_codecs_aom_nif, "av1 encoder", fun() ->
            webrtc_codecs_aom_nif:encoder_new(64, 48, Settings)
        end},
        {webrtc_codecs_openh264_nif, "h264 decoder", fun() ->
            webrtc_codecs_openh264_nif:decoder_new(100000)
        end},
        {webrtc_codecs_openh264_nif, "h264 encoder", fun() ->
            webrtc_codecs_openh264_nif:encoder_new(64, 48, Settings)
        end}
    ].

%% Whether this NIF is loaded and was built with fault injection.
injection(Nif) ->
    Nif:loaded() andalso
        try Nif:fail_after(0) of
            ok -> true
        catch
            error:nif_not_loaded -> false
        end.

constructor_failures_test_() ->
    [
        {lists:flatten(io_lib:format("~s, allocation ~b fails", [Name, N])), fun() ->
            ok = Nif:fail_after(N),
            ?assertMatch({error, _}, New()),
            ok = Nif:fail_after(0),
            ?assertMatch({ok, _}, New())
        end}
     || {Nif, Name, New} <- constructors(), injection(Nif), N <- [1, 2, 3]
    ].

%% Without fault injection the constructors still have to work.
constructors_test_() ->
    [
        {Name, fun() -> ?assertMatch({ok, _}, New()) end}
     || {Nif, Name, New} <- constructors(), Nif:loaded()
    ].

%% Every context with its close function and calls that reach the codec.
contexts() ->
    Settings = #{bitrate => 300000, threads => 1},
    Y = binary:copy(<<128>>, 64 * 48),
    C = binary:copy(<<128>>, 32 * 24),
    Junk = binary:copy(<<1, 2, 3, 4, 5, 6, 7, 8>>, 8),
    Pcm = binary:copy(<<0>>, 960 * 2 * 2),
    Video = fun(Nif) ->
        [
            fun(E) -> Nif:encode(E, Y, C, C, 3000, 3000, false) end,
            fun(E) -> Nif:encoder_bitrate(E, 200000) end
        ]
    end,
    [
        {webrtc_codecs_opus_nif, "opus decoder",
            fun() -> webrtc_codecs_opus_nif:decoder_new(48000, 2) end, decoder_close, [
                fun(D) -> webrtc_codecs_opus_nif:conceal(D, 960) end,
                fun(D) -> webrtc_codecs_opus_nif:decode(D, Junk) end,
                fun(D) -> webrtc_codecs_opus_nif:decode_fec(D, Junk, 960) end
            ]},
        {webrtc_codecs_opus_nif, "opus encoder",
            fun() -> webrtc_codecs_opus_nif:encoder_new(48000, 2, voip, #{}) end, encoder_close, [
                fun(E) -> webrtc_codecs_opus_nif:encode(E, Pcm) end,
                fun(E) -> webrtc_codecs_opus_nif:encoder_bitrate(E) end,
                fun(E) -> webrtc_codecs_opus_nif:encoder_set(E, #{bitrate => 32000}) end
            ]},
        {webrtc_codecs_vpx_nif, "vp8 decoder",
            fun() -> webrtc_codecs_vpx_nif:decoder_new(vp8, 1, 100000) end, decoder_close, [
                fun(D) -> webrtc_codecs_vpx_nif:decode(D, Junk) end
            ]},
        {webrtc_codecs_vpx_nif, "vp9 encoder",
            fun() -> webrtc_codecs_vpx_nif:encoder_new(vp9, 64, 48, Settings) end, encoder_close,
            Video(webrtc_codecs_vpx_nif)},
        {webrtc_codecs_dav1d_nif, "av1 decoder",
            fun() -> webrtc_codecs_dav1d_nif:decoder_new(1, 100000) end, decoder_close, [
                fun(D) -> webrtc_codecs_dav1d_nif:decode(D, Junk) end
            ]},
        {webrtc_codecs_aom_nif, "av1 encoder",
            fun() -> webrtc_codecs_aom_nif:encoder_new(64, 48, Settings) end, encoder_close,
            Video(webrtc_codecs_aom_nif)},
        {webrtc_codecs_openh264_nif, "h264 decoder",
            fun() -> webrtc_codecs_openh264_nif:decoder_new(100000) end, decoder_close, [
                fun(D) -> webrtc_codecs_openh264_nif:decode(D, <<0, 0, 0, 1, Junk/binary>>) end
            ]},
        {webrtc_codecs_openh264_nif, "h264 encoder",
            fun() -> webrtc_codecs_openh264_nif:encoder_new(64, 48, Settings) end, encoder_close, [
                fun(E) -> webrtc_codecs_openh264_nif:encode(E, Y, C, C, 3000, false) end,
                fun(E) -> webrtc_codecs_openh264_nif:encoder_bitrate(E, 200000) end
            ]}
    ].

%% A closed context answers `{error, closed}` to every call that would
%% reach its codec, and closing it again is harmless.
close_test_() ->
    [
        {Name ++ " closed", fun() ->
            {ok, Context} = New(),
            [?assertNotEqual({error, closed}, Use(Context)) || Use <- Uses],
            ?assertEqual(ok, Nif:Close(Context)),
            [?assertEqual({error, closed}, Use(Context)) || Use <- Uses],
            ?assertEqual(ok, Nif:Close(Context)),
            ?assertError(badarg, Nif:Close(make_ref()))
        end}
     || {Nif, Name, New, Close, Uses} <- contexts(), Nif:loaded()
    ].

%% Closing while other processes are in the codec waits for them: every
%% call ends with a result of the codec or with `closed`, none raises.
%% Each process calls until it is told the context is closed.
close_while_used_test_() ->
    [
        {timeout, 60,
            {Name ++ " closed while used", fun() ->
                {ok, Context} = New(),
                Self = self(),
                Pids = [
                    spawn_link(fun() -> Self ! {self(), use_until_closed(Uses, Context, [])} end)
                 || _ <- lists:seq(1, 8)
                ],
                timer:sleep(5),
                ok = Nif:Close(Context),
                Raised = lists:append([
                    receive
                        {Pid, R} -> R
                    after 30000 -> error(timeout)
                    end
                 || Pid <- Pids
                ]),
                ?assertEqual([], Raised),
                [?assertEqual({error, closed}, Use(Context)) || Use <- Uses]
            end}}
     || {Nif, Name, New, Close, Uses} <- contexts(), Nif:loaded()
    ].

%% What raised, once a call has answered `closed`.
use_until_closed(Uses, Context, Raised0) ->
    Results = [attempt(Use, Context) || Use <- Uses],
    Raised = [R || {raised, _} = R <- Results] ++ Raised0,
    case lists:member({error, closed}, Results) of
        true -> Raised;
        false -> use_until_closed(Uses, Context, Raised)
    end.

attempt(Use, Context) ->
    try
        Use(Context)
    catch
        Class:Reason -> {raised, {Class, Reason}}
    end.
