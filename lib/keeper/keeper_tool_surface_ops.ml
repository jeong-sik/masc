module Option = Stdlib.Option
module Sys = Stdlib.Sys
module List = Stdlib.List
module String = Stdlib.String
module Int = Stdlib.Int
module Float = Stdlib.Float

(** Keeper_tool_surface facade.  MCP entrypoints stay stable while keeper internals live in dedicated keeper modules. Keeper_tool_surface owns only runtime wrappers and dispatch. *)
open Tool_args
open Keeper_types
open Keeper_meta_contract
open Keeper_meta_store
open Keeper_types_profile
open Keeper_runtime
open Result.Syntax
module Turn = Keeper_turn
module Status = Keeper_status
module Persona = Keeper_persona
module Persona_audit = Keeper_tool_persona_audit
type 'a context = 'a Keeper_types_profile.context = {
  config : Workspace.config;
  agent_name : string;
  sw : Eio.Switch.t;
  clock : 'a Eio.Time.clock;
  proc_mgr : Eio_unix.Process.mgr_ty Eio.Resource.t option;
  net : [ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t option;
}
type tool_result = Keeper_types_profile.tool_result
let schemas = Keeper_types_profile.schemas
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
        Otel_metric_store.inc_counter
          Otel_metric_store.metric_tool_keeper_cache_ttl_parse_failures
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
        Otel_metric_store.inc_counter
          Otel_metric_store.metric_tool_keeper_cache_cas_conflicts ();
        cached_text_by_key cache_ref ~key ~ttl_s compute
      end

let submit_keeper_msg_with_captured_event_bus
      ~background_sw
      ~base_path
      ~caller
      ~keeper_name
      ~(f : ?event_bus:Agent_sdk.Event_bus.t -> Eio.Switch.t -> tool_result)
      () =
  let event_bus = Keeper_event_bus.get () in
  Keeper_msg_async.submit
    ~background_sw
    ~base_path
    ~caller
    ~keeper_name
    ~f:(fun request_sw -> f ?event_bus request_sw)
    ()

module For_testing = struct
  let reset_keeper_list_cache () =
    Atomic.set keeper_list_cache (empty_text_cache ~generation:0)
  let invalidate_keeper_list_cache = invalidate_keeper_list_cache
  let cached_keeper_list_text ~key ~ttl_s compute =
    cached_text_by_key keeper_list_cache ~key ~ttl_s compute
  let submit_keeper_msg_with_captured_event_bus =
    submit_keeper_msg_with_captured_event_bus
end
let annotate_keeper_json ~runtime_class json =
  match json with
  | `Assoc fields ->
      `Assoc (("runtime_class", `String runtime_class) :: fields)
  | other -> other
let attach_assoc_field key value = function
  | `Assoc fields -> `Assoc ((key, value) :: fields)
  | other -> other

let json_of_body body =
  try Yojson.Safe.from_string body with Yojson.Json_error _ -> `String body
(* RFC-0182 §3.1 — ctx-free body for keeper_dispatch_ref path. *)
let maybe_reseed_keeper_identity_config ~(config : Workspace.config) (meta : keeper_meta) =
  let expected_agent_name = Keeper_identity.keeper_agent_name meta.name in
  if String.equal expected_agent_name meta.agent_name then
    Ok (meta, None)
  else
    let previous_trace_id = Keeper_id.Trace_id.to_string meta.runtime.trace_id in
    let new_trace_id_raw = Keeper_identity.generate_trace_id () in
    let* new_trace_id =
      Keeper_id.Trace_id.of_string new_trace_id_raw
      |> Result.map_error (fun err ->
          Printf.sprintf
            "failed to reseed keeper identity for %s: invalid trace_id %s (%s)"
            meta.name new_trace_id_raw err)
    in
    let base_dir = Keeper_types_profile.session_base_dir config in
    let _session =
      Keeper_context_runtime.create_session ~session_id:new_trace_id_raw ~base_dir
    in
    let updated_meta =
      { meta with
        agent_name = expected_agent_name;
        updated_at = Keeper_meta_contract.now_iso ();
        runtime =
          { meta.runtime with
            trace_id = new_trace_id;
            trace_history =
              Json_util.dedupe_keep_order (previous_trace_id :: meta.runtime.trace_history);
            generation = meta.runtime.generation + 1;
          };
      }
    in
    let* () =
      Keeper_meta_store.write_meta_with_merge
        ~merge:Keeper_meta_merge.monotonic_usage_counters config updated_meta
      |> Result.map_error (fun err ->
          Printf.sprintf
            "failed to persist reseeded keeper identity for %s: %s"
            meta.name err)
    in
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

let maybe_reseed_keeper_identity ctx (meta : keeper_meta) =
  maybe_reseed_keeper_identity_config ~config:ctx.config meta

let prepare_keeper_up_identity ctx args =
  let name = String.trim (get_string args "name" "") in
  let* resolved =
    read_meta_resolved ctx.config name
    |> Result.map_error (fun err -> Printf.sprintf "%s" err)
  in
  match resolved with
  | None -> Ok (args, None)
  | Some (_resolved_name, meta) ->
      let* updated_meta, identity_reseed = maybe_reseed_keeper_identity ctx meta in
      let prepared_args =
        match args with
        | `Assoc fields ->
            `Assoc
              (("name", `String updated_meta.name)
              :: List.remove_assoc "name" fields)
        | other -> other
      in
      Ok (prepared_args, identity_reseed)
let startup_not_ready_error_json elapsed =
  `Assoc [ ("error", `String "server_initializing"); ("message", `String (Printf.sprintf "MASC server is still starting (%.0fs elapsed). Retry in a few seconds." elapsed)); ("retry_after_ms", `Int 3000) ]
  |> Yojson.Safe.pretty_to_string
let with_keeper_startup_gate f =
  if not Server_startup_state.((!state).state_ready) then begin
    let elapsed = Server_startup_state.elapsed_since_start () in
    Log.Keeper.warn "keeper_up rejected: server not ready (%.1fs since start)" elapsed;
    tool_result_error (startup_not_ready_error_json elapsed)
  end else
    f ()
let execute_keeper_up ctx args : tool_result =
  match
    let* prepared_args, identity_reseed = prepare_keeper_up_identity ctx args in
    let result = Turn.handle_keeper_up ctx prepared_args in
    if not (tool_result_success result) then
      Ok result
    else
      let body = tool_result_body result in
      let json = json_of_body body in
      let json =
        match identity_reseed with
        | Some note -> attach_assoc_field "identity_reseed" note json
        | None -> json
      in
      invalidate_keeper_list_cache ();
      Keeper_status_detail.invalidate_status_cache_for
        (get_string prepared_args "name" "");
      Ok
        (tool_result_ok
           (Yojson.Safe.pretty_to_string
              (annotate_keeper_json ~runtime_class:"keeper" json)))
  with
  | Ok result -> result
  | Error err -> tool_result_error err
let keeper_brief_meta_json (meta : keeper_meta) =
  `Assoc
    [
      ("name", `String meta.name); ("goal", `String meta.goal);
      ("trace_id", `String (Keeper_id.Trace_id.to_string meta.runtime.trace_id));
      ("created_at", `String meta.created_at); ("updated_at", `String meta.updated_at);
    ]

let keeper_list_effective_meta_error_json name err =
  `Assoc
    [
      ("keeper", `String name);
      ("message", `String err);
      ("terminal_reason", `String "effective_meta_read_failed");
      ("severity", `String "error");
      ("operator_action_required", `Bool true);
      ("next_action", `String "fix_keeper_toml_or_persona_profile");
    ]

let keeper_list_error_row_json ~runtime_class config name err =
  let persisted_meta =
    match read_meta config name with
    | Ok (Some meta) -> Some meta
    | Ok None | Error _ -> None
  in
  let keepalive_running =
    match persisted_meta with
    | Some meta -> Keeper_status_bridge.runtime_keepalive_running config meta
    | None -> false
  in
  let persisted_fields =
    match persisted_meta with
    | Some meta ->
        [
          ("meta", keeper_brief_meta_json meta);
          ("agent_name", `String meta.agent_name);
          ("created_at", `String meta.created_at);
          ("updated_at", `String meta.updated_at);
          ("autoboot_enabled", `Bool meta.autoboot_enabled);
          ("proactive_enabled", `Bool meta.proactive.enabled);
          ("proactive_idle_sec", `Int meta.proactive.idle_sec);
          ("proactive_cooldown_sec", `Int meta.proactive.cooldown_sec);
        ]
    | None ->
        [
          ("meta", `Null);
          ("agent_name", `Null);
          ("created_at", `Null);
          ("updated_at", `Null);
        ]
  in
  error_assoc
    ([
       ("runtime_class", `String runtime_class);
       ("name", `String name);
       ("keepalive_running", `Bool keepalive_running);
       ("effective_meta_error", keeper_list_effective_meta_error_json name err);
     ]
     @ persisted_fields)

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
            ~site:"keeper_tool_surface_ops_skill_route_metrics" metrics_path exn_class;
          []
  in
  let rec find_latest = function
    | [] -> `Null
    | line :: tl -> (
        try
          let json = Yojson.Safe.from_string line in
          match Safe_ops.json_string_opt "skill_primary" json with
          | Some primary when not (String.equal (String.trim primary) "") ->
              let secondary =
                match Json_util.get_array json "skill_secondary" with
                | Some (`List xs) ->
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
                    Json_util.string_opt_to_json (Safe_ops.json_string_opt "skill_reason" json) );
                ]
          | _ -> find_latest tl
        with Yojson.Json_error _ | Yojson.Safe.Util.Type_error _ -> find_latest tl)
  in
  find_latest (List.rev lines)
let keeper_list_row_json ~runtime_class config name =
  match read_effective_meta config name with
  | Error err -> Some (keeper_list_error_row_json ~runtime_class config name err)
  | Ok None -> None
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
            ("runtime_id", `String (Keeper_meta_contract.runtime_id_of_meta meta));
            ("runtime_id", `String (Keeper_meta_contract.runtime_id_of_meta meta));
            ("created_at", `String meta.created_at); ("updated_at", `String meta.updated_at);
          ]))
let invalidate_status_cache name =
  Keeper_status_detail.invalidate_status_cache_for name
let with_keeper_name args name =
  match args with
  | `Assoc fields ->
      `Assoc (("name", `String name) :: List.remove_assoc "name" fields)
  | other -> other
(* RFC-0182 §3.1 — ctx-free body for keeper_dispatch_ref path. *)
let prepare_passive_keeper_identity_config ~(config : Workspace.config) ~(agent_name : string) args =
  let requested_name =
    match String.trim (get_string args "name" "") with
    | "" -> String.trim agent_name
    | name -> name
  in
  if String.equal requested_name "" then
    Ok (args, None)
  else
    let* resolved =
      read_meta_resolved config requested_name
      |> Result.map_error (fun err -> Printf.sprintf "%s" err)
    in
    match resolved with
    | None -> Ok (args, None)
    | Some (_resolved_name, meta) ->
        let* updated_meta, identity_reseed =
          maybe_reseed_keeper_identity_config ~config meta
        in
        Ok (with_keeper_name args updated_meta.name, identity_reseed)

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
    tool_result_error (startup_not_ready_error_json elapsed)
  end else
    match
      let* persona, resolved_args =
        Keeper_tool_persona_runtime.resolved_keeper_args_from_persona args
        |> Result.map_error (fun e -> "" ^ e)
      in
      let dry_run = get_bool args "dry_run" false in
      if dry_run then
        Ok
          (tool_result_ok
             (Yojson.Safe.to_string
                (`Assoc
                   [
                     ( "persona",
                       Keeper_tool_persona_runtime.persona_summary_to_json persona );
                     ("created", `Bool false);
                     ("resolved_args", resolved_args);
                   ])))
      else
        let* _rendered_toml =
          Keeper_tool_persona_runtime.render_keeper_toml_from_resolved_args
            resolved_args
          |> Result.map_error (fun e -> "" ^ e)
        in
        let result =
          with_keeper_startup_gate (fun () -> execute_keeper_up ctx resolved_args)
        in
        if not (tool_result_success result) then
          Ok result
        else
          let body = tool_result_body result in
          let* durable_config =
            Keeper_tool_persona_runtime.persist_keeper_toml_from_resolved_args
              resolved_args
            |> Result.map_error (fun e ->
                "keeper created but durable config write failed: " ^ e)
          in
          let created_json = json_of_body body in
          let json =
            `Assoc
              [
                ( "persona",
                  Keeper_tool_persona_runtime.persona_summary_to_json persona );
                ("created", `Bool true);
                ("durable_config", durable_config);
                ( "result",
                  annotate_keeper_json ~runtime_class:"keeper" created_json );
                ("resolved_args", resolved_args);
              ]
          in
          invalidate_keeper_list_cache ();
          invalidate_status_cache (get_string resolved_args "name" "");
          Ok (tool_result_ok (Yojson.Safe.to_string json))
    with
    | Ok result -> result
    | Error err -> tool_result_error err
let handle_keeper_up ctx args : tool_result =
  with_keeper_startup_gate (fun () -> execute_keeper_up ctx args)

(* RFC-0182 Phase 5 PR-B.2: ctx-free body for [masc_keeper_up].  Same
   pattern as [keeper_msg_body] — construct a fresh keeper context
   from threaded Eio resources and delegate to the existing
   [Turn.handle_keeper_up] (via execute_keeper_up). *)
let keeper_up_body
      ~(config : Workspace.config)
      ~(agent_name : string)
      ~(sw : Eio.Switch.t)
      ~(clock : float Eio.Time.clock_ty Eio.Resource.t)
      ?proc_mgr
      ?net
      args : tool_result =
  let keeper_ctx : _ Keeper_types_profile.context =
    { config; agent_name; sw; clock; proc_mgr; net }
  in
  with_keeper_startup_gate (fun () -> execute_keeper_up keeper_ctx args)
;;
(* RFC-0182 §3.1 — ctx-free body for keeper_dispatch_ref path. *)
let keeper_status_body ~(config : Workspace.config) ~(agent_name : string) args : tool_result =
  match
    let* prepared_args, identity_reseed =
      prepare_passive_keeper_identity_config ~config ~agent_name args
    in
    let result =
      Keeper_status_detail.handle_keeper_status_config
        ~config
        ~agent_name
        prepared_args
    in
    if not (tool_result_success result) then
      Ok result
    else
      let body = tool_result_body result in
      let json = json_of_body body in
      let json =
        json
        |> annotate_keeper_json ~runtime_class:"keeper"
        |> attach_identity_reseed ?identity_reseed
      in
      Ok (tool_result_ok (Yojson.Safe.pretty_to_string json))
  with
  | Ok result -> result
  | Error err -> tool_result_error err

let handle_keeper_status ctx args : tool_result =
  keeper_status_body ~config:ctx.config ~agent_name:ctx.agent_name args
(* RFC-0182 §3.1 — ctx-free body for keeper_dispatch_ref path. *)
let keeper_name_lookup_candidates raw_name =
  let trimmed = String.trim raw_name in
  if String.equal trimmed "" then
    []
  else
    let aliases =
      match Keeper_identity.canonical_keeper_name trimmed with
      | Some candidate when not (String.equal candidate trimmed) -> [ candidate ]
      | Some _ | None -> []
    in
    trimmed :: aliases

let resolve_keeper_name_config ~(config : Workspace.config) args =
  let name = String.trim (get_string args "name" "") in
  let rec loop = function
    | [] -> Error (Printf.sprintf "keeper not found: %s" name)
    | candidate :: rest ->
        let* resolved = read_meta_resolved config candidate in
        (match resolved with
         | Some (resolved_name, _meta) -> Ok resolved_name
         | None -> loop rest)
  in
  loop (keeper_name_lookup_candidates name)


let resolve_keeper_name ctx args =
  resolve_keeper_name_config ~config:ctx.config args

let direct_reply_visible_text body =
  try
    let json = Yojson.Safe.from_string body in
    match Keeper_turn_outcome.of_reply_payload (Some json) with
    | Keeper_turn_outcome.Continuation_checkpoint -> None
    | Keeper_turn_outcome.No_visible_reply -> None
    | Keeper_turn_outcome.Visible_reply -> (
        match Json_util.get_string json "reply" with
        | None -> None
        | Some reply ->
            let visible =
              reply
              |> Keeper_skill_routing.strip_skill_route_lines
              |> String.trim
            in
            if visible = "" then None else Some visible)
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | Yojson.Json_error _ -> None
;;

let append_direct_chat_pair_if_reply ~(config : Workspace.config) ~name ~args result =
  if get_bool args "direct_reply" false && tool_result_success result then (
    let user_content = get_string args "message" "" |> String.trim in
    (* RFC-0233 §7: the join key the keeper minted into the reply payload,
       threaded onto the persisted row of this agent-initiated / connector
       turn (parse, don't repair — absent/malformed reads as None). *)
    let turn_ref =
      Keeper_turn_outcome.turn_ref_of_reply_payload
        (try Some (Yojson.Safe.from_string (tool_result_body result))
         with Yojson.Json_error _ -> None)
    in
    match user_content, direct_reply_visible_text (tool_result_body result) with
    | "", _ | _, None -> ()
    | _, Some assistant_content ->
        (* Agent-initiated [masc_keeper_msg] path: only the final tool
           result is visible here (no stream events), so no tool lines
           are persisted for this surface. *)
        (* RFC-0226 ownership split: connector traffic (a non-empty
           [channel], set by [Gate_keeper_backend.dispatch]) had its
           user line recorded at the gate inbound boundary, at delivery
           time — appending it again here would double-record. This
           site owns the assistant reply only. Without [channel] this
           is a genuine agent-initiated message with no upstream
           recorder, so it still owns the full pair. *)
        let channel = String.trim (get_string args "channel" "") in
        if channel = "" then begin
          Keeper_chat_store.append_turn
            ~base_dir:config.base_path
            ~keeper_name:name
            ~user_content
            ~user_attachments:[]
            ~surface:Surface_ref.Agent
            ~assistant_content
            ?turn_ref
            ();
          Keeper_chat_broadcast.chat_appended ~keeper_name:name ~source:"agent"
            ~content:assistant_content
            ()
        end
        else begin
          Keeper_chat_store.append_assistant_message
            ~base_dir:config.base_path
            ~keeper_name:name
            ~content:assistant_content
            ~surface:(Surface_ref.Gate { label = channel; address = [] })
            ?turn_ref
            ();
          Keeper_chat_broadcast.chat_appended ~keeper_name:name ~source:channel
            ~content:assistant_content
            ()
        end)
;;

(* RFC-0182 Phase 5 PR-B: ctx-free body for [masc_keeper_msg] descriptor
   projection.  Constructs a fresh [Keeper_types_profile.context] from the
   threaded Eio resources and delegates to the existing [Turn.preflight_*]
   / [Turn.handle_keeper_msg] handlers. *)
let keeper_msg_body
      ~(config : Workspace.config)
      ~(agent_name : string)
      ~(sw : Eio.Switch.t)
      ~(clock : float Eio.Time.clock_ty Eio.Resource.t)
      ?proc_mgr
      ?net
      ?continuation_channel
      args : tool_result =
  let keeper_ctx : _ Keeper_types_profile.context =
    { config; agent_name; sw; clock; proc_mgr; net }
  in
  match
    let* name = resolve_keeper_name_config ~config args in
    let resolved_args = with_keeper_name args name in
    let* () = Turn.preflight_keeper_msg keeper_ctx resolved_args in
    let* background_sw =
      Keeper_msg_async.server_background_switch ()
      |> Result.map_error (fun error ->
        Yojson.Safe.to_string (Keeper_msg_async.submit_error_to_json error))
    in
    let* request_id =
      submit_keeper_msg_with_captured_event_bus
        ~background_sw
        ~base_path:config.base_path
        ~caller:agent_name
        ~keeper_name:name
        ~f:(fun ?event_bus request_sw ->
          let worker_ctx = { keeper_ctx with sw = request_sw } in
          let result =
            Turn.handle_keeper_msg
              ?event_bus
              ?continuation_channel
              worker_ctx
              resolved_args
          in
          if tool_result_success result
          then begin
            append_direct_chat_pair_if_reply
              ~config
              ~name
              ~args:resolved_args
              result;
            invalidate_keeper_list_cache ();
            invalidate_status_cache name
          end;
          result)
        ()
      |> Result.map_error (fun error ->
        Yojson.Safe.to_string (Keeper_msg_async.submit_error_to_json error))
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
    Ok (tool_result_ok (Yojson.Safe.to_string json))
  with
  | Ok result -> result
  | Error err -> tool_result_error err
;;

let handle_keeper_msg ?continuation_channel ~submitted_by ctx args : tool_result =
  match
    let* name = resolve_keeper_name ctx args in
    let resolved_args = with_keeper_name args name in
    let* () = Turn.preflight_keeper_msg ctx resolved_args in
    let* background_sw =
      Keeper_msg_async.server_background_switch ()
      |> Result.map_error (fun error ->
        Yojson.Safe.to_string (Keeper_msg_async.submit_error_to_json error))
    in
    let* request_id =
      submit_keeper_msg_with_captured_event_bus
        ~background_sw
        ~base_path:ctx.config.base_path
        ~caller:submitted_by
        ~keeper_name:name
        ~f:(fun ?event_bus request_sw ->
          let worker_ctx = { ctx with sw = request_sw } in
          let result =
            Turn.handle_keeper_msg
              ?event_bus
              ?continuation_channel
              worker_ctx
              resolved_args
          in
          if tool_result_success result
          then begin
            append_direct_chat_pair_if_reply
              ~config:ctx.config
              ~name
              ~args:resolved_args
              result;
            invalidate_keeper_list_cache ();
            invalidate_status_cache name
          end;
          result)
        ()
      |> Result.map_error (fun error ->
        Yojson.Safe.to_string (Keeper_msg_async.submit_error_to_json error))
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
    Ok (tool_result_ok (Yojson.Safe.to_string json))
  with
  | Ok result -> result
  | Error err -> tool_result_error err
;;
(* RFC-0182 §3.1 — ctx-free body for keeper_dispatch_ref path. *)
let keeper_msg_result_body ~(config : Workspace.config) ~caller args : tool_result =
  let request_id = get_string args "request_id" "" in
  if String.equal request_id "" then
    tool_result_error {|{"error":"request_id is required"}|}
  else
    match Keeper_msg_async.poll ~base_path:config.base_path ~caller request_id with
    | Keeper_msg_async.Absent ->
      tool_result_error
        (Printf.sprintf {|{"error":"request_id not found","request_id":"%s"}|} request_id)
    | Keeper_msg_async.Unreadable reason ->
      tool_result_error
        (Yojson.Safe.to_string
           (`Assoc
              [ ("error", `String "request_record_unreadable")
              ; ( "message"
                , `String
                    (Printf.sprintf
                       "request record unreadable: %s — request was accepted but its \
                        result is lost"
                       reason) )
              ; ("request_id", `String request_id)
              ]))
    | Keeper_msg_async.Rejected rejection ->
      tool_result_error
        (Yojson.Safe.to_string (Keeper_msg_async.access_rejection_to_json rejection))
    | Keeper_msg_async.Found entry ->
      tool_result_ok (Yojson.Safe.to_string (Keeper_msg_async.entry_to_json entry))

let handle_keeper_msg_result ctx args : tool_result =
  keeper_msg_result_body ~config:ctx.config ~caller:ctx.agent_name args

(* RFC-0182 §3.1 — ctx-free body for keeper_dispatch_ref path. *)
let keeper_msg_cancel_body ~(config : Workspace.config) ~caller args : tool_result =
  let request_id = get_string args "request_id" "" in
  if String.equal request_id "" then
    tool_result_error {|{"error":"request_id is required"}|}
  else (
    let result =
      Keeper_msg_async.cancel ~base_path:config.base_path ~caller request_id
    in
    let json = Keeper_msg_async.cancel_result_to_json ~request_id result in
    match result with
    | Keeper_msg_async.Cancellation_requested
    | Keeper_msg_async.Cancelled_request
    | Keeper_msg_async.Cancel_in_progress ->
      tool_result_ok (Yojson.Safe.to_string json)
    | Keeper_msg_async.Cancel_not_found
    | Keeper_msg_async.Cancel_unreadable _
    | Keeper_msg_async.Cancel_rejected _
    | Keeper_msg_async.Cancel_already_terminal _
    | Keeper_msg_async.Cancel_persistence_failed _
    | Keeper_msg_async.Cancel_worker_signal_failed _
    | Keeper_msg_async.Cancel_state_invariant_failed _ ->
      tool_result_error (Yojson.Safe.to_string json))

let handle_keeper_msg_cancel ctx args : tool_result =
  keeper_msg_cancel_body ~config:ctx.config ~caller:ctx.agent_name args

let keeper_msg_queue_body ~(config : Workspace.config) ~caller args : tool_result =
  let keeper_name = get_string_opt args "keeper_name" in
  match
    Keeper_msg_async.list_for_keeper
      ~base_path:config.base_path
      ~caller
      ?keeper_name
      ()
  with
  | Ok entries ->
    let json_list = List.map Keeper_msg_async.entry_to_json entries in
    tool_result_ok (Yojson.Safe.to_string (`List json_list))
  | Error rejection ->
    tool_result_error
      (Yojson.Safe.to_string (Keeper_msg_async.access_rejection_to_json rejection))

let handle_keeper_msg_queue ctx args : tool_result =
  keeper_msg_queue_body ~config:ctx.config ~caller:ctx.agent_name args

let complete_keeper_msg_stream_result ~name result =
  if not (tool_result_success result) then result
  else begin
    let body = tool_result_body result in
    invalidate_keeper_list_cache ();
    invalidate_status_cache name;
    let json = json_of_body body in
    tool_result_ok
      (Yojson.Safe.pretty_to_string
         (annotate_keeper_json ~runtime_class:"keeper" json))
  end

let handle_keeper_msg_stream
      ?on_text_delta
      ?on_event
      ?continuation_channel
      ?on_admission_rejected
      ?on_admitted
      ctx
      args
  : tool_result
  =
  let run name =
    let resolved_args = with_keeper_name args name in
    (* Stream turns are synchronous today, but still pin the bus visible at the
       public surface boundary so later refactors cannot reintroduce a nested
       fallback lookup in the turn body. *)
    let event_bus = Keeper_event_bus.get () in
    let result =
      Turn.handle_keeper_msg
        ?on_text_delta
        ?on_event
        ?event_bus
        ?continuation_channel
        ?on_admission_rejected
        ?on_admitted
        ctx
        resolved_args
    in
    complete_keeper_msg_stream_result ~name result
  in
  match resolve_keeper_name ctx args with
  | Ok name -> run name
  | Error err ->
      let raw_name = String.trim (get_string args "name" "") in
      if not (Keeper_config.validate_name raw_name)
      then tool_result_error err
      else
        (* Preserve typed admission truth after lifecycle teardown removes the
           metadata row: a shutdown-fenced queued receipt must return to
           Pending, not become a terminal lookup failure. An open lane still
           runs the admitted body and surfaces its authoritative metadata
           error. *)
        run raw_name

let handle_keeper_msg_stream_if_free
      ?on_text_delta
      ?on_event
      ?continuation_channel
      ctx
      args
  =
  match resolve_keeper_name ctx args with
  | Error err ->
    let raw_name = String.trim (get_string args "name" "") in
    if not (Keeper_config.validate_name raw_name)
    then `Ran (tool_result_error err)
    else
      (* A connector message already accepted for a live/raw Keeper identity
         must remain queueable even if metadata resolution is temporarily
         unavailable. Run the resolution error itself through the same
         post-lock admission boundary: a held slot, parked waiter, active
         receipt, or queue read error returns Busy; only an atomically free
         lane returns the original metadata error. *)
      Keeper_turn_admission.run_chat_if_free
          ~base_path:ctx.config.base_path
          ~keeper_name:raw_name
          (fun () -> tool_result_error err)
  | Ok name ->
    let resolved_args = with_keeper_name args name in
    let event_bus = Keeper_event_bus.get () in
    (match
       Turn.handle_keeper_msg_if_free
         ?on_text_delta
         ?on_event
         ?event_bus
         ?continuation_channel
         ctx
         resolved_args
     with
     | `Busy rejection -> `Busy rejection
     | `Ran result ->
       `Ran (complete_keeper_msg_stream_result ~name result))
(* RFC-0182 §3.1 — ctx-free body for keeper_dispatch_ref path. *)
let resolve_keeper_meta_config ~(config : Workspace.config) args =
  let name = String.trim (get_string args "name" "") in
  let* resolved =
    read_effective_meta_resolved config name
    |> Result.map_error (fun err -> Printf.sprintf "%s" err)
  in
  match resolved with
  | Some (_resolved_name, meta) -> Ok meta
  | None -> Error (Printf.sprintf "keeper not found: %s" name)

let resolve_keeper_meta ctx args =
  resolve_keeper_meta_config ~config:ctx.config args

let adversarial_review_body ~(config : Workspace.config) ~(agent_name : string) args : tool_result =
  ignore config;
  let diff = get_string args "diff" "" in
  if String.equal (String.trim diff) ""
  then tool_result_error {|{"error":"diff is required"}|}
  else
    match
      let inputs =
        match get_string_opt args "path" with
        | Some path -> [ Adversarial_eval.Changed_file { path; content = diff } ]
        | None -> [ Adversarial_eval.Diff diff ]
      in
      let* valid_inputs =
        Adversarial_eval.validate_inputs inputs
        |> Result.map_error (fun (path, kind) ->
            let kind_str =
              match (kind : Adversarial_eval.banned_input_kind) with
              | Readme -> "readme"
              | Design_doc -> "design_doc"
              | State_history -> "state_history"
              | Task_history -> "task_history"
              | Governance_history -> "governance_history"
            in
            Printf.sprintf {|{"error":"banned input: %s (%s)"}|} path kind_str)
      in
      let session_id =
        Printf.sprintf "%s-%s-%.0f"
          agent_name
          "adversarial-review"
          (Time_compat.now ())
      in
      let ctx =
        Adversarial_eval.create_context ~session_id ~inputs:valid_inputs
      in
      let result = Adversarial_eval.evaluate ctx in
      Ok (tool_result_ok (Yojson.Safe.to_string (Adversarial_eval.result_to_yojson result)))
    with
    | Ok result -> result
    | Error err -> tool_result_error err

let handle_keeper_adversarial_review ctx args : tool_result =
  adversarial_review_body ~config:ctx.config ~agent_name:ctx.agent_name args

let handle_keeper_down ctx args : tool_result =
  invalidate_keeper_list_cache ();
  invalidate_status_cache (get_string args "name" "");
  Turn.handle_keeper_down ctx args
