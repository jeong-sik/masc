(** In-process runtime handlers for descriptor-backed coordination tools.

    RFC-0179 PR-2 onwards. This module hosts handlers for descriptors whose
    executor is [In_process] — pure OCaml-runtime functions with no sandbox,
    no host process spawn, no remote MCP. Each handler returns the raw output
    JSON string; the caller in [Keeper_exec_tools] wraps it via
    [make_executed_tool_result]. *)

val handle_time_now : args:Yojson.Safe.t -> string
(** [handle_time_now ~args] ignores [args] (the descriptor schema mandates an
    empty object) and returns
    [{ "now_iso": <ISO-8601 UTC>, "now_unix": <epoch seconds float> }]. *)
