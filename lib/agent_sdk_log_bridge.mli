(** Forward records emitted through [Agent_sdk.Log] into the masc-mcp
    structured log ring / JSONL sink.

    Without this bridge the OAS global sink registry is empty and all
    [Log.info] / [Log.warn] calls inside [agent_sdk] are silently
    dropped.  With it, every OAS record lands in the masc-mcp log
    stream with module name ["oas:<original>"] and the original
    structured fields preserved as JSON [details].

    Should be called exactly once during server bootstrap. *)

val effective_level : Agent_sdk.Log.record -> Log.level
(** Normalize the OAS record severity before forwarding it into masc-mcp.
    Preserves upstream levels by default, but promotes specific
    operator-actionable warn-level failures on the keeper main path to
    [Error]. Exposed at the module boundary so unit tests can pin the
    promotion table — a silent change to the operator-actionable warn
    set would surface in test_masc_log rather than as a stealth severity
    drift across the dashboard / log ring. *)

val install : unit -> unit
(** Register the OAS → masc-mcp log sink as a global OAS sink.  Call
    once before any keeper turn fires an LLM call.  Idempotent via an
    internal [Atomic.t] latch, so re-entering bootstrap (test harness,
    in-process restart) is safe. *)
