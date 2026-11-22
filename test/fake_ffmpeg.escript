#!/usr/bin/env escript
%% A program that stands in for ffmpeg or ffplay in the capture and
%% playback tests and misbehaves on demand. It takes the command line
%% the real one would get, finds the socket address in it, and acts as
%% told by `-mode Name`:
%%
%%   bad_header     write bytes that are no stream, for ever
%%   flood          write zeros as fast as they are taken, for ever
%%   ignore_close   connect, write nothing, ignore SIGTERM
%%   noisy          print 200 kB of text, then exit with status 3
%%   noisy_forever  print text for ever
%%   never_read     connect and never read
%%   ignore_eof     read to the end of input, then stay, ignoring SIGTERM
%%
%% `-pidfile Path` writes its process id there.
%%
%% Asked for `-devices` it lists the input devices named in the
%% environment variable FAKE_FFMPEG_DEVICES (separated by commas), and
%% for `-sources Backend` the sources FAKE_FFMPEG_SOURCES tells: `two`,
%% `none`, or `forever` for a listing that does not end.
main(Args) ->
    case value("-pidfile", Args) of
        undefined -> ok;
        File -> ok = file:write_file(File, os:getpid())
    end,
    case {lists:member("-devices", Args), value("-sources", Args)} of
        {true, _} -> devices();
        {false, undefined} -> run(value("-mode", Args), Args);
        {false, Backend} -> sources(Backend, os:getenv("FAKE_FFMPEG_SOURCES", "two"))
    end.

devices() ->
    io:put_chars("Devices:\n D. = Demuxing supported\n .E = Muxing supported\n ---\n"),
    io:put_chars(" D  lavfi           Libavfilter virtual input device\n"),
    io:put_chars("  E sdl,sdl2        SDL2 output device\n"),
    [
        io:put_chars([" DE ", string:pad(Name, 15), " an audio device\n"])
     || Name <- string:tokens(os:getenv("FAKE_FFMPEG_DEVICES", ""), ",")
    ],
    halt(0).

sources(Backend, "two") ->
    io:put_chars(["Auto-detected sources for ", Backend, ":\n"]),
    io:put_chars("  out.monitor [Monitor of Built-in Audio]\n"),
    io:put_chars("* in.analog-stereo [Built-in Audio [Analog] Stereo] (audio)\n"),
    halt(0);
sources(Backend, "none") ->
    io:put_chars(["Cannot list sources: ", Backend, "\n"]),
    halt(1);
sources(Backend, "forever") ->
    io:put_chars("  again [and again]\n"),
    sources(Backend, "forever").

value(Name, [Name, Value | _]) -> Value;
value(Name, [_ | Rest]) -> value(Name, Rest);
value(_Name, []) -> undefined.

connect(Args) ->
    ["unix:" ++ Path | _] = [A || "unix:" ++ _ = A <- Args],
    {ok, Socket} = gen_tcp:connect({local, Path}, 0, [binary, {active, false}]),
    Socket.

run("bad_header", Args) ->
    write(connect(Args), binary:copy(<<"not a stream ">>, 5000));
run("flood", Args) ->
    write(connect(Args), binary:copy(<<0>>, 65536));
run("ignore_close", Args) ->
    ok = os:set_signal(sigterm, ignore),
    _ = connect(Args),
    timer:sleep(infinity);
run("noisy", _Args) ->
    [io:put_chars(["line ", integer_to_list(I), " of what went wrong\n"]) || I <- lists:seq(1, 8000)],
    halt(3);
run("noisy_forever", Args) ->
    io:put_chars("something to say, again and again\n"),
    run("noisy_forever", Args);
run("never_read", Args) ->
    _ = connect(Args),
    timer:sleep(infinity);
run("ignore_eof", Args) ->
    ok = os:set_signal(sigterm, ignore),
    read(connect(Args)),
    timer:sleep(infinity).

write(Socket, Data) ->
    case gen_tcp:send(Socket, Data) of
        ok -> write(Socket, Data);
        {error, _} -> halt(1)
    end.

read(Socket) ->
    case gen_tcp:recv(Socket, 0) of
        {ok, _} -> read(Socket);
        {error, _} -> ok
    end.
