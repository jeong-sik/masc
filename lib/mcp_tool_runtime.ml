(** Mcp_tool_runtime — MCP server-local tool runtime.

    Delegates to sub-modules:
    - Mcp_tool_runtime_workspace: masc_start
    - Mcp_tool_runtime_comm: masc_broadcast, masc_messages
    - Mcp_tool_runtime_board: remaining tools (board, etc.)

    Keeps MCP-only server helpers that need per-request server state.

    RFC-0062 Phase 4c-2: handlers now return [Tool_result.result] directly;
    [wrap_result] adapter removed. *)

(** Re-export shared types so callers can use
    [Mcp_tool_runtime.context] and [Mcp_tool_runtime.tool_result]
    without knowing about the types sub-module. *)
type tool_result = Mcp_tool_runtime_types.tool_result
type context = Mcp_tool_runtime_types.context = {
  config : Workspace.config;
  agent_name : string;
  registry : Session.registry;
  state : Mcp_server.server_state;
  sw : Eio.Switch.t;
  clock : float Eio.Time.clock_ty Eio.Resource.t;
  arguments : Yojson.Safe.t;
  mcp_session_id : string option;
  record_mcp_session_agent : string -> unit;
  wait_for_message :
    Session.registry ->
    agent_name:string ->
    timeout:float ->
    Yojson.Safe.t option;
}

(** Dispatch a tool call.
    Returns [Some (Tool_result.result)] if the tool name is handled,
    [None] if the tool name is not recognized by this module. *)
let dispatch (ctx : context) ~(name : string) : Tool_result.result option =
  let start = Time_compat.now () in
  let config = ctx.config in
  let agent_name = ctx.agent_name in
  let state = ctx.state in
  let arguments = ctx.arguments in

  match Tool_schemas_misc.mcp_runtime_operation_of_tool_name name with
  (* ── Workspace lifecycle (delegated) ─────────────────────────────── *)
  | Some Tool_schemas_misc.Start ->
      Mcp_tool_runtime_workspace.handle_start ~tool_name:name ~start_time:start ctx

  (* ── Communication (delegated) ──────────────────────────────── *)
  | Some Tool_schemas_misc.Broadcast ->
      Mcp_tool_runtime_comm.handle_broadcast ~tool_name:name ~start_time:start ctx
  | Some Tool_schemas_misc.Messages ->
      Mcp_tool_runtime_comm.handle_messages ~tool_name:name ~start_time:start ctx

  (* ── Asking the operator (delegated) ────────────────────────── *)
  | Some Tool_schemas_misc.Ask ->
      Mcp_tool_runtime_ask.handle_ask ~tool_name:name ~start_time:start
        { Mcp_tool_runtime_ask.config; agent_name; arguments }
  | Some Tool_schemas_misc.Ask_status ->
      Mcp_tool_runtime_ask.handle_ask_status ~tool_name:name ~start_time:start
        { Mcp_tool_runtime_ask.config; agent_name; arguments }
  | Some Tool_schemas_misc.Ask_withdraw ->
      Mcp_tool_runtime_ask.handle_ask_withdraw ~tool_name:name ~start_time:start
        { Mcp_tool_runtime_ask.config; agent_name; arguments }

  (* ── Fallthrough to extra dispatch ──────────────────────────── *)
  | None ->
      Mcp_tool_runtime_board.dispatch ~config ~agent_name ~arguments ~state ~name ~start_time:start

(* ================================================================ *)
(* Tool_spec registration (RFC-0182 §3.2)                           *)
(* ================================================================ *)

(* MCP server-local workspace tools register through Tool_spec.

   Excluded (semantic widening would be required):
   - [masc_set_param], [channel_gate] —
     no Masc_domain.tool_schema record exists. They are dispatched via
     HTTP routes / MCP runtime arms but never advertised to MCP. Promoting
     them to Tool_spec.register requires authoring new input schemas
     and deciding visibility semantics for MCP exposure. *)

let runtime_tool_policy = function
  | Tool_schemas_misc.Start
  | Tool_schemas_misc.Broadcast
  | Tool_schemas_misc.Ask
  (* Taking a question back writes to the same durable log. *)
  | Tool_schemas_misc.Ask_withdraw ->
    (* Recording a question writes; the operator surface reads it back. *)
    false, true
  | Tool_schemas_misc.Messages | Tool_schemas_misc.Ask_status ->
    (* Reading back what was asked changes nothing. *)
    true, true
;;

let () =
  Tool_schemas_misc.mcp_runtime_operations
  |> List.iter (fun operation ->
    let schema = Tool_schemas_misc.mcp_runtime_schema operation in
    let is_read_only, mcp_context_required = runtime_tool_policy operation in
    Tool_spec.register
      (Tool_spec.create
         ~name:schema.name
         ~description:schema.description
         ~module_tag:Tool_dispatch.Mod_inline
         ~input_schema:schema.input_schema
         ~handler_binding:Tag_dispatch
         ~is_read_only
         ~mcp_context_required
         ()))
