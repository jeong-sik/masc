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
  | Walk_no_candidate_failure
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

(* The two reasons that name the transport are the facts [Provider_network]
   groups as [Connection]. The rest end the walk at the provider lane. *)
let group_of_exhaustion_reason : Internal_error.runtime_exhaustion_reason -> cause_group =
  function
  | Internal_error.Connection_refused | Internal_error.Dns_failure -> Connection
  | Internal_error.No_providers_available
  | Internal_error.All_providers_failed
  | Internal_error.Candidates_filtered_after_cycles
  | Internal_error.Session_conflict
  | Internal_error.Other_detail _ -> Provider

(* [Incomplete_tool_transcript] is the stored transcript failing validation
   before any provider dispatch, so no reply exists for it to be unusable.
   [Keeper_unified_turn] routes it with the two recovery errors as a failure
   MASC produces itself, so it joins them. *)
let group_of_masc_error : Internal_error.masc_internal_error -> cause_group = function
  | Internal_error.Official_client_recovery_required _
  | Internal_error.Resumable_cli_session _
  | Internal_error.Gate_replay_repair_required _
  | Internal_error.Incomplete_tool_transcript _ -> Recovery
  | Internal_error.Runtime_exhausted { reason; _ } -> group_of_exhaustion_reason reason
  | Internal_error.Accept_rejected _ -> Unusable_reply
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

(* The walk a receipt records and the time that belongs to it. A walk that holds
   a candidate fact takes the receipt's own time. A walk that holds none keeps
   the time the server reported, because an observed walk with no failure and
   no terminal is what an ordinary successful turn stores. *)
let read_evidence ~reported_at ~receipt_at (evidence : Evidence.t) =
  match evidence.terminal, evidence.failures with
  | Evidence.Terminal_not_observed, [] -> (Walk_no_candidate_failure, reported_at)
  | Evidence.Terminal_not_observed, (_ :: _ as failures) ->
      (Walk_no_terminal { tried = tried_of ~terminal_attempt:None failures }, receipt_at)
  | Evidence.Candidate_terminal { runtime_id; attempt; failure }, failures ->
      ( Walk_ended
          { runtime_id
          ; cause = cause_group_of_failure failure
          ; tried = tried_of ~terminal_attempt:(Some attempt) failures
          }
      , receipt_at )

(* The walk and the time that belongs to its source: a receipt that holds
   facts about the turn gives its own time, and every other case keeps the
   time the server reported with the last failure. *)
let read_receipt ~reported_at = function
  | None -> (Walk_absent, reported_at)
  | Some (Receipt.Runtime_lane_not_observed _) -> (Walk_not_captured, reported_at)
  | Some (Receipt.Runtime_lane_unreadable _) -> (Walk_unreadable, reported_at)
  | Some (Receipt.Runtime_lane_observed { turn; evidence }) ->
      read_evidence ~reported_at
        ~receipt_at:(Masc_domain.parse_iso8601_opt turn.receipt_ended_at)
        evidence

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

type attempt =
  { ordinal : int
  ; runtime_id : string
  ; dispatch : Runtime_attempt_dispatch.t option
  ; cause : cause_group
  ; fault : string option
  ; terminal : bool
  }

let fault_word = function
  | None -> None
  | Some Llm_provider.Candidate_fault.Unattributed -> Some "unattributed"
  | Some Llm_provider.Candidate_fault.Unknown_after_dispatch -> Some "uncertain"
  | Some Llm_provider.Candidate_fault.Local_admission -> Some "admission"
  | Some (Llm_provider.Candidate_fault.Binding binding) ->
      match binding with
      | Llm_provider.Candidate_fault.Credential -> Some "credential"
      | Llm_provider.Candidate_fault.Account_access -> Some "account access"
      | Llm_provider.Candidate_fault.Account -> Some "account"
      | Llm_provider.Candidate_fault.Model_absent -> Some "model absent"
      | Llm_provider.Candidate_fault.Rate_limit -> Some "rate limit"
      | Llm_provider.Candidate_fault.Capacity -> Some "capacity"
      | Llm_provider.Candidate_fault.Server -> Some "server"
      | Llm_provider.Candidate_fault.Window -> Some "context window"
      | Llm_provider.Candidate_fault.Body_limit -> Some "body limit"
      | Llm_provider.Candidate_fault.Admission -> Some "admission"
      | Llm_provider.Candidate_fault.Deadline -> Some "deadline"
      | Llm_provider.Candidate_fault.Output_dialect -> Some "dialect"
      | Llm_provider.Candidate_fault.Refusal_unread -> Some "unread"

let attempts_of_runtime (runtime : Decode.keeper_runtime option) : attempt list =
  match runtime with
  | None -> []
  | Some row ->
      let last = row.kr_last_failure in
      let observation = row.kr_runtime_lane_observation in
      let last_cause = Option.map (fun (f : Decode.keeper_failure) -> f.kf_cause) last in
      match last_cause with
      | None -> []
      | Some cause when not (is_turn_failure cause) -> []
      | Some _ ->
          match observation with
          | Some (Receipt.Runtime_lane_observed { evidence; _ }) ->
              let failures = evidence.failures in
              let terminal = evidence.terminal in
              let terminal_attempt =
                match terminal with
                | Evidence.Candidate_terminal { attempt; _ } -> Some attempt
                | Evidence.Terminal_not_observed -> None
              in
              let ordinals =
                let fail_ords = List.map (fun (f : Evidence.failure) -> f.attempt) failures in
                let all_ords =
                  match terminal_attempt with
                  | Some a -> a :: fail_ords
                  | None -> fail_ords
                in
                List.sort_uniq Int.compare all_ords
              in
              List.filter_map
                (fun ord ->
                  match terminal with
                  | Evidence.Candidate_terminal { runtime_id; attempt; failure } when attempt = ord ->
                      Some
                        { ordinal = ord
                        ; runtime_id
                        ; dispatch = None
                        ; cause = cause_group_of_failure failure
                        ; fault = None
                        ; terminal = true
                        }
                  | _ ->
                      (match List.find_opt (fun (f : Evidence.failure) -> f.attempt = ord) failures with
                       | Some f ->
                           Some
                             { ordinal = ord
                             ; runtime_id = f.runtime_id
                             ; dispatch = Some f.dispatch
                             ; cause = cause_group_of_failure f.failure
                             ; fault = fault_word f.api_candidate_fault
                             ; terminal = false
                             }
                       | None -> None))
                ordinals
          | _ -> []
