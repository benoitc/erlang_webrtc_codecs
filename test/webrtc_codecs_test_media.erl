%% Test helper: the encoded video of test/corpus, and FFmpeg as a
%% reference decoder.
-module(webrtc_codecs_test_media).

-export([
    root/0, corpus/1, ivf/1, reference/3, ffmpeg_encode/2, frames/2, decode/3, decode_all/3, sum/2
]).

%% The path of a corpus file: the encoded video of test/corpus.
corpus(File) ->
    Path = filename:join([root(), "test", "corpus", File]),
    true = filelib:is_regular(Path),
    Path.

%% The directory of this package, from wherever the tests run.
root() ->
    {ok, Cwd} = file:get_cwd(),
    up(Cwd).

up("/") ->
    "/";
up(Dir) ->
    case
        filelib:is_dir(filename:join(Dir, "c_src")) andalso
            filelib:is_regular(filename:join(Dir, "rebar.config"))
    of
        true -> Dir;
        false -> up(filename:dirname(Dir))
    end.

%% IVF: a 32 byte header, then per frame a 4 byte size and an 8 byte
%% timestamp, little endian.
ivf(Path) ->
    {ok, <<"DKIF", _:28/binary, Rest/binary>>} = file:read_file(Path),
    ivf_frames(Rest).

ivf_frames(<<Size:32/little, _Pts:64/little, Frame:Size/binary, Rest/binary>>) ->
    [Frame | ivf_frames(Rest)];
ivf_frames(<<>>) ->
    [].

%% The pictures FFmpeg decodes from a file, as raw picture maps without
%% timestamps; false without ffmpeg.
reference(Path, W, H) ->
    case os:find_executable("ffmpeg") of
        false ->
            false;
        Ffmpeg ->
            Out = string:trim(os:cmd("mktemp")),
            Cmd = io_lib:format(
                "'~ts' -v error -y -i '~ts' -pix_fmt yuv420p -f rawvideo '~ts' 2>&1", [
                    Ffmpeg, Path, Out
                ]
            ),
            "" = os:cmd(lists:flatten(Cmd)),
            {ok, Raw} = file:read_file(Out),
            ok = file:delete(Out),
            Cw = (W + 1) div 2,
            Ch = (H + 1) div 2,
            [
                #{format => i420, width => W, height => H, y => Y, u => U, v => V}
             || <<Y:(W * H)/binary, U:(Cw * Ch)/binary, V:(Cw * Ch)/binary>> <= Raw
            ]
    end.

%% Twelve 176 x 144 pictures of FFmpeg's test source encoded with the
%% given output options, as erlang_webrtc's corpus is made: the path of
%% a temporary file to delete, or false without ffmpeg or its encoder.
ffmpeg_encode(Options, Extension) ->
    case os:find_executable("ffmpeg") of
        false ->
            false;
        Ffmpeg ->
            File = string:trim(os:cmd("mktemp")) ++ Extension,
            Cmd = io_lib:format(
                "'~ts' -v error -y -f lavfi -i testsrc=size=176x144:rate=30 -frames:v 12 ~s '~ts' 2>&1",
                [Ffmpeg, Options, File]
            ),
            case os:cmd(lists:flatten(Cmd)) of
                "" ->
                    File;
                _ ->
                    _ = file:delete(File),
                    false
            end
    end.

%% Encoded frames as decode/2 takes them, 30 per second from timestamp 0.
frames(Datas, IsKey) ->
    [
        #{data => D, timestamp => I * 3000, keyframe => IsKey(D)}
     || {I, D} <- lists:enumerate(0, Datas)
    ].

%% decode/2 without what it asks of the sender, which some tests do not
%% look at.
decode(Mod, Frame, St0) ->
    case Mod:decode(Frame, St0) of
        {ok, Outs, Stats, St, _Feedback} -> {ok, Outs, Stats, St};
        Other -> Other
    end.

%% Run decode/2 over frames: the outputs, the statistics added up, the state.
decode_all(Mod, Frames, St0) ->
    {Outs, {Stats, St}} = lists:mapfoldl(
        fun(Frame, {Acc, StA}) ->
            {ok, Out, Stats, StB} = decode(Mod, Frame, StA),
            {Out, {sum(Acc, Stats), StB}}
        end,
        {#{}, St0},
        Frames
    ),
    {lists:append(Outs), Stats, St}.

%% Merge statistics the way erlang_webrtc does: counters add up, the
%% other members replace the previous value.
sum(A, B) ->
    maps:merge_with(
        fun
            (targetBitrate, _, Y) -> Y;
            (_, X, Y) when is_number(X), is_number(Y) -> X + Y;
            (_, _, Y) -> Y
        end,
        A,
        B
    ).
