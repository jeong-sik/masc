(** Provider-attempt provenance and health helpers for keeper turn driver. *)

open Cascade_attempt_fsm

let provider_attempt_status_of_result = function
  | Ok _ -> "provider_returned"
  | Error (Agent_sdk.Error.Api (Llm_provider.Retry.Timeout _)) -> "timeout"
  | Error (Agent_sdk.Error.Provider (Llm_provider.Error.Timeout _)) -> "timeout"
  | Error _ -> "error"

let provider_attempt_exception_kind_of_result = function
  | Error (Agent_sdk.Error.Api (Llm_provider.Retry.Timeout _)) ->
    Some "outer_oas_timeout"
  | Error (Agent_sdk.Error.Provider (Llm_provider.Error.Timeout _)) ->
    Some "outer_oas_timeout"
  | Ok _ | Error _ -> None

let provider_attempt_status_and_error_of_exception = function
  | Eio.Time.Timeout -> "timeout", "Eio.Time.Timeout"
  | Eio.Cancel.Cancelled inner ->
    ( "cancelled"
    , Printf.sprintf
        "Eio.Cancel.Cancelled(%s)"
        (Printexc.to_string inner) )
  | exn -> "exception", Printexc.to_string exn

type provider_attempt_provenance =
  { model_source : string
  ; resolved_model_source : string
  ; capability_source : string
  ; fallback_authority : string
  ; provider_source_cascade : string option
  }

let base_provider_attempt_provenance =
  { model_source = "named_cascade"
  ; resolved_model_source = "cascade_catalog_binding"
  ; capability_source = "provider_config_from_cascade_catalog"
  ; fallback_authority = "declared_cascade"
  ; provider_source_cascade = None
  }

let provider_attempt_provenance_fields p =
  let base =
    [ ("model_source", `String p.model_source)
    ; ("resolved_model_source", `String p.resolved_model_source)
    ; ("capability_source", `String p.capability_source)
    ; ("fallback_authority", `String p.fallback_authority)
    ]
  in
  match p.provider_source_cascade with
  | None -> base
  | Some source_cascade ->
      ("provider_source_cascade", `String source_cascade) :: base

type provider_attempt_started_record =
  { started_provenance : provider_attempt_provenance
  ; started_is_last : bool
  ; started_per_provider_timeout_s : float option
  }

type provider_attempt_finished_record =
  { finished_provenance : provider_attempt_provenance
  ; finished_status : string
  ; finished_latency_ms : float
  ; finished_checkpoint_after_present : bool
  ; finished_error : Yojson.Safe.t
  ; finished_exception_kind : string option
  }

let provider_attempt_started_decision record =
  `Assoc
    (provider_attempt_provenance_fields record.started_provenance
     @ [
         ("is_last", `Bool record.started_is_last);
         ( "per_provider_timeout_s",
           match record.started_per_provider_timeout_s with
           | None -> `Null
           | Some timeout -> `Float timeout );
       ])
;;

let provider_attempt_finished_decision record =
  let decision_fields =
    [
      ("latency_ms", `Float record.finished_latency_ms);
      ("checkpoint_after_present", `Bool record.finished_checkpoint_after_present);
      ("error", record.finished_error);
    ]
  in
  let decision_fields =
    provider_attempt_provenance_fields record.finished_provenance @ decision_fields
  in
  let decision_fields =
    match record.finished_exception_kind with
    | None -> decision_fields
    | Some kind -> ("exception_kind", `String kind) :: decision_fields
  in
  `Assoc decision_fields
;;

let client_capacity_full_decision ~capacity_key =
  `Assoc
    [ "blocker", `String "client_capacity_full"
    ; "capacity_key", `String capacity_key
    ; "provider_attempt_started", `Bool false
    ]
;;

let success_selected_model_raw candidate =
  Some (Cascade_runtime_candidate.model_health_key candidate)

(* Error/rejected/exhausted observations intentionally leave the concrete
   selected model absent. Downstream attribution uses candidate_models or the
   cascade route for those outcomes. *)
let error_selected_model_raw = None

let health_error_kind label =
  Cascade_health_tracker.error_kind_of_string label

let record_candidate_health_success candidate ~latency_ms =
  Cascade_runtime_candidate.health_keys candidate
  |> List.iter (fun provider_key ->
    Cascade_health_tracker.record_success
      Cascade_health_tracker.global
      ~provider_key
      ~latency_ms
      ())

let record_candidate_health_rejected candidate ~reason =
  let error_kind = health_error_kind "accept_rejected" in
  Cascade_runtime_candidate.health_keys candidate
  |> List.iter (fun provider_key ->
    Cascade_health_tracker.record_rejected
      Cascade_health_tracker.global
      ~provider_key
      ~error_kind
      ~error_reason:reason
      ())

let record_candidate_health_error candidate sdk_err =
  let error_reason = Agent_sdk.Error.to_string sdk_err in
  let health_keys = Cascade_runtime_candidate.health_keys candidate in
  if sdk_error_is_hard_quota sdk_err
  then (
    let error_kind = health_error_kind "hard_quota" in
    health_keys
    |> List.iter (fun provider_key ->
      Cascade_health_tracker.record_hard_quota
        Cascade_health_tracker.global
        ~provider_key
        ~error_kind
        ~error_reason
        ()))
  else if sdk_error_is_terminal_provider_runtime_failure sdk_err
  then (
    let error_kind = health_error_kind "terminal_provider_runtime_failure" in
    health_keys
    |> List.iter (fun provider_key ->
      Cascade_health_tracker.record_terminal_failure
        Cascade_health_tracker.global
        ~provider_key
        ~error_kind
        ~error_reason
        ()))
  else
    match sdk_error_soft_rate_limited sdk_err with
    | Some retry_after_s ->
      let error_kind = health_error_kind "soft_rate_limited" in
      health_keys
      |> List.iter (fun provider_key ->
        Cascade_health_tracker.record_soft_rate_limited
          Cascade_health_tracker.global
          ~provider_key
          ?retry_after_s
          ~error_kind
          ~error_reason
          ())
    | None ->
      let error_kind = health_error_kind "provider_error" in
      health_keys
      |> List.iter (fun provider_key ->
        Cascade_health_tracker.record_failure
          Cascade_health_tracker.global
          ~provider_key
          ~error_kind
          ~error_reason
          ())

let runtime_candidate_label = "runtime"
