-module(webrtc_codecs_dav1d_nif).
-moduledoc false.

%% dav1d (c_src/webrtc_codecs_dav1d_nif.c). The module loads without the
%% NIF when dav1d was not there at build time: loaded/0 is then false
%% and every other function raises nif_not_loaded.

-export([loaded/0, version/0]).
-export([decoder_new/2, decode/2]).

-export_type([decoder/0, reason/0]).

-on_load(init/0).

-opaque decoder() :: reference().
-type reason() ::
    alloc_fail
    | too_large
    | unsupported_bitstream
    | unsupported_format
    | invalid_frame
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

-spec decoder_new(pos_integer(), pos_integer()) -> {ok, decoder()} | {error, reason()}.
decoder_new(_Threads, _MaxPixels) -> erlang:nif_error(nif_not_loaded).

%% The pictures a temporal unit shows and the quantizer of the last one.
-spec decode(decoder(), binary()) ->
    {ok, [webrtc_codecs_video:planes()], non_neg_integer()} | {error, reason()}.
decode(_Decoder, _TemporalUnit) -> erlang:nif_error(nif_not_loaded).
