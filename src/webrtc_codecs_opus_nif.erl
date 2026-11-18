-module(webrtc_codecs_opus_nif).
-moduledoc false.

%% libopus (c_src/webrtc_codecs_opus_nif.c). The module loads without
%% the NIF when libopus was not there at build time: loaded/0 is then
%% false and every other function raises nif_not_loaded.

-export([loaded/0, version/0]).
-export([decoder_new/2, decode/2, decode_fec/3, conceal/2]).
-export([encoder_new/4, encoder_set/2, encoder_bitrate/1, encode/2]).

-export_type([decoder/0, encoder/0, reason/0, settings/0]).

-on_load(init/0).

-opaque decoder() :: reference().
-opaque encoder() :: reference().
-type reason() ::
    bad_arg
    | buffer_too_small
    | invalid_packet
    | unimplemented
    | invalid_state
    | alloc_fail
    | internal_error.
-type settings() :: #{
    bitrate => pos_integer(),
    complexity => 0..10,
    fec => boolean(),
    dtx => boolean(),
    packet_loss => 0..100
}.

init() ->
    Dir =
        case code:priv_dir(webrtc_codecs) of
            {error, _} ->
                filename:join(filename:dirname(filename:dirname(code:which(?MODULE))), "priv");
            Priv ->
                Priv
        end,
    %% A missing or unloadable NIF leaves the stubs below in place.
    _ = erlang:load_nif(filename:join(Dir, "webrtc_codecs_opus_nif"), 0),
    ok.

-spec loaded() -> boolean().
loaded() ->
    try version() of
        _ -> true
    catch
        error:nif_not_loaded -> false
    end.

-spec version() -> binary().
version() -> erlang:nif_error(nif_not_loaded).

-spec decoder_new(pos_integer(), 1 | 2) -> {ok, decoder()} | {error, reason()}.
decoder_new(_Rate, _Channels) -> erlang:nif_error(nif_not_loaded).

-spec decode(decoder(), binary()) -> {ok, binary()} | {error, reason()}.
decode(_Decoder, _Packet) -> erlang:nif_error(nif_not_loaded).

-spec decode_fec(decoder(), binary(), pos_integer()) -> {ok, binary()} | {error, reason()}.
decode_fec(_Decoder, _Packet, _Samples) -> erlang:nif_error(nif_not_loaded).

-spec conceal(decoder(), pos_integer()) -> {ok, binary()} | {error, reason()}.
conceal(_Decoder, _Samples) -> erlang:nif_error(nif_not_loaded).

-spec encoder_new(pos_integer(), 1 | 2, voip | audio | lowdelay, settings()) ->
    {ok, encoder()} | {error, reason()}.
encoder_new(_Rate, _Channels, _Application, _Settings) -> erlang:nif_error(nif_not_loaded).

-spec encoder_set(encoder(), settings()) -> ok | {error, reason()}.
encoder_set(_Encoder, _Settings) -> erlang:nif_error(nif_not_loaded).

-spec encoder_bitrate(encoder()) -> {ok, integer()} | {error, reason()}.
encoder_bitrate(_Encoder) -> erlang:nif_error(nif_not_loaded).

-spec encode(encoder(), binary()) -> {ok, binary()} | {error, reason()}.
encode(_Encoder, _Pcm) -> erlang:nif_error(nif_not_loaded).
