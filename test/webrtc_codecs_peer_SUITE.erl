%% The plugins inside erlang_webrtc: two peer connections on loopback,
%% one encoding with send_media/3, the other decoding what it receives.
-module(webrtc_codecs_peer_SUITE).
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([pcmu/1, pcma/1]).

all() -> [pcmu, pcma].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(webrtc),
    Config.

end_per_suite(_Config) ->
    ok.

pcmu(_Config) -> g711(<<"PCMU">>).

pcma(_Config) -> g711(<<"PCMA">>).

%% A sends a second of tone in 20 ms frames; B gets the same samples
%% back within G.711's precision, and both report the plugin's members.
g711(Name) ->
    Plugin = {webrtc_codecs, #{}},
    Codecs = #{
        audio => [C || #{name := N} = C <- webrtc_jsep_caps:default_codecs(audio), N =:= Name]
    },
    {ok, A} = webrtc:new_peer_connection(#{loopback => true, codecs => Codecs}),
    {ok, B} = webrtc:new_peer_connection(#{
        loopback => true, codecs => Codecs, frames => true, codec_plugins => #{audio => Plugin}
    }),
    {ok, _} = webrtc:add_transceiver(A, audio, #{frames => true, codec_plugin => Plugin}),
    ok = connect(A, B),
    Format = #{sample_rate => 8000, channels => 1},
    Count = 50,
    [
        begin
            ok = webrtc:send_media(
                A, <<"0">>, webrtc_codecs_pattern:tone(440, 20, Format, I * 160)
            ),
            timer:sleep(20)
        end
     || I <- lists:seq(0, Count - 1)
    ],
    Decoded = collect(
        B,
        fun
            ({decoded, <<"0">>, #{samples := _}}) -> true;
            (_) -> false
        end,
        Count,
        5000
    ),
    ?assertEqual(Count, length(Decoded)),
    ?assertEqual(
        [I * 160 || I <- lists:seq(0, Count - 1)], [T || {decoded, _, #{timestamp := T}} <- Decoded]
    ),
    Received = #{samples => iolist_to_binary([S || {decoded, _, #{samples := S}} <- Decoded])},
    Sent = webrtc_codecs_pattern:tone(440, 20 * Count, Format, 0),
    ?assert(webrtc_codecs_pattern:snr(Sent, Received) > 30),
    timer:sleep(200),
    [#{targetBitrate := 64000, encoderImplementation := <<"webrtc_codecs G.711">>}] =
        [
            O
         || _ := #{type := <<"outbound-rtp">>, kind := <<"audio">>} = O <- webrtc:get_stats(A, #{
                format => w3c
            })
        ],
    [#{totalSamplesReceived := 8000, decoderImplementation := <<"webrtc_codecs G.711">>}] =
        [
            O
         || _ := #{type := <<"inbound-rtp">>, kind := <<"audio">>} = O <- webrtc:get_stats(B, #{
                format => w3c
            })
        ],
    ok = webrtc:close(A),
    ok = webrtc:close(B).

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
