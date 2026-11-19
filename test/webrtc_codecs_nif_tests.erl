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
