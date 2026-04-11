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
    once before any keeper turn fires an LLM call; subsequent calls
    will add duplicate sinks and cause each record to be forwarded
    multiple times. *)
