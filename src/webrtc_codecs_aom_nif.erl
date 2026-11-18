-module(webrtc_codecs_aom_nif).
-moduledoc false.

%% libaom (c_src/webrtc_codecs_aom_nif.c). The module loads without the
%% NIF when libaom was not there at build time: loaded/0 is then false
%% and every other function raises nif_not_loaded.

-export([loaded/0, version/0]).
-export([encoder_new/3, encoder_bitrate/2, encode/7]).

-export_type([encoder/0, reason/0]).

-on_load(init/0).

-opaque encoder() :: reference().
-type reason() ::
    alloc_fail
    | abi_mismatch
    | incapable
    | unsupported_bitstream
    | unsupported_feature
    | corrupt_frame
    | invalid_param
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

-spec encoder_new(pos_integer(), pos_integer(), webrtc_codecs_video:settings()) ->
    {ok, encoder()} | {error, reason()}.
encoder_new(_Width, _Height, _Settings) -> erlang:nif_error(nif_not_loaded).

-spec encoder_bitrate(encoder(), pos_integer()) -> ok | {error, reason()}.
encoder_bitrate(_Encoder, _Bitrate) -> erlang:nif_error(nif_not_loaded).

%% Pts and Duration in 90 kHz units; Pts grows from one call to the next.
-spec encode(encoder(), binary(), binary(), binary(), non_neg_integer(), pos_integer(), boolean()) ->
    {ok, [{binary(), boolean()}], non_neg_integer()} | {error, reason()}.
encode(_Encoder, _Y, _U, _V, _Pts, _Duration, _ForceKey) -> erlang:nif_error(nif_not_loaded).
