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
  net : [ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t option;
}

type tool_result = Keeper_types.tool_result

let schemas = Keeper_types.schemas

type text_cache = {
  mutable key : string option;
  mutable value : string option;
  mutable expires_at : float;
}

let _keeper_list_cache = { key = None; value = None; expires_at = 0.0 }

let cache_ttl_seconds env_var ~default =
  match Sys.getenv_opt env_var with
  | Some raw -> (
      match Float.of_string_opt (String.trim raw) with
      | Some value when value >= 0.0 -> value
      | _ -> default)
  | None -> default

let keeper_list_cache_ttl_s () =
  cache_ttl_seconds "MASC_KEEPER_LIST_CACHE_TTL_S" ~default:2.0

let invalidate_keeper_list_cache () =
  _keeper_list_cache.key <- None;
  _keeper_list_cache.value <- None;
  _keeper_list_cache.expires_at <- 0.0

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

let annotate_keeper_json ~runtime_class json =
  match json with
  | `Assoc fields ->
      `Assoc (("runtime_class", `String runtime_class) :: fields)
  | other -> other

let keeper_brief_meta_json (meta : keeper_meta) =
  `Assoc
    [
      ("name", `String meta.name);
      ("goal", `String meta.goal);
      ("trace_id", `String meta.runtime.trace_id);
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

let keeper_list_row_json ~runtime_class config name =
  match read_meta config name with
  | Error _ | Ok None -> None
  | Ok (Some (meta : keeper_meta)) ->
      let now_ts = Time_compat.now () in
      let keepalive_running = Keeper_status_bridge.runtime_keepalive_running config meta in
      let agent_status =
        Keeper_exec_status.parse_agent_status config ~agent_name:meta.agent_name
      in
      let diagnostic =
        Keeper_exec_status.keeper_diagnostic_json
          ~meta
          ~agent_status
          ~keepalive_running ~history_items:[] ~now_ts
        |> Keeper_exec_status.augment_keeper_diagnostic_json
             ~meta ~keepalive_running
             ~keepalive_started_at:
               (Keeper_status_bridge.runtime_keepalive_started_at config meta)
             ~now_ts
      in
      let status =
        Keeper_exec_status.keeper_surface_status ~agent_status ~diagnostic
      in
      Some
        (`Assoc
          [
            ("runtime_class", `String runtime_class);
            ("name", `String meta.name);
            ("meta", keeper_brief_meta_json meta);
            ("agent_name", `String meta.agent_name);
            ("status", `String status);
            ("keepalive_running", `Bool keepalive_running);
            ("scope_kind", `String meta.scope_kind);
            ("room_scope", `String meta.room_scope);
            ("proactive_enabled", `Bool meta.proactive.enabled);
            ("proactive_idle_sec", `Int meta.proactive.idle_sec);
            ("proactive_cooldown_sec", `Int meta.proactive.cooldown_sec);
            ("social_model", `String meta.social_model);
            ( "last_speech_act",
              if String.trim meta.runtime.last_speech_act = ""
              then `Null
              else `String meta.runtime.last_speech_act );
            ("skill_route", keeper_list_skill_route_json config meta);
            ("cascade_name", `String meta.cascade_name);
            ("created_at", `String meta.created_at);
            ("updated_at", `String meta.updated_at);
          ])

let handle_keeper_create_from_persona ctx args : tool_result =
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
              ("resolved_args", resolved_args);
            ]
        in
        (true, Yojson.Safe.pretty_to_string json)
      else
        let ok, body = Turn.handle_keeper_up ctx resolved_args in
        if not ok then
          (false, body)
        else
          let created_json =
            try Yojson.Safe.from_string body with Yojson.Json_error _ -> `String body
          in
          let json =
            `Assoc
              [
                ("persona", Keeper_exec_persona.persona_summary_to_json persona);
                ("created", `Bool true);
                ("result", annotate_keeper_json ~runtime_class:"keeper" created_json);
                ("resolved_args", resolved_args);
              ]
          in
          invalidate_keeper_list_cache ();
          (true, Yojson.Safe.pretty_to_string json)

let handle_keeper_up ctx args : tool_result =
  let ok, body = Turn.handle_keeper_up ctx args in
  if not ok then (ok, body)
  else
    let json =
      try Yojson.Safe.from_string body with Yojson.Json_error _ -> `String body
    in
    invalidate_keeper_list_cache ();
    (true,
     Yojson.Safe.pretty_to_string
       (annotate_keeper_json ~runtime_class:"keeper" json))

let handle_keeper_status ctx args : tool_result =
  let ok, body = Status.handle_keeper_status ctx args in
  if not ok then (ok, body)
  else
    let json =
      try Yojson.Safe.from_string body with Yojson.Json_error _ -> `String body
    in
    (true,
     Yojson.Safe.pretty_to_string
       (annotate_keeper_json ~runtime_class:"keeper" json))

let ensure_keeper_exists ctx args =
  let name = get_string args "name" "" in
  match read_meta ctx.config name with
  | Ok (Some _) -> Ok ()
  | Ok None -> Error (Printf.sprintf "❌ keeper not found: %s" name)
  | Error err -> Error (Printf.sprintf "❌ %s" err)

let handle_keeper_msg ctx args : tool_result =
  match ensure_keeper_exists ctx args with
  | Error err -> (false, err)
  | Ok _ ->
      let ok, body = Turn.handle_keeper_msg ctx args in
      if not ok then (ok, body)
      else begin
        invalidate_keeper_list_cache ();
        let json =
          try Yojson.Safe.from_string body with Yojson.Json_error _ -> `String body
        in
        (true,
         Yojson.Safe.pretty_to_string
           (annotate_keeper_json ~runtime_class:"keeper" json))
      end

let handle_keeper_msg_stream ~on_text_delta ctx args : tool_result =
  match ensure_keeper_exists ctx args with
  | Error err -> (false, err)
  | Ok _ ->
      let ok, body = Turn.handle_keeper_msg ~on_text_delta ctx args in
      if not ok then (ok, body)
      else begin
        invalidate_keeper_list_cache ();
        let json =
          try Yojson.Safe.from_string body with Yojson.Json_error _ -> `String body
        in
        (true,
         Yojson.Safe.pretty_to_string
           (annotate_keeper_json ~runtime_class:"keeper" json))
      end

let resolve_keeper_meta ctx args =
  let name = get_string args "name" "" in
  match read_meta ctx.config name with
  | Ok (Some meta) -> Ok meta
  | Ok None -> Error (Printf.sprintf "❌ keeper not found: %s" name)
  | Error err -> Error (Printf.sprintf "❌ %s" err)

let default_keeper_model_label (meta : keeper_meta) =
  match String.trim meta.runtime.usage.last_model_used with
  | "" -> (
      match Oas_model_resolve.models_of_cascade_name meta.cascade_name with
      | first :: _ when String.trim first <> "" -> first
      | _ -> "llama:qwen3.5-9b-local")
  | model -> model

let annotate_keeper_repair_json ~(keeper_name : string) body =
  let parsed =
    try Some (Yojson.Safe.from_string body) with Yojson.Json_error _ -> None
  in
  match parsed with
  | Some (`Assoc fields) ->
      Yojson.Safe.pretty_to_string
        (`Assoc
          ( ("runtime_class", `String "keeper")
          :: ("keeper_name", `String keeper_name)
          :: ("delegated_tool", `String "masc_repair_loop")
          :: fields ))
  | _ -> body

let handle_keeper_repair ctx args : tool_result =
  match resolve_keeper_meta ctx args with
  | Error err -> (false, err)
  | Ok meta ->
      let task_spec = get_string args "task_spec" "" in
      if String.trim task_spec = "" then
        (false, "task_spec is required")
      else
        let target_mode = get_string args "target_mode" "snippet" in
        let working_dir_arg = get_string args "working_dir" (Sys.getcwd ()) in
        let plugin_id = get_string args "plugin_id" "ocaml" in
        let target_file_opt = get_string_opt args "target_file" in
        let cwd_root =
          try Unix.realpath (Sys.getcwd ()) with
          | Unix.Unix_error _ -> Sys.getcwd ()
        in
        let resolved_working_dir_result =
          try Ok (Unix.realpath working_dir_arg) with
          | Unix.Unix_error _ ->
              Error "working_dir does not exist or is not accessible"
        in
        match resolved_working_dir_result with
        | Error msg -> (false, msg)
        | Ok working_dir ->
            if not
                 (Tool_repair_loop.is_safe_subpath ~parent:cwd_root
                    ~child:working_dir)
            then
              (false, "working_dir must be within the current workspace")
            else
              match
                Tool_repair_loop.validate_target_file ~working_dir
                  ~target_file:target_file_opt
              with
              | Error msg -> (false, msg)
              | Ok validated_target_file ->
                  let validator_profile =
                    get_string args "validator_profile"
                      (if
                         String.equal (String.lowercase_ascii target_mode)
                           "repo"
                       then
                         "repo_dune_build"
                       else
                         "snippet_ocamlc")
                  in
                  let max_attempts =
                    min 10 (max 1 (get_int args "max_attempts" 2))
                  in
                  let fields =
                    [
                      ("plugin_id", `String plugin_id);
                      ("task_spec", `String task_spec);
                      ("target_mode", `String target_mode);
                      ("working_dir", `String working_dir);
                      ("validator_profile", `String validator_profile);
                      ( "model_label",
                        `String
                          (get_string args "model_label"
                             (default_keeper_model_label meta)) );
                      ("max_attempts", `Int max_attempts);
                      ("artifact_session_id", `String meta.runtime.trace_id);
                    ]
                  in
                  let fields =
                    match validated_target_file with
                    | Some target_file ->
                        ("target_file", `String target_file) :: fields
                    | None -> fields
                  in
                  let fields =
                    match get_string_opt args "source_text" with
                    | Some source_text ->
                        ("source_text", `String source_text) :: fields
                    | None -> fields
                  in
                  let ok, body =
                    Team_session_oas_bridge.run_repair_loop_until_terminal
                      ~sw:ctx.sw ~clock:ctx.clock ~config:ctx.config
                      (`Assoc fields)
                  in
                  (ok, annotate_keeper_repair_json ~keeper_name:meta.name body)

let handle_keeper_down ctx args : tool_result =
  invalidate_keeper_list_cache ();
  Turn.handle_keeper_down ctx args

let keeper_rows_json ctx names =
  names
  |> List.filter_map (keeper_list_row_json ~runtime_class:"keeper" ctx.config)

let handle_keeper_list ctx args : tool_result =
  let limit = max 0 (get_int args "limit" 50) in
  let detailed = get_bool args "detailed" false in
  let cache_key = Printf.sprintf "%d:%b" limit detailed in
  let body =
    cached_text_by_key _keeper_list_cache ~key:cache_key
      ~ttl_s:(keeper_list_cache_ttl_s ()) (fun () ->
        let names =
          keeper_names ctx.config
          |> take limit
        in
        let rows = keeper_rows_json ctx names in
        let json =
          if not detailed then
            `Assoc
              [
                ("count", `Int (List.length names));
                ("keepers", `List (List.map (fun name -> `String name) names));
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

(* ================================================================ *)
(* Recurring loop tools (#3190)                                      *)
(* ================================================================ *)

let handle_keeper_add_loop _ctx (args : Yojson.Safe.t) : tool_result =
  let keeper_name = Safe_ops.json_string ~default:"" "keeper_name" args in
  let label = Safe_ops.json_string ~default:"" "label" args in
  let interval_sec = Safe_ops.json_int ~default:600 "interval_sec" args in
  let message = Safe_ops.json_string ~default:"" "message" args in
  let max_failures = Safe_ops.json_int ~default:5 "max_failures" args in
  if keeper_name = "" then (false, "keeper_name required")
  else if message = "" then (false, "message required")
  else if interval_sec < 30 then (false, "interval_sec minimum is 30")
  else
    let task = Keeper_recurring.add
      ~keeper_name ~label:(if label = "" then message else label)
      ~interval_sec ~max_failures
      (Keeper_recurring.Broadcast message) in
    (true, Printf.sprintf "Recurring task registered: %s (every %ds)\n%s"
       task.id interval_sec
       (Yojson.Safe.to_string (Keeper_recurring.task_to_json task)))

let handle_keeper_list_loops _ctx (args : Yojson.Safe.t) : tool_result =
  let keeper_name = Safe_ops.json_string ~default:"" "keeper_name" args in
  let tasks =
    if keeper_name = "" then Keeper_recurring.list_all ()
    else Keeper_recurring.list ~keeper_name
  in
  let tasks_json = `List (List.map Keeper_recurring.task_to_json tasks) in
  (true, Printf.sprintf "%d recurring task(s)\n%s"
     (List.length tasks) (Yojson.Safe.to_string tasks_json))

let handle_keeper_remove_loop _ctx (args : Yojson.Safe.t) : tool_result =
  let id = Safe_ops.json_string ~default:"" "id" args in
  if id = "" then (false, "id required")
  else if Keeper_recurring.remove ~id then
    (true, Printf.sprintf "Task '%s' removed" id)
  else
    (false, Printf.sprintf "Task '%s' not found" id)

let should_bootstrap_existing_keepalives name args =
  match name with
  | "masc_keeper_msg" ->
      String.trim (get_string args "message" "") <> ""
  | _ -> false

let maybe_bootstrap_existing_keepalives ctx ~name ~args =
  if should_bootstrap_existing_keepalives name args then
    (try start_existing_keepalives ctx
     with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
       Log.Keeper.error "start_existing_keepalives failed: %s"
         (Printexc.to_string exn))

(** Resolve base_path from keeper registry.  Dashboard/external sessions may
    use a different base_path than the target keeper. *)
let resolve_keeper_base_path ctx args =
  let keeper_name = get_string args "name" "" in
  if keeper_name = "" then ctx
  else match Keeper_registry.find_by_name keeper_name with
  | Some entry when entry.base_path <> ctx.config.base_path ->
      { ctx with config = { ctx.config with base_path = entry.base_path } }
  | _ -> ctx

let dispatch ctx ~name ~args : tool_result option =
  maybe_bootstrap_existing_keepalives ctx ~name ~args;
  let ctx = resolve_keeper_base_path ctx args in
  match name with
  | "masc_persona_list" -> Some (Persona.handle_persona_list ctx args)
  | "masc_keeper_create_from_persona" -> Some (handle_keeper_create_from_persona ctx args)
  | "masc_keeper_up" -> Some (handle_keeper_up ctx args)
  | "masc_keeper_status" -> Some (handle_keeper_status ctx args)
  | "masc_keeper_msg" -> Some (handle_keeper_msg ctx args)
  | "masc_keeper_repair" -> Some (handle_keeper_repair ctx args)
  | "masc_keeper_down" -> Some (handle_keeper_down ctx args)
  | "masc_keeper_list" -> Some (handle_keeper_list ctx args)
  | "masc_keeper_trajectory" -> Some (Status.handle_keeper_trajectory ctx args)
  | "masc_keeper_eval" -> Some (Status.handle_keeper_eval ctx args)
  (* Recurring loops (#3190) *)
  | "masc_keeper_add_loop" -> Some (handle_keeper_add_loop ctx args)
  | "masc_keeper_list_loops" -> Some (handle_keeper_list_loops ctx args)
  | "masc_keeper_remove_loop" -> Some (handle_keeper_remove_loop ctx args)
  (* Housekeeping: keepers maintain their own world *)
  | "masc_housekeep_scan" | "masc_housekeep_delete" | "masc_housekeep_prune" ->
      Tool_housekeep.dispatch ctx.config ~name ~args
  | _ -> None

(** Streaming dispatch: only handles keeper_msg with text delta forwarding.
    Returns None for all other tool names.
    Called from server_routes_http_keeper_stream. *)
let dispatch_stream ~on_text_delta ctx ~name ~args : tool_result option =
  maybe_bootstrap_existing_keepalives ctx ~name ~args;
  let ctx = resolve_keeper_base_path ctx args in
  match name with
  | "masc_keeper_msg" ->
      Some (handle_keeper_msg_stream ~on_text_delta ctx args)
  | _ -> None
