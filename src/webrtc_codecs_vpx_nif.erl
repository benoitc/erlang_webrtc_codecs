-module(webrtc_codecs_vpx_nif).
-moduledoc false.

%% libvpx (c_src/webrtc_codecs_vpx_nif.c). The module loads without the
%% NIF when libvpx was not there at build time: loaded/0 is then false
%% and every other function raises nif_not_loaded.

-export([loaded/0, version/0, fail_after/1]).
-export([decoder_new/3, decode/2]).
-export([encoder_new/4, encoder_bitrate/2, encode/7]).

-export_type([decoder/0, encoder/0, codec/0, reason/0, planes/0, settings/0]).

-on_load(init/0).

-opaque decoder() :: reference().
-opaque encoder() :: reference().
-type codec() :: vp8 | vp9.
-type reason() ::
    alloc_fail
    | abi_mismatch
    | incapable
    | unsupported_bitstream
    | unsupported_feature
    | unsupported_format
    | corrupt_frame
    | invalid_param
    | invalid_frame
    | too_large
    | bad_planes
    | internal_error.
%% Width, height and the Y, U and V planes without padding.
-type planes() :: {pos_integer(), pos_integer(), binary(), binary(), binary()}.
-type settings() :: #{
    bitrate => pos_integer(),
    threads => pos_integer(),
    cpu_used => integer(),
    keyframe_interval => pos_integer()
}.

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

-spec decoder_new(codec(), pos_integer(), pos_integer()) -> {ok, decoder()} | {error, reason()}.
decoder_new(_Codec, _Threads, _MaxPixels) -> erlang:nif_error(nif_not_loaded).

%% The pictures the frame gives (none for a frame that is not shown) and
%% the quantizer of the frame.
-spec decode(decoder(), binary()) -> {ok, [planes()], non_neg_integer()} | {error, reason()}.
decode(_Decoder, _Frame) -> erlang:nif_error(nif_not_loaded).

-spec encoder_new(codec(), pos_integer(), pos_integer(), settings()) ->
    {ok, encoder()} | {error, reason()}.
encoder_new(_Codec, _Width, _Height, _Settings) -> erlang:nif_error(nif_not_loaded).

-spec encoder_bitrate(encoder(), pos_integer()) -> ok | {error, reason()}.
encoder_bitrate(_Encoder, _Bitrate) -> erlang:nif_error(nif_not_loaded).

%% Pts and Duration in 90 kHz units; Pts grows from one call to the next.
-spec encode(encoder(), binary(), binary(), binary(), non_neg_integer(), pos_integer(), boolean()) ->
    {ok, [{binary(), boolean()}], non_neg_integer()} | {error, reason()}.
encode(_Encoder, _Y, _U, _V, _Pts, _Duration, _ForceKey) -> erlang:nif_error(nif_not_loaded).
