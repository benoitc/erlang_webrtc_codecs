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
main(Args) ->
    case value("-pidfile", Args) of
        undefined -> ok;
        File -> ok = file:write_file(File, os:getpid())
    end,
    run(value("-mode", Args), Args).

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
