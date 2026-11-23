-module(webrtc_codecs_g711).
-moduledoc """
G.711 codec plugin: PCMU (mu-law) and PCMA (A-law), 8 kHz mono, in pure
Erlang.

```erlang
webrtc:add_transceiver(Pc, audio, #{frames => true, codec_plugin => {webrtc_codecs_g711, #{}}}).
```

`decode/2` gives one `t:webrtc_codecs:audio/0` per frame, at 8000 Hz,
one channel. `encode/2` takes the same at 8000 Hz, one channel, and
gives one frame per `ptime` of samples.

Options: `ptime`, the frame duration in milliseconds (default 20).
""".
-behaviour(webrtc_media_codec).

-export([codecs/0]).
-export([init/3, decode/2, encode/2, info/1]).
-export([compress/2, expand/2]).

-define(RATE, 8000).
-define(BITRATE, 64000).
-define(IMPLEMENTATION, <<"webrtc_codecs G.711">>).
%% A frame has to fit one RTP packet.
-define(MAX_PTIME, 120).
%% Two seconds: the most a frame to decode may hold.
-define(MAX_PAYLOAD, 2 * ?RATE).

-record(st, {
    law :: ulaw | alaw,
    %% Samples per encoded frame.
    frame :: pos_integer(),
    %% RTP timestamp of the next encoded frame when the raw audio has none.
    next = 0 :: non_neg_integer()
}).

-doc false.
codecs() ->
    [
        #{
            name => N,
            kind => audio,
            decode => true,
            encode => true,
            implementation => ?IMPLEMENTATION
        }
     || N <- [<<"PCMU">>, <<"PCMA">>]
    ].

-doc false.
init(audio, #{name := Name}, Opts) when is_map(Opts) ->
    Ptime = maps:get(ptime, Opts, 20),
    case {law(Name), Ptime} of
        {error, _} ->
            {error, {unsupported_codec, Name}};
        {Law, _} when is_integer(Ptime), Ptime > 0, Ptime =< ?MAX_PTIME ->
            {ok, #st{law = Law, frame = ?RATE * Ptime div 1000}};
        _ ->
            {error, {badarg, {ptime, Ptime}}}
    end;
init(Kind, _Codec, Opts) ->
    {error, {badarg, {Kind, Opts}}}.

-doc false.
decode(#{data := Data, timestamp := Ts}, St) when byte_size(Data) > ?MAX_PAYLOAD ->
    %% No sender puts that much in a packet: bad media, dropped.
    {ok, [#{dropped => too_large, timestamp => Ts}], #{}, St};
decode(#{data := Data, timestamp := Ts}, #st{law = Law} = St) ->
    Out = #{
        format => s16le,
        sample_rate => ?RATE,
        channels => 1,
        samples => expand(Law, Data),
        timestamp => Ts
    },
    {ok, [Out], #{totalSamplesReceived => byte_size(Data)}, St}.

-doc false.
encode(#{format := s16le, sample_rate := ?RATE, channels := 1, samples := Pcm} = Raw, St) when
    is_binary(Pcm), byte_size(Pcm) rem 2 =:= 0
->
    #st{law = Law, frame = Frame, next = Next} = St,
    Ts = maps:get(timestamp, Raw, Next),
    Frames = frames(compress(Law, Pcm), Frame, Ts),
    {ok, Frames, #{targetBitrate => ?BITRATE}, St#st{next = ts(Ts + byte_size(Pcm) div 2)}};
encode(#{} = Raw, St) when not is_map_key(samples, Raw) ->
    %% A control map: G.711 has one bitrate and no key frames.
    {ok, [], #{}, St};
encode(#{} = Raw, St) ->
    %% An error leaves the plugin on: the audio is lost.
    {error, {bad_raw_audio, maps:without([samples], Raw)}, St};
encode(_Raw, St) ->
    {error, bad_raw_audio, St}.

-doc false.
info(_St) ->
    #{implementation => ?IMPLEMENTATION, power_efficient => false}.

law(Name) ->
    case string:lowercase(Name) of
        <<"pcmu">> -> ulaw;
        <<"pcma">> -> alaw;
        _ -> error
    end.

frames(<<>>, _Frame, _Ts) ->
    [];
frames(Data, Frame, Ts) when byte_size(Data) =< Frame ->
    [frame(Data, Ts)];
frames(Data, Frame, Ts) ->
    <<One:Frame/binary, Rest/binary>> = Data,
    [frame(One, Ts) | frames(Rest, Frame, ts(Ts + Frame))].

%% Every G.711 frame decodes on its own.
frame(Data, Ts) ->
    #{data => Data, timestamp => Ts, keyframe => true}.

ts(T) -> T band 16#FFFFFFFF.

-doc "Compress signed 16 bit little endian samples to one G.711 byte each.".
-spec compress(ulaw | alaw, binary()) -> binary().
compress(ulaw, Pcm) -> <<<<(linear_to_ulaw(S))>> || <<S:16/little-signed>> <= Pcm>>;
compress(alaw, Pcm) -> <<<<(linear_to_alaw(S))>> || <<S:16/little-signed>> <= Pcm>>.

-doc "Expand G.711 bytes to signed 16 bit little endian samples.".
-spec expand(ulaw | alaw, binary()) -> binary().
expand(ulaw, Data) -> <<<<(ulaw_to_linear(B)):16/little-signed>> || <<B>> <= Data>>;
expand(alaw, Data) -> <<<<(alaw_to_linear(B)):16/little-signed>> || <<B>> <= Data>>.

%% ITU-T G.711 mu-law: a sign bit, a 3 bit segment and 4 bits of the
%% biased magnitude, all inverted on the wire.
-define(ULAW_BIAS, 16#84).
-define(ULAW_CLIP, 32635).

linear_to_ulaw(S) when S < 0 -> ulaw_magnitude(-S) bxor 16#7F;
linear_to_ulaw(S) -> ulaw_magnitude(S) bxor 16#FF.

ulaw_magnitude(M0) ->
    M = min(M0, ?ULAW_CLIP) + ?ULAW_BIAS,
    Seg = segment(M bsr 8),
    (Seg bsl 4) bor ((M bsr (Seg + 3)) band 16#F).

ulaw_to_linear(B0) ->
    B = B0 bxor 16#FF,
    T = ((((B band 16#F) bsl 3) + ?ULAW_BIAS) bsl ((B band 16#70) bsr 4)) - ?ULAW_BIAS,
    case B band 16#80 of
        0 -> T;
        _ -> -T
    end.

%% ITU-T G.711 A-law, on the 13 most significant bits: a sign bit, a 3
%% bit segment and 4 bits of magnitude, even bits inverted on the wire.
linear_to_alaw(S) when S < 0 -> alaw_magnitude((-S - 1) bsr 3) bxor 16#55;
linear_to_alaw(S) -> alaw_magnitude(S bsr 3) bxor 16#D5.

alaw_magnitude(M) ->
    case segment(M bsr 5) of
        0 -> (M bsr 1) band 16#F;
        Seg -> (Seg bsl 4) bor ((M bsr Seg) band 16#F)
    end.

alaw_to_linear(B0) ->
    B = B0 bxor 16#55,
    Seg = (B band 16#70) bsr 4,
    T0 = (B band 16#F) bsl 4,
    T =
        case Seg of
            0 -> T0 + 8;
            _ -> (T0 + 16#108) bsl (Seg - 1)
        end,
    case B band 16#80 of
        0 -> -T;
        _ -> T
    end.

%% Number of significant bits of N, at most 7.
segment(0) -> 0;
segment(N) when N < 2 -> 1;
segment(N) when N < 4 -> 2;
segment(N) when N < 8 -> 3;
segment(N) when N < 16 -> 4;
segment(N) when N < 32 -> 5;
segment(N) when N < 64 -> 6;
segment(_) -> 7.
