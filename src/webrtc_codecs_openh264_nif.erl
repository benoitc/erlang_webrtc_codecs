-module(webrtc_codecs_openh264_nif).
-moduledoc false.

%% OpenH264 (c_src/webrtc_codecs_openh264_nif.c). The module loads
%% without the NIF when OpenH264 was not there at build time: loaded/0
%% is then false and every other function raises nif_not_loaded.

-export([loaded/0, version/0, fail_after/1]).
-export([decoder_close/1, encoder_close/1]).
-export([decoder_new/1, decode/2]).
-export([encoder_new/3, encoder_bitrate/2, encode/6]).

-export_type([decoder/0, encoder/0, reason/0]).

-on_load(init/0).

-opaque decoder() :: reference().
-opaque encoder() :: reference().
-type reason() ::
    closed
    | alloc_fail
    | no_parameter_sets
    | reference_lost
    | corrupt_frame
    | invalid_frame
    | invalid_param
    | too_large
    | unsupported_format
    | bad_planes
    | internal_error.

init() ->
    %% A missing or unloadable NIF leaves the stubs below in place.
    _ = erlang:load_nif(webrtc_codecs_nif:path(?MODULE), 0),
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

%% Only in a build with WEBRTC_CODECS_FAULT_INJECTION: the Nth allocation
%% from now on fails, once; 0 disarms. Raises nif_not_loaded elsewhere.
-spec fail_after(non_neg_integer()) -> ok.
fail_after(_Count) -> erlang:nif_error(nif_not_loaded).

-spec decoder_new(pos_integer()) -> {ok, decoder()} | {error, reason()}.
decoder_new(_MaxPixels) -> erlang:nif_error(nif_not_loaded).

%% The picture an access unit gives, if it gives one.
-spec decode(decoder(), binary()) -> {ok, [webrtc_codecs_video:planes()]} | {error, reason()}.
decode(_Decoder, _AccessUnit) -> erlang:nif_error(nif_not_loaded).

-spec encoder_new(pos_integer(), pos_integer(), webrtc_codecs_video:settings()) ->
    {ok, encoder()} | {error, reason()}.
encoder_new(_Width, _Height, _Settings) -> erlang:nif_error(nif_not_loaded).

-spec encoder_bitrate(encoder(), pos_integer()) -> ok | {error, reason()}.
encoder_bitrate(_Encoder, _Bitrate) -> erlang:nif_error(nif_not_loaded).

%% Pts in 90 kHz units. No frame for a picture the encoder skips.
-spec encode(encoder(), binary(), binary(), binary(), non_neg_integer(), boolean()) ->
    {ok, [{binary(), boolean()}]} | {error, reason()}.
encode(_Encoder, _Y, _U, _V, _Pts, _ForceKey) -> erlang:nif_error(nif_not_loaded).

%% Destroys the codec now instead of when the reference is collected.
%% Calls on it then give `{error, closed}`.
-spec decoder_close(decoder()) -> ok.
decoder_close(_Decoder) -> erlang:nif_error(nif_not_loaded).

%% Destroys the codec now instead of when the reference is collected.
%% Calls on it then give `{error, closed}`.
-spec encoder_close(encoder()) -> ok.
encoder_close(_Encoder) -> erlang:nif_error(nif_not_loaded).
