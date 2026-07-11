(** Keeper_turn_lifecycle -- keeper shutdown handlers.

    Extracted from keeper_turn.ml. Provides [handle_keeper_down]. *)

open Tool_args
open Keeper_types
open Keeper_meta_contract
open Keeper_meta_store
open Keeper_types_profile
open Keeper_keepalive

type tool_result = Keeper_types_profile.tool_result

type shutdown_request =
  { remove_meta : bool
  ; remove_session : bool
  }

type shutdown_failure_stage =
  | Pending_confirm_cleanup
  | Paused_intent_persist
  | Lane_stop
  | Meta_removal
  | Session_removal

let shutdown_failure_stage_to_wire = function
  | Pending_confirm_cleanup -> "pending_confirm_cleanup"
  | Paused_intent_persist -> "paused_intent_persist"
  | Lane_stop -> "lane_stop"
  | Meta_removal -> "meta_removal"
  | Session_removal -> "session_removal"

type remove_pending_confirms_by_target =
  Workspace.config ->
  target_type:string ->
  target_id:string option ->
  (int, string) result

let remove_pending_confirms_by_target_callback
    : remove_pending_confirms_by_target option Atomic.t
  =
  Atomic.make None

let register_remove_pending_confirms_by_target fn =
  Atomic.set remove_pending_confirms_by_target_callback (Some fn)

let remove_pending_confirms_by_target config ~target_type ~target_id =
  match Atomic.get remove_pending_confirms_by_target_callback with
  | Some remove -> remove config ~target_type ~target_id
  | None -> Error "operator pending-confirm cleanup is not registered"

let shutdown_failure
      ~stage
      ~name
      ~stopped
      ~request
      ~pending_confirms_removed
      detail
  =
  let stage_wire = shutdown_failure_stage_to_wire stage in
  Log.Keeper.error
    "keeper_down failed keeper=%s stage=%s stopped=%b pending_confirms_removed=%d: %s"
    name
    stage_wire
    stopped
    pending_confirms_removed
    detail;
  tool_result_error
    (Yojson.Safe.to_string
       (`Assoc
         [ "error", `String "keeper_down_failed"
         ; "failure_stage", `String stage_wire
         ; "detail", `String detail
         ; "name", `String name
         ; "stopped", `Bool stopped
         ; "remove_meta", `Bool request.remove_meta
         ; "remove_session", `Bool request.remove_session
         ; "pending_confirms_removed", `Int pending_confirms_removed
         ]))

let remove_keeper_meta config name =
  let path = keeper_meta_path config name in
  Workspace_utils.delete_path_result config path
  |> Result.map_error (fun message ->
       Printf.sprintf "failed to remove keeper meta %s: %s" path message)

let remove_keeper_session config (meta : keeper_meta) =
  let raw_trace_id = Keeper_id.Trace_id.to_string meta.runtime.trace_id in
  match Keeper_id.Trace_id.of_string raw_trace_id with
  | Error msg -> Error msg
  | Ok trace_id ->
    let dir = Filename.concat (session_base_dir config) (Keeper_id.Trace_id.to_string trace_id) in
    (try
       Fs_compat.remove_tree dir;
       Ok ()
     with
     | Eio.Cancel.Cancelled _ as exn -> raise exn
     | exn ->
       Error
         (Printf.sprintf
            "failed to remove keeper session %s: %s"
            dir
            (Printexc.to_string exn)))

let persist_paused_shutdown_intent config name (meta : keeper_meta) =
  let paused =
    {
      meta with
      updated_at = now_iso ();
      paused = true;
      (* This is also the fail-closed guard for [remove_meta=true]: if
         final deletion fails after the lane stops, the next supervisor pass
         must not relaunch it. *)
      latched_reason =
        Some
          (Keeper_latched_reason.Operator_paused
             { operator_actor = Keeper_latched_reason.operator_actor_keeper_down });
    }
  in
  match
    write_meta_with_merge
      ~merge:Keeper_meta_merge.caller_wins config paused
  with
  | Ok () ->
    Keeper_registry.update_meta ~base_path:config.base_path name paused;
    Ok ()
  | Error err ->
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string WriteMetaFailures)
      ~labels:
        [ "keeper", name
        ; ( "phase"
          , if Keeper_meta_store.is_version_conflict_error err
            then "keeper_down_cas_race"
            else "keeper_down" )
        ]
      ();
    Error (Printf.sprintf "failed to persist paused shutdown intent: %s" err)

let keeper_down_success ~name ~request ~pending_confirms_removed =
  tool_result_ok
    (Yojson.Safe.to_string
       (`Assoc
         [ "name", `String name
         ; "stopped", `Bool true
         ; "remove_meta", `Bool request.remove_meta
         ; "remove_session", `Bool request.remove_session
         ; "pending_confirms_removed", `Int pending_confirms_removed
         ]))

let stop_keeper_lane config name =
  stop_keepalive ~base_path:config.base_path name;
  match Keeper_registry.get ~base_path:config.base_path name with
  | None -> Ok ()
  | Some entry ->
    (match entry.phase with
     | Keeper_state_machine.Stopped
     | Keeper_state_machine.Crashed
     | Keeper_state_machine.Dead -> Ok ()
     | phase ->
       Error
         (Printf.sprintf
            "stop transition left Keeper in phase %s"
            (Keeper_state_machine.phase_to_string phase)))

let finalize_keeper_down
      config
      ~name
      ~(meta : keeper_meta)
      ~request
      ~pending_confirms_removed
  =
  match stop_keeper_lane config name with
  | Error detail ->
    shutdown_failure
      ~stage:Lane_stop
      ~name
      ~stopped:false
      ~request
      ~pending_confirms_removed
      detail
  | Ok () ->
    let meta_removal =
      if request.remove_meta then remove_keeper_meta config name else Ok ()
    in
    (match meta_removal with
     | Error detail ->
       shutdown_failure
         ~stage:Meta_removal
         ~name
         ~stopped:true
         ~request
         ~pending_confirms_removed
         detail
     | Ok () ->
       (if request.remove_meta then (
          Keeper_registry.unregister ~base_path:config.base_path name;
          (* Only a completed metadata removal drops the tool-emission
             accumulator.  A failed removal keeps the paused fallback and its
             pending emissions available for recovery. *)
          Keeper_tool_emission_hook.drop_keeper_accumulator name));
       let session_removal =
         if request.remove_session then remove_keeper_session config meta else Ok ()
       in
       (match session_removal with
        | Error detail ->
          Otel_metric_store.inc_counter
            Keeper_metrics.(to_string SessionCleanupFailures)
            ~labels:[ "keeper", name; "site", "keeper_down" ]
            ();
          shutdown_failure
            ~stage:Session_removal
            ~name
            ~stopped:true
            ~request
            ~pending_confirms_removed
            detail
        | Ok () -> keeper_down_success ~name ~request ~pending_confirms_removed))

let handle_existing_keeper config ~name ~(meta : keeper_meta) ~request =
  match
    remove_pending_confirms_by_target
      config
      ~target_type:"keeper"
      ~target_id:(Some name)
  with
  | Error detail ->
    shutdown_failure
      ~stage:Pending_confirm_cleanup
      ~name
      ~stopped:false
      ~request
      ~pending_confirms_removed:0
      detail
  | Ok pending_confirms_removed ->
    Log.Misc.info
      "[keeper_down] cleanup keeper=%s pending_confirms_removed=%d \
       remove_meta=%b remove_session=%b"
      name
      pending_confirms_removed
      request.remove_meta
      request.remove_session;
    (* Pending-confirm cleanup is an independent, idempotent mutation.  A
       later preparation failure reports its committed removal count.  The
       selected Keeper lane is not stopped until a durable paused intent is
       available as either the final state or a deletion-failure guard. *)
    (match persist_paused_shutdown_intent config name meta with
     | Error detail ->
       shutdown_failure
         ~stage:Paused_intent_persist
         ~name
         ~stopped:false
         ~request
         ~pending_confirms_removed
         detail
     | Ok () ->
       finalize_keeper_down
         config
         ~name
         ~meta
         ~request
         ~pending_confirms_removed)

let handle_keeper_down_config ~(config : Workspace.config) args : tool_result =
  let requested_name = String.trim (get_string args "name" "") in
  if not (validate_name requested_name) then
    tool_result_error
      (Printf.sprintf
         "invalid keeper name %S (must be non-empty and match \
          [A-Za-z0-9._-]+; see Keeper_config.validate_name)"
         requested_name)
  else
    let request =
      { remove_meta = get_bool args "remove_meta" false
      ; remove_session = get_bool args "remove_session" false
      }
    in
    match read_meta_resolved config requested_name with
    | Error e -> tool_result_error e
    | Ok None ->
      stop_keepalive ~base_path:config.base_path requested_name;
      tool_result_ok (Printf.sprintf "keeper already absent: %s" requested_name)
    | Ok (Some (name, m)) ->
      handle_existing_keeper config ~name ~meta:m ~request

let handle_keeper_down (ctx : _ context) args = handle_keeper_down_config ~config:ctx.config args

module For_testing = struct
  let remove_pending_confirms_by_target ~config ~target_type ~target_id =
    remove_pending_confirms_by_target config ~target_type ~target_id

  let reset_remove_pending_confirms_by_target () =
    Atomic.set remove_pending_confirms_by_target_callback None
end
