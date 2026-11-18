-module(webrtc_codecs_nif).
-moduledoc false.

%% Where the codec NIFs are. Each NIF module loads its own library in
%% its on_load, since erlang:load_nif/2 only serves the calling module.

-export([path/1]).

-spec path(atom()) -> file:filename_all().
path(Module) ->
    Dir =
        case code:priv_dir(webrtc_codecs) of
            {error, _} ->
                filename:join(filename:dirname(filename:dirname(code:which(?MODULE))), "priv");
            Priv ->
                Priv
        end,
    filename:join(Dir, atom_to_list(Module)).
