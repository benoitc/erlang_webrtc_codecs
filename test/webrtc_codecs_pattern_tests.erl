-module(webrtc_codecs_pattern_tests).
-include_lib("eunit/include/eunit.hrl").

-define(P, webrtc_codecs_pattern).

picture_planes_test() ->
    #{format := i420, width := 176, height := 144, y := Y, u := U, v := V, timestamp := 9000} = ?P:picture(
        176, 144, 3
    ),
    ?assertEqual(176 * 144, byte_size(Y)),
    ?assertEqual(88 * 72, byte_size(U)),
    ?assertEqual(88 * 72, byte_size(V)).

%% The square moves, and stays inside pictures of any even size.
picture_moves_test() ->
    ?assertNotEqual(maps:get(y, ?P:picture(64, 48, 0)), maps:get(y, ?P:picture(64, 48, 1))),
    [
        ?assertEqual(W * H, byte_size(maps:get(y, ?P:picture(W, H, N))))
     || {W, H} <- [{16, 16}, {18, 34}, {320, 240}], N <- [0, 1, 7, 1000]
    ].

psnr_test() ->
    A = ?P:picture(64, 48, 0),
    ?assertEqual(infinity, ?P:psnr(A, A)),
    Low = ?P:psnr(A, ?P:picture(64, 48, 5)),
    ?assert(is_float(Low) andalso Low < 40),
    %% One level of error on every sample: 20 * log10(255).
    Off = maps:map(
        fun
            (K, V) when K =:= y; K =:= u; K =:= v -> <<<<(B - 1)>> || <<B>> <= V>>;
            (_, V) -> V
        end,
        A
    ),
    ?assert(abs(?P:psnr(A, Off) - 48.13) < 0.01).

tone_test() ->
    Fmt = #{sample_rate => 48000, channels => 2},
    #{format := s16le, sample_rate := 48000, channels := 2, samples := S, timestamp := 960} = ?P:tone(
        440, 20, Fmt, 960
    ),
    ?assertEqual(960 * 2 * 2, byte_size(S)),
    <<L:16/little-signed, R:16/little-signed, _/binary>> = S,
    ?assertEqual(L, R),
    %% Two calls join into the same samples as one.
    #{samples := Both} = ?P:tone(440, 40, Fmt, 0),
    ?assertEqual(Both, <<(maps:get(samples, ?P:tone(440, 20, Fmt, 0)))/binary, S/binary>>).

snr_test() ->
    A = ?P:tone(440, 20, #{sample_rate => 8000, channels => 1}, 0),
    ?assertEqual(infinity, ?P:snr(A, A)),
    Silence = A#{samples := binary:copy(<<0>>, byte_size(maps:get(samples, A)))},
    ?assert(abs(?P:snr(A, Silence)) < 0.001).
