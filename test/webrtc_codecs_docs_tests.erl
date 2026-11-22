%% The documentation against the repository, for what a test can tell:
%% the module map names every source module and no module that is gone,
%% every link between pages leads to a file, and every guide is in the
%% documentation build, and every call in a code block names a function
%% that exists. It does not read the prose, nor check the arguments.
-module(webrtc_codecs_docs_tests).
-include_lib("eunit/include/eunit.hrl").

root() -> webrtc_codecs_test_media:root().

read(Path) ->
    {ok, Text} = file:read_file(filename:join(root(), Path)),
    Text.

pages() ->
    ["README.md", "CONTRIBUTING.md", "SECURITY.md", "CHANGELOG.md", "AGENTS.md"] ++
        [
            "docs/" ++ filename:basename(F)
         || F <- filelib:wildcard(filename:join([root(), "docs", "*.md"]))
        ].

%% Every module of src and c_src is in the module map, and the map names
%% no file that does not exist.
module_map_test() ->
    Map = read("docs/module-map.md"),
    Sources =
        [filename:basename(F) || F <- filelib:wildcard(filename:join([root(), "src", "*.erl"]))] ++
            [
                filename:basename(F)
             || F <- filelib:wildcard(filename:join([root(), "c_src", "*.{c,h}"]))
            ],
    Named = lists:usort([
        binary_to_list(F)
     || [F] <- element(
            2,
            re:run(Map, "(?:src|c_src)/(webrtc_codecs[a-z0-9_]*\\.(?:erl|c|h))", [
                global, {capture, [1], binary}
            ])
        )
    ]),
    %% The NIF modules are named by a pattern, `webrtc_codecs_<lib>_nif`.
    Pattern = fun(File) -> re:run(File, "^webrtc_codecs_[a-z0-9]+_nif\\.(erl|c)$") =/= nomatch end,
    ?assertEqual([], [F || F <- Named, not lists:member(F, Sources)]),
    ?assertEqual([], [F || F <- Sources, not lists:member(F, Named), not Pattern(F)]),
    ?assertNotEqual(nomatch, binary:match(Map, <<"webrtc_codecs_<lib>_nif">>)).

%% Every test file the module map names exists.
module_map_tests_test() ->
    Map = read("docs/module-map.md"),
    {match, Tests} = re:run(Map, "`(test/[A-Za-z0-9_./]+)`", [global, {capture, [1], list}]),
    ?assertEqual([], [T || [T] <- Tests, not filelib:is_file(filename:join(root(), T))]).

%% Every link from one page to a file of the repository leads somewhere.
links_test() ->
    Broken = [
        {Page, Target}
     || Page <- pages(),
        [Target0] <- links(read(Page)),
        Target <- [hd(string:split(Target0, "#"))],
        Target =/= "",
        not lists:prefix("http", Target),
        not filelib:is_file(filename:join([root(), filename:dirname(Page), Target]))
    ],
    ?assertEqual([], Broken).

%% The targets of Markdown links: what is between the parentheses of
%% [text](target), when it reads as a path or an address.
links(Text) ->
    case re:run(Text, "\\]\\(([A-Za-z0-9_./:#~-]+)\\)", [global, {capture, [1], list}]) of
        {match, Links} -> Links;
        nomatch -> []
    end.

%% Every call to this package or to erlang_webrtc in an Erlang block of
%% a page names an exported function, so a guide does not keep a call
%% that was renamed or removed.
calls_test() ->
    Unknown = [
        {Page, Call}
     || Page <- pages(),
        not lists:prefix("docs/reviews", Page),
        Block <- erlang_blocks(read(Page)),
        [M, F] = Call <- calls(Block),
        not exported(list_to_atom(M), list_to_atom(F))
    ],
    ?assertEqual([], lists:usort(Unknown)).

erlang_blocks(Text) ->
    case re:run(Text, "```erlang\\n(.*?)```", [global, dotall, {capture, [1], binary}]) of
        {match, Blocks} -> [B || [B] <- Blocks];
        nomatch -> []
    end.

calls(Block) ->
    case
        re:run(Block, "\\b(webrtc[a-z0-9_]*):([a-z][A-Za-z0-9_]*)\\(", [
            global, {capture, [1, 2], list}
        ])
    of
        {match, Calls} -> Calls;
        nomatch -> []
    end.

exported(Module, Function) ->
    code:ensure_loaded(Module) =:= {module, Module} andalso
        lists:keymember(Function, 1, Module:module_info(exports)).

%% Every guide under docs is built into the documentation, and the build
%% lists no page that is gone.
ex_doc_extras_test() ->
    {ok, Config} = file:consult(filename:join(root(), "rebar.config")),
    Extras = [
        binary_to_list(E)
     || E <- proplists:get_value(extras, proplists:get_value(ex_doc, Config))
    ],
    Guides = [P || "docs/" ++ _ = P <- pages()],
    ?assertEqual([], [G || G <- Guides, not lists:member(G, Extras)]),
    ?assertEqual([], [E || E <- Extras, not filelib:is_file(filename:join(root(), E))]).

%% Every codec the README lists is one a full build has, and the reverse.
readme_codecs_test() ->
    case os:getenv("WEBRTC_CODECS_REQUIRE") of
        Required when Required =:= false; Required =:= "" ->
            ok;
        _ ->
            Readme = read("README.md"),
            [
                ?assertNotEqual(nomatch, binary:match(Readme, Label))
             || #{name := Name} <- webrtc_codecs:available(),
                Label <- [label(Name)]
            ]
    end.

label(<<"opus">>) -> <<"| Opus |">>;
label(<<"PCMU">>) -> <<"PCMU">>;
label(<<"PCMA">>) -> <<"PCMA">>;
label(<<"H264">>) -> <<"H.264">>;
label(Name) -> Name.
