(** A stored audio file made into a Discord voice message.

    Discord plays a voice message from an Ogg Opus stream and draws it from a
    waveform the sender computes. One ffmpeg run writes both the Opus stream
    and the mono PCM the waveform is read from. *)

type source_format =
  | Mp3
  | Wav
  | Ogg
  | Mp4
  | Webm
(** The audio containers MASC stores, each read with its own ffmpeg demuxer
    so ffmpeg never guesses a format from the bytes. *)

val waveform_sample_rate : int
(** Sample rate, in Hz, of the mono PCM the waveform is read from. *)

val waveform_of_pcm_s16le : sample_rate:int -> string -> (float * string) option
(** [(duration_secs, waveform)] for mono signed 16-bit little-endian PCM.
    One waveform point per 100 ms of audio, at least one and at most
    {!Discord_rest_client.voice_waveform_max_points}; each point is the
    peak absolute sample of its slice scaled to 0..255. [None] when there is
    no whole sample or [sample_rate] is not positive. *)

val of_audio : source_format -> string -> (Discord_rest_client.voice_clip, string) result
(** Transcode [bytes] to mono 48 kHz Opus at 32 kbps in Ogg, as Discord's
    clients send, and read its duration and waveform. Runs [ffmpeg] from
    [PATH] with only the [file] protocol allowed, in a private temporary
    directory that is removed afterwards. [Error] when ffmpeg is absent,
    refused, fails or times out, or the audio decodes to no samples. *)
