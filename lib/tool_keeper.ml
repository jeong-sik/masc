(** Tool_keeper facade.

    MCP entrypoints stay stable while keeper internals live in dedicated
    keeper modules. Tool_keeper owns only runtime wrappers and dispatch.
*)

open Tool_args
open Keeper_types
open Keeper_runtime

module Turn = Keeper_turn
module Status = Keeper_status
module Policy = Keeper_policy
module Persona = Keeper_persona

type 'a context = 'a Keeper_types.context = {
  config : Room.config;
  agent_name : string;
  sw : Eio.Switch.t;
  clock : 'a Eio.Time.clock;
  proc_mgr : Eio_unix.Process.mgr_ty Eio.Resource.t option;
}

type tool_result = Keeper_types.tool_result

let schemas = Keeper_types.schemas

let annotate_keeper_json ~runtime_class ~desired ~resident_registered json =
  match json with
  | `Assoc fields ->
      `Assoc
        (("runtime_class", `String runtime_class)
        :: ("desired", `Bool desired)
        :: ("resident_registered", `Bool resident_registered)
        :: fields)
  | other -> other

let handle_resident_keeper_create_from_persona ctx args : tool_result =
  match Keeper_exec_persona.resolved_keeper_args_from_persona args with
  | Error e -> (false, "❌ " ^ e)
  | Ok (persona, resolved_args) ->
      let dry_run = get_bool args "dry_run" false in
      if dry_run then
        let json =
          `Assoc
            [
              ("persona", Keeper_exec_persona.persona_summary_to_json persona);
              ("created", `Bool false);
              ("resident", `Bool true);
              ("resolved_args", resolved_args);
            ]
        in
        (true, Yojson.Safe.pretty_to_string json)
      else
        let ok, body = Turn.handle_keeper_up ctx resolved_args in
        if not ok then
          (false, body)
        else
          let name =
            match resolved_args with
            | `Assoc fields -> (
                match List.assoc_opt "name" fields with
                | Some (`String value) -> value
                | _ -> "")
            | _ -> ""
          in
          let register_result =
            match read_meta ctx.config name with
            | Ok (Some meta) -> register_resident_keeper_from_meta ctx.config meta
            | Ok None -> Error "resident keeper meta missing after persona create"
            | Error e -> Error e
          in
          (match register_result with
          | Error e -> (false, "❌ " ^ e)
          | Ok () ->
              let created_json =
                try Yojson.Safe.from_string body with Yojson.Json_error _ -> `String body
              in
              let json =
                `Assoc
                  [
                    ("persona", Keeper_exec_persona.persona_summary_to_json persona);
                    ("created", `Bool true);
                    ("resident", `Bool true);
                    ("result", annotate_keeper_json ~runtime_class:"resident_keeper" ~desired:true ~resident_registered:true created_json);
                    ("resolved_args", resolved_args);
                  ]
              in
              (true, Yojson.Safe.pretty_to_string json))


let handle_resident_keeper_up ctx args : tool_result =
  let ok, body = Turn.handle_keeper_up ctx args in
  if not ok then (ok, body)
  else
    let name = get_string args "name" "" in
    match read_meta ctx.config name with
    | Error e -> (false, "❌ " ^ e)
    | Ok None -> (false, "❌ resident keeper meta missing after up")
    | Ok (Some meta) ->
        (match register_resident_keeper_from_meta ctx.config meta with
        | Error e -> (false, "❌ " ^ e)
        | Ok () ->
            let json =
              try Yojson.Safe.from_string body with Yojson.Json_error _ -> `String body
            in
            (true,
             Yojson.Safe.pretty_to_string
               (annotate_keeper_json ~runtime_class:"resident_keeper" ~desired:true
                  ~resident_registered:true json)))

let handle_resident_keeper_status ctx args : tool_result =
  let name = get_string args "name" "" in
  if validate_name name then maybe_promote_live_legacy_keeper ctx.config name;
  match read_resident_keeper ctx.config name with
  | Error e -> (false, "❌ " ^ e)
  | Ok None -> (false, Printf.sprintf "resident keeper not found: %s" name)
  | Ok (Some _spec) ->
      let ok, body = Status.handle_keeper_status ctx args in
      if not ok then (ok, body)
      else
        let json =
          try Yojson.Safe.from_string body with Yojson.Json_error _ -> `String body
        in
        (true,
         Yojson.Safe.pretty_to_string
           (annotate_keeper_json ~runtime_class:"resident_keeper" ~desired:true
              ~resident_registered:true json))

let handle_resident_keeper_msg ctx args : tool_result =
  let name = get_string args "name" "" in
  if validate_name name then maybe_promote_live_legacy_keeper ctx.config name;
  let ensure_result =
    match read_resident_keeper ctx.config name with
    | Ok (Some _) -> Ok ()
    | _ ->
        let ok, body = handle_resident_keeper_up ctx args in
        if ok then Ok () else Error body
  in
  match ensure_result with
  | Error err -> (false, err)
  | Ok _ ->
      let ok, body = Turn.handle_keeper_msg ctx args in
      if not ok then (ok, body)
      else begin
        (match read_meta ctx.config name with
        | Ok (Some meta) ->
            (match register_resident_keeper_from_meta ctx.config meta with
             | Ok () -> () | Error e -> Log.Keeper.warn "register_from_meta failed: %s" e)
        | _ -> ());
        let json =
          try Yojson.Safe.from_string body with Yojson.Json_error _ -> `String body
        in
        (true,
         Yojson.Safe.pretty_to_string
           (annotate_keeper_json ~runtime_class:"resident_keeper" ~desired:true
              ~resident_registered:true json))
      end

let handle_resident_keeper_msg_stream ~on_text_delta ctx args : tool_result =
  let name = get_string args "name" "" in
  if validate_name name then maybe_promote_live_legacy_keeper ctx.config name;
  let ensure_result =
    match read_resident_keeper ctx.config name with
    | Ok (Some _) -> Ok ()
    | _ ->
        let ok, body = handle_resident_keeper_up ctx args in
        if ok then Ok () else Error body
  in
  match ensure_result with
  | Error err -> (false, err)
  | Ok _ ->
      let ok, body = Turn.handle_keeper_msg ~on_text_delta ctx args in
      if not ok then (ok, body)
      else begin
        (match read_meta ctx.config name with
        | Ok (Some meta) ->
            (match register_resident_keeper_from_meta ctx.config meta with
             | Ok () -> () | Error e -> Log.Keeper.warn "register_from_meta failed: %s" e)
        | _ -> ());
        let json =
          try Yojson.Safe.from_string body with Yojson.Json_error _ -> `String body
        in
        (true,
         Yojson.Safe.pretty_to_string
           (annotate_keeper_json ~runtime_class:"resident_keeper" ~desired:true
              ~resident_registered:true json))
      end

let handle_resident_keeper_down ctx args : tool_result =
  let name = get_string args "name" "" in
  if validate_name name then remove_resident_keeper ctx.config name;
  Turn.handle_keeper_down ctx args

let handle_resident_keeper_model_set ctx args : tool_result =
  let name = get_string args "name" "" in
  match read_resident_keeper ctx.config name with
  | Error e -> (false, "❌ " ^ e)
  | Ok None -> (false, Printf.sprintf "resident keeper not found: %s" name)
  | Ok (Some _spec) ->
      let ok, body = Turn.handle_keeper_model_set ctx args in
      if not ok then (ok, body)
      else begin
        (match read_meta ctx.config name with
        | Ok (Some meta) -> ignore (register_resident_keeper_from_meta ctx.config meta)
        | _ -> ());
        let json =
          try Yojson.Safe.from_string body with Yojson.Json_error _ -> `String body
        in
        (true,
         Yojson.Safe.pretty_to_string
           (annotate_keeper_json ~runtime_class:"resident_keeper" ~desired:true
              ~resident_registered:true json))
      end

let handle_resident_keeper_list ctx args : tool_result =
  let limit = max 0 (get_int args "limit" 50) in
  let detailed = get_bool args "detailed" false in
  let resident =
    resident_keeper_names ctx.config
    |> take limit
  in
  if not detailed then
    let json =
      `Assoc
        [
          ("count", `Int (List.length resident));
          ("keepers", `List (List.map (fun name -> `String name) resident));
        ]
    in
    (true, Yojson.Safe.pretty_to_string json)
  else
    let rows =
      resident
      |> List.filter_map (fun name ->
             let status_args =
               `Assoc
                 [
                   ("name", `String name);
                   ("tail_turns", `Int 3);
                   ("tail_messages", `Int 5);
                   ("tail_compactions", `Int 10);
                   ("tail_bytes", `Int 60000);
                 ]
             in
             let ok, body = handle_resident_keeper_status ctx status_args in
             if not ok then None
             else
               try Some (Yojson.Safe.from_string body)
               with Yojson.Json_error _ -> None)
    in
    let json =
      `Assoc
        [
          ("count", `Int (List.length rows));
          ("keepers", `List rows);
        ]
    in
    (true, Yojson.Safe.pretty_to_string json)

let handle_persistent_agent_list ctx args : tool_result =
  let limit = max 0 (get_int args "limit" 50) in
  let detailed = get_bool args "detailed" false in
  let names = persistent_agent_names ctx.config |> take limit in
  if not detailed then
    let json =
      `Assoc
        [
          ("count", `Int (List.length names));
          ("persistent_agents", `List (List.map (fun name -> `String name) names));
        ]
    in
    (true, Yojson.Safe.pretty_to_string json)
  else
    let rows =
      names
      |> List.filter_map (fun name ->
             let status_args =
               `Assoc
                 [
                   ("name", `String name);
                   ("tail_turns", `Int 3);
                   ("tail_messages", `Int 5);
                   ("tail_compactions", `Int 10);
                   ("tail_bytes", `Int 60000);
                 ]
             in
             let ok, body = Status.handle_keeper_status ctx status_args in
             if not ok then None
             else
               try
                 let json = Yojson.Safe.from_string body in
                 Some
                   (annotate_keeper_json ~runtime_class:"persistent_agent"
                      ~desired:false ~resident_registered:false json)
               with Yojson.Json_error _ -> None)
    in
    let json =
      `Assoc
        [
          ("count", `Int (List.length rows));
          ("persistent_agents", `List rows);
        ]
    in
    (true, Yojson.Safe.pretty_to_string json)

let handle_persistent_agent_up ctx args : tool_result =
  let ok, body = Turn.handle_keeper_up ctx args in
  if not ok then (ok, body)
  else
    let json =
      try Yojson.Safe.from_string body with Yojson.Json_error _ -> `String body
    in
    (true,
     Yojson.Safe.pretty_to_string
       (annotate_keeper_json ~runtime_class:"persistent_agent" ~desired:false
          ~resident_registered:false json))

let handle_persistent_agent_status ctx args : tool_result =
  let ok, body = Status.handle_keeper_status ctx args in
  if not ok then (ok, body)
  else
    let name = get_string args "name" "" in
    let json =
      try Yojson.Safe.from_string body with Yojson.Json_error _ -> `String body
    in
    (true,
     Yojson.Safe.pretty_to_string
       (annotate_keeper_json ~runtime_class:"persistent_agent" ~desired:false
          ~resident_registered:(validate_name name && is_resident_keeper ctx.config name)
          json))

let handle_persistent_agent_msg ctx args : tool_result =
  let ok, body = Turn.handle_keeper_msg ctx args in
  if not ok then (ok, body)
  else
    let json =
      try Yojson.Safe.from_string body with Yojson.Json_error _ -> `String body
    in
    (true,
     Yojson.Safe.pretty_to_string
       (annotate_keeper_json ~runtime_class:"persistent_agent" ~desired:false
          ~resident_registered:false json))

let handle_persistent_agent_down ctx args : tool_result =
  Turn.handle_keeper_down ctx args

let handle_persistent_agent_model_set ctx args : tool_result =
  Turn.handle_keeper_model_set ctx args

let handle_persistent_agent_create_from_persona ctx args : tool_result =
  Persona.handle_keeper_create_from_persona ctx args

let dispatch ctx ~name ~args : tool_result option =
  (* Resident keepers are bootstrapped lazily on tool use as a fallback.
     Server startup also calls bootstrap_existing_keepers for always-on presence. *)
  (try start_existing_keepalives ctx with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
    Log.Keeper.error "start_existing_keepalives failed: %s" (Printexc.to_string exn));
  match name with
  | "masc_persona_list" -> Some (Persona.handle_persona_list ctx args)
  | "masc_keeper_create_from_persona" -> Some (handle_resident_keeper_create_from_persona ctx args)
  | "masc_keeper_up" -> Some (handle_resident_keeper_up ctx args)
  | "masc_keeper_status" -> Some (handle_resident_keeper_status ctx args)
  | "masc_keeper_msg" -> Some (handle_resident_keeper_msg ctx args)
  | "masc_keeper_model_set" -> Some (handle_resident_keeper_model_set ctx args)
  | "masc_keeper_policy_set" -> Some (Policy.handle_keeper_policy_set ctx args)
  | "masc_keeper_feedback_record" -> Some (Policy.handle_keeper_feedback_record ctx args)
  | "masc_keeper_dataset_export" -> Some (Policy.handle_keeper_dataset_export ctx args)
  | "masc_keeper_action_explain" -> Some (Policy.handle_keeper_action_explain ctx args)
  | "masc_keeper_eval_replay" -> Some (Policy.handle_keeper_eval_replay ctx args)
  | "masc_keeper_down" -> Some (handle_resident_keeper_down ctx args)
  | "masc_keeper_list" -> Some (handle_resident_keeper_list ctx args)
  | "masc_keeper_autonomy" -> Some (Policy.handle_keeper_autonomy ctx args)
  | "masc_keeper_goals" -> Some (Policy.handle_keeper_goals ctx args)
  | "masc_keeper_trajectory" -> Some (Status.handle_keeper_trajectory ctx args)
  | "masc_keeper_eval" -> Some (Status.handle_keeper_eval ctx args)
  | "masc_persistent_agent_create_from_persona" ->
      Some (handle_persistent_agent_create_from_persona ctx args)
  | "masc_persistent_agent_up" -> Some (handle_persistent_agent_up ctx args)
  | "masc_persistent_agent_status" -> Some (handle_persistent_agent_status ctx args)
  | "masc_persistent_agent_msg" -> Some (handle_persistent_agent_msg ctx args)
  | "masc_persistent_agent_model_set" -> Some (handle_persistent_agent_model_set ctx args)
  | "masc_persistent_agent_policy_set" -> Some (Policy.handle_keeper_policy_set ctx args)
  | "masc_persistent_agent_feedback_record" ->
      Some (Policy.handle_keeper_feedback_record ctx args)
  | "masc_persistent_agent_dataset_export" ->
      Some (Policy.handle_keeper_dataset_export ctx args)
  | "masc_persistent_agent_action_explain" ->
      Some (Policy.handle_keeper_action_explain ctx args)
  | "masc_persistent_agent_eval_replay" ->
      Some (Policy.handle_keeper_eval_replay ctx args)
  | "masc_persistent_agent_down" -> Some (handle_persistent_agent_down ctx args)
  | "masc_persistent_agent_list" -> Some (handle_persistent_agent_list ctx args)
  | "masc_persistent_agent_autonomy" -> Some (Policy.handle_keeper_autonomy ctx args)
  | "masc_persistent_agent_goals" -> Some (Policy.handle_keeper_goals ctx args)
  | "masc_persistent_agent_trajectory" -> Some (Status.handle_keeper_trajectory ctx args)
  | "masc_persistent_agent_eval" -> Some (Status.handle_keeper_eval ctx args)
  (* Housekeeping: keepers maintain their own world *)
  | "masc_housekeep_scan" | "masc_housekeep_delete" | "masc_housekeep_prune" ->
      Tool_housekeep.dispatch ctx.config ~name ~args
  | _ -> None

(** Streaming dispatch: only handles keeper_msg with text delta forwarding.
    Returns None for all other tool names.
    Called from server_routes_http_keeper_stream. *)
let dispatch_stream ~on_text_delta ctx ~name ~args : tool_result option =
  (try start_existing_keepalives ctx with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
    Log.Keeper.error "start_existing_keepalives failed: %s" (Printexc.to_string exn));
  match name with
  | "masc_keeper_msg" ->
      Some (handle_resident_keeper_msg_stream ~on_text_delta ctx args)
  | _ -> None
