(** RMS of the most recent moment of a capture that is still being recorded.

    sox cannot answer this question. [stat] on a file whose header still
    carries no length fails outright ("RIFF header not found"), and a
    negative [trim] offset needs the length that header does not yet have.
    Both were measured against a live [rec] on 2026-09-04.

    Reading the samples is arithmetic, and doing it here also takes a
    subprocess out of a loop that runs several times a second. The values
    agree with sox to six decimal places on a finished file. *)

(** Sample rate every capture is recorded at. Declared rather than read back:
    the recorder is told this and the reader assumes it, so the two cannot
    drift apart silently. *)
val sample_rate : int

(** Amplitude of the last [window_seconds] of samples, on the same 0.0-1.0
    scale sox reports, or why it could not be read.

    A file shorter than the window is measured whole rather than refused: at
    the start of a capture that is the only audio there is. *)
val tail_rms : ?window_seconds:float -> string -> (float, string) result
