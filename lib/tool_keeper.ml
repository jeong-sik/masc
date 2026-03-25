(** Tool_keeper facade.

    MCP entrypoints stay stable while keeper internals live in dedicated
    keeper modules. Tool_keeper owns only runtime wrappers and dispatch.
*)

open Tool_args
open Keeper_types
open Keeper_runtime

module Turn = Keeper_turn
module Status = Keeper_status

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

type text_cache = {
  mutable key : string option;
  mutable value : string option;
  mutable expires_at : float;
}

let _resident_keeper_list_cache = { key = None; value = None; expires_at = 0.0 }

let cache_ttl_seconds env_var ~default =
  match Sys.getenv_opt env_var with
  | Some raw -> (
      match Float.of_string_opt (String.trim raw) with
      | Some value when value >= 0.0 -> value
      | _ -> default)
  | None -> default

let resident_keeper_list_cache_ttl_s () =
  cache_ttl_seconds "MASC_KEEPER_LIST_CACHE_TTL_S" ~default:2.0

let invalidate_resident_keeper_list_cache () =
  _resident_keeper_list_cache.key <- None;
  _resident_keeper_list_cache.value <- None;
  _resident_keeper_list_cache.expires_at <- 0.0

let cached_text_by_key cache ~key ~ttl_s compute =
  let now = Time_compat.now () in
  match cache.key, cache.value with
  | Some cached_key, Some value
    when String.equal cached_key key && now < cache.expires_at ->
      value
  | _ ->
      let value = compute () in
      cache.key <- Some key;
      cache.value <- Some value;
      cache.expires_at <- now +. ttl_s;
      value

let annotate_keeper_json ~runtime_class ~desired ~resident_registered json =
  match json with
  | `Assoc fields ->
      `Assoc
        (("runtime_class", `String runtime_class)
        :: ("desired", `Bool desired)
        :: ("resident_registered", `Bool resident_registered)
        :: fields)
  | other -> other

let keeper_brief_meta_json (meta : keeper_meta) =
  `Assoc
    [
      ("name", `String meta.name);
      ("goal", `String meta.goal);
      ("trace_id", `String meta.trace_id);
      ("created_at", `String meta.created_at);
      ("updated_at", `String meta.updated_at);
    ]

let keeper_list_skill_route_json config (meta : keeper_meta) =
  let metrics_store = keeper_metrics_store config meta.name in
  let metrics_path = keeper_metrics_path config meta.name in
  let lines =
    let dated = Dated_jsonl.read_recent_lines metrics_store 50 in
    if dated <> [] then dated
    else Keeper_memory.read_file_tail_lines metrics_path ~max_bytes:16_000 ~max_lines:50
  in
  let open Yojson.Safe.Util in
  let rec find_latest = function
    | [] -> `Null
    | line :: tl -> (
        try
          let json = Yojson.Safe.from_string line in
          match Safe_ops.json_string_opt "skill_primary" json with
          | Some primary when String.trim primary <> "" ->
              let secondary =
                match json |> member "skill_secondary" with
                | `List xs ->
                    xs
                    |> List.filter_map (function
                         | `String s when String.trim s <> "" -> Some (`String s)
                         | _ -> None)
                | _ -> []
              in
              `Assoc
                [
                  ("primary", `String primary);
                  ("secondary", `List secondary);
                  ( "reason",
                    match Safe_ops.json_string_opt "skill_reason" json with
                    | Some value -> `String value
                    | None -> `Null );
                ]
          | _ -> find_latest tl
        with Yojson.Json_error _ | Yojson.Safe.Util.Type_error _ -> find_latest tl)
  in
  find_latest (List.rev lines)

let keeper_list_row_json ~runtime_class ~desired ~resident_registered config
    name =
  match read_meta config name with
  | Error _ | Ok None -> None
  | Ok (Some (meta : keeper_meta)) ->
      let now_ts = Time_compat.now () in
      let keepalive_running = Keeper_keepalive.keeper_keepalive_running meta.name in
      let agent_status =
        Keeper_exec_status.parse_agent_status config ~agent_name:meta.agent_name
      in
      let diagnostic =
        Keeper_exec_status.keeper_diagnostic_json
          ~meta
          ~agent_status
          ~keepalive_running ~history_items:[] ~now_ts
        |> Keeper_exec_status.augment_keeper_diagnostic_json
             ~desired ~meta ~keepalive_running
             ~keepalive_started_at:
               (Keeper_keepalive.keeper_keepalive_started_at meta.name)
             ~now_ts
      in
      let status =
        Keeper_exec_status.keeper_surface_status ~agent_status ~diagnostic
      in
      Some
        (`Assoc
          [
            ("runtime_class", `String runtime_class);
            ("desired", `Bool desired);
            ("resident_registered", `Bool resident_registered);
            ("name", `String meta.name);
            ("meta", keeper_brief_meta_json meta);
            ("agent_name", `String meta.agent_name);
            ("status", `String status);
            ("diagnostic", diagnostic);
            ("keepalive_running", `Bool keepalive_running);
            ("presence_keepalive", `Bool meta.presence_keepalive);
            ("presence_keepalive_sec", `Int meta.presence_keepalive_sec);
            ("scope_kind", `String meta.scope_kind);
            ("room_scope", `String meta.room_scope);
            ("proactive_enabled", `Bool meta.proactive.enabled);
            ("proactive_idle_sec", `Int meta.proactive.idle_sec);
            ("proactive_cooldown_sec", `Int meta.proactive.cooldown_sec);
            ("initiative_enabled", `Bool meta.initiative_enabled);
            ("initiative_idle_sec", `Int meta.initiative_idle_sec);
            ("initiative_cooldown_sec", `Int meta.initiative_cooldown_sec);
            ("skill_route", keeper_list_skill_route_json config meta);
            ("models", `List (List.map (fun model -> `String model) meta.models));
            ("created_at", `String meta.created_at);
            ("updated_at", `String meta.updated_at);
          ])

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
              invalidate_resident_keeper_list_cache ();
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
            invalidate_resident_keeper_list_cache ();
            let json =
              try Yojson.Safe.from_string body with Yojson.Json_error _ -> `String body
            in
            (true,
             Yojson.Safe.pretty_to_string
               (annotate_keeper_json ~runtime_class:"resident_keeper" ~desired:true
                  ~resident_registered:true json)))

let handle_resident_keeper_status ctx args : tool_result =
  let name = get_string args "name" "" in
  if validate_name name then maybe_promote_live_persistent_keeper ctx.config name;
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

let inject_models_from_meta config name args =
  match Safe_ops.json_string_list "models" args with
  | _ :: _ -> args
  | [] ->
    match read_meta config name with
    | Ok (Some meta) when meta.models <> [] ->
      let models_json = `List (List.map (fun m -> `String m) meta.models) in
      (match args with
       | `Assoc fields -> `Assoc (("models", models_json) :: fields)
       | _ -> args)
    | _ -> args

let inject_goal_from_message args =
  match Safe_ops.json_string_opt "goal" args with
  | Some _ -> args
  | None ->
    let message = get_string args "message" "" in
    if message = "" then args
    else
      match args with
      | `Assoc fields -> `Assoc (("goal", `String message) :: fields)
      | _ -> args

let handle_resident_keeper_msg ctx args : tool_result =
  let name = get_string args "name" "" in
  if validate_name name then maybe_promote_live_persistent_keeper ctx.config name;
  let ensure_result =
    match read_resident_keeper ctx.config name with
    | Ok (Some _) -> Ok ()
    | _ ->
        let args_enriched =
          args |> inject_goal_from_message
               |> inject_models_from_meta ctx.config name
        in
        let ok, body = handle_resident_keeper_up ctx args_enriched in
        if ok then Ok () else Error body
  in
  match ensure_result with
  | Error err -> (false, err)
  | Ok _ ->
      let ok, body = Turn.handle_keeper_msg ctx args in
      if not ok then (ok, body)
      else begin
        invalidate_resident_keeper_list_cache ();
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
  if validate_name name then maybe_promote_live_persistent_keeper ctx.config name;
  let ensure_result =
    match read_resident_keeper ctx.config name with
    | Ok (Some _) -> Ok ()
    | _ ->
        let args_enriched =
          args |> inject_goal_from_message
               |> inject_models_from_meta ctx.config name
        in
        let ok, body = handle_resident_keeper_up ctx args_enriched in
        if ok then Ok () else Error body
  in
  match ensure_result with
  | Error err -> (false, err)
  | Ok _ ->
      let ok, body = Turn.handle_keeper_msg ~on_text_delta ctx args in
      if not ok then (ok, body)
      else begin
        invalidate_resident_keeper_list_cache ();
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
  invalidate_resident_keeper_list_cache ();
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
        invalidate_resident_keeper_list_cache ();
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
  let cache_key = Printf.sprintf "%d:%b" limit detailed in
  let body =
    cached_text_by_key _resident_keeper_list_cache ~key:cache_key
      ~ttl_s:(resident_keeper_list_cache_ttl_s ()) (fun () ->
        let resident =
          resident_keeper_names ctx.config
          |> take limit
        in
        let rows =
          resident
          |> List.filter_map
               (keeper_list_row_json ~runtime_class:"resident_keeper" ~desired:true
                  ~resident_registered:true ctx.config)
        in
        let json =
          if not detailed then
            `Assoc
              [
                ("count", `Int (List.length resident));
                ("keepers", `List (List.map (fun name -> `String name) resident));
                ("items", `List rows);
              ]
          else
            `Assoc
              [
                ("count", `Int (List.length rows));
                ("keepers", `List rows);
              ]
        in
        Yojson.Safe.pretty_to_string json)
  in
  (true, body)

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
  | "masc_keeper_policy_set" -> Some (false, "keeper policy update has been removed")
  | "masc_keeper_feedback_record" -> Some (false, "policy feedback system has been removed")
  | "masc_keeper_dataset_export" -> Some (false, "policy dataset system has been removed")
  | "masc_keeper_action_explain" -> Some (false, "policy action explain has been removed")
  | "masc_keeper_eval_replay" -> Some (false, "policy eval replay has been removed")
  | "masc_keeper_down" -> Some (handle_resident_keeper_down ctx args)
  | "masc_keeper_list" -> Some (handle_resident_keeper_list ctx args)
  | "masc_keeper_autonomy" -> Some (false, "autonomy_level has been removed")
  | "masc_keeper_goals" -> Some (false, "policy goals system has been removed")
  | "masc_keeper_trajectory" -> Some (Status.handle_keeper_trajectory ctx args)
  | "masc_keeper_eval" -> Some (Status.handle_keeper_eval ctx args)
  | "masc_persistent_agent_create_from_persona" ->
      Some (handle_persistent_agent_create_from_persona ctx args)
  | "masc_persistent_agent_up" -> Some (handle_persistent_agent_up ctx args)
  | "masc_persistent_agent_status" -> Some (handle_persistent_agent_status ctx args)
  | "masc_persistent_agent_msg" -> Some (handle_persistent_agent_msg ctx args)
  | "masc_persistent_agent_model_set" -> Some (handle_persistent_agent_model_set ctx args)
  | "masc_persistent_agent_policy_set" ->
      Some (false, "keeper policy update has been removed")
  | "masc_persistent_agent_feedback_record" -> Some (false, "policy feedback system has been removed")
  | "masc_persistent_agent_dataset_export" -> Some (false, "policy dataset system has been removed")
  | "masc_persistent_agent_action_explain" -> Some (false, "policy action explain has been removed")
  | "masc_persistent_agent_eval_replay" -> Some (false, "policy eval replay has been removed")
  | "masc_persistent_agent_down" -> Some (handle_persistent_agent_down ctx args)
  | "masc_persistent_agent_list" -> Some (handle_persistent_agent_list ctx args)
  | "masc_persistent_agent_autonomy" -> Some (false, "autonomy_level has been removed")
  | "masc_persistent_agent_goals" -> Some (false, "policy goals system has been removed")
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
