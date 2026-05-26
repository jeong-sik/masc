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

val handle_stay_silent : args:Yojson.Safe.t -> string
(** [handle_stay_silent ~args] ignores [args] and returns
    [{ "status": "silent" }]. *)

val handle_tools_list
  :  meta:Keeper_types.keeper_meta
  -> args:Yojson.Safe.t
  -> string
(** [handle_tools_list ~meta ~args] ignores [args] and returns the
    keeper-visible tool list JSON via [Keeper_exec_shared.keeper_tools_list_json]. *)
