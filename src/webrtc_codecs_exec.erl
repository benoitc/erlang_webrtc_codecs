-module(webrtc_codecs_exec).
-moduledoc false.

%% An external program (ffmpeg, ffplay) and its end, for the processes
%% that run one: capture and playback.
%%
%% The program is started without a shell, so the process id the port
%% knows is the program's. What it writes to its standard output and
%% error comes as port data, of which only the end is kept. stop/2 does
%% not return before the program is gone: it waits for it, then asks it
%% to end, then kills it.
%%
%% The process that calls open/2 owns the port and gets its messages;
%% it passes them to handle/2.

-export([open/2, handle/2, poll/1, write/2, exited/1, tail/1, stop/2, run/3]).
-export([listen/0, close_listen/1]).

-export_type([exec/0, ended/0, endpoint/0]).

%% What is kept of what the program says.
-define(TAIL, 4096).
%% Between asking a program to end and killing it, and after killing it.
-define(TERM_MS, 2000).
-define(KILL_MS, 2000).

-record(exec, {
    port :: port(),
    os_pid :: undefined | non_neg_integer(),
    tail = <<>> :: binary(),
    %% The exit status once the program has ended by itself.
    status :: undefined | integer()
}).

-opaque exec() :: #exec{}.
%% How a program ended: by itself with a status, or killed by stop/2,
%% with the end of what it said.
-type ended() :: {exited, integer(), binary()} | {killed, binary()}.
%% A socket a program connects to, in place of a pipe: the address for
%% its command line, the listening socket, and what to remove after.
-type endpoint() :: #{
    url := string(), socket := gen_tcp:socket(), dir := undefined | file:filename()
}.

-doc "Start a program. The caller owns the port.".
-spec open(file:filename_all(), [string()]) -> exec().
open(Exe, Args) ->
    Port = open_port({spawn_executable, Exe}, [
        {args, Args}, binary, stream, exit_status, stderr_to_stdout, hide
    ]),
    OsPid =
        case erlang:port_info(Port, os_pid) of
            {os_pid, Pid} -> Pid;
            undefined -> undefined
        end,
    #exec{port = Port, os_pid = OsPid}.

-doc """
Take a message the owner received. `{ok, Exec}` for what the program
said, `{exited, Exec}` when it has ended, `ignore` for a message that is
not of this program.
""".
-spec handle(term(), exec()) -> {ok, exec()} | {exited, exec()} | ignore.
handle({Port, {data, Data}}, #exec{port = Port} = Exec) ->
    {ok, said(Data, Exec)};
handle({Port, {exit_status, Status}}, #exec{port = Port} = Exec) ->
    {exited, Exec#exec{status = Status}};
handle({'EXIT', Port, _Reason}, #exec{port = Port, status = undefined} = Exec) ->
    %% The port went without a status, on a write to a program that was
    %% gone: it has ended, how is not known.
    {exited, Exec#exec{status = -1}};
handle({'EXIT', Port, _Reason}, #exec{port = Port} = Exec) ->
    {ok, Exec};
handle(_Msg, _Exec) ->
    ignore.

-doc "Take the messages of the program that are waiting, without waiting for more.".
-spec poll(exec()) -> exec().
poll(#exec{port = Port} = Exec) ->
    receive
        {Port, {data, Data}} -> poll(said(Data, Exec));
        {Port, {exit_status, Status}} -> poll(Exec#exec{status = Status});
        {'EXIT', Port, _} when Exec#exec.status =:= undefined -> poll(Exec#exec{status = -1});
        {'EXIT', Port, _} -> poll(Exec)
    after 0 ->
        Exec
    end.

said(Data, #exec{tail = Tail} = Exec) ->
    All = <<Tail/binary, Data/binary>>,
    Keep = min(byte_size(All), ?TAIL),
    Exec#exec{tail = binary:part(All, byte_size(All) - Keep, Keep)}.

-doc """
Write to the standard input of the program, all of the data or none:
`false` when the program is behind and the data was not taken, `closed`
when the program is gone.
""".
-spec write(exec(), iodata()) -> true | false | closed.
write(#exec{status = undefined, port = Port}, Data) ->
    try
        erlang:port_command(Port, Data, [nosuspend])
    catch
        error:badarg -> closed
    end;
write(#exec{}, _Data) ->
    closed.

-doc "The exit status if the program has ended by itself.".
-spec exited(exec()) -> {true, integer()} | false.
exited(#exec{status = undefined}) -> false;
exited(#exec{status = Status}) -> {true, Status}.

-doc "The end of what the program said, trimmed.".
-spec tail(exec()) -> binary().
tail(#exec{tail = Tail}) ->
    string:trim(Tail).

-doc """
End the program and return how it ended. A program that has not ended
by itself after `Grace` milliseconds is sent SIGTERM, then SIGKILL two
seconds later. The port is closed in every case.
""".
-spec stop(exec(), non_neg_integer()) -> ended().
stop(#exec{status = undefined} = Exec0, Grace) ->
    case wait(Exec0, deadline(Grace)) of
        #exec{status = undefined} = Exec1 ->
            signal("TERM", Exec1),
            case wait(Exec1, deadline(?TERM_MS)) of
                #exec{status = undefined} = Exec2 ->
                    signal("KILL", Exec2),
                    Exec3 = wait(Exec2, deadline(?KILL_MS)),
                    close(Exec3),
                    {killed, tail(Exec3)};
                Exec2 ->
                    close(Exec2),
                    {killed, tail(Exec2)}
            end;
        Exec1 ->
            stop(Exec1, 0)
    end;
stop(#exec{status = Status} = Exec, _Grace) ->
    close(Exec),
    {exited, Status, tail(Exec)}.

deadline(Ms) ->
    erlang:monotonic_time(millisecond) + Ms.

%% Take the messages of the port until the program ends or the deadline.
wait(#exec{port = Port} = Exec, Deadline) ->
    receive
        {Port, {data, Data}} -> wait(said(Data, Exec), Deadline);
        {Port, {exit_status, Status}} -> Exec#exec{status = Status};
        {'EXIT', Port, _} -> Exec#exec{status = -1}
    after max(0, Deadline - erlang:monotonic_time(millisecond)) ->
        Exec
    end.

signal(_Name, #exec{os_pid = undefined}) ->
    ok;
signal(Name, #exec{os_pid = OsPid}) ->
    case os:type() of
        {unix, _} ->
            _ = os:cmd("kill -" ++ Name ++ " " ++ integer_to_list(OsPid) ++ " 2>/dev/null"),
            ok;
        _ ->
            ok
    end.

%% The port may already be closed, and a late message of it stay behind.
close(#exec{port = Port}) ->
    try
        port_close(Port)
    catch
        error:badarg -> true
    end,
    flush(Port).

flush(Port) ->
    receive
        {Port, _} -> flush(Port);
        {'EXIT', Port, _} -> flush(Port)
    after 0 -> ok
    end.

-doc """
Run a program to its end and give what it wrote, at most `MaxBytes`,
and how it ended. It is ended when it has not finished `Timeout`
milliseconds from now, however much it writes meanwhile.
""".
-spec run(file:filename_all(), [string()], #{timeout := pos_integer(), max_bytes := pos_integer()}) ->
    {ended(), binary()}.
run(Exe, Args, #{timeout := Timeout, max_bytes := MaxBytes}) ->
    Flag = process_flag(trap_exit, true),
    try
        collect(open(Exe, Args), deadline(Timeout), MaxBytes, <<>>)
    after
        process_flag(trap_exit, Flag)
    end.

collect(#exec{port = Port} = Exec, Deadline, MaxBytes, Acc) ->
    receive
        {Port, {data, Data}} when byte_size(Acc) < MaxBytes ->
            Room = MaxBytes - byte_size(Acc),
            Part = binary:part(Data, 0, min(Room, byte_size(Data))),
            collect(Exec, Deadline, MaxBytes, <<Acc/binary, Part/binary>>);
        {Port, {data, _}} ->
            collect(Exec, Deadline, MaxBytes, Acc);
        {Port, {exit_status, Status}} ->
            {stop(Exec#exec{status = Status}, 0), Acc};
        {'EXIT', Port, _} ->
            {stop(Exec#exec{status = -1}, 0), Acc}
    after max(0, Deadline - erlang:monotonic_time(millisecond)) ->
        {stop(Exec, 0), Acc}
    end.

-doc """
A socket for a program to connect to and exchange media on, so that the
flow is controlled as on any socket. On Unix it is a socket in a
directory only this user can enter; elsewhere a TCP socket on the
loopback address.
""".
-spec listen() -> {ok, endpoint()} | {error, term()}.
listen() ->
    Options = [binary, {active, false}, {packet, raw}, {backlog, 1}],
    case os:type() of
        {unix, _} ->
            Dir = filename:join(
                tmp_dir(), "wc-" ++ integer_to_list(erlang:unique_integer([positive])) ++ random()
            ),
            Path = filename:join(Dir, "s"),
            maybe
                ok ?= file:make_dir(Dir),
                ok ?= file:change_mode(Dir, 8#700),
                {ok, Socket} ?= gen_tcp:listen(0, [{ifaddr, {local, Path}} | Options]),
                {ok, #{url => "unix:" ++ Path, socket => Socket, dir => Dir}}
            else
                {error, Reason} ->
                    _ = file:del_dir_r(Dir),
                    {error, {listen, Reason}}
            end;
        _ ->
            maybe
                {ok, Socket} ?= gen_tcp:listen(0, [{ip, {127, 0, 0, 1}} | Options]),
                {ok, Port} ?= inet:port(Socket),
                {ok, #{
                    url => "tcp://127.0.0.1:" ++ integer_to_list(Port),
                    socket => Socket,
                    dir => undefined
                }}
            else
                {error, Reason} -> {error, {listen, Reason}}
            end
    end.

-doc "Stop listening and remove what `listen/0` made.".
-spec close_listen(endpoint()) -> ok.
close_listen(#{socket := Socket, dir := Dir}) ->
    _ = gen_tcp:close(Socket),
    _ = Dir =/= undefined andalso file:del_dir_r(Dir),
    ok.

tmp_dir() ->
    case os:getenv("TMPDIR") of
        false -> "/tmp";
        Dir -> Dir
    end.

%% A name another user cannot guess before the directory exists.
random() ->
    binary_to_list(binary:encode_hex(crypto:strong_rand_bytes(6))).
