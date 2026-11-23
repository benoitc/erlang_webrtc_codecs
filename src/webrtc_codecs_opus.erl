-module(webrtc_codecs_opus).
-moduledoc """
Opus codec plugin, on libopus.

```erlang
webrtc:add_transceiver(Pc, audio, #{frames => true, codec_plugin => {webrtc_codecs_opus, #{}}}).
```

`decode/2` gives `t:webrtc_codecs:audio/0`. When frames were lost
before the one it is given, it first gives the audio that fills the
gap: recovered from the redundancy in the packet (in-band FEC) for the
last lost frame, synthesized for the others.

`encode/2` takes `t:webrtc_codecs:audio/0` at 8000, 12000, 16000, 24000
or 48000 Hz, one or two channels, 2.5, 5, 10, 20, 40 or 60 ms at a
time. It follows `bitrate` (bits per second) and `packet_loss` (percent
the peer reports, which sizes the redundancy) given in the raw map.

Options, each defaulting to what the negotiated `fmtp` says:

- `sample_rate`: of decoded audio, default 48000
- `channels`: of decoded audio, default 2 with `stereo=1`, else 1
- `bitrate`: of the encoder at start, default chosen by libopus
- `fec`: in-band FEC, default `useinbandfec`
- `dtx`: send nothing during silence, default `usedtx`
- `packet_loss`: percent expected at start, default 0
- `max_playback_rate`: highest rate the peer plays, which caps the audio
  bandwidth sent, default `maxplaybackrate`, else 48000
- `application`: `voip` (default), `audio` or `lowdelay`
- `complexity`: 0 to 10, default chosen by libopus
""".
-behaviour(webrtc_media_codec).

-export([codecs/0]).
-export([init/3, decode/2, encode/2, info/1, control/2, terminate/1]).

%% RTP always counts Opus at 48 kHz (RFC 7587 section 4.1).
-define(CLOCK, 48000).
-define(RATES, [8000, 12000, 16000, 24000, 48000]).
-define(MIN_BITRATE, 6000).
-define(MAX_BITRATE, 510000).
%% A longer hole is a pause (DTX, mute), not a loss to fill.
-define(MAX_CONCEAL, 120 * ?CLOCK div 1000).

-record(st, {
    %% Format of decoded audio.
    rate :: pos_integer(),
    channels :: 1 | 2,
    decoder :: undefined | webrtc_codecs_opus_nif:decoder(),
    %% RTP timestamp after the last decoded frame, and its duration.
    expected :: undefined | non_neg_integer(),
    last = 960 :: pos_integer(),
    %% Encoder, made for the format of the first raw audio.
    encoder :: undefined | {webrtc_codecs_opus_nif:encoder(), pos_integer(), 1 | 2},
    application :: voip | audio | lowdelay,
    settings :: webrtc_codecs_opus_nif:settings(),
    max_bitrate :: pos_integer(),
    %% The most the peer allows (TMMBR), and the bitrate libopus chose
    %% when none was set, to come back to when the peer lifts its limit.
    peer_max = infinity :: infinity | non_neg_integer(),
    auto :: undefined | pos_integer(),
    target :: undefined | integer(),
    %% RTP timestamp of the next encoded frame when the raw audio has none.
    next = 0 :: non_neg_integer()
}).

-doc false.
codecs() ->
    case webrtc_codecs_opus_nif:loaded() of
        true ->
            [
                #{
                    name => <<"opus">>,
                    kind => audio,
                    decode => true,
                    encode => true,
                    implementation => webrtc_codecs_opus_nif:version()
                }
            ];
        false ->
            []
    end.

-doc false.
init(audio, #{name := Name} = Codec, Opts) when is_map(Opts) ->
    case {string:lowercase(Name), webrtc_codecs_opus_nif:loaded()} of
        {<<"opus">>, true} -> init(maps:get(fmtp, Codec, []), Opts);
        {<<"opus">>, false} -> {error, {not_built, opus}};
        _ -> {error, {unsupported_codec, Name}}
    end;
init(Kind, _Codec, Opts) ->
    {error, {badarg, {Kind, Opts}}}.

init(Fmtp, Opts) ->
    Rate = maps:get(sample_rate, Opts, ?CLOCK),
    Channels = maps:get(channels, Opts, 1 + fmtp_int(<<"stereo">>, Fmtp, 0)),
    Application = maps:get(application, Opts, voip),
    Max = min(
        ?MAX_BITRATE, max(?MIN_BITRATE, fmtp_int(<<"maxaveragebitrate">>, Fmtp, ?MAX_BITRATE))
    ),
    %% RFC 7587 section 7.1: what the peer plays, 48000 when it says
    %% nothing.
    Playback = max(8000, min(48000, fmtp_int(<<"maxplaybackrate">>, Fmtp, 48000))),
    Settings0 = maps:merge(
        #{
            fec => fmtp_int(<<"useinbandfec">>, Fmtp, 0) =:= 1,
            dtx => fmtp_int(<<"usedtx">>, Fmtp, 0) =:= 1,
            max_playback_rate => Playback
        },
        maps:with([bitrate, fec, dtx, packet_loss, complexity, max_playback_rate], Opts)
    ),
    Settings = clamp(Settings0, Max),
    Valid =
        lists:member(Rate, ?RATES) andalso
            (Channels =:= 1 orelse Channels =:= 2) andalso
            lists:member(Application, [voip, audio, lowdelay]) andalso
            valid(Settings),
    case Valid of
        true ->
            {ok, #st{
                rate = Rate,
                channels = Channels,
                application = Application,
                settings = Settings,
                max_bitrate = Max
            }};
        false ->
            {error, {badarg, Opts}}
    end.

valid(Settings) ->
    maps:fold(fun(K, V, Ok) -> Ok andalso valid(K, V) end, true, Settings).

valid(bitrate, V) -> is_integer(V) andalso V > 0;
valid(complexity, V) -> is_integer(V) andalso V >= 0 andalso V =< 10;
valid(packet_loss, V) -> is_integer(V) andalso V >= 0 andalso V =< 100;
valid(max_playback_rate, V) -> is_integer(V) andalso V >= 8000 andalso V =< 48000;
valid(_, V) -> is_boolean(V).

clamp(#{bitrate := B} = Settings, Max) when is_integer(B) ->
    Settings#{bitrate := max(?MIN_BITRATE, min(B, Max))};
clamp(Settings, _Max) ->
    Settings.

%% fmtp is a list of {Name, Value} binaries; anything else is skipped.
fmtp_int(Key, Fmtp, Default) when is_list(Fmtp) ->
    case lists:keyfind(Key, 1, [P || {_, _} = P <- Fmtp]) of
        {_, Value} when is_binary(Value) ->
            try
                binary_to_integer(Value)
            catch
                error:badarg -> Default
            end;
        _ ->
            Default
    end;
fmtp_int(_Key, _Fmtp, Default) ->
    Default.

%% Decoding

-doc false.
decode(
    #{data := Data, timestamp := Ts},
    #st{decoder = undefined, rate = Rate, channels = Channels} = St
) ->
    case webrtc_codecs_opus_nif:decoder_new(Rate, Channels) of
        {ok, Decoder} -> decode1(Data, Ts, St#st{decoder = Decoder});
        {error, Reason} -> {error, {opus, Reason}}
    end;
decode(#{data := Data, timestamp := Ts}, St) ->
    decode1(Data, Ts, St).

decode1(Data, Ts, #st{decoder = Decoder, rate = Rate} = St) ->
    {Filled, Concealed, Recovered} = fill(Data, Ts, St),
    Stats0 = #{totalSamplesReceived => Concealed + Recovered},
    Stats1 =
        case Filled of
            [] -> Stats0;
            _ -> Stats0#{concealedSamples => Concealed, concealmentEvents => 1}
        end,
    case webrtc_codecs_opus_nif:decode(Decoder, Data) of
        {ok, Pcm} ->
            Samples = samples(Pcm, St),
            Duration = Samples * ?CLOCK div Rate,
            Stats = Stats1#{totalSamplesReceived := Concealed + Recovered + Samples},
            {ok, Filled ++ [audio(Pcm, Ts, St)], Stats, St#st{
                expected = ts(Ts + Duration), last = max(Duration, 120)
            }};
        {error, Reason} ->
            %% Bad media from the peer: the frame is dropped, the plugin goes on.
            {ok, Filled ++ [#{dropped => Reason, timestamp => Ts}], Stats1, St}
    end.

%% The audio between the last decoded frame and this one, when frames
%% were lost: the last lost frame from the redundancy this packet may
%% carry, the earlier ones synthesized. Returns the outputs and the
%% number of samples synthesized and recovered. libopus synthesizes when
%% the packet has no redundancy, without saying so; those samples are
%% counted as recovered.
fill(_Data, _Ts, #st{expected = undefined}) ->
    {[], 0, 0};
fill(Data, Ts, #st{expected = Expected, last = Last, rate = Rate} = St) ->
    Gap = (Ts - Expected) band 16#FFFFFFFF,
    Unit = ?CLOCK div 400,
    case Gap > 0 andalso Gap =< ?MAX_CONCEAL andalso Gap rem Unit =:= 0 of
        true ->
            Fec = min(Last, Gap),
            {Out0, Concealed} = conceal(Expected, Gap - Fec, St, [], 0),
            case webrtc_codecs_opus_nif:decode_fec(St#st.decoder, Data, Fec * Rate div ?CLOCK) of
                {ok, Pcm} ->
                    {
                        lists:reverse([audio(Pcm, ts(Ts - Fec), St) | Out0]),
                        Concealed,
                        samples(Pcm, St)
                    };
                {error, _} ->
                    {lists:reverse(Out0), Concealed, 0}
            end;
        false ->
            {[], 0, 0}
    end.

conceal(_Ts, 0, _St, Out, Count) ->
    {Out, Count};
conceal(Ts, Left, #st{decoder = Decoder, last = Last, rate = Rate} = St, Out, Count) ->
    Duration = min(Last, Left),
    case webrtc_codecs_opus_nif:conceal(Decoder, Duration * Rate div ?CLOCK) of
        {ok, Pcm} ->
            conceal(
                ts(Ts + Duration),
                Left - Duration,
                St,
                [audio(Pcm, Ts, St) | Out],
                Count + samples(Pcm, St)
            );
        {error, _} ->
            {Out, Count}
    end.

audio(Pcm, Ts, #st{rate = Rate, channels = Channels}) ->
    #{format => s16le, sample_rate => Rate, channels => Channels, samples => Pcm, timestamp => Ts}.

samples(Pcm, #st{channels = Channels}) ->
    byte_size(Pcm) div (2 * Channels).

%% Encoding

-doc false.
encode(
    #{format := s16le, sample_rate := Rate, channels := Channels, samples := Pcm} = Raw, St0
) when
    is_binary(Pcm)
->
    %% An error leaves the plugin on: the audio is lost, the next is tried.
    case encoder(Rate, Channels, raw_control(Raw, St0)) of
        {ok, #st{encoder = {Encoder, _, _}, next = Next} = St} ->
            case webrtc_codecs_opus_nif:encode(Encoder, Pcm) of
                {ok, Packet} ->
                    Ts = maps:get(timestamp, Raw, Next),
                    Duration = byte_size(Pcm) div (2 * Channels) * ?CLOCK div Rate,
                    {ok, frames(Packet, Ts), stats(St), St#st{next = ts(Ts + Duration)}};
                {error, bad_arg} ->
                    Bad = maps:without([samples], Raw#{bytes => byte_size(Pcm)}),
                    {error, {bad_raw_audio, Bad}, St};
                {error, Reason} ->
                    {error, {opus, Reason}, St}
            end;
        {error, Reason} ->
            {error, Reason, St0}
    end;
encode(#{} = Raw, St) when not is_map_key(samples, Raw) ->
    case apply_settings(raw_control(Raw, St)) of
        {ok, St1} -> {ok, [], stats(St1), St1};
        {error, Reason} -> {error, Reason, St}
    end;
encode(#{} = Raw, St) ->
    {error, {bad_raw_audio, maps:without([samples], Raw)}, St};
encode(_Raw, St) ->
    {error, bad_raw_audio, St}.

%% With DTX, libopus gives a packet of at most two bytes for a frame
%% that is not to be sent (RFC 7587 section 3.1.3).
frames(Packet, _Ts) when byte_size(Packet) =< 2 -> [];
frames(Packet, Ts) -> [#{data => Packet, timestamp => Ts, keyframe => true}].

stats(#st{target = undefined}) -> #{};
stats(#st{target = Target}) -> #{targetBitrate => Target}.

%% What erlang_webrtc tells the encoder: the bitrate the application
%% asks for and the most the peer allows. They reach libopus with the
%% next audio. A key frame request means nothing to Opus.
-doc false.
control({target_bitrate, Bps}, #st{settings = Settings, max_bitrate = Max} = St) when
    is_integer(Bps), Bps > 0
->
    {ok, St#st{settings = clamp(Settings#{bitrate => Bps}, Max), target = undefined}};
control({max_bitrate, Limit}, St) when Limit =:= infinity; is_integer(Limit), Limit >= 0 ->
    {ok, St#st{peer_max = Limit, target = undefined}};
control(_Event, St) ->
    {ok, St}.

%% The stream ended: the codecs are destroyed now.
-doc false.
terminate(#st{decoder = Decoder, encoder = Encoder}) ->
    _ = Decoder =:= undefined orelse webrtc_codecs_opus_nif:decoder_close(Decoder),
    case Encoder of
        undefined -> ok;
        {Ref, _, _} -> webrtc_codecs_opus_nif:encoder_close(Ref)
    end.

%% Settings the raw map changes; they reach libopus in apply_settings/1.
raw_control(Raw, #st{settings = Settings, max_bitrate = Max} = St) ->
    Changes = maps:filter(fun valid/2, maps:with([bitrate, packet_loss], Raw)),
    case clamp(maps:merge(Settings, Changes), Max) of
        Settings -> St;
        New -> St#st{settings = New, target = undefined}
    end.

encoder(Rate, Channels, #st{encoder = {_, Rate, Channels}} = St) ->
    apply_settings(St);
encoder(Rate, Channels, #st{application = Application, settings = Settings} = St) ->
    case lists:member(Rate, ?RATES) andalso (Channels =:= 1 orelse Channels =:= 2) of
        true ->
            _ = terminate(St#st{decoder = undefined}),
            case webrtc_codecs_opus_nif:encoder_new(Rate, Channels, Application, Settings) of
                {ok, Encoder} ->
                    started(St#st{encoder = {Encoder, Rate, Channels}, auto = undefined});
                {error, Reason} ->
                    {error, {opus, Reason}}
            end;
        false ->
            {error, {bad_raw_audio, #{sample_rate => Rate, channels => Channels}}}
    end.

%% target is undefined while the encoder has not been given the settings.
apply_settings(#st{encoder = undefined} = St) ->
    {ok, St};
apply_settings(#st{target = Target} = St) when Target =/= undefined ->
    {ok, St};
apply_settings(#st{encoder = {Encoder, _, _}} = St) ->
    case webrtc_codecs_opus_nif:encoder_set(Encoder, effective(St)) of
        ok -> target(St);
        {error, Reason} -> {error, {opus, Reason}}
    end.

%% A new encoder has the settings of the options. Its bitrate is learned
%% first, so that a limit of the peer applies to the one libopus chose.
started(#st{settings = Settings} = St0) ->
    maybe
        {ok, #st{target = Target} = St1} ?= target(St0),
        St =
            case Settings of
                #{bitrate := _} -> St1;
                _ -> St1#st{auto = Target}
            end,
        case St#st.peer_max of
            infinity -> {ok, St};
            _ -> apply_settings(St#st{target = undefined})
        end
    end.

%% The settings within what the peer allows.
effective(#st{settings = #{bitrate := _} = Settings, peer_max = infinity}) ->
    Settings;
effective(#st{settings = #{bitrate := Bitrate} = Settings, peer_max = Max}) ->
    Settings#{bitrate := max(?MIN_BITRATE, min(Bitrate, Max))};
effective(#st{settings = Settings, auto = undefined}) ->
    Settings;
effective(#st{settings = Settings, auto = Auto, peer_max = infinity}) ->
    Settings#{bitrate => Auto};
effective(#st{settings = Settings, auto = Auto, peer_max = Max}) ->
    Settings#{bitrate => max(?MIN_BITRATE, min(Auto, Max))}.

target(#st{encoder = {Encoder, _, _}} = St) ->
    case webrtc_codecs_opus_nif:encoder_bitrate(Encoder) of
        {ok, Bitrate} -> {ok, St#st{target = Bitrate}};
        {error, Reason} -> {error, {opus, Reason}}
    end.

-doc false.
info(_St) ->
    #{implementation => webrtc_codecs_opus_nif:version(), power_efficient => false}.

ts(T) -> T band 16#FFFFFFFF.
