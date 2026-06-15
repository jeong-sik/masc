(** Keeper_stream_text_accum — text-delta policy for the keeper chat stream.

    Owns the invariant that model text reaches the live view exactly once:
    every delta is redacted and emitted as it arrives, and the terminal
    full-reply chunk re-send fires only when no delta was emitted (the
    empty-reply fallback path).

    History (issue #20907): #20825 buffered deltas for redaction and removed
    token streaming; #20854 restored live emission; #20869 removed it again
    inside an unrelated test PR. The decision lives here as a typed unit with
    tests (test/test_keeper_stream_text_accum.ml) so the next removal has to
    delete a module and its tests instead of two inline lines. *)

type t

val create : unit -> t

(** [on_delta t ~redact text] records the raw [text] for the terminal
    fallback, marks the stream as live-emitted, and returns the redacted
    chunk that the caller must publish immediately. A pattern that spans a
    delta boundary can escape the live view; the persisted turn and the
    terminal reply still pass through full-text redaction, so the durable
    record stays clean. *)
val on_delta : t -> redact:(string -> string) -> string -> string

(** Raw concatenation of every delta seen so far. Terminal visible-reply
    fallback for an empty provider body; the caller applies full-text
    redaction afterwards. *)
val streamed_text : t -> string

(** True once [on_delta] ran at least once: the terminal chunk re-send must
    be suppressed so streamed text is not rendered twice. *)
val suppress_terminal_resend : t -> bool
