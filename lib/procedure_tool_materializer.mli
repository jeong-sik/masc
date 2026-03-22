(** Procedure-to-Tool Materializer — promotes high-confidence learned procedures
    into callable MCP tools at runtime.

    Materialized tools use the "proc_" prefix and execute via Oas_worker.run_named
    (structured prompt, not arbitrary code).

    @since 2.128.0 *)

(** A procedure that has been registered as a runtime MCP tool. *)
type materialized_tool = {
  procedure_id : string;
  tool_name : string;
  description : string;
  confidence : float;
  evidence_count : int;
  registered_at : float;
}

val materialize_mature_procedures : unit -> materialized_tool list
(** Scan procedural memory for mature entries (confidence >= 0.9,
    evidence >= 5), register each as an MCP tool via Tool_dispatch.
    Returns newly materialized tools (already-materialized are skipped). *)

val materialized_tools : unit -> materialized_tool list
(** List all currently materialized tools, sorted by registration time (newest first). *)

val materialized_count : unit -> int
(** Number of currently materialized tools. *)

val dematerialize : tool_name:string -> unit
(** Remove a materialized tool from the registry by tool name.
    The tool's dispatch handler persists (Tool_dispatch has no unregister)
    but the tool is removed from the materialized listing. *)

val sanitize_tool_name : string -> string
(** Convert a procedure pattern into a valid tool name with "proc_" prefix.
    Exposed for testing. *)

val status_json : unit -> Yojson.Safe.t
(** JSON status of all materialized tools (for dashboard/status endpoints). *)

val materialized_tool_to_json : materialized_tool -> Yojson.Safe.t
(** Serialize a single materialized tool to JSON. *)

val make_schema : tool_name:string -> description:string -> Types.tool_schema
(** Generate a tool_schema for a materialized procedure.
    Useful for callers that need to register materialized tool schemas
    in Config.raw_all_tool_schemas or MCP schema listings. *)

val discover_agent_names : unit -> string list
(** List agent names that have procedure directories.
    Exposed for testing. *)
