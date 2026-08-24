(** Runtime operations used by the keeper MCP tool surface. *)
open Tool_args
open Keeper_types
open Keeper_meta_contract
open Keeper_meta_store
open Keeper_types_profile
open Keeper_runtime
open Result.Syntax
module Turn = Keeper_turn
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
let schemas = Keeper_schema.schemas

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
}
let empty_json_cache () = { key = None; value = None; expires_at = 0.0 }
let keeper_list_cache = Atomic.make (empty_json_cache ())
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
  Atomic.set cache_ref (empty_json_cache ())
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
        }
      in
      if Atomic.compare_and_set cache_ref cache next then value
      else begin
        Otel_metric_store.inc_counter
          Otel_metric_store.metric_tool_keeper_cache_cas_conflicts ();
        cached_json_by_key cache_ref ~key ~ttl_s compute
      end

module For_testing = struct
  let reset_keeper_list_cache () =
    Atomic.set keeper_list_cache (empty_json_cache ())
  let invalidate_keeper_list_cache = invalidate_keeper_list_cache
  let cached_keeper_list_data ~key ~ttl_s compute =
    cached_json_by_key keeper_list_cache ~key ~ttl_s compute
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
    let* updated_meta =
      match
        Keeper_owner_registry.apply_meta
          ~base_path:config.base_path
          ~keeper_name:meta.name
          (Keeper_owner_reducer.Handoff_identity
             { keeper_id = meta.keeper_id
             ; agent_name = expected_agent_name
             ; trace_id = new_trace_id
             ; trace_history =
                 Json_util.dedupe_keep_order
                   (previous_trace_id :: meta.runtime.trace_history)
             ; updated_at = Keeper_meta_contract.now_iso ()
             })
      with
      | Ok (Some updated_meta) -> Ok updated_meta
      | Ok None ->
        Error
          (Printf.sprintf
             "failed to reseed keeper identity for %s: owner metadata missing"
             meta.name)
      | Error error ->
        Error
          (Printf.sprintf
             "failed to persist reseeded keeper identity for %s: %s"
             meta.name
             (Keeper_owner_registry.command_error_to_string error))
    in
    let base_dir = Keeper_types_profile.session_base_dir config in
    ignore
      (Keeper_context_runtime.create_session
         ~session_id:new_trace_id_raw
         ~base_dir);
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
    ]
let with_keeper_startup_gate f =
  if not (Server_startup_state.snapshot ()).state_ready then begin
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
      ("next_action", `String "fix_keeper_toml_or_keeper_instructions");
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
      let diagnostic =
        Keeper_status_runtime.keeper_diagnostic_json
          ~config
          ~meta
          ~keepalive_running ~history_items:[] ~now_ts
        |> Keeper_status_runtime.augment_keeper_diagnostic_json
             ~keepalive_running
             ~keepalive_started_at:
               (Keeper_status_bridge.runtime_keepalive_started_at config meta)
             ~now_ts
      in
      (* One keeper is described by four separate readings, and each row
         carries its own field for one of them rather than a single word that
         answers for all four:

           phase        lifecycle state machine  - which cell it is in
           health       observed signal          - is it reporting on time
           paused       operator override        - did a person stop it
           next_action  what to do about it      - already derived from health

         [status] is a fifth field that re-answers [health] with three of its
         values folded into "inactive". The TUI counted that word as running
         while the dashboard counted it as attention, because a folded word
         leaves the reader to guess. Both are published here so neither has to.

         The diagnostic already carries health and next_action; this only stops
         discarding them. *)
      let status = Keeper_status_runtime.keeper_surface_status ~diagnostic in
      let health =
        Keeper_status_runtime.keeper_health_to_string
          (Keeper_status_runtime.keeper_diagnostic_health
             ~diagnostic
             ~source:"keeper_list_row")
      in
      (* The action the diagnostic already derived. Absent means the diagnostic
         did not name one, which is a different thing from "nothing to do", so
         it publishes as null rather than as an empty string. *)
      let next_action =
        Json_util.string_opt_to_json
          (Json_util.get_string diagnostic "next_action_path")
      in
      let phase =
        match Keeper_registry.get_phase ~base_path:config.base_path meta.name with
        | Some p -> Keeper_state_machine.phase_to_string p
        | None -> "offline"
      in
      Some
        (`Assoc (
          [
            ("runtime_class", `String runtime_class); ("name", `String meta.name);
            ("meta", keeper_brief_meta_json meta); ("agent_name", `String meta.agent_name);
            ("status", `String status); ("phase", `String phase);
            ("health", `String health);
            ("paused", `Bool meta.paused);
            ("next_action", next_action);
            ("keepalive_running", `Bool keepalive_running);
            ("autoboot_enabled", `Bool meta.autoboot_enabled); ("proactive_enabled", `Bool meta.proactive.enabled);
            ("runtime_id", `String (Keeper_meta_contract.runtime_id_of_meta meta));
            ("created_at", `String meta.created_at); ("updated_at", `String meta.updated_at);
          ]))
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

let attach_identity_reseed ?identity_reseed json =
  match identity_reseed with
  | None -> json
  | Some note -> attach_assoc_field "identity_reseed" note json
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

(* Resolution carries the meta it read (RFC-0371 B6). The name-only shape
   below discarded it, which forced the preflight one call later to read the
   same keeper again from disk — two reads per submitted message for one
   question. Effective meta (TOML overlay) is read here because the only
   downstream consumer of the carried meta is the runtime-id preflight,
   which must see overlay-owned fields. *)
let resolve_keeper_config ~(config : Workspace.config) name =
  let name = String.trim name in
  let rec loop = function
    | [] -> Error (Printf.sprintf "keeper not found: %s" name)
    | candidate :: rest ->
        let* resolved = read_effective_meta_resolved config candidate in
        (match resolved with
         | Some (resolved_name, meta) -> Ok (resolved_name, meta)
         | None -> loop rest)
  in
  loop (keeper_name_lookup_candidates name)

let resolve_keeper_name_string_config ~(config : Workspace.config) name =
  Result.map fst (resolve_keeper_config ~config name)

let resolve_keeper_name_config ~(config : Workspace.config) args =
  resolve_keeper_name_string_config
    ~config
    (get_string args "name" "")


let resolve_keeper ctx message =
  resolve_keeper_config
    ~config:ctx.config
    (Keeper_invocation_contract.direct_message_target_name message)

type direct_reply_decode_error =
  | Turn_outcome_decode_error of Keeper_turn_outcome.decode_error
  | Visible_reply_missing_reply

let direct_reply_decode_error_to_string = function
  | Turn_outcome_decode_error error ->
    Keeper_turn_outcome.decode_error_to_string error
  | Visible_reply_missing_reply ->
    "keeper reply payload is missing reply for visible_reply"
;;

let direct_reply_projection json =
  match Keeper_turn_outcome.of_reply_payload (Some json) with
  | Ok Keeper_turn_outcome.Visible_reply ->
    (match Json_util.get_string json "reply" with
     | Some reply ->
       Ok
         (Keeper_chat_blocks.connector_projection
            ~turn_outcome:Keeper_turn_outcome.Visible_reply
            ~reply:(Some reply))
     | None -> Error Visible_reply_missing_reply)
  | Ok turn_outcome ->
    Ok
      (Keeper_chat_blocks.connector_projection
         ~turn_outcome
         ~reply:(Json_util.get_string json "reply"))
  | Error error -> Error (Turn_outcome_decode_error error)
;;

let direct_reply_visible_text json =
  match direct_reply_projection json with
  | Ok (Keeper_chat_blocks.Connector_text text) -> Ok (Some text)
  | Ok (Connector_status _ | Connector_no_visible_reply) -> Ok None
  | Error error -> Error error
;;

let owner_operation_error_code = function
  | Keeper_owner_registry.Command_lifecycle_reserved _ -> "owner_stopping"
  | Command_lookup_failed Inventory_stopping -> "owner_stopping"
  | Command_lookup_failed
      (Inventory_not_installed _ | Owner_not_found _ | Owner_unavailable _
      | Owner_initialization_failed _) ->
    "store_unavailable"
  | Command_rejected (Keeper_owner.Owner_stopping | Owner_closed) ->
    "owner_stopping"
  | Command_rejected (Keeper_owner.Operation_rejected error) ->
    (match Keeper_owner.operation_error_kind error with
     | Invalid_operation_input -> "invalid_input"
     | Unknown_operation -> "unknown_operation"
     | Operation_not_queued -> "not_queued"
     | Operation_idempotency_conflict -> "idempotency_conflict"
     | Operation_store_unavailable -> "store_unavailable")
  | Command_rejected (Keeper_owner.Store_unavailable _ | Reducer_rejected _) ->
    "store_unavailable"
;;

let operation_payload_error code detail =
  Payload_error
    (`Assoc
       [ "error", `String code
       ; "message", `String detail
       ])
;;

let operation_id_of_invocation_ref invocation_ref =
  let canonical =
    Tool_invocation_ref.to_yojson invocation_ref |> Yojson.Safe.to_string
  in
  let digest = Digestif.SHA256.(digest_string canonical |> to_hex) in
  "kmsg-" ^ String.sub digest 0 32
;;

let submit_agent_operation
      ?continuation_channel
      ?operation_id_raw
      ~submitted_by
      ~keeper_name
      ~message
      ~user_blocks
      ~turn_instructions
      ~surface_context
      ~attachments
      ctx
  =
  let ( let* ) = Result.bind in
  let operation_id_raw =
    Option.value
      operation_id_raw
      ~default:(Random_id.prefixed ~prefix:"kmsg-" ~bytes:16)
  in
  let* operation_id =
    Keeper_owner.Chat_operation.Operation_id.of_string operation_id_raw
    |> Result.map_error (operation_payload_error "invalid_input")
  in
  let thread_id = "keeper:" ^ keeper_name in
  let* continuation_channel =
    match continuation_channel with
    | Some continuation_channel -> Ok continuation_channel
    | None ->
      Keeper_continuation_channel.dashboard ~thread_id
      |> Result.map_error (operation_payload_error "invalid_input")
  in
  let* source =
    Keeper_chat_operation_payload.source_to_json
      ~submitted_by
      ~thread_id
      ~continuation_channel
      ~surface:Surface_ref.Agent
      ~channel:"agent"
      ~channel_user_id:""
      ~channel_user_name:""
      ~channel_workspace_id:""
      ~conversation_id:None
      ~external_message_id:None
      ~workspace_id:None
      ~extra_mentions:[]
      ~user_row_origin:Keeper_chat_store.Needs_append
    |> Result.map_error (operation_payload_error "invalid_input")
  in
  let input =
    Keeper_chat_operation_payload.input_to_json
      ~message
      ~user_blocks
      ~turn_instructions
      ~surface_context
      ~attachments
  in
  match
    Keeper_owner_registry.submit_operation
      ~base_path:ctx.config.base_path
      ~keeper_name
      ~operation_id
      ~source
      ~input
  with
  | Ok acceptance ->
    Ok
      (tool_result_ok_data
         (`Assoc
            [ "operation_id", `String operation_id_raw
            ; "state",
              `String
                (Keeper_owner.Chat_operation.state_to_string
                   acceptance.operation.state)
            ; "queued_count", `Int acceptance.queued_count
            ; "existing", `Bool acceptance.existing
            ]))
  | Error error ->
    Error
      (operation_payload_error
         (owner_operation_error_code error)
         (Keeper_owner_registry.command_error_to_string error))
;;

let handle_keeper_msg ?continuation_channel ~submitted_by ctx message : tool_result =
  match
    let* name, meta = message_error (resolve_keeper ctx message) in
    let* message =
      Keeper_invocation_contract.direct_message_with_keeper_name message name
      |> Result.map_error Keeper_invocation_contract.request_error_to_string
      |> message_error
    in
    let* message = message_error (Turn.preflight_keeper_msg_resolved ~meta message) in
    submit_agent_operation
      ?continuation_channel
      ~submitted_by
      ~keeper_name:name
      ~message:(Keeper_invocation_contract.direct_message_prompt message)
      ~user_blocks:(Keeper_invocation_contract.direct_message_user_blocks message)
      ~turn_instructions:
        (Keeper_invocation_contract.direct_message_turn_instructions message)
      ~surface_context:
        (Keeper_invocation_contract.direct_message_surface_context message)
      ~attachments:(Keeper_invocation_contract.direct_message_attachments message)
      ctx
  with
  | Ok result -> result
  | Error error -> tool_result_of_handler_error error
;;

let handle_keeper_delegate ?invocation_ref ~submitted_by ctx args =
  match
    let* request =
      Keeper_invocation_contract.request_of_json args
      |> Result.map_error Keeper_invocation_contract.request_error_to_string
      |> message_error
    in
    let* request = message_error (Turn.preflight_keeper_delegate ctx request) in
    submit_agent_operation
      ?operation_id_raw:(Option.map operation_id_of_invocation_ref invocation_ref)
      ~submitted_by
      ~keeper_name:(Keeper_invocation_contract.target_name request)
      ~message:(Keeper_invocation_contract.prompt request)
      ~user_blocks:[]
      ~turn_instructions:None
      ~surface_context:None
      ~attachments:[]
      ctx
  with
  | Ok result -> result
  | Error error -> tool_result_of_handler_error error
;;

(* Raw-args boundary for masc_keeper_msg, mirroring [handle_keeper_delegate]'s
   args decode so both dispatch tables (Keeper_tool_surface.dispatch and
   Keeper_dispatch_ref.dispatch) can register it the same way. Target
   resolution, preflight, and submission stay inside [handle_keeper_msg]. *)
let handle_keeper_msg_from_args ~submitted_by ctx args : tool_result =
  match
    Keeper_invocation_contract.direct_message
      ~keeper_name:(get_string args "name" "")
      ~prompt:(get_string args "message" "")
      ~direct_reply:true
      ~channel:""
      ~user_blocks:[]
      ~attachments:[]
      ()
    |> Result.map_error Keeper_invocation_contract.request_error_to_string
    |> message_error
  with
  | Ok message -> handle_keeper_msg ~submitted_by ctx message
  | Error error -> tool_result_of_handler_error error
;;

let operation_reference_arg args =
  let invalid detail =
    Error
      (`Assoc
         [ "error", `String "invalid_input"
         ; "message", `String detail
         ])
  in
  match args with
  | `Assoc fields ->
    let keys = List.map fst fields |> List.sort String.compare in
    if keys <> [ "operation_id"; "target" ]
    then invalid "operation lookup requires exactly operation_id and target"
    else
      (match
         Keeper_invocation_contract.target_of_json (List.assoc "target" fields),
         List.assoc "operation_id" fields
       with
       | Error error, _ ->
         invalid (Keeper_invocation_contract.request_error_to_string error)
       | Ok target, `String operation_id ->
         (match
            Keeper_owner.Chat_operation.Operation_id.of_string operation_id
          with
          | Ok operation_id ->
            Ok
              ( Keeper_invocation_contract.target_name_of_target target
              , operation_id )
          | Error detail -> invalid detail)
       | Ok _, _ -> invalid "operation_id must be a string")
  | _ -> invalid "operation lookup must be an object"
;;

let operation_target_arg args =
  match args with
  | `Assoc [ ("target", target) ] ->
    Keeper_invocation_contract.target_of_json target
    |> Result.map Keeper_invocation_contract.target_name_of_target
    |> Result.map_error (fun error ->
      `Assoc
        [ "error", `String "invalid_input"
        ; "message",
          `String (Keeper_invocation_contract.request_error_to_string error)
        ])
  | _ ->
    Error
      (`Assoc
         [ "error", `String "invalid_input"
         ; "message", `String "operation list requires exactly target"
         ])
;;

let owner_command_error_result error =
  tool_result_error_data
    (`Assoc
       [ "error", `String (owner_operation_error_code error)
       ; "message",
         `String (Keeper_owner_registry.command_error_to_string error)
       ])
;;

let operation_is_owned_by ~caller (operation : Keeper_owner.Chat_operation.t) =
  match Keeper_chat_operation_payload.source_of_json operation.source with
  | Ok source -> Ok (String.equal caller source.submitted_by)
  | Error detail -> Error detail
;;

let keeper_delegate_status_body ~(config : Workspace.config) ~caller args =
  match operation_reference_arg args with
  | Error json -> tool_result_error_data json
  | Ok (keeper_name, operation_id) ->
    (match
       Keeper_owner_registry.exact_operation
         ~base_path:config.base_path
         ~keeper_name
         operation_id
     with
     | Error error -> owner_command_error_result error
     | Ok None ->
       tool_result_error_data
         (`Assoc
            [ "error", `String "unknown_operation"
            ; "message", `String "Keeper chat operation was not found"
            ])
     | Ok (Some operation) ->
       (match operation_is_owned_by ~caller operation with
        | Error detail ->
          tool_result_error_data
            (`Assoc
               [ "error", `String "store_unavailable"
               ; "message", `String detail
               ])
        | Ok false ->
          tool_result_error_data
            (`Assoc
               [ "error", `String "unknown_operation"
               ; "message", `String "Keeper chat operation was not found"
               ])
        | Ok true ->
          tool_result_ok_data (Keeper_owner.Chat_operation.to_json operation)))
;;

let keeper_delegate_cancel_body ~(config : Workspace.config) ~caller args =
  match operation_reference_arg args with
  | Error json -> tool_result_error_data json
  | Ok (keeper_name, operation_id) ->
    (match
       Keeper_owner_registry.exact_operation
         ~base_path:config.base_path
         ~keeper_name
         operation_id
     with
     | Error error -> owner_command_error_result error
     | Ok None ->
       tool_result_error_data
         (`Assoc
            [ "error", `String "unknown_operation"
            ; "message", `String "Keeper chat operation was not found"
            ])
     | Ok (Some operation) ->
       (match operation_is_owned_by ~caller operation with
        | Error detail ->
          tool_result_error_data
            (`Assoc
               [ "error", `String "store_unavailable"
               ; "message", `String detail
               ])
        | Ok false ->
          tool_result_error_data
            (`Assoc
               [ "error", `String "unknown_operation"
               ; "message", `String "Keeper chat operation was not found"
               ])
        | Ok true ->
          (match
             Keeper_owner_registry.cancel_queued_operation
               ~base_path:config.base_path
               ~keeper_name
               operation_id
           with
           | Error error -> owner_command_error_result error
           | Ok operation ->
             tool_result_ok_data
               (Keeper_owner.Chat_operation.to_json operation))))
;;

let keeper_delegate_list_body ~(config : Workspace.config) ~caller args =
  match operation_target_arg args with
  | Error json -> tool_result_error_data json
  | Ok keeper_name ->
    (match
       Keeper_owner_registry.list_queued_operations
         ~base_path:config.base_path
         ~keeper_name
         ~after_sequence:None
         ~limit:100
     with
     | Error error -> owner_command_error_result error
     | Ok operations ->
       let rec owned acc = function
         | [] -> Ok (List.rev acc)
         | operation :: rest ->
           (match operation_is_owned_by ~caller operation with
            | Error detail -> Error detail
            | Ok false -> owned acc rest
            | Ok true ->
              owned
                (Keeper_owner.Chat_operation.to_json operation :: acc)
                rest)
       in
       (match owned [] operations with
        | Ok operations -> tool_result_ok_data (`List operations)
        | Error detail ->
          tool_result_error_data
            (`Assoc
               [ "error", `String "store_unavailable"
               ; "message", `String detail
               ])))
;;
let complete_keeper_msg_stream_result result =
  if not (tool_result_success result) then result
  else begin
    invalidate_keeper_list_cache ();
    tool_result_ok_data
      (annotate_keeper_json ~runtime_class:"keeper" (Tool_result.data result))
  end

let handle_keeper_msg_stream_admitted
      ~admission_token
      ?on_text_delta
      ?on_event
      ?on_tool_result_ready
      ?approval_gate
      ?continuation_channel
      ctx
      message
  =
  let raw_name =
    Keeper_invocation_contract.direct_message_target_name message
  in
  match
    Keeper_invocation_contract.direct_message_with_keeper_name message raw_name
  with
  | Error error ->
    tool_result_error (Keeper_invocation_contract.request_error_to_string error)
  | Ok message ->
    let event_bus = Event_bus_slots.get_keeper () in
    Turn.handle_keeper_msg_admitted
      ~admission_token
      ?on_text_delta
      ?on_event
      ?on_tool_result_ready
      ?approval_gate
      ?event_bus
      ?continuation_channel
      ctx
      message
    |> complete_keeper_msg_stream_result

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

let handle_keeper_down ctx args : tool_result =
  invalidate_keeper_list_cache ();
  Turn.handle_keeper_down ctx args
