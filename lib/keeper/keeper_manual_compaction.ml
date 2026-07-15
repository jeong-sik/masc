open Keeper_meta_contract
type success =
  { recovery : Keeper_context_runtime.overflow_retry_recovery
  ; meta : keeper_meta
  }
type failure =
  | Unsupported_trigger of Compaction_trigger.t
  | Lifecycle of string * bool * Keeper_context_runtime.lifecycle_dispatch_error
  | Recovery of
      Keeper_post_turn.compaction_recovery_error
      * (unit, Keeper_context_runtime.lifecycle_dispatch_error) result
  | Manifest_projection of
      { operation_id : string
      ; detail : string
      ; failure_dispatch :
          (unit, Keeper_context_runtime.lifecycle_dispatch_error) result
      }
  | Metadata_projection of
      { operation_id : string
      ; detail : string
      ; failure_dispatch :
          (unit, Keeper_context_runtime.lifecycle_dispatch_error) result
      }

let project_compaction_runtime ~operation_id ~applied_at ~trigger rt =
  if Option.equal String.equal rt.last_operation_id (Some operation_id)
  then rt
  else
    { rt with
      count = rt.count + 1
    ; last_ts = applied_at
    ; last_operation_id = Some operation_id
    ; last_check_ts = applied_at
    ; last_decision =
        Keeper_compact_policy.compaction_decision_to_string
          (Keeper_compact_policy.Applied trigger)
        |> compaction_runtime_decision_of_string
    }
;;

let persist_compaction_projection ~config ~meta ~trigger recovery =
  let operation_id = recovery.Keeper_context_runtime.operation_id in
  let applied_at = Time_compat.now () in
  let project meta =
    map_compaction_rt
      (project_compaction_runtime ~operation_id ~applied_at ~trigger)
      meta
  in
  match
    Keeper_meta_store.write_meta_with_merge
      ~merge:(fun ~latest ~caller:_ -> project latest)
      config
      (project meta)
  with
  | Error _ as error -> error
  | Ok () ->
    (match Keeper_meta_store.read_meta config meta.name with
     | Ok (Some latest)
       when Option.equal String.equal
              latest.runtime.compaction_rt.last_operation_id
              (Some operation_id) ->
       Ok latest
     | Ok (Some _) -> Error "persisted compaction operation identity did not round-trip"
     | Ok None -> Error "persisted compaction metadata disappeared"
     | Error detail -> Error detail)
;;
let primary_max_context meta =
  let min_context = Keeper_config.min_keeper_context_tokens in
  let resolution = Keeper_context_runtime.resolve_max_context_resolution_of_meta meta in
  max min_context resolution.effective_budget
;;
let append_manifest ~config ~base_dir ~(meta : keeper_meta) recovery =
  match recovery.Keeper_context_runtime.compaction.trigger with
  | None -> Error "manual compaction completed without its typed trigger"
  | Some trigger ->
    let trace_id = Keeper_id.Trace_id.to_string meta.runtime.trace_id in
    let context : Keeper_runtime_manifest.turn_context =
      { manifest_keeper_name = meta.name
      ; manifest_agent_name = Some meta.agent_name
      ; manifest_trace_id = trace_id
      ; manifest_generation = Some recovery.turn_generation
      ; manifest_keeper_turn_id = Some recovery.checkpoint.turn_count
      }
    in
    let checkpoint_path =
      Keeper_checkpoint_store.oas_checkpoint_path
        ~session_dir:(Filename.concat base_dir recovery.checkpoint.session_id)
        ~session_id:recovery.checkpoint.session_id
    in
    let clock_refs =
      Keeper_runtime_manifest.clock_refs_for_context
        context
        ~event:Keeper_runtime_manifest.Context_compacted
        ~compaction_source:
          (match trigger with
           | Compaction_trigger.Manual -> "operator_manual"
           | Ratio_threshold _ | Message_count _ | Token_count _ ->
             "configured_threshold"
           | Provider_overflow _ -> "provider_overflow")
        ()
    in
    Keeper_runtime_manifest.make_for_context
      context
      ~event:Keeper_runtime_manifest.Context_compacted
      ?runtime_id:recovery.evidence.selected_runtime_id
      ~status:"compacted"
      ~decision:
        (Keeper_runtime_manifest.with_clock_refs
           ~clock_refs
           (Keeper_runtime_manifest.with_payload_role
              ~payload_role:Keeper_runtime_manifest.Checkpoint
              (`Assoc
                [ "operation_id", `String recovery.operation_id
                ; "trigger", `String (Compaction_trigger.to_label trigger)
                ; "trigger_detail", Compaction_trigger.to_detail_json trigger
                ; ( "exact_evidence"
                  , Keeper_compact_policy.compaction_evidence_to_json recovery.evidence )
                ])))
      ~checkpoint_path
      ()
    |> Keeper_runtime_manifest.append_once ~operation_id:recovery.operation_id config
;;
let run ~(config : Workspace.config) ~(meta : keeper_meta) ~trigger =
  let dispatch stage event =
    Keeper_context_runtime.dispatch_keeper_phase_event_result
      ~config
      ~origin:Keeper_registry.Requested_compaction
      ~keeper_name:meta.name
      event
    |> Result.map_error (fun error ->
      Lifecycle (stage, false, error))
  in
  let dispatch_failed reason =
    Keeper_context_runtime.dispatch_keeper_phase_event_result
      ~config
      ~origin:Keeper_registry.Requested_compaction
      ~keeper_name:meta.name
      (Keeper_state_machine.Compaction_failed { reason })
  in
  let request_dispatch =
    match trigger with
    | Compaction_trigger.Manual ->
      dispatch "operator_request" Keeper_state_machine.Operator_compact_requested
    | Ratio_threshold _ | Message_count _ | Token_count _ -> Ok ()
    | Provider_overflow _ -> Error (Unsupported_trigger trigger)
  in
  match request_dispatch with
  | Error _ as error -> error
  | Ok () ->
    (match dispatch "compaction_started" Keeper_state_machine.Compaction_started with
     | Error _ as error ->
       dispatch_failed "compaction_start_rejected" |> ignore;
       error
     | Ok () ->
       let base_dir = Keeper_types_profile.session_base_dir config in
       (match
          Keeper_context_runtime.recover_latest_checkpoint_for_overflow_retry
            ~base_dir
            ~meta
            ~trigger
            ~primary_model_max_tokens:(primary_max_context meta)
        with
        | Error error ->
          let failure_dispatch =
            dispatch_failed (Keeper_post_turn.compaction_recovery_error_to_tag error)
          in
          Error (Recovery (error, failure_dispatch))
        | Ok recovery ->
          (match append_manifest ~config ~base_dir ~meta recovery with
           | Error detail ->
             let failure_dispatch = dispatch_failed "manifest_projection_failed" in
             Error
               (Manifest_projection
                  { operation_id = recovery.operation_id; detail; failure_dispatch })
           | Ok
               ( Keeper_runtime_manifest.Appended
               | Keeper_runtime_manifest.Already_present ) ->
             (match persist_compaction_projection ~config ~meta ~trigger recovery with
              | Error detail ->
                let failure_dispatch = dispatch_failed "metadata_projection_failed" in
                Error
                  (Metadata_projection
                     { operation_id = recovery.operation_id; detail; failure_dispatch })
              | Ok meta ->
                (match
                   Keeper_context_runtime.dispatch_compaction_completed
                     ~config
                     ~keeper_name:meta.name
                     ~origin:Keeper_registry.Requested_compaction
                 with
                 | Error error ->
                   Error (Lifecycle ("compaction_completed", true, error))
                 | Ok () -> Ok { recovery; meta })))))
;;

let dispatch_result_to_string = function
  | Ok () -> "ok"
  | Error error -> Keeper_context_runtime.lifecycle_dispatch_error_to_string error
;;

let failure_to_string = function
  | Unsupported_trigger trigger ->
    Printf.sprintf "unsupported_trigger=%s" (Compaction_trigger.to_human trigger)
  | Lifecycle (stage, checkpoint_applied, error) ->
    Printf.sprintf
      "stage=%s checkpoint_applied=%b error=%s"
      stage
      checkpoint_applied
      (Keeper_context_runtime.lifecycle_dispatch_error_to_string error)
  | Recovery (error, failure_dispatch) ->
    Printf.sprintf
      "recovery=%s failure_dispatch=%s"
      (Keeper_post_turn.compaction_recovery_error_to_string error)
      (dispatch_result_to_string failure_dispatch)
  | Manifest_projection { operation_id; detail; failure_dispatch } ->
    Printf.sprintf
      "operation_id=%s checkpoint_applied=true manifest_projection=%s \
       failure_dispatch=%s"
      operation_id
      detail
      (dispatch_result_to_string failure_dispatch)
  | Metadata_projection { operation_id; detail; failure_dispatch } ->
    Printf.sprintf
      "operation_id=%s checkpoint_applied=true metadata_projection=%s failure_dispatch=%s"
      operation_id
      detail
      (dispatch_result_to_string failure_dispatch)
;;

module For_testing = struct
  let project_compaction_runtime = project_compaction_runtime
end
