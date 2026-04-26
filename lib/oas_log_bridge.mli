(** Forward records emitted through [Agent_sdk.Log] into the masc-mcp
    structured log ring / JSONL sink.

    Without this bridge the OAS global sink registry is empty and all
    [Log.info] / [Log.warn] calls inside [agent_sdk] are silently
    dropped.  With it, every OAS record lands in the masc-mcp log
    stream with module name ["oas:<original>"] and the original
    structured fields preserved as JSON [details].

    Should be called exactly once during server bootstrap. *)

(** Render an OAS log record into the human-readable message string that
    masc-mcp writes to stderr / the structured ring. This interpolates
    printf-style templates and normalizes known structured OAS messages
    into an operator-friendly form. *)
val render_record_message : Agent_sdk.Log.record -> string

(** Normalize the OAS record severity before forwarding it into masc-mcp.
    This preserves upstream levels by default, but promotes specific
    operator-actionable warn-level failures on the keeper main path to
    [Error]. *)
val effective_level : Agent_sdk.Log.record -> Log.level

(** Register the OAS → masc-mcp log sink as a global OAS sink.  Call
    once before any keeper turn fires an LLM call.  Idempotent via an
    internal [Atomic.t] latch, so re-entering bootstrap (test harness,
    in-process restart) is safe. *)
val install : unit -> unit
