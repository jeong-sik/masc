(** Forward records emitted through [Agent_sdk.Log] into the masc
    structured log ring / JSONL sink.

    Without this bridge the OAS global sink registry is empty and all
    [Log.info] / [Log.warn] calls inside [agent_sdk] are silently
    dropped.  With it, every OAS record lands in the masc log
    stream with module name ["oas:<original>"] and the original
    structured fields preserved as JSON [details].

    Should be called exactly once during server bootstrap. *)

val install : unit -> unit
(** Register the OAS → masc log sink as a global OAS sink.  Call
    once before any keeper turn fires an LLM call.  Idempotent via an
    internal [Atomic.t] latch, so re-entering bootstrap (test harness,
    in-process restart) is safe. *)

val effective_level : Agent_sdk.Log.record -> Log.level
(** Return the effective log level for an OAS record after bridge-level
    promotion/demotion rules (e.g. MCP server failure → Error).
    Test-only surface — do not call from production code paths. *)
