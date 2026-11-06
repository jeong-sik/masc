module Decode = Masc.Tui_decode
module Receipt = Masc.Keeper_execution_receipt
module Evidence = Keeper_runtime_walk_evidence
module Request_failure = Keeper_request_failure
module Core_failure = Keeper_request_failure_core
module Internal_error = Keeper_internal_error

type cause_group =
  | Rate_limited
  | Connection
  | Provider
  | Configuration
  | Input
  | Unusable_reply
  | Effect_fenced
  | Recovery
  | Stopped
  | Server
  | Internal

type walk =
  | Walk_ended of { runtime_id : string; cause : cause_group; tried : int }
  | Walk_no_terminal of { tried : int }
  | Walk_not_captured
  | Walk_unreadable
  | Walk_absent
  | Walk_not_applicable

type trail =
  | Trail_sound
  | Trail_failed of
      { ended_at : float option
      ; last : Decode.keeper_failure_cause option
      ; walk : walk
      }

(* Agent-core's own top-level projection. A category that names no operator
   action of its own joins [Internal]. *)
let group_of_core_category : Agent_core.Error.category -> cause_group = function
  | Agent_core.Error.Api_category | Agent_core.Error.Provider_category -> Provider
  | Agent_core.Error.Config_category -> Configuration
  | Agent_core.Error.Agent_category
  | Agent_core.Error.Mcp_category
  | Agent_core.Error.Serialization_category
  | Agent_core.Error.Io_category
  | Agent_core.Error.Orchestration_category
  | Agent_core.Error.Media_category
  | Agent_core.Error.Internal_category -> Internal

let group_of_masc_error : Internal_error.masc_internal_error -> cause_group = function
  | Internal_error.Official_client_recovery_required _
  | Internal_error.Resumable_cli_session _
  | Internal_error.Gate_replay_repair_required _ -> Recovery
  | Internal_error.Runtime_exhausted _ -> Provider
  | Internal_error.Accept_rejected _
  | Internal_error.Incomplete_tool_transcript _ -> Unusable_reply
  | Internal_error.Internal_unhandled_exception _
  | Internal_error.Internal_bridge_exception _
  | Internal_error.Internal_contract_rejected _
  | Internal_error.Receipt_persistence_failed _ -> Internal
  | Internal_error.Terminal_effect_failed _
  | Internal_error.Provider_attempt_effect_fenced _
  | Internal_error.Tool_correction_lost _ -> Effect_fenced
  | Internal_error.Host_stopped_turn _ -> Stopped
  | Internal_error.Runtime_connection_closed _ -> Connection

let cause_group_of_failure (failure : Request_failure.t) =
  match failure.Request_failure.cause with
  | Request_failure.Core { Core_failure.category; message = _ } ->
      group_of_core_category category
  | Request_failure.Masc error -> group_of_masc_error error
  | Request_failure.Provider_network _ -> Connection
  | Request_failure.Provider_rate_limited _ -> Rate_limited
  | Request_failure.Context_overflow _ | Request_failure.Input_capacity -> Input
  | Request_failure.Operator_cancelled -> Stopped
  | Request_failure.Server_not_initialized
  | Request_failure.Server_restarted
  | Request_failure.Dispatch_unavailable -> Server
  | Request_failure.Keeper_meta_unresolved _
  | Request_failure.Keeper_not_registered _
  | Request_failure.Invocation_rejected _
  | Request_failure.Chat_identity_mismatch
  | Request_failure.Turn_resources_unavailable _
  | Request_failure.Runtime_selection_failed _ -> Configuration
  | Request_failure.Turn_continuation_unpersisted _
  | Request_failure.User_row_unpersisted _
  | Request_failure.Raised _ -> Internal
  | Request_failure.Gate_session_full _ -> Recovery
  | Request_failure.Reply_contract_rejected _
  | Request_failure.No_visible_reply _ -> Unusable_reply

(* A receipt records the candidate walk of one turn. Four causes end a turn at
   a runtime candidate. A heartbeat failure ends no turn, and a fiber, an
   exception or an operator interrupt need not end one at a candidate, so a
   receipt read beside them would pass for their cause. *)
let is_turn_failure : Decode.keeper_failure_cause -> bool = function
  | Decode.Keeper_failure_turn
  | Decode.Keeper_failure_provider
  | Decode.Keeper_failure_configuration
  | Decode.Keeper_failure_client_recovery -> true
  | Decode.Keeper_failure_heartbeat
  | Decode.Keeper_failure_fiber
  | Decode.Keeper_failure_exception
  | Decode.Keeper_failure_operator_interrupt -> false

(* Candidate ordinals are zero-based and may repeat across failures and the
   terminal, so candidates are counted by distinct ordinal. *)
let tried_of ~terminal_attempt (failures : Evidence.failure list) =
  let ordinals = List.map (fun (failure : Evidence.failure) -> failure.attempt) failures in
  let ordinals =
    match terminal_attempt with
    | Some attempt -> attempt :: ordinals
    | None -> ordinals
  in
  List.length (List.sort_uniq Int.compare ordinals)

let walk_of_evidence (evidence : Evidence.t) =
  match evidence.terminal with
  | Evidence.Terminal_not_observed ->
      Walk_no_terminal { tried = tried_of ~terminal_attempt:None evidence.failures }
  | Evidence.Candidate_terminal { runtime_id; attempt; failure } ->
      Walk_ended
        { runtime_id
        ; cause = cause_group_of_failure failure
        ; tried = tried_of ~terminal_attempt:(Some attempt) evidence.failures
        }

(* The walk and the time that belongs to its source: a receipt that holds
   facts about the turn gives its own time, and every other case keeps the
   time the server reported with the last failure. *)
let read_receipt ~reported_at = function
  | None -> (Walk_absent, reported_at)
  | Some (Receipt.Runtime_lane_not_observed _) -> (Walk_not_captured, reported_at)
  | Some (Receipt.Runtime_lane_unreadable _) -> (Walk_unreadable, reported_at)
  | Some (Receipt.Runtime_lane_observed { turn; evidence }) ->
      (walk_of_evidence evidence, Masc_domain.parse_iso8601_opt turn.receipt_ended_at)

let failed runtime =
  let last =
    Option.bind runtime (fun (row : Decode.keeper_runtime) -> row.kr_last_failure)
  in
  let observation =
    Option.bind runtime (fun (row : Decode.keeper_runtime) ->
        row.kr_runtime_lane_observation)
  in
  let last_cause =
    Option.map (fun (failure : Decode.keeper_failure) -> failure.kf_cause) last
  in
  let reported_at =
    Option.bind last (fun (failure : Decode.keeper_failure) -> failure.kf_at_unix)
  in
  let walk, ended_at =
    match last_cause with
    | None -> (Walk_not_applicable, reported_at)
    | Some cause ->
        if is_turn_failure cause then read_receipt ~reported_at observation
        else (Walk_not_applicable, reported_at)
  in
  Trail_failed { ended_at; last = last_cause; walk }

let of_readings ~health ~runtime =
  match health with
  | None -> Trail_sound
  | Some value -> (
      match Decode.keeper_health_reading value with
      | Decode.Health_failing -> failed runtime
      | Decode.Health_running | Decode.Health_idle | Decode.Health_offline -> Trail_sound)
