module Option = Stdlib.Option
module Sys = Stdlib.Sys
module List = Stdlib.List
module String = Stdlib.String
module Int = Stdlib.Int
module Float = Stdlib.Float

(** Tool_keeper facade.  MCP entrypoints stay stable while keeper internals live in dedicated keeper modules. Tool_keeper owns only runtime wrappers and dispatch. *)
open Tool_args
open Keeper_types
open Keeper_runtime
module Turn = Keeper_turn
module Status = Keeper_status
module Persona = Keeper_persona
module Persona_audit = Tool_keeper_persona_audit
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
  key : string option;
  value : string option;
  expires_at : float;
  generation : int;
}
let empty_text_cache ~generation = { key = None; value = None; expires_at = 0.0; generation }
let keeper_list_cache = Atomic.make (empty_text_cache ~generation:0)
let cache_ttl_seconds env_var ~default =
  match Sys.getenv_opt env_var with
  | None -> default
  | Some raw ->
      let trimmed = String.trim raw in
      let emit_failure reason =
        Prometheus.inc_counter
          Prometheus.metric_tool_keeper_cache_ttl_parse_failures
          ~labels:[ ("env_var", env_var); ("reason", reason) ]
          ();
        Log.Keeper.warn
          "cache_ttl_seconds: %s=%S parse failure (%s); using default %.3fs"
          env_var trimmed reason default
      in
      (match Parse_outcome.parse_safe Float.of_string trimmed with
       | Ok value when Stdlib.Float.compare value 0.0 >= 0 -> value
       | Ok _ ->
           emit_failure "negative_or_nan";
           default
       | Error (`Json_parse_error _) ->
           (* Float.of_string never raises Yojson errors; defensive arm. *)
           emit_failure "invalid_float";
           default
       | Error (`Other _) ->
           emit_failure "invalid_float";
           default)
let keeper_list_cache_ttl_s () =
  cache_ttl_seconds "MASC_KEEPER_LIST_CACHE_TTL_S" ~default:2.0
let invalidate_text_cache cache_ref =
  Lockfree_atomic.update cache_ref (fun current ->
    empty_text_cache ~generation:(current.generation + 1))
let invalidate_keeper_list_cache () = invalidate_text_cache keeper_list_cache
let rec cached_text_by_key cache_ref ~key ~ttl_s compute =
  let now = Time_compat.now () in
  let cache = Atomic.get cache_ref in
  match cache.key, cache.value with
  | Some cached_key, Some value
    when String.equal cached_key key && Stdlib.Float.compare now cache.expires_at < 0 ->
      value
  | _ ->
      let value = compute () in
      let next =
        {
          key = Some key;
          value = Some value;
          expires_at = Time_compat.now () +. ttl_s;
          generation = cache.generation;
        }
      in
      if Atomic.compare_and_set cache_ref cache next then value
      else begin
        Prometheus.inc_counter
          Prometheus.metric_tool_keeper_cache_cas_conflicts ();
        cached_text_by_key cache_ref ~key ~ttl_s compute
      end
module For_testing = struct
  let reset_keeper_list_cache () =
    Atomic.set keeper_list_cache (empty_text_cache ~generation:0)
  let invalidate_keeper_list_cache = invalidate_keeper_list_cache
  let cached_keeper_list_text ~key ~ttl_s compute =
    cached_text_by_key keeper_list_cache ~key ~ttl_s compute
end
let annotate_keeper_json ~runtime_class json =
  match json with
  | `Assoc fields ->
      `Assoc (("runtime_class", `String runtime_class) :: fields)
  | other -> other
let attach_assoc_field key value = function
  | `Assoc fields -> `Assoc ((key, value) :: fields)
  | other -> other
(* RFC-0182 §3.1 — ctx-free body for keeper_dispatch_ref path. *)
let maybe_reseed_keeper_identity_config ~(config : Coord.config) (meta : keeper_meta) =
  let expected_agent_name = Keeper_identity.keeper_agent_name meta.name in
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
        let base_dir = Keeper_types.session_base_dir config in
        let _session =
          Keeper_context_runtime.create_session ~session_id:new_trace_id_raw
            ~base_dir
        in
        let updated_meta =
          { meta with
            agent_name = expected_agent_name;
            updated_at = Keeper_types.now_iso ();
            runtime = { meta.runtime with
              trace_id = new_trace_id;
              trace_history = Json_util.dedupe_keep_order (previous_trace_id :: meta.runtime.trace_history);
              generation = meta.runtime.generation + 1 } }
        in
        (match Keeper_types.write_meta ~force:true config updated_meta with
         | Ok () ->
             Keeper_status_detail.invalidate_status_cache_for updated_meta.name;
             Ok
               ( updated_meta,
                 Some
                   (`Assoc
                      [
                        ("reason", `String "agent_name_mismatch"); ("keeper_name", `String updated_meta.name);
                        ("previous_agent_name", `String meta.agent_name);
                        ("expected_agent_name", `String expected_agent_name);
                        ("previous_trace_id", `String previous_trace_id); ("new_trace_id", `String new_trace_id_raw);
                      ]) )
         | Error err ->
             Error
               (Printf.sprintf
                  "failed to persist reseeded keeper identity for %s: %s"
                  meta.name err))

let maybe_reseed_keeper_identity ctx (meta : keeper_meta) =
  maybe_reseed_keeper_identity_config ~config:ctx.config meta

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
  `Assoc [ ("error", `String "server_initializing"); ("message", `String (Printf.sprintf "MASC server is still starting (%.0fs elapsed). Retry in a few seconds." elapsed)); ("retry_after_ms", `Int 3000) ]
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
      ("name", `String meta.name); ("goal", `String meta.goal);
      ("trace_id", `String (Keeper_id.Trace_id.to_string meta.runtime.trace_id));
      ("created_at", `String meta.created_at); ("updated_at", `String meta.updated_at);
    ]
let keeper_list_skill_route_json config (meta : keeper_meta) =
  let metrics_store = Keeper_types_support.keeper_metrics_store config meta.name in
  let metrics_path = Keeper_types_support.keeper_metrics_path config meta.name in
  let lines =
    let dated = Dated_jsonl.read_recent_lines metrics_store 50 in
    if Stdlib.List.length dated > 0 then dated
    else
      match
        Keeper_memory.read_file_tail_lines_result metrics_path
          ~max_bytes:16_000 ~max_lines:50
      with
      | Ok lines -> lines
      | Error exn_class ->
          Keeper_memory.record_memory_recall_read_error
            ~site:"tool_keeper_ops_skill_route_metrics" metrics_path exn_class;
          []
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
        Keeper_status_runtime.parse_agent_status config ~agent_name:meta.agent_name
      in
      let diagnostic =
        Keeper_status_runtime.keeper_diagnostic_json
          ~meta
          ~agent_status
          ~keepalive_running ~history_items:[] ~now_ts
        |> Keeper_status_runtime.augment_keeper_diagnostic_json
             ~meta ~keepalive_running
             ~keepalive_started_at:
               (Keeper_status_bridge.runtime_keepalive_started_at config meta)
             ~now_ts
      in
      let status =
        Keeper_status_runtime.keeper_surface_status ~agent_status ~diagnostic
      in
      Some
        (`Assoc (
          [
            ("runtime_class", `String runtime_class); ("name", `String meta.name);
            ("meta", keeper_brief_meta_json meta); ("agent_name", `String meta.agent_name);
            ("status", `String status); ("keepalive_running", `Bool keepalive_running);
            ("autoboot_enabled", `Bool meta.autoboot_enabled); ("proactive_enabled", `Bool meta.proactive.enabled);
            ("proactive_idle_sec", `Int meta.proactive.idle_sec);
            ("proactive_cooldown_sec", `Int meta.proactive.cooldown_sec);
            ("skill_route", keeper_list_skill_route_json config meta);
            ("cascade_name", `String (Keeper_types.cascade_name_of_meta meta));
            ("created_at", `String meta.created_at); ("updated_at", `String meta.updated_at);
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
(* RFC-0182 §3.1 — ctx-free body for keeper_dispatch_ref path. *)
let prepare_passive_keeper_identity_config ~(config : Coord.config) ~(agent_name : string) args =
  let requested_name =
    match String.trim (get_string args "name" "") with
    | "" -> String.trim agent_name
    | name -> name
  in
  if String.equal requested_name "" then
    Ok (args, None)
  else
    match read_meta_resolved config requested_name with
    | Ok (Some (_resolved_name, meta)) -> (
        match maybe_reseed_keeper_identity_config ~config meta with
        | Ok (updated_meta, identity_reseed) ->
            Ok (with_keeper_name args updated_meta.name, identity_reseed)
        | Error _ as err -> err)
    | Ok None -> Ok (args, None)
    | Error err -> Error (Printf.sprintf "%s" err)

let prepare_passive_keeper_identity ctx args =
  prepare_passive_keeper_identity_config
    ~config:ctx.config
    ~agent_name:ctx.agent_name
    args
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
  match Agent_tool_persona_runtime.resolved_keeper_args_from_persona args with
  | Error e -> (false, "" ^ e)
  | Ok (persona, resolved_args) ->
      let dry_run = get_bool args "dry_run" false in
      if dry_run then
        let json =
          `Assoc
            [
              ("persona", Agent_tool_persona_runtime.persona_summary_to_json persona); ("created", `Bool false);
              ("resolved_args", resolved_args);
            ]
        in
        (true, Yojson.Safe.to_string json)
      else
        match Agent_tool_persona_runtime.render_keeper_toml_from_resolved_args resolved_args with
        | Error e -> (false, "" ^ e)
        | Ok _ ->
        let (ok, body) = with_keeper_startup_gate (fun () -> execute_keeper_up ctx resolved_args) in
        if not ok then
          (false, body)
        else
          match Agent_tool_persona_runtime.persist_keeper_toml_from_resolved_args resolved_args with
          | Error e ->
              (false, "keeper created but durable config write failed: " ^ e)
          | Ok durable_config ->
          let created_json =
            try Yojson.Safe.from_string body with Yojson.Json_error _ -> `String body
          in
          let json =
            `Assoc
              [
                ("persona", Agent_tool_persona_runtime.persona_summary_to_json persona); ("created", `Bool true);
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

(* RFC-0182 Phase 5 PR-B.2: ctx-free body for [masc_keeper_up].  Same
   pattern as [keeper_msg_body] — construct a fresh keeper context
   from threaded Eio resources and delegate to the existing
   [Turn.handle_keeper_up] (via execute_keeper_up). *)
let keeper_up_body
      ~(config : Coord.config)
      ~(agent_name : string)
      ~(sw : Eio.Switch.t)
      ~(clock : float Eio.Time.clock_ty Eio.Resource.t)
      ?proc_mgr
      ?net
      args : tool_result =
  let keeper_ctx : _ Keeper_types.context =
    { config; agent_name; sw; clock; proc_mgr; net }
  in
  with_keeper_startup_gate (fun () -> execute_keeper_up keeper_ctx args)
;;
(* RFC-0182 §3.1 — ctx-free body for keeper_dispatch_ref path. *)
let keeper_status_body ~(config : Coord.config) ~(agent_name : string) args : tool_result =
  match prepare_passive_keeper_identity_config ~config ~agent_name args with
  | Error err -> (false, err)
  | Ok (prepared_args, identity_reseed) ->
      let ok, body =
        Keeper_status_detail.handle_keeper_status_config
          ~config
          ~agent_name
          prepared_args
      in
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

let handle_keeper_status ctx args : tool_result =
  keeper_status_body ~config:ctx.config ~agent_name:ctx.agent_name args
(* RFC-0182 §3.1 — ctx-free body for keeper_dispatch_ref path. *)
let resolve_keeper_name_config ~(config : Coord.config) args =
  let name = String.trim (get_string args "name" "") in
  match read_meta_resolved config name with
  | Ok (Some (resolved_name, _meta)) -> Ok resolved_name
  | Ok None -> Error (Printf.sprintf "keeper not found: %s" name)
  | Error err -> Error (Printf.sprintf "%s" err)

let resolve_keeper_name ctx args =
  resolve_keeper_name_config ~config:ctx.config args

(* RFC-0182 Phase 5 PR-B: ctx-free body for [masc_keeper_msg] descriptor
   projection.  Constructs a fresh [Keeper_types.context] from the
   threaded Eio resources and delegates to the existing [Turn.preflight_*]
   / [Turn.handle_keeper_msg] handlers. *)
let keeper_msg_body
      ~(config : Coord.config)
      ~(agent_name : string)
      ~(sw : Eio.Switch.t)
      ~(clock : float Eio.Time.clock_ty Eio.Resource.t)
      ?proc_mgr
      ?net
      args : tool_result =
  let keeper_ctx : _ Keeper_types.context =
    { config; agent_name; sw; clock; proc_mgr; net }
  in
  match resolve_keeper_name_config ~config args with
  | Error err -> (false, err)
  | Ok name ->
      let resolved_args = with_keeper_name args name in
      (match Turn.preflight_keeper_msg keeper_ctx resolved_args with
       | Error err -> (false, err)
       | Ok () ->
         let timeout_sec =
           match Turn.keeper_msg_timeout_override resolved_args with
           | Ok value -> value
           | Error _ -> None
         in
         let request_id =
           Keeper_msg_async.submit
             ?timeout_sec
             ~clock
             ~sw
             ~base_path:config.base_path
             ~keeper_name:name
             ~f:(fun () ->
               let ok, body = Turn.handle_keeper_msg keeper_ctx resolved_args in
               if ok
               then begin
                 invalidate_keeper_list_cache ();
                 invalidate_status_cache name
               end;
               (ok, body))
             ()
         in
         let json =
           `Assoc
             [ "request_id", `String request_id
             ; "keeper_name", `String name
             ; "status", `String "queued"
             ; ( "message"
               , `String
                   "Keeper turn submitted. Poll with keeper_msg_result." )
             ]
         in
         (true, Yojson.Safe.to_string json))
;;

let handle_keeper_msg ctx args : tool_result =
  match resolve_keeper_name ctx args with
  | Error err -> (false, err)
  | Ok name ->
      let resolved_args = with_keeper_name args name in
      (match Turn.preflight_keeper_msg ctx resolved_args with
       | Error err -> (false, err)
       | Ok () ->
         let timeout_sec =
           match Turn.keeper_msg_timeout_override resolved_args with
           | Ok value -> value
           | Error _ -> None
         in
         let request_id =
           Keeper_msg_async.submit
             ?timeout_sec
             ~clock:ctx.clock
             ~sw:ctx.sw
             ~base_path:ctx.config.base_path
             ~keeper_name:name
             ~f:(fun () ->
               let ok, body = Turn.handle_keeper_msg ctx resolved_args in
               if ok
               then begin
                 invalidate_keeper_list_cache ();
                 invalidate_status_cache name
               end;
               (ok, body))
             ()
         in
         let json =
           `Assoc
             [ "request_id", `String request_id
             ; "keeper_name", `String name
             ; "status", `String "queued"
             ; ( "message"
               , `String
                   "Keeper turn submitted. Poll with keeper_msg_result." )
             ]
         in
         (true, Yojson.Safe.to_string json))
;;
(* RFC-0182 §3.1 — ctx-free body for keeper_dispatch_ref path. *)
let keeper_msg_result_body ~(config : Coord.config) args : tool_result =
  let request_id = get_string args "request_id" "" in
  if String.equal request_id "" then
    (false, {|{"error":"request_id is required"}|})
  else
    match Keeper_msg_async.poll ~base_path:config.base_path request_id with
    | None ->
      (false, Printf.sprintf {|{"error":"request_id not found","request_id":"%s"}|} request_id)
    | Some entry ->
      (true, Yojson.Safe.to_string (Keeper_msg_async.entry_to_json entry))

let handle_keeper_msg_result ctx args : tool_result =
  keeper_msg_result_body ~config:ctx.config args
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
(* RFC-0182 §3.1 — ctx-free body for keeper_dispatch_ref path. *)
let resolve_keeper_meta_config ~(config : Coord.config) args =
  let name = String.trim (get_string args "name" "") in
  match read_meta_resolved config name with
  | Ok (Some (_resolved_name, meta)) -> Ok meta
  | Ok None -> Error (Printf.sprintf "keeper not found: %s" name)
  | Error err -> Error (Printf.sprintf "%s" err)

let resolve_keeper_meta ctx args =
  resolve_keeper_meta_config ~config:ctx.config args
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
              ("runtime_class", `String "keeper"); ("keeper_name", `String keeper_name);
              ("delegated_tool", `String "masc_keeper_repair");
            ]
          @ fields))
  | _ -> body
let is_safe_subpath = Tool_keeper_path_validation.is_safe_subpath
let validate_target_file = Tool_keeper_path_validation.validate_target_file
let resolve_playground_working_dir =
  Tool_keeper_path_validation.resolve_playground_working_dir
(* RFC-0182 §3.1 — ctx-free body for keeper_dispatch_ref path.
   masc_keeper_repair is currently a stub (returns a typed
   "unsupported" response after validating inputs) so no Eio fields are
   actually consumed.  The previous [ignore (ctx.sw, ctx.clock,
   ctx.config)] line was warning-suppression scaffolding for a future
   real implementation. *)
let keeper_repair_body ~(config : Coord.config) ~(agent_name : string) args : tool_result =
  match resolve_keeper_meta_config ~config args with
  | Error err -> (false, err)
  | Ok meta -> (
      match maybe_reseed_keeper_identity_config ~config meta with
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
            match
              resolve_playground_working_dir
                ~agent_name
                ~base_path:config.base_path
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
                        ("plugin_id", `String plugin_id); ("task_spec", `String task_spec);
                        ("target_mode", `String target_mode); ("working_dir", `String working_dir);
                        ("validator_profile", `String validator_profile);
                        ( "model_label",
                          `String (get_string args "model_label" "runtime") );
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
                      let body_json =
                        `Assoc
                          [ ( "error"
                            , `String
                                "masc_keeper_repair execution path is \
                                 not yet implemented; the tool \
                                 advertises its schema for future \
                                 migration but currently returns this \
                                 typed unsupported response." )
                          ; ("unsupported", `Bool true)
                          ; ("tool", `String "masc_keeper_repair")
                          ; ("validated_fields", `Assoc fields)
                          ; ( "operator_guidance"
                            , `String
                                "All input arguments were validated \
                                 successfully (keeper identity, \
                                 playground working_dir, validator \
                                 profile, max_attempts, optional \
                                 target_file / source_text). If this \
                                 tool is critical for your workflow, \
                                 please file a tracking issue \
                                 requesting implementation rather than \
                                 retrying." )
                          ]
                      in
                      (false, Yojson.Safe.to_string body_json)
                    in
                    invalidate_status_cache meta.name;
                    ( ok,
                      annotate_keeper_repair_json ?identity_reseed
                        ~keeper_name:meta.name body )
)

let handle_keeper_repair ctx args : tool_result =
  keeper_repair_body ~config:ctx.config ~agent_name:ctx.agent_name args

let handle_keeper_down ctx args : tool_result =
  invalidate_keeper_list_cache ();
  invalidate_status_cache (get_string args "name" "");
  Turn.handle_keeper_down ctx args
