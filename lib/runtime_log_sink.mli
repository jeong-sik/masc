(** Forward records emitted through [Agent_sdk.Log] into the MASC
    structured log ring / JSONL sink.

    Without this sink the agent core global sink registry is empty and all
    [Log.info] / [Log.warn] calls inside the core are silently
    dropped.  With it, every core record lands in the MASC log
    stream with module name ["oas:<original>"] and the original
    structured fields preserved as JSON [details].

    Should be called exactly once during server bootstrap. *)

val install : unit -> unit
(** Register the agent core → MASC log sink as a global core sink.  Call
    once before any keeper turn fires an LLM call.  Idempotent via an
    internal [Atomic.t] latch, so re-entering bootstrap (test harness,
    in-process restart) is safe. *)
