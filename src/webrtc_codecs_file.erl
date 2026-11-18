-module(webrtc_codecs_file).
-moduledoc """
Read and write the two simple media files tests use: IVF, a list of
encoded video frames (VP8, VP9, AV1), and WAV, 16 bit PCM audio.

```erlang
{ok, #{fourcc := <<"VP80">>, frames := Frames}} = webrtc_codecs_file:read_ivf("clip.ivf"),
ok = webrtc_codecs_file:write_wav("out.wav", Audio).
```

For other containers (MP4, WebM, Matroska) go through FFmpeg:
`webrtc_codecs_capture` reads a file as raw media and
`webrtc_codecs_playback` writes raw media to one.
""".

-include_lib("kernel/include/file.hrl").

-export([read_ivf/1, read_ivf/2, write_ivf/3, read_wav/1, read_wav/2, write_wav/2]).

%% A file is read whole: the largest one read unless `max_bytes` says otherwise.
-define(MAX_BYTES, 256 * 1024 * 1024).

-export_type([ivf/0, ivf_frame/0]).

-doc """
`fourcc` names the codec: `<<"VP80">>`, `<<"VP90">>` or `<<"AV01">>`.
`time_base` is the duration of one timestamp unit as `{Numerator,
Denominator}` seconds: `{1, 90000}` makes the timestamps RTP timestamps.
""".
-type ivf() :: #{
    fourcc := <<_:32>>,
    width := non_neg_integer(),
    height := non_neg_integer(),
    time_base => {pos_integer(), pos_integer()},
    frames => [ivf_frame()]
}.
-type ivf_frame() :: #{data := binary(), timestamp := non_neg_integer(), atom() => term()}.

-doc "Read an IVF file: its header and its frames, each with its timestamp in units of the time base.".
-spec read_ivf(file:filename_all()) -> {ok, ivf()} | {error, term()}.
read_ivf(Path) ->
    read_ivf(Path, #{}).

-doc """
The same, with options: `max_bytes`, the largest file to read, default
256 MB. A larger one gives `{error, too_large}`.
""".
-spec read_ivf(file:filename_all(), #{max_bytes => pos_integer()}) -> {ok, ivf()} | {error, term()}.
read_ivf(Path, Opts) ->
    case read(Path, Opts) of
        {ok,
            <<"DKIF", _Version:16/little, HeaderSize:16/little, Fourcc:4/binary, W:16/little,
                H:16/little, Den:32/little, Num:32/little, _Count:32/little, _:32,
                Rest0/binary>>} when
            HeaderSize >= 32, byte_size(Rest0) >= HeaderSize - 32
        ->
            <<_:(HeaderSize - 32)/binary, Rest/binary>> = Rest0,
            case ivf_frames(Rest, []) of
                {ok, Frames} ->
                    Header = #{
                        fourcc => Fourcc,
                        width => W,
                        height => H,
                        time_base => {max(Num, 1), max(Den, 1)}
                    },
                    {ok, Header#{frames => Frames}};
                error ->
                    {error, truncated}
            end;
        {ok, _} ->
            {error, not_ivf};
        {error, _} = Error ->
            Error
    end.

ivf_frames(<<Size:32/little, Pts:64/little, Data:Size/binary, Rest/binary>>, Acc) ->
    ivf_frames(Rest, [#{data => Data, timestamp => Pts} | Acc]);
ivf_frames(<<>>, Acc) ->
    {ok, lists:reverse(Acc)};
ivf_frames(_, _Acc) ->
    error.

-doc """
Write frames to an IVF file. The frames are those a video plugin's
`encode/2` gives: with the default time base of `{1, 90000}` their RTP
timestamps are written as they are.
""".
-spec write_ivf(file:filename_all(), ivf(), [ivf_frame()]) -> ok | {error, term()}.
write_ivf(Path, #{fourcc := <<Fourcc:4/binary>>, width := W, height := H} = Header, Frames) ->
    {Num, Den} = maps:get(time_base, Header, {1, 90000}),
    Head =
        <<"DKIF", 0:16/little, 32:16/little, Fourcc/binary, W:16/little, H:16/little, Den:32/little,
            Num:32/little, (length(Frames)):32/little, 0:32>>,
    Body = [
        [<<(byte_size(D)):32/little, Ts:64/little>>, D]
     || #{data := D, timestamp := Ts} <- Frames
    ],
    file:write_file(Path, [Head | Body]).

-doc "Read a WAV file of 16 bit PCM as one `t:webrtc_codecs:audio/0`.".
-spec read_wav(file:filename_all()) -> {ok, webrtc_codecs:audio()} | {error, term()}.
read_wav(Path) ->
    read_wav(Path, #{}).

-doc """
The same, with options: `max_bytes`, the largest file to read, default
256 MB. A larger one gives `{error, too_large}`.
""".
-spec read_wav(file:filename_all(), #{max_bytes => pos_integer()}) ->
    {ok, webrtc_codecs:audio()} | {error, term()}.
read_wav(Path, Opts) ->
    case read(Path, Opts) of
        {ok, <<"RIFF", _:32, "WAVE", Chunks/binary>>} ->
            case {wav_chunk(<<"fmt ">>, Chunks), wav_chunk(<<"data">>, Chunks)} of
                {
                    {ok,
                        <<1:16/little, Channels:16/little, Rate:32/little, _:48, 16:16/little,
                            _/binary>>},
                    {ok, Pcm}
                } when
                    Channels > 0, Rate > 0
                ->
                    Whole = byte_size(Pcm) - byte_size(Pcm) rem (2 * Channels),
                    {ok, #{
                        format => s16le,
                        sample_rate => Rate,
                        channels => Channels,
                        samples => binary:part(Pcm, 0, Whole)
                    }};
                {{ok, _}, {ok, _}} ->
                    {error, unsupported_format};
                _ ->
                    {error, not_wav}
            end;
        {ok, _} ->
            {error, not_wav};
        {error, _} = Error ->
            Error
    end.

%% The body of the first chunk with this id. A data chunk whose size
%% runs past the end of the file, as a writer that could not seek back
%% leaves it, is taken to the end.
wav_chunk(Id, <<Id:4/binary, Size:32/little, Rest/binary>>) ->
    {ok, binary:part(Rest, 0, min(Size, byte_size(Rest)))};
wav_chunk(Id, <<_:4/binary, Size:32/little, Rest/binary>>) ->
    Skip = Size + Size rem 2,
    case Rest of
        <<_:Skip/binary, Next/binary>> -> wav_chunk(Id, Next);
        _ -> error
    end;
wav_chunk(_Id, _) ->
    error.

-doc "Write audio, one map or several of the same format in order, to a WAV file of 16 bit PCM.".
-spec write_wav(file:filename_all(), webrtc_codecs:audio() | [webrtc_codecs:audio()]) ->
    ok | {error, term()}.
write_wav(Path, #{} = Audio) ->
    write_wav(Path, [Audio]);
write_wav(Path, [#{format := s16le, sample_rate := Rate, channels := Channels} | _] = Chunks) ->
    case
        lists:all(
            fun(C) ->
                maps:with([format, sample_rate, channels], C) =:=
                    maps:with([format, sample_rate, channels], hd(Chunks))
            end,
            Chunks
        )
    of
        true ->
            Pcm = [S || #{samples := S} <- Chunks],
            Size = iolist_size(Pcm),
            Fmt =
                <<1:16/little, Channels:16/little, Rate:32/little, (Rate * Channels * 2):32/little,
                    (Channels * 2):16/little, 16:16/little>>,
            Head =
                <<"RIFF", (36 + Size):32/little, "WAVE", "fmt ", 16:32/little, Fmt/binary, "data",
                    Size:32/little>>,
            file:write_file(Path, [Head | Pcm]);
        false ->
            {error, mixed_formats}
    end;
write_wav(_Path, _) ->
    {error, badarg}.

%% The whole file, when it is not larger than max_bytes.
read(Path, Opts) ->
    Max = maps:get(max_bytes, Opts, ?MAX_BYTES),
    case file:read_file_info(Path) of
        {ok, #file_info{size = Size}} when Size > Max -> {error, too_large};
        {ok, _} -> file:read_file(Path);
        {error, _} = Error -> Error
    end.
