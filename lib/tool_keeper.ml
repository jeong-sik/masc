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
  config : Coord.config;
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
      | Some value when Stdlib.Float.compare value 0.0 >= 0 -> value
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
    when String.equal cached_key key && Stdlib.Float.compare now cache.expires_at < 0 ->
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

let attach_assoc_field key value = function
  | `Assoc fields -> `Assoc ((key, value) :: fields)
  | other -> other

let maybe_reseed_keeper_identity ctx (meta : keeper_meta) =
  let expected_agent_name = Keeper_types.keeper_agent_name meta.name in
  if String.equal expected_agent_name meta.agent_name then
    Ok (meta, None)
  else
    let previous_trace_id = Keeper_id.Trace_id.to_string meta.runtime.trace_id in
    let new_trace_id_raw = Keeper_identity.generate_trace_id () in
    match Keeper_id.Trace_id.of_string new_trace_id_raw with
    | Error err ->
        Error
          (Printf.sprintf
             "failed to reseed keeper identity for %s: invalid trace_id %s (%s)"
             meta.name new_trace_id_raw err)
    | Ok new_trace_id ->
        let base_dir = Keeper_types.session_base_dir ctx.config in
        let _session =
          Keeper_exec_context.create_session ~session_id:new_trace_id_raw
            ~base_dir
        in
        let updated_meta =
          {
            meta with
            agent_name = expected_agent_name;
            updated_at = Keeper_types.now_iso ();
            runtime =
              {
                meta.runtime with
                trace_id = new_trace_id;
                trace_history =
                  Json_util.dedupe_keep_order
                    (previous_trace_id :: meta.runtime.trace_history);
                generation = meta.runtime.generation + 1;
              };
          }
        in
        (match Keeper_types.write_meta ~force:true ctx.config updated_meta with
         | Ok () ->
             Keeper_status_detail.invalidate_status_cache_for updated_meta.name;
             Ok
               ( updated_meta,
                 Some
                   (`Assoc
                      [
                        ("reason", `String "agent_name_mismatch");
                        ("keeper_name", `String updated_meta.name);
                        ("previous_agent_name", `String meta.agent_name);
                        ("expected_agent_name", `String expected_agent_name);
                        ("previous_trace_id", `String previous_trace_id);
                        ("new_trace_id", `String new_trace_id_raw);
                      ]) )
         | Error err ->
             Error
               (Printf.sprintf
                  "failed to persist reseeded keeper identity for %s: %s"
                  meta.name err))

let prepare_keeper_up_identity ctx args =
  let name = String.trim (get_string args "name" "") in
  match read_meta_resolved ctx.config name with
  | Ok (Some (_resolved_name, meta)) -> (
      match maybe_reseed_keeper_identity ctx meta with
      | Ok (updated_meta, identity_reseed) ->
          let prepared_args =
            match args with
            | `Assoc fields ->
                `Assoc
                  (("name", `String updated_meta.name)
                  :: List.remove_assoc "name" fields)
            | other -> other
          in
          Ok (prepared_args, identity_reseed)
      | Error _ as err -> err)
  | Ok None -> Ok (args, None)
  | Error err -> Error (Printf.sprintf "%s" err)

let startup_not_ready_error_json elapsed =
  `Assoc
    [
      ("error", `String "server_initializing");
      ( "message",
        `String
          (Printf.sprintf
             "MASC server is still starting (%.0fs elapsed). Retry in a few seconds."
             elapsed) );
      ("retry_after_ms", `Int 3000);
    ]
  |> Yojson.Safe.pretty_to_string

let with_keeper_startup_gate f =
  if not Server_startup_state.((!state).state_ready) then begin
    let elapsed = Server_startup_state.elapsed_since_start () in
    Log.Keeper.warn "keeper_up rejected: server not ready (%.1fs since start)" elapsed;
    (false, startup_not_ready_error_json elapsed)
  end else
    f ()

let execute_keeper_up ctx args : tool_result =
  match prepare_keeper_up_identity ctx args with
  | Error err -> (false, err)
  | Ok (prepared_args, identity_reseed) ->
      let ok, body = Turn.handle_keeper_up ctx prepared_args in
      if not ok then
        (ok, body)
      else
        let json =
          try Yojson.Safe.from_string body with Yojson.Json_error _ -> `String body
        in
        let json =
          match identity_reseed with
          | Some note -> attach_assoc_field "identity_reseed" note json
          | None -> json
        in
        invalidate_keeper_list_cache ();
        Keeper_status_detail.invalidate_status_cache_for
          (get_string prepared_args "name" "");
        (true,
         Yojson.Safe.pretty_to_string
           (annotate_keeper_json ~runtime_class:"keeper" json))

let keeper_brief_meta_json (meta : keeper_meta) =
  `Assoc
    [
      ("name", `String meta.name);
      ("goal", `String meta.goal);
      ("trace_id", `String (Keeper_id.Trace_id.to_string meta.runtime.trace_id));
      ("created_at", `String meta.created_at);
      ("updated_at", `String meta.updated_at);
    ]

let keeper_list_skill_route_json config (meta : keeper_meta) =
  let metrics_store = keeper_metrics_store config meta.name in
  let metrics_path = keeper_metrics_path config meta.name in
  let lines =
    let dated = Dated_jsonl.read_recent_lines metrics_store 50 in
    if Stdlib.List.length dated > 0 then dated
    else Keeper_memory.read_file_tail_lines metrics_path ~max_bytes:16_000 ~max_lines:50
  in
  let open Yojson.Safe.Util in
  let rec find_latest = function
    | [] -> `Null
    | line :: tl -> (
        try
          let json = Yojson.Safe.from_string line in
          match Safe_ops.json_string_opt "skill_primary" json with
          | Some primary when not (String.equal (String.trim primary) "") ->
              let secondary =
                match json |> member "skill_secondary" with
                | `List xs ->
                    xs
                    |> List.filter_map (function
                         | `String s when not (String.equal (String.trim s) "") -> Some (`String s)
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
        (`Assoc (
          [
            ("runtime_class", `String runtime_class);
            ("name", `String meta.name);
            ("meta", keeper_brief_meta_json meta);
            ("agent_name", `String meta.agent_name);
            ("status", `String status);
            ("keepalive_running", `Bool keepalive_running);
            ("autoboot_enabled", `Bool meta.autoboot_enabled);
            ("proactive_enabled", `Bool meta.proactive.enabled);
            ("proactive_idle_sec", `Int meta.proactive.idle_sec);
            ("proactive_cooldown_sec", `Int meta.proactive.cooldown_sec);
            ("skill_route", keeper_list_skill_route_json config meta);
            ("cascade_name", `String meta.cascade_name);
            ("created_at", `String meta.created_at);
            ("updated_at", `String meta.updated_at);
          ]
          @ Keeper_status_bridge.social_model_resolution_fields_json meta
          @ [
            ( "last_speech_act",
              if String.equal (String.trim meta.runtime.last_speech_act) "" then `Null
              else `String meta.runtime.last_speech_act );
            ( "delivery_surface_view",
              Json_util.string_opt_to_json
                (Keeper_social_model.delivery_surface_view_of_meta meta
                 |> Option.map Keeper_social_model.delivery_surface_to_string)
            );
            ( "delivery_surface_view_source",
              Json_util.string_opt_to_json
                (Keeper_social_model.delivery_surface_view_source_of_meta meta)
            );
            ( "last_social_transition_reason",
              if String.equal (String.trim meta.runtime.last_social_transition_reason) "" then `Null
              else `String meta.runtime.last_social_transition_reason );
          ]))

let invalidate_status_cache name =
  Keeper_status_detail.invalidate_status_cache_for name

let with_keeper_name args name =
  match args with
  | `Assoc fields ->
      `Assoc (("name", `String name) :: List.remove_assoc "name" fields)
  | other -> other

let prepare_passive_keeper_identity ctx args =
  let requested_name =
    match String.trim (get_string args "name" "") with
    | "" -> String.trim ctx.agent_name
    | name -> name
  in
  if String.equal requested_name "" then
    Ok (args, None)
  else
    match read_meta_resolved ctx.config requested_name with
    | Ok (Some (_resolved_name, meta)) -> (
        match maybe_reseed_keeper_identity ctx meta with
        | Ok (updated_meta, identity_reseed) ->
            Ok (with_keeper_name args updated_meta.name, identity_reseed)
        | Error _ as err -> err)
    | Ok None -> Ok (args, None)
    | Error err -> Error (Printf.sprintf "%s" err)

let attach_identity_reseed ?identity_reseed json =
  match identity_reseed with
  | None -> json
  | Some note -> attach_assoc_field "identity_reseed" note json

let handle_keeper_create_from_persona ctx args : tool_result =
  if not Server_startup_state.((!state).state_ready) then begin
    let elapsed = Server_startup_state.elapsed_since_start () in
    Log.Keeper.warn "create_from_persona rejected: server not ready (%.1fs)" elapsed;
    (false, startup_not_ready_error_json elapsed)
  end else
  match Keeper_exec_persona.resolved_keeper_args_from_persona args with
  | Error e -> (false, "" ^ e)
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
        (true, Yojson.Safe.to_string json)
      else
        match Keeper_exec_persona.render_keeper_toml_from_resolved_args resolved_args with
        | Error e -> (false, "" ^ e)
        | Ok _ ->
        let (ok, body) = with_keeper_startup_gate (fun () -> execute_keeper_up ctx resolved_args) in
        if not ok then
          (false, body)
        else
          match Keeper_exec_persona.persist_keeper_toml_from_resolved_args resolved_args with
          | Error e ->
              (false, "keeper created but durable config write failed: " ^ e)
          | Ok durable_config ->
          let created_json =
            try Yojson.Safe.from_string body with Yojson.Json_error _ -> `String body
          in
          let json =
            `Assoc
              [
                ("persona", Keeper_exec_persona.persona_summary_to_json persona);
                ("created", `Bool true);
                ("durable_config", durable_config);
                ("result", annotate_keeper_json ~runtime_class:"keeper" created_json);
                ("resolved_args", resolved_args);
              ]
          in
          invalidate_keeper_list_cache ();
          invalidate_status_cache (get_string resolved_args "name" "");
          (true, Yojson.Safe.to_string json)

let handle_keeper_up ctx args : tool_result =
  with_keeper_startup_gate (fun () -> execute_keeper_up ctx args)

let handle_keeper_status ctx args : tool_result =
  match prepare_passive_keeper_identity ctx args with
  | Error err -> (false, err)
  | Ok (prepared_args, identity_reseed) ->
      let ok, body = Status.handle_keeper_status ctx prepared_args in
      if not ok then (ok, body)
      else
        let json =
          try Yojson.Safe.from_string body with Yojson.Json_error _ -> `String body
        in
        let json =
          json
          |> annotate_keeper_json ~runtime_class:"keeper"
          |> attach_identity_reseed ?identity_reseed
        in
        (true, Yojson.Safe.pretty_to_string json)

let resolve_keeper_name ctx args =
  let name = String.trim (get_string args "name" "") in
  match read_meta_resolved ctx.config name with
  | Ok (Some (resolved_name, _meta)) -> Ok resolved_name
  | Ok None ->
      (match keeper_name_from_agent_name name with
       | Some stripped ->
           Error
             (Printf.sprintf
                "keeper not found: %s (also tried %s)"
                name stripped)
       | None -> Error (Printf.sprintf "keeper not found: %s" name))
  | Error err -> Error (Printf.sprintf "%s" err)

let handle_keeper_msg ctx args : tool_result =
  match resolve_keeper_name ctx args with
  | Error err -> (false, err)
  | Ok name ->
      let resolved_args = with_keeper_name args name in
      let request_id = Keeper_msg_async.submit ~sw:ctx.sw
        ~keeper_name:name
        ~f:(fun () ->
          let ok, body = Turn.handle_keeper_msg ctx resolved_args in
          if ok then begin
            invalidate_keeper_list_cache ();
            invalidate_status_cache name
          end;
          (ok, body))
      in
      let json = `Assoc [
        ("request_id", `String request_id);
        ("keeper_name", `String name);
        ("status", `String "queued");
        ("message", `String "Keeper turn submitted. Poll with keeper_msg_result.");
      ] in
      (true, Yojson.Safe.to_string json)

let handle_keeper_msg_result _ctx args : tool_result =
  let request_id = get_string args "request_id" "" in
  if String.equal request_id "" then
    (false, {|{"error":"request_id is required"}|})
  else
    match Keeper_msg_async.poll request_id with
    | None ->
      (false, Printf.sprintf {|{"error":"request_id not found","request_id":"%s"}|} request_id)
    | Some entry ->
      (true, Yojson.Safe.to_string (Keeper_msg_async.entry_to_json entry))

let handle_keeper_msg_stream ~on_text_delta ctx args : tool_result =
  match resolve_keeper_name ctx args with
  | Error err -> (false, err)
  | Ok name ->
      let resolved_args = with_keeper_name args name in
      let ok, body = Turn.handle_keeper_msg ~on_text_delta ctx resolved_args in
      if not ok then (ok, body)
      else begin
        invalidate_keeper_list_cache ();
        invalidate_status_cache name;
        let json =
          try Yojson.Safe.from_string body with Yojson.Json_error _ -> `String body
        in
        (true,
         Yojson.Safe.pretty_to_string
           (annotate_keeper_json ~runtime_class:"keeper" json))
      end

let resolve_keeper_meta ctx args =
  let name = String.trim (get_string args "name" "") in
  match read_meta_resolved ctx.config name with
  | Ok (Some (_resolved_name, meta)) -> Ok meta
  | Ok None -> Error (Printf.sprintf "keeper not found: %s" name)
  | Error err -> Error (Printf.sprintf "%s" err)

let default_keeper_model_label (meta : keeper_meta) =
  match String.trim meta.runtime.usage.last_model_used with
  | "" -> (
      match
        Cascade_runtime.models_of_cascade_name
          (Keeper_cascade_profile.Runtime_name meta.cascade_name)
      with
      | first :: _ when not (String.equal (String.trim first) "") -> first
      | _ -> Env_config.Local_runtime.default_model)
  | model -> model

let annotate_keeper_repair_json ?identity_reseed ~(keeper_name : string) body =
  let parsed =
    try Some (Yojson.Safe.from_string body) with Yojson.Json_error _ -> None
  in
  match parsed with
  | Some (`Assoc fields) ->
      Yojson.Safe.pretty_to_string
        (`Assoc
          ((match identity_reseed with
            | Some note -> [ ("identity_reseed", note) ]
            | None -> [])
          @ [
              ("runtime_class", `String "keeper");
              ("keeper_name", `String keeper_name);
              ("delegated_tool", `String "masc_keeper_repair");
            ]
          @ fields))
  | _ -> body

(* Playground path containment helpers (inlined from deleted Tool_repair_loop). *)

let is_safe_subpath ~parent ~child =
  if String.equal child parent then true
  else
    let parent_with_sep =
      if Filename.check_suffix parent Stdlib.Filename.dir_sep then parent
      else parent ^ Filename.dir_sep
    in
    let plen = String.length parent_with_sep in
    String.length child >= plen
    && String.equal (Stdlib.String.sub child 0 plen) parent_with_sep

let validate_target_file ~working_dir ~target_file =
  match target_file with
  | None -> Ok None
  | Some tf ->
      if not (Filename.is_relative tf) then
        Error "target_file must be a relative path"
      else
        let candidate = Filename.concat working_dir tf in
        let resolved =
          try Unix.realpath candidate with
          | Unix.Unix_error _ -> candidate
        in
        if is_safe_subpath ~parent:working_dir ~child:resolved then
          Ok (Some tf)
        else
          Error "target_file must reside within working_dir"

let resolve_playground_working_dir ~agent_name ~base_path ~working_dir_arg =
  let playground_rel =
    Keeper_alerting_path.playground_path_of_keeper agent_name
  in
  let playground_abs_raw = Filename.concat base_path playground_rel in
  match
    try Ok (Unix.realpath playground_abs_raw) with
    | Unix.Unix_error _ ->
        Error
          (Printf.sprintf
             "keeper playground directory %S does not exist yet — cannot \
              validate working_dir containment. Run masc_worktree_create \
              to provision your playground first. See #6527/#6641."
             playground_rel)
  with
  | Error msg -> Error msg
  | Ok playground_abs ->
      let effective_arg =
        if String.equal (String.trim working_dir_arg) "" then playground_abs
        else working_dir_arg
      in
      let resolved =
        try Ok (Unix.realpath effective_arg) with
        | Unix.Unix_error _ ->
            Error "working_dir does not exist or is not accessible"
      in
      (match resolved with
      | Error msg -> Error msg
      | Ok working_dir ->
          if is_safe_subpath ~parent:playground_abs ~child:working_dir then
            Ok working_dir
          else
            Error
              (Printf.sprintf
                 "working_dir must be inside your own keeper playground \
                  (%s). Cross-keeper repair loops are blocked — use \
                  masc_worktree_create to provision a workspace under your \
                  playground first. See #6527/#6641."
                 playground_rel))

let handle_keeper_repair ctx args : tool_result =
  match resolve_keeper_meta ctx args with
  | Error err -> (false, err)
  | Ok meta -> (
      match maybe_reseed_keeper_identity ctx meta with
      | Error err -> (false, err)
      | Ok (meta, identity_reseed) ->
          let task_spec = get_string args "task_spec" "" in
          if String.equal (String.trim task_spec) "" then
            (false, "task_spec is required")
          else
            let target_mode = get_string args "target_mode" "snippet" in
            let working_dir_arg = get_string args "working_dir" "" in
            let plugin_id = get_string args "plugin_id" "ocaml" in
            let target_file_opt = get_string_opt args "target_file" in
            (* #6641 iter10 — narrow working_dir to caller's playground.
               Default (empty arg) resolves to the caller's own playground
               bundle root, not [Sys.getcwd ()]. Cross-keeper targets are
               rejected. Shares the resolver with tool_repair_loop so the
               same fix applies to both dispatchers. *)
            match
              resolve_playground_working_dir
                ~agent_name:ctx.agent_name
                ~base_path:ctx.config.base_path
                ~working_dir_arg
            with
            | Error msg -> (false, msg)
            | Ok working_dir ->
                match
                  validate_target_file ~working_dir
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
                        ( "artifact_session_id",
                          `String
                            (Keeper_id.Trace_id.to_string meta.runtime.trace_id)
                        );
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
                      (* Team_session_oas_bridge removed *)
                      ignore (ctx.sw, ctx.clock, ctx.config, fields);
                      (false, {|{"error":"team session oas bridge removed"}|})
                    in
                    invalidate_status_cache meta.name;
                    ( ok,
                      annotate_keeper_repair_json ?identity_reseed
                        ~keeper_name:meta.name body )
)

let handle_keeper_down ctx args : tool_result =
  invalidate_keeper_list_cache ();
  invalidate_status_cache (get_string args "name" "");
  Turn.handle_keeper_down ctx args

let handle_keeper_list ctx args : tool_result =
  let limit = max 0 (get_int args "limit" 50) in
  let detailed = get_bool args "detailed" false in
  let cache_key =
    Printf.sprintf "%s:%d:%b" ctx.config.base_path limit detailed
  in
  let body =
    cached_text_by_key _keeper_list_cache ~key:cache_key
      ~ttl_s:(keeper_list_cache_ttl_s ()) (fun () ->
        let entries =
          Keeper_registry.all ~base_path:ctx.config.base_path ()
          |> List.sort (fun (a : Keeper_registry.registry_entry)
                            (b : Keeper_registry.registry_entry) ->
               String.compare a.name b.name)
          |> take limit
        in
        let names = List.map (fun (e : Keeper_registry.registry_entry) -> e.name) entries in
        let rows =
          entries
          |> List.filter_map (fun (e : Keeper_registry.registry_entry) ->
               keeper_list_row_json ~runtime_class:"keeper" ctx.config e.name)
        in
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

let json_bool_opt = function
  | Some value -> `Bool value
  | None -> `Null

let json_float_opt = function
  | Some value -> `Float value
  | None -> `Null

let existing_path_json ?(candidates = []) path_opt =
  let exists =
    match path_opt with
    | Some path -> Fs_compat.file_exists path
    | None -> false
  in
  `Assoc
    [
      ("path", Json_util.string_opt_to_json path_opt);
      ("exists", `Bool exists);
      ( "candidates",
        `List (List.map (fun path -> `String path) candidates) );
    ]

let dedupe_sorted_strings values =
  values
  |> List.map String.trim
  |> List.filter (fun value -> not (String.equal value ""))
  |> List.sort_uniq String.compare

let keeper_persona_audit_requested_names ctx args =
  let explicit_names =
    let names = get_string_list args "names" in
    (match get_string_opt args "name" with
     | Some name -> name :: names
     | None -> names)
    |> dedupe_sorted_strings
  in
  if Stdlib.List.length explicit_names > 0 then explicit_names
  else
    let registry_names =
      Keeper_registry.all ~base_path:ctx.config.base_path ()
      |> List.map (fun (entry : Keeper_registry.registry_entry) -> entry.name)
    in
    registry_names @ configured_keeper_names ctx.config @ keeper_names ctx.config
    |> dedupe_sorted_strings

let keeper_persona_audit_status ctx (meta : keeper_meta) =
  let keepalive_running =
    Keeper_status_bridge.runtime_keepalive_running ctx.config meta
  in
  let agent_status =
    Keeper_exec_status.parse_agent_status ctx.config ~agent_name:meta.agent_name
  in
  let now_ts = Time_compat.now () in
  let diagnostic =
    Keeper_exec_status.keeper_diagnostic_json
      ~meta ~agent_status ~keepalive_running ~history_items:[] ~now_ts
    |> Keeper_exec_status.augment_keeper_diagnostic_json
         ~meta ~keepalive_running
         ~keepalive_started_at:
           (Keeper_status_bridge.runtime_keepalive_started_at ctx.config meta)
         ~now_ts
  in
  Keeper_exec_status.keeper_surface_status ~agent_status ~diagnostic

let keeper_persona_profile_candidates persona_name =
  let resolution = Config_dir_resolver.resolve () in
  (resolution.personas.path :: Config_dir_resolver.personas_dirs ())
  |> dedupe_sorted_strings
  |> List.map (fun root ->
         Filename.concat (Filename.concat root persona_name) "profile.json")

let keeper_persona_audit_item ctx requested_name =
  let meta_result = read_meta_resolved ctx.config requested_name in
  let resolved_name, runtime_meta, runtime_meta_error =
    match meta_result with
    | Ok (Some (name, meta)) -> (name, Some meta, None)
    | Ok None -> (requested_name, None, None)
    | Error msg -> (requested_name, None, Some msg)
  in
  let keeper_toml_candidate =
    Filename.concat (Config_dir_resolver.keepers_dir ()) (resolved_name ^ ".toml")
  in
  let keeper_toml_path =
    match keeper_toml_path_opt resolved_name with
    | Some path -> Some path
    | None -> Some keeper_toml_candidate
  in
  let keeper_toml_exists = Fs_compat.file_exists keeper_toml_candidate in
  let defaults_result = load_keeper_profile_defaults_result resolved_name in
  let default_source = keeper_default_source_snapshot resolved_name in
  let defaults =
    match defaults_result with
    | Ok defaults -> defaults
    | Error _ -> default_source.defaults
  in
  let toml_error =
    match defaults_result with
    | Ok _ -> None
    | Error msg -> Some msg
  in
  let explicit_persona_name =
    match defaults.persona_name with
    | Some name when not (String.equal (String.trim name) "") -> Some (String.trim name)
    | _ -> None
  in
  let default_source_kind = default_source.source_kind in
  let inferred_persona_name =
    resolved_persona_name ~keeper_name:resolved_name defaults |> String.trim
  in
  let inferred_persona_profile_path =
    match inferred_persona_name with
    | "" -> None
    | name -> persona_profile_path_opt name
  in
  let persona_name =
    match explicit_persona_name with
    | Some name -> Some name
    | None -> (
        match default_source_kind, inferred_persona_profile_path with
        | Some "persona", _ when not (String.equal inferred_persona_name "") ->
            Some inferred_persona_name
        | _, Some _ when not (String.equal inferred_persona_name "") -> Some inferred_persona_name
        | _ -> None)
  in
  let persona_candidates =
    match persona_name with
    | Some name -> keeper_persona_profile_candidates name
    | None -> []
  in
  let persona_profile_path =
    match persona_name with
    | Some name -> (
        match persona_profile_path_opt name with
        | Some path -> Some path
        | None -> (
            match persona_candidates with
            | candidate :: _ -> Some candidate
            | [] -> None))
    | None -> None
  in
  let persona_profile_exists =
    match persona_profile_path with
    | Some path -> Fs_compat.file_exists path
    | None -> false
  in
  let persona_expected =
    Option.is_some explicit_persona_name
    || persona_profile_exists
    ||
    match default_source_kind with
    | Some "persona" -> true
    | _ -> false
  in
  let live_meta_path = keeper_meta_path ctx.config resolved_name in
  let live_meta_exists = Fs_compat.file_exists live_meta_path in
  let registry_entry =
    Keeper_registry.get ~base_path:ctx.config.base_path resolved_name
  in
  let keepalive_running =
    runtime_meta
    |> Option.map (Keeper_status_bridge.runtime_keepalive_running ctx.config)
  in
  let keepalive_started_at =
    match runtime_meta with
    | Some meta -> Keeper_status_bridge.runtime_keepalive_started_at ctx.config meta
    | None -> None
  in
  let runtime_status =
    runtime_meta |> Option.map (keeper_persona_audit_status ctx)
  in
  let autoboot_enabled =
    match runtime_meta with
    | Some meta -> Some meta.autoboot_enabled
    | None -> defaults.autoboot_enabled
  in
  let paused = runtime_meta |> Option.map (fun meta -> meta.paused) in
  let issues =
    let add cond issue acc = if cond then issue :: acc else acc in
    []
    |> add (not keeper_toml_exists) "missing_keeper_toml"
    |> add (Option.is_some toml_error) "toml_parse_error"
    |> add (persona_expected && not persona_profile_exists)
         "missing_persona_profile"
    |> add (not live_meta_exists) "missing_runtime_meta"
    |> add (Option.is_some runtime_meta_error) "runtime_meta_error"
    |> add (Option.is_some runtime_meta && Option.is_none registry_entry)
         "registry_missing"
    |> add (match autoboot_enabled with Some false -> true | _ -> false)
         "autoboot_disabled"
    |> add (match paused with Some true -> true | _ -> false) "keeper_paused"
    |> add (match runtime_meta with Some meta when Stdlib.List.length meta.active_goal_ids = 0 -> true | _ -> false)
         "empty_active_goal_ids"
    |> add
         (match runtime_meta, autoboot_enabled, paused, keepalive_running with
          | Some _, (Some true | None), (Some false | None), Some false -> true
          | _ -> false)
         "keepalive_not_running"
    |> List.rev
  in
  let phase =
    registry_entry
    |> Option.map (fun (entry : Keeper_registry.registry_entry) ->
           Keeper_state_machine.phase_to_string entry.phase)
  in
  `Assoc
    [
      ("name", `String resolved_name);
      ( "requested_name",
        if String.equal requested_name resolved_name then `Null
        else `String requested_name );
      ( "keeper_toml",
        existing_path_json ~candidates:[ keeper_toml_candidate ] keeper_toml_path );
      ("default_source_kind", Json_util.string_opt_to_json default_source_kind);
      ( "default_manifest_path",
        Json_util.string_opt_to_json defaults.manifest_path );
      ("toml_error", Json_util.string_opt_to_json toml_error);
      ("persona_name", Json_util.string_opt_to_json persona_name);
      ( "explicit_persona_name",
        Json_util.string_opt_to_json explicit_persona_name );
      ( "persona_profile",
        existing_path_json ~candidates:persona_candidates persona_profile_path );
      ( "runtime_meta",
        `Assoc
          [
            ("path", `String live_meta_path);
            ("exists", `Bool live_meta_exists);
            ("error", Json_util.string_opt_to_json runtime_meta_error);
          ] );
      ("registry_present", `Bool (Option.is_some registry_entry));
      ("phase", Json_util.string_opt_to_json phase);
      ("runtime_status", Json_util.string_opt_to_json runtime_status);
      ("autoboot_enabled", json_bool_opt autoboot_enabled);
      ("paused", json_bool_opt paused);
      ("keepalive_running", json_bool_opt keepalive_running);
      ("keepalive_started_at", json_float_opt keepalive_started_at);
      ("issues", `List (List.map (fun issue -> `String issue) issues));
      ("ok", `Bool (Stdlib.List.length issues = 0));
    ]

let keeper_persona_audit_summary items =
  let issue_list item =
    match Yojson.Safe.Util.member "issues" item with
    | `List issues ->
        List.filter_map (function `String issue -> Some issue | _ -> None) issues
    | _ -> []
  in
  let has_issue issue item = List.mem issue (issue_list item) in
  let count pred =
    List.fold_left (fun acc item -> if pred item then acc + 1 else acc) 0 items
  in
  let count_issue issue = count (has_issue issue) in
  let ok_count =
    count (fun item ->
        match Yojson.Safe.Util.member "ok" item with
        | `Bool true -> true
        | _ -> false)
  in
  `Assoc
    [
      ("total", `Int (List.length items));
      ("ok", `Int ok_count);
      ("with_issues", `Int (List.length items - ok_count));
      ("missing_keeper_toml", `Int (count_issue "missing_keeper_toml"));
      ("toml_parse_error", `Int (count_issue "toml_parse_error"));
      ( "missing_persona_profile",
        `Int (count_issue "missing_persona_profile") );
      ("missing_runtime_meta", `Int (count_issue "missing_runtime_meta"));
      ("runtime_meta_error", `Int (count_issue "runtime_meta_error"));
      ("registry_missing", `Int (count_issue "registry_missing"));
      ("autoboot_disabled", `Int (count_issue "autoboot_disabled"));
      ("keeper_paused", `Int (count_issue "keeper_paused"));
      ("keepalive_not_running", `Int (count_issue "keepalive_not_running"));
      ("empty_active_goal_ids", `Int (count_issue "empty_active_goal_ids"));
    ]

let handle_keeper_persona_audit ctx args : tool_result =
  let names = keeper_persona_audit_requested_names ctx args in
  let invalid_names = List.filter (fun name -> not (validate_name name)) names in
  if Stdlib.List.length invalid_names > 0 then
    error_result_typed ~code:Validation_error
      (Printf.sprintf "invalid keeper name(s): %s"
         (String.concat ", " invalid_names))
  else
    let limit = get_int args "limit" 100 |> max 0 |> min 500 in
    let include_ok = get_bool args "include_ok" true in
    let repair = get_bool args "repair" false in
    let dry_run_repair = get_bool args "dry_run_repair" false in
    let audited_items =
      names
      |> take limit
      |> List.map (keeper_persona_audit_item ctx)
    in
    let returned_items =
      if include_ok then audited_items
      else
        List.filter
          (fun item ->
            match Yojson.Safe.Util.member "ok" item with
            | `Bool true -> false
            | _ -> true)
          audited_items
    in
    let repair_result =
      if repair || dry_run_repair then
        Some
          (if dry_run_repair then Keeper_goal_repair.dry_run ctx.config
           else Keeper_goal_repair.run ctx.config)
      else None
    in
    let resolution = Config_dir_resolver.resolve () in
    let roots =
      `Assoc
        [
          ("base_path", `String ctx.config.base_path);
          ("masc_root", `String (Coord.masc_root_dir ctx.config));
          ("config_resolution", Config_dir_resolver.to_json resolution);
          ( "personas_dirs",
            `List
              (List.map
                 (fun path -> `String path)
                 (Config_dir_resolver.personas_dirs ())) );
        ]
    in
    let base_response =
      [
        ("status", `String "ok");
        ("tool", `String "masc_keeper_persona_audit");
        ("roots", roots);
        ("summary", keeper_persona_audit_summary audited_items);
        ("returned_count", `Int (List.length returned_items));
        ("items", `List returned_items);
      ]
    in
    let response_with_repair =
      match repair_result with
      | Some r -> ("goal_repair", Keeper_goal_repair.repair_result_to_yojson r) :: base_response
      | None -> base_response
    in
    ( true,
      Yojson.Safe.pretty_to_string (`Assoc response_with_repair) )

let parse_network_mode_or_error raw =
  match network_mode_of_string raw with
  | Some mode -> Ok mode
  | None ->
      Error
        (Printf.sprintf "invalid network_mode %S (allowed: %s)" raw
           (String.concat ", " valid_network_mode_strings))

let handle_keeper_sandbox_status ctx args : tool_result =
  let verbose = get_bool args "verbose" false in
  let include_preflight = get_bool args "include_preflight" true in
  let timeout_sec = Stdlib.Float.min 20.0 (Stdlib.Float.max 1.0 (get_float args "timeout_sec" 5.0)) in
  let render_item (meta : keeper_meta) =
    Keeper_sandbox_control.live_status_json
      ~include_preflight ~config:ctx.config ~meta ~timeout_sec ~verbose ()
  in
  match String.trim (get_string args "name" "") with
  | "" ->
      let items =
        Keeper_registry.all ~base_path:ctx.config.base_path ()
        |> List.sort (fun (a : Keeper_registry.registry_entry)
                          (b : Keeper_registry.registry_entry) ->
             String.compare a.name b.name)
        |> List.filter_map (fun (entry : Keeper_registry.registry_entry) ->
             match read_meta ctx.config entry.name with
             | Ok (Some meta) -> Some (render_item meta)
             | Ok None | Error _ -> None)
      in
      ( true,
        Yojson.Safe.pretty_to_string
          (`Assoc
             [
               ("count", `Int (List.length items));
               ("items", `List items);
             ]) )
  | _ ->
      (match prepare_passive_keeper_identity ctx args with
       | Error err -> (false, err)
       | Ok (prepared_args, identity_reseed) -> (
           match resolve_keeper_meta ctx prepared_args with
           | Error err -> (false, err)
           | Ok meta ->
               let json =
                 `Assoc
                   [
                     ("keeper", `String meta.name);
                     ("sandbox", render_item meta);
                   ]
                 |> attach_identity_reseed ?identity_reseed
               in
               (true, Yojson.Safe.pretty_to_string json)))

let handle_keeper_sandbox_start ctx args : tool_result =
  match resolve_keeper_meta ctx args with
  | Error err -> (false, err)
  | Ok meta ->
      let timeout_sec = Stdlib.Float.min 30.0 (Stdlib.Float.max 1.0 (get_float args "timeout_sec" 10.0)) in
      let ttl_sec = Stdlib.Float.min 86_400.0 (Stdlib.Float.max 1.0 (get_float args "ttl_sec" 1800.0)) in
      let network_mode_raw =
        String.trim
          (get_string args "network_mode"
             (network_mode_to_string meta.network_mode))
      in
      (match parse_network_mode_or_error network_mode_raw with
       | Error err -> (false, err)
       | Ok network_mode -> (
           match
             Keeper_sandbox_control.start_managed_container
               ~config:ctx.config ~meta ~network_mode ~ttl_sec ~timeout_sec ()
           with
           | Error err -> (false, err)
           | Ok result ->
               invalidate_status_cache meta.name;
               ( true,
                 Yojson.Safe.pretty_to_string
                   (`Assoc
                      [
                        ("keeper", `String meta.name);
                        ("action", `String "start");
                        ("sandbox", result);
                      ]) )))

let handle_keeper_sandbox_stop ctx args : tool_result =
  let timeout_sec = Stdlib.Float.min 30.0 (Stdlib.Float.max 1.0 (get_float args "timeout_sec" 10.0)) in
  let prune_stale = get_bool args "prune_stale" false in
  let container_kind_raw =
    get_string args "container_kind" Keeper_sandbox_control.managed_kind
  in
  let keeper_name =
    match String.trim (get_string args "name" "") with
    | "" -> None
    | name -> Some name
  in
  match Keeper_sandbox_control.parse_stop_scope container_kind_raw with
  | Error err -> error_result_typed ~code:Validation_error err
  | Ok scope ->
      let stop_result =
        Keeper_sandbox_control.stop_containers
          ?keeper_name ~scope ~config:ctx.config ~timeout_sec ()
      in
      let stale_cleanup =
        if prune_stale then
          Some
            (Keeper_sandbox_control.cleanup_stale ~config:ctx.config
               ~timeout_sec:(Stdlib.Float.min timeout_sec 5.0) ())
        else
          None
      in
      (match keeper_name with
       | Some name -> invalidate_status_cache name
       | None -> Keeper_status_detail.invalidate_status_cache_all ());
      let stop_json =
        `Assoc
          [
            ("matched", `Int stop_result.matched);
            ("removed", `Int stop_result.removed);
            ("errors", `List (List.map (fun err -> `String err) stop_result.errors));
          ]
      in
      let stale_json =
        match stale_cleanup with
        | None -> `Null
        | Some cleanup ->
            `Assoc
              [
                ("scanned", `Int cleanup.scanned);
                ("removed", `Int cleanup.removed);
                ("errors",
                 `List (List.map (fun err -> `String err) cleanup.errors));
              ]
      in
      ( true,
        Yojson.Safe.pretty_to_string
          (`Assoc
             [
               ("action", `String "stop");
               ("keeper", Json_util.string_opt_to_json keeper_name);
               ("container_kind", `String (Keeper_sandbox_control.stop_scope_to_string scope));
               ("stop_result", stop_json);
               ("stale_cleanup", stale_json);
             ]) )

(* masc_keeper_reconcile tool removed along with the manual_reconcile
   blocker mechanism. Failed turns record evidence via Keeper_registry;
   recovery is autonomous (next turn's observation) or operator-driven
   (keeper_chat/board), not blocker-driven. *)

(* Recurring loop tools (#3190) removed: zero callers. *)

let should_bootstrap_existing_keepalives name args =
  match name with
  | "masc_keeper_msg" ->
      not (String.equal (String.trim (get_string args "message" "")) "")
  | _ -> false

let maybe_bootstrap_existing_keepalives ctx ~name ~args =
  if should_bootstrap_existing_keepalives name args then
    (try start_existing_keepalives ctx
     with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
       Log.Keeper.error "start_existing_keepalives failed: %s"
         (Stdlib.Printexc.to_string exn))

(** Keeper tools are scoped to the caller's current base_path.
    Do not retarget requests across other base_path registries. *)
let resolve_ctx ctx ~name:_ _args = ctx

let handle_keeper_reset ctx args : tool_result =
  match resolve_keeper_meta ctx args with
  | Error err -> (false, err)
  | Ok meta ->
    let reset_meta = Keeper_types.reset_runtime_state meta in
    (match Keeper_types.write_meta ctx.config reset_meta with
     | Ok () ->
       (true, Printf.sprintf
         "Reset runtime state for %s: usage counters zeroed, last_model_used cleared."
         meta.name)
     | Error err ->
       (false, Printf.sprintf "Failed to write reset meta for %s: %s" meta.name err))

(** Resolve the primary model max context for a keeper.

    Returns the resolved primary provider/cascade budget, separate from any
    requested [max_context_override] turn-budget widening.
    Returns [min_keeper_context_tokens] when meta is unavailable. *)
let resolve_primary_max_context (meta : Keeper_types.keeper_meta option) : int =
  let min_ctx = Keeper_config.min_keeper_context_tokens in
  match meta with
  | None -> min_ctx
  | Some meta ->
    let resolution =
      Keeper_exec_context.resolve_max_context_resolution_of_meta meta
    in
    max min_ctx resolution.effective_budget

(** Operator-initiated context compaction.

    Dispatches [Operator_compact_requested] to the FSM, then compacts the
    keeper's latest checkpoint via OAS checkpoint recovery.  Returns
    before/after token counts on success. *)
let handle_keeper_compact ctx args : tool_result =
  match resolve_keeper_name ctx args with
  | Error err -> (false, err)
  | Ok name ->
    let force = get_bool args "force" false in
    (* Registry race: [resolve_keeper_name] succeeded but the registry entry
       can still disappear if another fiber unregistered the keeper.  Treat
       this as a distinct "not found" error rather than an opaque
       "phase=unknown" precondition failure. *)
    match Keeper_registry.get ~base_path:ctx.config.base_path name with
    | None ->
      Prometheus.inc_counter Prometheus.metric_keeper_operator_compact
        ~labels:[("keeper", name); ("result", "not_found")] ();
      error_result_typed ~code:Validation_error
        (Printf.sprintf "keeper %s is not in the registry" name)
    | Some entry ->
    let phase_before = Keeper_state_machine.phase_to_string entry.phase in
    (* Phase precondition: Overflowed, Paused, or (Running/Failing with force).
       Match on the variant directly so the compiler warns when new phases
       are added — the catch-all wildcard would silently default to [false]. *)
    let allowed =
      match entry.phase with
      | Overflowed | Paused | Compacting -> true
      | Running | Failing -> force
      | Offline | Stopped | Dead | Zombie | Crashed | Restarting | HandingOff | Draining -> false
    in
    if not allowed then begin
      Prometheus.inc_counter Prometheus.metric_keeper_operator_compact
        ~labels:[("keeper", name); ("result", "precondition")] ();
      error_result_typed ~code:Validation_error
        (Printf.sprintf
           "keeper %s is in phase %s; compaction requires Overflowed, Paused, or force=true"
           name phase_before)
    end
    else begin
      (* Dispatch FSM event *)
      Keeper_exec_context.dispatch_keeper_phase_event
        ~config:ctx.config ~keeper_name:name
        Keeper_state_machine.Operator_compact_requested;
      (* Read meta for checkpoint access *)
      match read_meta_resolved ctx.config name with
      | Ok None | Error _ ->
        (false, Printf.sprintf "keeper %s: meta unavailable for compaction" name)
      | Ok (Some (_resolved, meta)) ->
        let base_dir = Keeper_types.session_base_dir ctx.config in
        let model = Keeper_exec_context.checkpoint_model_of_meta meta in
        let max_tokens = resolve_primary_max_context (Some meta) in
        Keeper_exec_context.dispatch_keeper_phase_event
          ~config:ctx.config ~keeper_name:name
          Keeper_state_machine.Compaction_started;
        match
          Keeper_exec_context.recover_latest_checkpoint_for_overflow_retry
            ~base_dir ~meta ~model ~primary_model_max_tokens:max_tokens
        with
        | Some recovery ->
          Keeper_exec_context.dispatch_compaction_completed
            ~config:ctx.config ~keeper_name:name
            ~before_tokens:recovery.compaction.before_tokens
            ~after_tokens:recovery.compaction.after_tokens;
          invalidate_status_cache name;
          Prometheus.inc_counter Prometheus.metric_keeper_operator_compact
            ~labels:[("keeper", name); ("result", "ok")] ();
          (true,
           Yojson.Safe.to_string
             (`Assoc [
               ("name", `String name);
               ("phase_before", `String phase_before);
               ("phase_after", `String
                  (match Keeper_registry.get ~base_path:ctx.config.base_path name with
                   | Some entry -> Keeper_state_machine.phase_to_string entry.phase
                   | None -> "unknown"));
               ("before_tokens", `Int recovery.compaction.before_tokens);
               ("after_tokens", `Int recovery.compaction.after_tokens);
             ]))
        | None ->
          (* Compaction infrastructure unavailable — emit [Compaction_failed]
             so [context_overflow] stays set and [derive_phase] re-projects
             to Overflowed.  A subsequent [Compact_retry_exhausted] dispatch
             (owned by the retry-loop caller) will latch the keeper to Paused.
             Emitting [Compaction_completed] here would be a false success
             signal. *)
          Keeper_exec_context.dispatch_keeper_phase_event
            ~config:ctx.config ~keeper_name:name
            (Keeper_state_machine.Compaction_failed {
               reason = "no_valid_checkpoint";
            });
          Prometheus.inc_counter Prometheus.metric_keeper_operator_compact
            ~labels:[("keeper", name); ("result", "no_checkpoint")] ();
          (false,
           Printf.sprintf
             "keeper %s: checkpoint compaction unavailable (no valid checkpoint found)"
             name)
    end

(** Last-resort context clear.

    Drops all conversation messages from the keeper's checkpoint file,
    optionally preserving the system prompt.  Dispatches
    [Operator_clear_requested] to reset overflow-related FSM conditions. *)
let handle_keeper_clear ctx args : tool_result =
  match resolve_keeper_name ctx args with
  | Error err -> (false, err)
  | Ok name ->
    let reason = String.trim (get_string args "reason" "") in
    if String.equal reason "" then
      error_result_typed ~code:Validation_error
        "reason is required for masc_keeper_clear (audit trail)"
    else
    (* Same registry race guard as [handle_keeper_compact]: if the keeper
       disappeared between [resolve_keeper_name] and [get], abort cleanly
       rather than silently proceed with a half-applied clear. *)
    match Keeper_registry.get ~base_path:ctx.config.base_path name with
    | None ->
      error_result_typed ~code:Validation_error
        (Printf.sprintf "keeper %s is not in the registry" name)
    | Some entry ->
      let preserve_system = get_bool args "preserve_system_prompt" true in
      let phase_before = Keeper_state_machine.phase_to_string entry.phase in
      let base_dir = Keeper_types.session_base_dir ctx.config in
      (* Must use the keeper's OWN trace_id to locate its checkpoint file.
         Using generate_trace_id () would create a fresh session dir and
         always report 0 cleared messages, because the existing checkpoint
         lives under meta.runtime.trace_id. *)
      let meta_for_trace =
        match read_meta_resolved ctx.config name with
        | Ok (Some (_, meta)) -> Some meta
        | _ -> None
      in
      let trace_id =
        match meta_for_trace with
        | Some meta -> Keeper_id.Trace_id.to_string meta.runtime.trace_id
        | None -> Keeper_exec_context.generate_trace_id ()
      in
      let max_tokens = resolve_primary_max_context meta_for_trace in
      let max_checkpoint_messages =
        match meta_for_trace with
        | Some meta -> meta.compaction.max_checkpoint_messages
        | None -> 100
      in
      let session, ctx_opt =
        Keeper_exec_context.load_context_from_checkpoint
          ~max_checkpoint_messages
          ~trace_id
          ~primary_model_max_tokens:max_tokens
          ~base_dir
      in
      let checkpoint_found = Option.is_some ctx_opt in
      let cleared_count =
        match ctx_opt with
        | None -> 0
        | Some wctx ->
          let existing_messages = Keeper_exec_context.messages_of_context wctx in
          let msg_count = List.length existing_messages in
          let cleared_messages =
            if preserve_system then
              (* Keep only system-role messages *)
              List.filter
                (fun (m : Agent_sdk.Types.message) ->
                   (=) m.role Llm_provider.Types.System)
                existing_messages
            else
              []
          in
          let cleared_ctx =
            {
              wctx with
              checkpoint =
                {
                  (Keeper_exec_context.checkpoint_of_context wctx) with
                  messages = cleared_messages;
                };
            }
          in
          (* Increment generation from meta to signal a new context epoch.
             Using a hardcoded value would violate generation monotonicity
             — the keeper_unified_turn retry loop uses meta.runtime.generation
             to detect stale contexts. *)
          let current_gen =
            match meta_for_trace with
            | Some meta -> meta.runtime.generation
            | None -> 0
          in
          (match meta_for_trace with
           | Some meta ->
               let model = Keeper_exec_context.checkpoint_model_of_meta meta in
               (match
                  Keeper_exec_context.save_oas_checkpoint
                    ~max_checkpoint_messages
                    ~session
                    ~agent_name:meta.agent_name
                    ~model
                    ~ctx:cleared_ctx
                    ~generation:(current_gen + 1)
                with
                | Ok _ -> ()
                | Error err ->
                    Log.Keeper.warn
                      "%s: failed to save cleared OAS checkpoint: %s"
                      name err)
           | None -> ());
          msg_count - List.length cleared_messages
      in
      let legacy_shadow_removed_count =
        let files = Keeper_checkpoint_store.list_checkpoints ~session_dir:session.session_dir in
        List.fold_left
          (fun count filename ->
            let path = Filename.concat session.session_dir filename in
            try
              Sys.remove path;
              count + 1
            with
            | Eio.Cancel.Cancelled _ as e -> raise e
            | exn ->
                Log.Keeper.warn
                  "%s: failed to remove legacy checkpoint shadow %s: %s"
                  name path (Stdlib.Printexc.to_string exn);
                count)
          0 files
      in
      let continuity_cleared =
        match meta_for_trace with
        | Some meta ->
            let updated_meta =
              {
                meta with
                continuity_summary = "";
                updated_at = Keeper_types.now_iso ();
                runtime =
                  {
                    meta.runtime with
                    last_continuity_update_ts = 0.0;
                  };
              }
            in
            (match Keeper_types.write_meta ~force:true ctx.config updated_meta with
             | Ok () -> true
             | Error err ->
                 Log.Keeper.warn
                   "%s: failed to clear continuity meta during operator clear: %s"
                   name err;
                 false)
        | None -> false
      in
      (* Dispatch FSM event to clear overflow conditions *)
      Keeper_exec_context.dispatch_keeper_phase_event
        ~config:ctx.config ~keeper_name:name
        (Keeper_state_machine.Operator_clear_requested { preserve_system; reason });
      (* Clear registry failure state *)
      Keeper_registry.set_failure_reason ~base_path:ctx.config.base_path name None;
      Keeper_registry.reset_turn_failures ~base_path:ctx.config.base_path name;
      invalidate_status_cache name;
      Log.Keeper.warn
        "%s: context cleared by operator (reason=%s, preserve_system=%b, cleared=%d msgs)"
        name reason preserve_system cleared_count;
      Prometheus.inc_counter Prometheus.metric_keeper_operator_clear
        ~labels:[("keeper", name);
                 ("preserve_system", Bool.to_string preserve_system)] ();
      (true,
       Yojson.Safe.to_string
         (`Assoc [
           ("name", `String name);
           ("phase_before", `String phase_before);
           ("phase_after", `String
              (match Keeper_registry.get ~base_path:ctx.config.base_path name with
               | Some entry -> Keeper_state_machine.phase_to_string entry.phase
               | None -> "unknown"));
           ("cleared_message_count", `Int cleared_count);
           ("checkpoint_found", `Bool checkpoint_found);
           ("continuity_cleared", `Bool continuity_cleared);
           ("legacy_shadow_removed_count", `Int legacy_shadow_removed_count);
           ("preserve_system_prompt", `Bool preserve_system);
           ("reason", `String reason);
         ]))

let dispatch ctx ~name ~args : tool_result option =
  maybe_bootstrap_existing_keepalives ctx ~name ~args;
  let ctx = resolve_ctx ctx ~name args in
  match name with
  | "masc_persona_list" -> Some (Persona.handle_persona_list ctx args)
  | "masc_persona_schema" -> Some (Persona.handle_persona_schema ctx args)
  | "masc_persona_generate" -> Some (Persona.handle_persona_generate ctx args)
  | "masc_persona_save" -> Some (Persona.handle_persona_save ctx args)
  | "masc_keeper_create_from_persona" -> Some (handle_keeper_create_from_persona ctx args)
  | "masc_keeper_up" -> Some (handle_keeper_up ctx args)
  | "masc_keeper_status" -> Some (handle_keeper_status ctx args)
  | "masc_keeper_msg" -> Some (handle_keeper_msg ctx args)
  | "masc_keeper_msg_result" -> Some (handle_keeper_msg_result ctx args)
  | "masc_keeper_repair" -> Some (handle_keeper_repair ctx args)
  | "masc_keeper_down" -> Some (handle_keeper_down ctx args)
  | "masc_keeper_list" -> Some (handle_keeper_list ctx args)
  | "masc_keeper_persona_audit" -> Some (handle_keeper_persona_audit ctx args)
  | "masc_keeper_sandbox_status" -> Some (handle_keeper_sandbox_status ctx args)
  | "masc_keeper_sandbox_start" -> Some (handle_keeper_sandbox_start ctx args)
  | "masc_keeper_sandbox_stop" -> Some (handle_keeper_sandbox_stop ctx args)
  | "masc_keeper_reset" -> Some (handle_keeper_reset ctx args)
  | "masc_keeper_compact" -> Some (handle_keeper_compact ctx args)
  | "masc_keeper_clear" -> Some (handle_keeper_clear ctx args)
  | _ -> None

(** Streaming dispatch: only handles keeper_msg with text delta forwarding.
    Returns None for all other tool names.
    Called from server_routes_http_keeper_stream. *)
let dispatch_stream ~on_text_delta ctx ~name ~args : tool_result option =
  maybe_bootstrap_existing_keepalives ctx ~name ~args;
  let ctx = resolve_ctx ctx ~name args in
  match name with
  | "masc_keeper_msg" ->
      Some (handle_keeper_msg_stream ~on_text_delta ctx args)
  | _ -> None

(* ================================================================ *)
(* Tool_spec registration                                           *)
(* ================================================================ *)

let _tool_spec_read_only =
  [ "masc_persona_list"; "masc_persona_schema"; "masc_keeper_list";
    "masc_keeper_status"; "masc_keeper_persona_audit";
    "masc_keeper_sandbox_status" ]

let tool_required_permission = function
  | "masc_persona_list" | "masc_persona_schema" | "masc_keeper_list"
  | "masc_keeper_status" | "masc_keeper_persona_audit"
  | "masc_keeper_sandbox_status" ->
      Some Types.CanReadState
  | "masc_persona_generate" | "masc_persona_save"
  | "masc_keeper_create_from_persona" | "masc_keeper_up"
  | "masc_keeper_msg" | "masc_keeper_msg_result"
  | "masc_keeper_repair"
  | "masc_keeper_sandbox_start" | "masc_keeper_sandbox_stop"
  | "masc_keeper_down" | "masc_keeper_reset"
  | "masc_keeper_compact" | "masc_keeper_clear" ->
      Some Types.CanBroadcast
  | _ -> None

let () =
  List.iter
    (fun (s : Types.tool_schema) ->
      Tool_spec.register
        (Tool_spec.create
           ~name:s.name
           ~description:s.description
           ~module_tag:Tool_dispatch.Mod_keeper
           ~input_schema:s.input_schema
           ~handler_binding:Tag_dispatch
           ~is_read_only:(List.mem s.name _tool_spec_read_only)
           ~is_idempotent:(List.mem s.name _tool_spec_read_only)
           ?required_permission:(tool_required_permission s.name)
           ()))
    schemas
