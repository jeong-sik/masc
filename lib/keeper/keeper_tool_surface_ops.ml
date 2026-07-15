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
  publication_recovery_provider :
    Keeper_publication_recovery_availability.provider;
}
type tool_result = Keeper_types_profile.tool_result
let schemas = Keeper_types_profile.schemas

type handler_error =
  | Message_error of string
  | Payload_error of Yojson.Safe.t

let message_error result = Result.map_error (fun error -> Message_error error) result

let tool_result_of_handler_error = function
  | Message_error message -> tool_result_error message
  | Payload_error data -> tool_result_error_data data
;;

type json_cache = {
  key : string option;
  value : Yojson.Safe.t option;
  expires_at : float;
  generation : int;
}
let empty_json_cache ~generation = { key = None; value = None; expires_at = 0.0; generation }
let keeper_list_cache = Atomic.make (empty_json_cache ~generation:0)
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
let invalidate_json_cache cache_ref =
  Lockfree_atomic.update cache_ref (fun current ->
    empty_json_cache ~generation:(current.generation + 1))
let invalidate_keeper_list_cache () = invalidate_json_cache keeper_list_cache
let rec cached_json_by_key cache_ref ~key ~ttl_s compute =
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
        cached_json_by_key cache_ref ~key ~ttl_s compute
      end

let submit_keeper_msg_with_captured_event_bus
      ~background_sw
      ~base_path
      ~caller
      ~request
      ~(f :
          ?event_bus:Agent_sdk.Event_bus.t
          -> Keeper_invocation_contract.request
          -> Eio.Switch.t
          -> tool_result)
      () =
  let event_bus = Keeper_event_bus.get () in
  Keeper_invocation_contract.submit
    ~background_sw
    ~base_path
    ~caller
    ~request
    ~f:(fun request request_sw -> f ?event_bus request request_sw)
    ()

module For_testing = struct
  let reset_keeper_list_cache () =
    Atomic.set keeper_list_cache (empty_json_cache ~generation:0)
  let invalidate_keeper_list_cache = invalidate_keeper_list_cache
  let cached_keeper_list_data ~key ~ttl_s compute =
    cached_json_by_key keeper_list_cache ~key ~ttl_s compute
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
let startup_not_ready_error_data elapsed =
  `Assoc
    [ ("error", `String "server_initializing")
    ; ( "message"
      , `String
          (Printf.sprintf
             "MASC server is still starting (%.0fs elapsed). Retry in a few seconds."
             elapsed) )
    ; ("retry_after_ms", `Int 3000)
    ]
let with_keeper_startup_gate f =
  if not Server_startup_state.((!state).state_ready) then begin
    let elapsed = Server_startup_state.elapsed_since_start () in
    Log.Keeper.warn "keeper_up rejected: server not ready (%.1fs since start)" elapsed;
    tool_result_error_data (startup_not_ready_error_data elapsed)
  end else
    f ()
let execute_keeper_up ctx args : tool_result =
  match
    let* prepared_args, identity_reseed = prepare_keeper_up_identity ctx args in
    let result = Turn.handle_keeper_up ctx prepared_args in
    if not (tool_result_success result) then
      Ok result
    else
      let json = Tool_result.data result in
      let json =
        match identity_reseed with
        | Some note -> attach_assoc_field "identity_reseed" note json
        | None -> json
      in
      invalidate_keeper_list_cache ();
      Keeper_status_detail.invalidate_status_cache_for
        (get_string prepared_args "name" "");
      Ok (tool_result_ok_data (annotate_keeper_json ~runtime_class:"keeper" json))
  with
  | Ok result -> result
  | Error err -> tool_result_error err
let keeper_brief_meta_json (meta : keeper_meta) =
  `Assoc
    [
      ("name", `String meta.name);
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

let with_invocation_request args request =
  match args with
  | `Assoc fields ->
    let fields =
      fields |> List.remove_assoc "name" |> List.remove_assoc "message"
    in
    `Assoc
      (("name", `String (Keeper_invocation_contract.target_name request))
       :: ("message", `String (Keeper_invocation_contract.prompt request))
       :: fields)
  | other -> other
;;
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
    tool_result_error_data (startup_not_ready_error_data elapsed)
  end else
    match
      let* persona, resolved_args =
        Keeper_tool_persona_runtime.resolved_keeper_args_from_persona args
        |> Result.map_error (fun e -> "" ^ e)
      in
      let dry_run = get_bool args "dry_run" false in
      if dry_run then
        Ok
          (tool_result_ok_data
             (`Assoc
                [
                  ( "persona",
                    Keeper_tool_persona_runtime.persona_summary_to_json persona );
                  ("created", `Bool false);
                  ("resolved_args", resolved_args);
                ]))
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
          let* durable_config =
            Keeper_tool_persona_runtime.persist_keeper_toml_from_resolved_args
              resolved_args
            |> Result.map_error (fun e ->
                "keeper created but durable config write failed: " ^ e)
          in
          let created_json = Tool_result.data result in
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
          Ok (tool_result_ok_data json)
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
      ~(publication_recovery_provider :
          Keeper_publication_recovery_availability.provider)
      ?proc_mgr
      ?net
      args : tool_result =
  let keeper_ctx : _ Keeper_types_profile.context =
    { config
    ; agent_name
    ; sw
    ; clock
    ; proc_mgr
    ; net
    ; publication_recovery_provider
    }
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
      let json = Tool_result.data result in
      let json =
        json
        |> annotate_keeper_json ~runtime_class:"keeper"
        |> attach_identity_reseed ?identity_reseed
      in
      Ok (tool_result_ok_data json)
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

let direct_reply_visible_text json =
  match Keeper_turn_outcome.of_reply_payload (Some json) with
  | Keeper_turn_outcome.Continuation_checkpoint -> None
  | Keeper_turn_outcome.No_visible_reply -> None
  | Keeper_turn_outcome.Visible_reply -> (
      match Json_util.get_string json "reply" with
      | None -> None
      | Some reply ->
          let visible = String.trim reply in
          if visible = "" then None else Some visible)
;;

let append_direct_chat_pair_if_reply ~(config : Workspace.config) ~name ~args result =
  if get_bool args "direct_reply" false && tool_result_success result then (
    let user_content = get_string args "message" "" |> String.trim in
    (* RFC-0233 §7: the join key the keeper minted into the reply payload,
       threaded onto the persisted row of this agent-initiated / connector
       turn (parse, don't repair — absent/malformed reads as None). *)
    let turn_ref =
      Keeper_turn_outcome.turn_ref_of_reply_payload
        (Some (Tool_result.data result))
    in
    match user_content, direct_reply_visible_text (Tool_result.data result) with
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

let submit_keeper_invocation
      ~submitted_by
      ~submission_to_json
      ~submission_error_to_json
      ~run_turn
      ctx
      ~request
  =
  let name = Keeper_invocation_contract.target_name request in
  match
    let* background_sw =
      Keeper_msg_async.server_background_switch ()
      |> Result.map_error (fun error ->
        Payload_error (submission_error_to_json error))
    in
    let* submission =
      submit_keeper_msg_with_captured_event_bus
        ~background_sw
        ~base_path:ctx.config.base_path
        ~caller:submitted_by
        ~request
        ~f:(fun ?event_bus request request_sw ->
          let worker_ctx = { ctx with sw = request_sw } in
          let result = run_turn ?event_bus request worker_ctx in
          if tool_result_success result
          then begin
            invalidate_keeper_list_cache ();
            invalidate_status_cache name
          end;
          result)
        ()
      |> Result.map_error (fun error ->
        Payload_error (submission_error_to_json error))
    in
    Ok
      (tool_result_ok_data
         (submission_to_json request submission))
  with
  | Ok result -> result
  | Error error -> tool_result_of_handler_error error
;;

let handle_keeper_msg ?continuation_channel ~submitted_by ctx args : tool_result =
  match
    let* name = message_error (resolve_keeper_name ctx args) in
    let worker_args = with_keeper_name args name in
    let* request = message_error (Turn.preflight_keeper_msg ctx worker_args) in
    Ok
      (submit_keeper_invocation
         ~submitted_by
         ~submission_to_json:Keeper_invocation_contract.delegate_submission_to_json
         ~submission_error_to_json:
           (Keeper_invocation_contract.delegate_submission_error_to_json request)
         ~run_turn:(fun ?event_bus request worker_ctx ->
           let worker_args = with_invocation_request worker_args request in
           let result =
             Turn.handle_keeper_msg
               ?event_bus
               ?continuation_channel
               worker_ctx
               worker_args
           in
           append_direct_chat_pair_if_reply
             ~config:ctx.config ~name ~args:worker_args result;
           result)
         ctx ~request)
  with
  | Ok result -> result
  | Error error -> tool_result_of_handler_error error
;;

let handle_keeper_delegate ~submitted_by ctx args =
  match
    let* request =
      Keeper_invocation_contract.request_of_json args |> message_error
    in
    let* request = message_error (Turn.preflight_keeper_delegate ctx request) in
    Ok
      (submit_keeper_invocation
         ~submitted_by
         ~submission_to_json:Keeper_invocation_contract.delegate_submission_to_json
         ~submission_error_to_json:
           (Keeper_invocation_contract.delegate_submission_error_to_json request)
         ~run_turn:(fun ?event_bus request worker_ctx ->
           Turn.handle_keeper_delegate ?event_bus worker_ctx request)
         ctx
         ~request)
  with
  | Ok result -> result
  | Error error -> tool_result_of_handler_error error
;;

let run_ref_arg args =
  match args with
  | `Assoc [ ("run_ref", value) ] -> Keeper_invocation_contract.run_ref_of_json value
  | _ ->
    Error
      (Keeper_invocation_contract.Invalid_wire_value
         { field = "delegate_operation"; expected = "object containing only run_ref" })
;;

let run_ref_error error =
  tool_result_error_data
    (`Assoc
       [ "error", `String "invalid_run_ref"
       ; "message", `String (Keeper_invocation_contract.request_error_to_string error)
       ])
;;

let keeper_delegate_status_body ~(config : Workspace.config) ~caller args =
  match run_ref_arg args with
  | Error error -> run_ref_error error
  | Ok reference ->
    (match Keeper_invocation_contract.poll ~base_path:config.base_path ~caller reference with
     | Error error -> run_ref_error error
     | Ok Keeper_msg_async.Absent ->
       tool_result_error_data
         (`Assoc [ "error", `String "run_not_found"; "run_ref", Keeper_invocation_contract.run_ref_to_json reference ])
     | Ok (Keeper_msg_async.Unreadable reason) ->
       tool_result_error_data
         (`Assoc
            [ "error", `String "invocation_record_unreadable"
            ; "message", `String reason
            ; "run_ref", Keeper_invocation_contract.run_ref_to_json reference
            ])
     | Ok (Keeper_msg_async.Rejected rejection) ->
       tool_result_error_data
         (Keeper_invocation_contract.delegate_access_rejection_to_json reference rejection)
     | Ok (Keeper_msg_async.Found entry) ->
       (match Keeper_invocation_contract.delegate_entry_to_json entry with
        | Ok json -> tool_result_ok_data json
        | Error error ->
          run_ref_error error))
;;

let keeper_delegate_cancel_body ~(config : Workspace.config) ~caller args =
  match run_ref_arg args with
  | Error error -> run_ref_error error
  | Ok reference ->
    (match Keeper_invocation_contract.cancel ~base_path:config.base_path ~caller reference with
     | Error error -> run_ref_error error
     | Ok result ->
       let json =
         Keeper_invocation_contract.delegate_cancellation_to_json reference result
       in
       match result with
       | Keeper_msg_async.Cancellation_requested _ ->
         tool_result_ok_data json
       | Keeper_msg_async.Cancel_not_found
       | Keeper_msg_async.Cancel_unreadable _
       | Keeper_msg_async.Cancel_rejected _
       | Keeper_msg_async.Cancel_worker_ownership_unknown _
       | Keeper_msg_async.Cancel_already_terminal _
       | Keeper_msg_async.Cancel_persistence_failed _
       | Keeper_msg_async.Cancel_worker_signal_failed _
       | Keeper_msg_async.Cancel_state_invariant_failed _ ->
         tool_result_error_data json)
;;

let keeper_delegate_list_body ~(config : Workspace.config) ~caller args =
  let target =
    match args with
    | `Assoc [] -> Ok None
    | `Assoc [ ("target", value) ] ->
      Keeper_invocation_contract.target_of_json value |> Result.map (fun target -> Some target)
    | _ ->
      Error
        (Keeper_invocation_contract.Invalid_wire_value
           { field = "delegate_list"; expected = "empty object or typed target" })
  in
  match target with
  | Error error -> run_ref_error error
  | Ok target ->
  let keeper_name = Option.map Keeper_invocation_contract.target_name_of_target target in
  match
    Keeper_msg_async.list_for_keeper
      ~base_path:config.base_path
      ~caller
      ?keeper_name
      ()
  with
  | Ok entries ->
    let rec project = function
      | [] -> Ok []
      | entry :: rest ->
        let* json = Keeper_invocation_contract.delegate_entry_to_json entry in
        let* rest = project rest in
        Ok (json :: rest)
    in
    (match project entries with
     | Ok json_list -> tool_result_ok_data (`List json_list)
     | Error error -> run_ref_error error)
  | Error rejection ->
    tool_result_error_data (Keeper_msg_async.access_rejection_to_json rejection)
;;

let complete_keeper_msg_stream_result ~name result =
  if not (tool_result_success result) then result
  else begin
    invalidate_keeper_list_cache ();
    invalidate_status_cache name;
    tool_result_ok_data
      (annotate_keeper_json ~runtime_class:"keeper" (Tool_result.data result))
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

let handle_keeper_down ctx args : tool_result =
  invalidate_keeper_list_cache ();
  invalidate_status_cache (get_string args "name" "");
  Turn.handle_keeper_down ctx args
