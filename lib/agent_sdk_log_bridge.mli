(** Forward records emitted through [Agent_sdk.Log] into the masc-mcp
    structured log ring / JSONL sink.

    Without this bridge the OAS global sink registry is empty and all
    [Log.info] / [Log.warn] calls inside [agent_sdk] are silently
    dropped.  With it, every OAS record lands in the masc-mcp log
    stream with module name ["oas:<original>"] and the original
    structured fields preserved as JSON [details].

    Should be called exactly once during server bootstrap. *)

val effective_level : Agent_sdk.Log.record -> Log.level
(** Map an OAS log record to the masc-mcp level that will actually
    be emitted, accounting for promotion rules (e.g. MCP server
    failures bumped from Warn to Error). *)

val install : unit -> unit
(** Register the OAS → masc-mcp log sink as a global OAS sink.  Call
    once before any keeper turn fires an LLM call.  Idempotent via an
    internal [Atomic.t] latch, so re-entering bootstrap (test harness,
    in-process restart) is safe. *)
