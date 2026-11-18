-module(webrtc_codecs_pattern).
-moduledoc """
Test media made in Erlang: a moving picture and a tone to feed an
encoder when you have no camera or microphone, and the measures to
compare what a decoder gives back.

```erlang
Pic = webrtc_codecs_pattern:picture(320, 240, N),
ok = webrtc:send_media(Pc, Mid, Pic#{timestamp => N * 3000}).
```
""".

-export([picture/3, tone/4, psnr/2, snr/2]).

%% Luma and chroma of eight vertical bars: white, yellow, cyan, green,
%% magenta, red, blue, black.
-define(BARS, [
    {235, 128, 128},
    {210, 16, 146},
    {170, 166, 16},
    {145, 54, 34},
    {106, 202, 222},
    {81, 90, 240},
    {41, 240, 110},
    {16, 128, 128}
]).

-doc """
Picture number `N` of the pattern: eight colour bars with a grey square
that moves across them, so consecutive pictures differ. `Width` and
`Height` are even. The timestamp is `N` at 30 pictures per second.
""".
-spec picture(pos_integer(), pos_integer(), non_neg_integer()) -> webrtc_codecs:picture().
picture(W, H, N) when W >= 16, H >= 16, W rem 2 =:= 0, H rem 2 =:= 0, N >= 0 ->
    Cw = W div 2,
    Ch = H div 2,
    %% The square, in chroma units so it covers whole chroma samples.
    Side = max(2, min(Cw, Ch) div 4),
    X = (N * 2) rem (Cw - Side + 1),
    Y = N rem (Ch - Side + 1),
    Plane = fun(Sel, Width, Scale, Grey) ->
        Row = row(Sel, Width),
        Boxed = <<
            (binary:part(Row, 0, X * Scale))/binary,
            (binary:copy(<<Grey>>, Side * Scale))/binary,
            (binary:part(Row, (X + Side) * Scale, Width - (X + Side) * Scale))/binary
        >>,
        <<
            (binary:copy(Row, Y * Scale))/binary,
            (binary:copy(Boxed, Side * Scale))/binary,
            (binary:copy(Row, (Ch - Y - Side) * Scale))/binary
        >>
    end,
    #{
        format => i420,
        width => W,
        height => H,
        y => Plane(1, W, 2, 126),
        u => Plane(2, Cw, 1, 128),
        v => Plane(3, Cw, 1, 128),
        timestamp => N * 3000
    }.

%% One row of the bars for a plane of the given width.
row(Sel, Width) ->
    Bars = list_to_tuple(?BARS),
    <<<<(element(Sel, element(1 + I * 8 div Width, Bars)))>> || I <- lists:seq(0, Width - 1)>>.

-doc """
`Ms` milliseconds of a sine at `Hz`, the same on every channel, starting
at sample `Offset` so consecutive calls join without a click. The
timestamp is `Offset`.
""".
-spec tone(
    number(),
    pos_integer(),
    #{sample_rate := pos_integer(), channels := pos_integer()},
    non_neg_integer()
) ->
    webrtc_codecs:audio().
tone(Hz, Ms, #{sample_rate := Rate, channels := Channels}, Offset) ->
    Count = Rate * Ms div 1000,
    Step = 2 * math:pi() * Hz / Rate,
    Samples = <<
        <<(binary:copy(<<(round(16000 * math:sin(Step * I))):16/little-signed>>, Channels))/binary>>
     || I <- lists:seq(Offset, Offset + Count - 1)
    >>,
    #{
        format => s16le,
        sample_rate => Rate,
        channels => Channels,
        samples => Samples,
        timestamp => Offset
    }.

-doc """
Peak signal to noise ratio between two pictures of the same size, in
dB over the three planes; `infinity` when they are identical.
""".
-spec psnr(webrtc_codecs:picture(), webrtc_codecs:picture()) -> float() | infinity.
psnr(#{width := W, height := H} = A, #{width := W, height := H} = B) ->
    Sq = lists:sum([squares(maps:get(P, A), maps:get(P, B), 8) || P <- [y, u, v]]),
    ratio(255 * 255 * (W * H * 3 div 2), Sq).

-doc """
Signal to noise ratio of decoded audio against the original, in dB, over
the samples both have; `infinity` when they are identical.
""".
-spec snr(webrtc_codecs:audio(), webrtc_codecs:audio()) -> float() | infinity.
snr(#{samples := Ref0}, #{samples := Dec0}) ->
    Size = min(byte_size(Ref0), byte_size(Dec0)) band (bnot 1),
    Ref = binary:part(Ref0, 0, Size),
    Dec = binary:part(Dec0, 0, Size),
    Signal = lists:sum([S * S || <<S:16/little-signed>> <= Ref]),
    ratio(Signal, squares(Ref, Dec, 16)).

ratio(_Signal, 0) -> infinity;
ratio(Signal, Noise) -> 10 * math:log10(max(Signal, 1) / Noise).

%% Sum of the squared differences of two binaries of the same size.
squares(A, B, 8) when byte_size(A) =:= byte_size(B) ->
    squares8(A, B, 0);
squares(A, B, 16) when byte_size(A) =:= byte_size(B) ->
    squares16(A, B, 0).

squares8(<<X, A/binary>>, <<Y, B/binary>>, Acc) -> squares8(A, B, Acc + (X - Y) * (X - Y));
squares8(<<>>, <<>>, Acc) -> Acc.

squares16(<<X:16/little-signed, A/binary>>, <<Y:16/little-signed, B/binary>>, Acc) ->
    squares16(A, B, Acc + (X - Y) * (X - Y));
squares16(<<>>, <<>>, Acc) ->
    Acc.
