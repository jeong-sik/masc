(** Forward records emitted through [Agent_sdk.Log] into the masc-mcp
    structured log ring / JSONL sink.

    Without this bridge the OAS global sink registry is empty and all
    [Log.info] / [Log.warn] calls inside [agent_sdk] are silently
    dropped.  With it, every OAS record lands in the masc-mcp log
    stream with module name ["oas:<original>"] and the original
    structured fields preserved as JSON [details].

    Should be called exactly once during server bootstrap. *)

val install : unit -> unit
(** Register the OAS → masc-mcp log sink as a global OAS sink.  Call
    once before any keeper turn fires an LLM call.  Idempotent via an
    internal [Atomic.t] latch, so re-entering bootstrap (test harness,
    in-process restart) is safe. *)

val render_record_message : Agent_sdk.Log.record -> string
(** Format an OAS [Log.record] into a human-readable single-line message;
    exposed for test/test_masc_log.ml golden assertions. *)

val effective_level : Agent_sdk.Log.record -> Log.level
(** Determine the effective [Log.level] for a record after promotion
    rules (e.g. WARN→ERROR for known classifiers). Exposed for tests
    that pin the promotion policy. *)
