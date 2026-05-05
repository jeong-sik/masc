module Format = Stdlib.Format
module Map = Stdlib.Map
module Set = Stdlib.Set
module Queue = Stdlib.Queue
module Hashtbl = Stdlib.Hashtbl
module Mutex = Stdlib.Mutex
module Option = Stdlib.Option
module Result = Stdlib.Result
module Sys = Stdlib.Sys
module Filename = Stdlib.Filename
module List = Stdlib.List
module Array = Stdlib.Array
module String = Stdlib.String
module Char = Stdlib.Char
module Int = Stdlib.Int
module Float = Stdlib.Float

(** Tool_inline_dispatch — thin dispatch router for inline tool handlers.

    Delegates to sub-modules:
    - Tool_inline_dispatch_coord: masc_start, masc_join, masc_leave
    - Tool_inline_dispatch_comm: masc_broadcast, masc_messages, masc_who
    - Tool_inline_dispatch_extra: remaining tools (board, etc.)

    Keeps inline: mcp_session, approval_pending, approval_resolve,
    spawn, discover_tools.
*)

(** Re-export shared types so callers can use
    [Tool_inline_dispatch.context] and [Tool_inline_dispatch.tool_result]
    without knowing about the types sub-module. *)
type tool_result = Tool_inline_dispatch_types.tool_result
type context = Tool_inline_dispatch_types.context = {
  config : Coord.config;
  agent_name : string;
  registry : Session.registry;
  state : Mcp_server.server_state;
  sw : Eio.Switch.t;
  clock : float Eio.Time.clock_ty Eio.Resource.t;
  arguments : Yojson.Safe.t;
  mcp_session_id : string option;
  write_mcp_session_agent : string -> unit;
  wait_for_message :
    Session.registry ->
    agent_name:string ->
    timeout:float ->
    Yojson.Safe.t option;
  governance_defaults : string -> Mcp_server_eio_governance.governance_config;
  save_governance :
    Coord.config -> Mcp_server_eio_governance.governance_config -> unit;
  load_mcp_sessions : Coord.config -> Mcp_server_eio_governance.mcp_session_record list;
  save_mcp_sessions :
    Coord.config -> Mcp_server_eio_governance.mcp_session_record list -> unit;
}

let safe_exec = Tool_inline_dispatch_types.safe_exec

(** Dispatch a tool call.
    Returns [Some (success, message)] if the tool name is handled,
    [None] if the tool name is not recognized by this module. *)
let dispatch (ctx : context) ~(name : string) : tool_result option =
  let config = ctx.config in
  let agent_name = ctx.agent_name in
  let state = ctx.state in
  let sw = ctx.sw in
  let clock = ctx.clock in
  let arguments = ctx.arguments in

  (* Argument extraction helpers — delegate to Safe_ops *)
  let arg_get_string key default =
    Safe_ops.json_string ~default key arguments
  in
  let arg_get_int key default =
    Safe_ops.json_int ~default key arguments
  in
  let _arg_get_bool key default =
    Safe_ops.json_bool ~default key arguments
  in
  let _arg_get_string_list key =
    Safe_ops.json_string_list key arguments
  in
  let arg_get_string_opt key =
    match Safe_ops.json_string_opt key arguments with
    | Some "" -> None
    | other -> other
  in
  let _arg_get_string_required key =
    Tool_args.get_string_required arguments key
  in
  let _arg_get_int_opt _key = () in  (* unused but kept for symmetry *)
  let _arg_get_float_opt key =
    Safe_ops.json_float_opt key arguments
  in

  match name with
  (* ── Coord lifecycle (delegated) ─────────────────────────────── *)
  | "masc_start" -> Tool_inline_dispatch_coord.handle_start ctx
  | "masc_join" -> Tool_inline_dispatch_coord.handle_join ctx
  | "masc_leave" -> Tool_inline_dispatch_coord.handle_leave ctx

  (* ── Communication (delegated) ──────────────────────────────── *)
  | "masc_broadcast" -> Tool_inline_dispatch_comm.handle_broadcast ctx
  | "masc_messages" -> Tool_inline_dispatch_comm.handle_messages ctx
  | "masc_who" -> Tool_inline_dispatch_comm.handle_who ctx

  (* ── HITL Approval Queue (#5907) ─────────────────────────────── *)
  | "masc_approval_pending" ->
      let json = Keeper_approval_queue.list_pending_json () in
      Some (true, Yojson.Safe.to_string json)
  | "masc_approval_get" ->
      let id = arg_get_string "id" "" in
      if String.equal id "" then Some (false, "id is required")
      else
        (match Keeper_approval_queue.get_pending_json ~id with
         | Some json -> Some (true, Yojson.Safe.to_string json)
         | None ->
           Some (false,
             Printf.sprintf
               "approval %s is no longer pending or was not found. Refresh with masc_approval_pending before approving/rejecting."
               id))
  | "masc_approval_resolve" ->
      let id = arg_get_string "id" "" in
      let decision_str = arg_get_string "decision" "approve" in
      if String.equal id "" then Some (false, "id is required")
      else
        let decision = match String.lowercase_ascii decision_str with
          | "approve" -> Agent_sdk.Hooks.Approve
          | "reject" ->
            let reason = arg_get_string "reason" "operator rejected" in
            Agent_sdk.Hooks.Reject reason
          | _ -> Agent_sdk.Hooks.Reject (Printf.sprintf "unknown decision: %s" decision_str)
        in
        (match Keeper_approval_queue.resolve ~id ~decision with
         | Ok () ->
           Some (true, Printf.sprintf "{\"resolved\":\"%s\",\"decision\":\"%s\"}" id decision_str)
         | Error err ->
           Some (false, Keeper_approval_queue.resolve_error_to_string err))

  (* Verification tools removed: pruned *)

  (* ── MCP Session ────────────────────────────────────────────── *)
  | "masc_mcp_session" ->
      (* Issue #8520: parse via Mcp_session.action_of_string_opt;
         dispatch via exhaustive match on the Variant — adding a 6th
         action will fail compilation here, not silently break. *)
      let raw = arg_get_string "action" "" in
      (match Mcp_session.action_of_string_opt raw with
       | None ->
         Some (false,
           Printf.sprintf
             "action must be one of [%s]; got %S"
             (String.concat "|" Mcp_session.valid_action_strings) raw)
       | Some action ->
      let now = Time_compat.now () in
      let sessions = ctx.load_mcp_sessions config in
      let save sessions = ctx.save_mcp_sessions config sessions in
      let response =
        match action with
        | Mcp_session.Create ->
            let agent_name = arg_get_string_opt "agent_name" in
            let id = Mcp_session.generate () in
            let record : Mcp_server_eio_governance.mcp_session_record =
              { id; agent_name; created_at = now; last_seen = now } in
            save (record :: sessions);
            Ok (`Assoc [
              ("status", `String "created");
              ("session", Mcp_server_eio_governance.mcp_session_to_json record);
            ])
        | Mcp_session.Get ->
            let session_id = arg_get_string "session_id" "" in
            (match List.find_opt (fun (s : Mcp_server_eio_governance.mcp_session_record) -> String.equal s.id session_id) sessions with
             | None -> Error (Printf.sprintf "MCP session '%s' not found" session_id)
             | Some s ->
                 let updated = { s with last_seen = now } in
                 let others = List.filter (fun (x : Mcp_server_eio_governance.mcp_session_record) -> not (String.equal x.id session_id)) sessions in
                 save (updated :: others);
                 Ok (`Assoc [
                   ("status", `String "ok");
                   ("session", Mcp_server_eio_governance.mcp_session_to_json updated);
                 ]))
        | Mcp_session.List ->
            Ok (`Assoc [
              ("count", `Int (List.length sessions));
              ("sessions", `List (List.map Mcp_server_eio_governance.mcp_session_to_json sessions));
            ])
        | Mcp_session.Cleanup ->
            let cutoff = now -. Masc_time_constants.days_to_seconds 7 in
            let remaining = List.filter (fun (s : Mcp_server_eio_governance.mcp_session_record) -> Stdlib.Float.compare s.last_seen cutoff >= 0) sessions in
            let removed = List.length sessions - List.length remaining in
            save remaining;
            Ok (`Assoc [
              ("status", `String "cleaned");
              ("removed", `Int removed);
              ("remaining", `Int (List.length remaining));
            ])
        | Mcp_session.Remove ->
            let session_id = arg_get_string "session_id" "" in
            let remaining = List.filter (fun (s : Mcp_server_eio_governance.mcp_session_record) -> not (String.equal s.id session_id)) sessions in
            if List.length remaining = List.length sessions then
              Error (Printf.sprintf "MCP session '%s' not found" session_id)
            else begin
              save remaining;
              Ok (`Assoc [
                ("status", `String "removed");
                ("session_id", `String session_id);
              ])
            end
      in
      (match response with
       | Ok json -> Some (true, Yojson.Safe.to_string json)
       | Error e -> Some (false, e)))

  (* Infrastructure tools: cancellation, subscription, progress,
     governance_set removed — pruned from surfaces *)

  | "masc_spawn" ->
      let spawn_agent_name = arg_get_string "agent_name" "" in
      let prompt = arg_get_string "prompt" "" in
      if String.equal prompt "" then Some (false, "prompt is required")
      else
      let timeout_seconds = arg_get_int "timeout_seconds" 300 in
      let model_name =
        match arguments |> Yojson.Safe.Util.member "model" with
        | `String s ->
            let trimmed = String.trim s in
            if String.equal trimmed "" then None else Some trimmed
        | _ -> None
      in
      let runtime_model_valid =
        match (spawn_agent_name, model_name) with
        (* Stable provider name — see Provider_adapter.cn_llama *)
        | "llama", None -> Error "model is required when agent_name=llama"
        | "llama", Some raw ->
            let spec_name =
              if String.contains raw ':' then raw else Provider_adapter.make_local_label raw
            in
            (* Validate the label parses without retaining model_spec *)
            (match Cascade_config.parse_model_string spec_name with Some _ -> Ok () | None -> Error "invalid model spec")
        | _ ->
            (match Provider_adapter.preferred_execution_model_labels () with _ :: _ -> Ok () | [] -> Error "no execution model")
      in
      let module U = Yojson.Safe.Util in
      let working_dir = match arguments |> U.member "working_dir" with
        | `String s when not (String.equal s "") -> Some s
        | _ -> None
      in
       (match runtime_model_valid with
       | Error e -> Some (false, e)
       | Ok () ->
           ignore (sw, state);
           let result =
             Spawn.spawn ~agent_name:spawn_agent_name
               ~prompt ~timeout_seconds ?working_dir ()
           in
           Some (result.Spawn.success, Spawn.result_to_string result))

  (* ── Tool discovery ─────────────────────────────────────────── *)
  | "masc_discover_tools" ->
      let query = String.lowercase_ascii (arg_get_string "query" "") in
      let limit = arg_get_int "limit" 20 in
      if String.equal query "" then
        Some (false, "query is required")
      else
        let all_schemas = Config.visible_tool_schemas ~include_hidden:true ~include_deprecated:false () in
        let words = String.split_on_char ' ' query |> List.filter (fun w -> String.length w > 0) in
        let matches =
          all_schemas
          |> List.filter (fun (schema : Masc_domain.tool_schema) ->
                 let name_l = String.lowercase_ascii schema.name in
                 let desc_l = String.lowercase_ascii schema.description in
                 let haystack = name_l ^ " " ^ desc_l in
                 words |> List.exists (fun w ->
                   String_util.contains_substring haystack w))
          |> List.filteri (fun i _ -> i < limit)
        in
        let results = List.map (fun (schema : Masc_domain.tool_schema) ->
          `Assoc [
            ("name", `String schema.name);
            ("description", `String schema.description);
          ]
        ) matches in
        Some (true, Yojson.Safe.to_string (`Assoc [
          ("query", `String query);
          ("count", `Int (List.length results));
          ("tools", `List results);
          ("hint", `String "These tools are callable via tools/call even if not in the default tools/list.");
        ]))

  (* ── Fallthrough to extra dispatch ──────────────────────────── *)
  | _ -> Tool_inline_dispatch_extra.dispatch ~config ~agent_name ~arguments ~state ~sw ~clock ~name
