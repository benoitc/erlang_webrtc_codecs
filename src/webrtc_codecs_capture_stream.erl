-module(webrtc_codecs_capture_stream).
-moduledoc false.

%% What FFmpeg writes for a capture, cut into pictures, chunks of audio
%% or encoded frames and sent to the owner, unless the owner is behind.
%% It runs in the capture process, which gives it the bytes as they come
%% and stops when the bytes are not the stream that was asked for.

-export([new/5, push/2, counts/1]).

-export_type([cut/0]).

-record(cut, {
    owner :: pid(),
    kind :: video | audio,
    opts :: map(),
    %% How the output of FFmpeg is cut: raw media in chunks of `size`
    %% bytes, an IVF stream (its header first, then frames whose
    %% timestamps count in units of Num/Den seconds), or H.264 access
    %% units that each start with a delimiter.
    format = raw :: raw | ivf_header | {ivf, pos_integer(), pos_integer()} | annexb,
    codec :: undefined | vp8 | vp9 | av1 | h264,
    %% Bytes of one picture or one chunk of audio.
    size :: pos_integer(),
    %% An encoded frame was dropped: those after it are of no use until
    %% a key frame.
    skip = false :: boolean(),
    buffer = <<>> :: binary(),
    %% Pictures or chunks read, and how many of them were dropped.
    count = 0 :: non_neg_integer(),
    dropped = 0 :: non_neg_integer()
}).

-opaque cut() :: #cut{}.

%% An encoded frame larger than this is not one: the stream is not what
%% it should be.
-define(MAX_FRAME, 8 * 1024 * 1024).

-spec new(pid(), video | audio, webrtc_codecs_capture_command:format(), undefined | atom(), map()) ->
    cut().
new(Owner, Kind, Format, Codec, Opts) ->
    #cut{
        owner = Owner,
        kind = Kind,
        opts = Opts,
        format = Format,
        codec = Codec,
        size = size(Kind, Opts)
    }.

%% Take the bytes that came. `bad_stream` when they cannot be the stream
%% that was asked for.
-spec push(binary(), cut()) -> {ok, cut()} | bad_stream.
push(Data, #cut{buffer = Buffer} = Cut) ->
    case deliver(<<Buffer/binary, Data/binary>>, Cut) of
        #cut{} = Cut1 -> {ok, Cut1};
        bad_stream -> bad_stream
    end.

%% What was read, and how much of it was dropped.
-spec counts(cut()) -> {non_neg_integer(), non_neg_integer()}.
counts(#cut{count = Count, dropped = Dropped}) ->
    {Count, Dropped}.

size(video, #{width := W, height := H}) ->
    W * H * 3 div 2;
size(audio, #{sample_rate := Rate, channels := Channels, frame_ms := Ms}) ->
    Rate * Ms div 1000 * Channels * 2.

%% Cut what was read into pictures, chunks or encoded frames and send
%% them, unless the owner is behind.
deliver(Buffer, #cut{format = raw, size = Size} = St) when byte_size(Buffer) >= Size ->
    <<Chunk:Size/binary, Rest/binary>> = Buffer,
    #cut{count = Count, dropped = Dropped} = St,
    case behind(St) of
        true ->
            deliver(Rest, St#cut{count = Count + 1, dropped = Dropped + 1});
        false ->
            St#cut.owner ! {webrtc_capture, self(), raw(Chunk, Count, St)},
            deliver(Rest, St#cut{count = Count + 1})
    end;
deliver(
    <<"DKIF", _:12/binary, Den:32/little, Num:32/little, _:64, Rest/binary>>,
    #cut{format = ivf_header} = St
) ->
    deliver(Rest, St#cut{format = {ivf, max(Num, 1), max(Den, 1)}});
deliver(
    <<Size:32/little, Pts:64/little, Data:Size/binary, Rest/binary>>,
    #cut{format = {ivf, Num, Den}} = St
) ->
    Ts = (Pts * 90000 * Num div Den) band 16#FFFFFFFF,
    deliver(Rest, encoded(Data, Ts, St));
deliver(<<Size:32/little, _/binary>>, #cut{format = {ivf, _, _}}) when Size > ?MAX_FRAME ->
    bad_stream;
deliver(Buffer, #cut{format = annexb, count = Count, opts = #{frame_rate := Fps}} = St) ->
    %% An access unit ends where the delimiter of the next one starts:
    %% a start code and a NAL unit of type 9, looked for past the unit's
    %% own. A start code of four bytes begins one byte earlier.
    case
        byte_size(Buffer) > 8 andalso
            binary:match(Buffer, <<0, 0, 1, 9>>, [{scope, {4, byte_size(Buffer) - 4}}])
    of
        {Found, _} ->
            Pos =
                case binary:at(Buffer, Found - 1) of
                    0 -> Found - 1;
                    _ -> Found
                end,
            <<Unit:Pos/binary, Rest/binary>> = Buffer,
            Ts = (Count * 90000 div Fps) band 16#FFFFFFFF,
            deliver(Rest, encoded(Unit, Ts, St));
        _ when byte_size(Buffer) > ?MAX_FRAME ->
            bad_stream;
        _ ->
            St#cut{buffer = Buffer}
    end;
deliver(Buffer, #cut{format = ivf_header}) when byte_size(Buffer) >= 32 ->
    %% Enough for the header, and it is not one.
    bad_stream;
deliver(Buffer, #cut{size = Size} = St) when byte_size(Buffer) =< max(Size, ?MAX_FRAME + 12) ->
    St#cut{buffer = Buffer};
deliver(_Buffer, _St) ->
    %% More kept than any state needs: a state above let it through.
    bad_stream.

behind(#cut{owner = Owner, opts = Opts}) ->
    case erlang:process_info(Owner, message_queue_len) of
        {message_queue_len, Len} -> Len > maps:get(max_queue, Opts);
        undefined -> true
    end.

%% Send an encoded frame. After one is dropped, the frames that depend
%% on it are dropped too, up to the next key frame.
encoded(Data, Ts, #cut{codec = Codec, count = Count, dropped = Dropped, skip = Skip} = St) ->
    Key = keyframe(Codec, Data),
    case behind(St) orelse (Skip andalso not Key) of
        true ->
            St#cut{count = Count + 1, dropped = Dropped + 1, skip = true};
        false ->
            St#cut.owner !
                {webrtc_capture, self(), #{
                    codec => Codec, data => Data, timestamp => Ts, keyframe => Key
                }},
            St#cut{count = Count + 1, skip = false}
    end.

keyframe(av1, Data) ->
    webrtc_codecs_av1:frame_info(av1, Data) =:= key;
keyframe(h264, Data) ->
    %% An IDR slice: NAL unit type 5, whatever its reference bits.
    binary:match(Data, [<<0, 0, 1, 16#65>>, <<0, 0, 1, 16#45>>, <<0, 0, 1, 16#25>>]) =/= nomatch;
keyframe(Codec, Data) ->
    case webrtc_codecs_vpx:frame_size(Codec, Data) of
        {key, _, _} -> true;
        _ -> false
    end.

%% Pictures are numbered in the 90 kHz clock from the rate asked for, so
%% a dropped picture leaves its place in the timestamps. Audio has no
%% timestamp: an encoder counts the samples it is given.
raw(Chunk, Count, #cut{kind = video, opts = #{width := W, height := H, frame_rate := Fps}}) ->
    Luma = W * H,
    Chroma = Luma div 4,
    <<Y:Luma/binary, U:Chroma/binary, V:Chroma/binary>> = Chunk,
    #{
        format => i420,
        width => W,
        height => H,
        y => Y,
        u => U,
        v => V,
        timestamp => (Count * 90000 div Fps) band 16#FFFFFFFF
    };
raw(Chunk, _Count, #cut{kind = audio, opts = #{sample_rate := Rate, channels := Channels}}) ->
    #{format => s16le, sample_rate => Rate, channels => Channels, samples => Chunk}.
