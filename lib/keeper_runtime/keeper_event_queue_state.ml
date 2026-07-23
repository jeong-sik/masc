type lease_kind =
  | Single
  | Board_batch
  | Legacy_inflight

type requeue_reason =
  | Cycle_busy
  | Turn_not_scheduled
  | Rotate_now
  | Cancelled
  | Cycle_crashed
  | Registration_recovery
  | Retry_after_observed
  | Context_compaction_retry
  | Transcript_quarantine_retry
  | Approval_grant_unconsumed
  | Approval_grant_state_unavailable
    (* The two approval arms are no longer produced: the approval-wake
       settlement follows the completed turn since the 2026-07-21
       delivery-not-consumption amendment (#25539, RFC
       keeper-conversation-hitl-flow). Kept for decoding persisted
       receipts/WAL rows written before the amendment. *)

type exact_execution_terminal_cause =
  | Execution_failed_after_dispatch
  | Attempt_already_started
  | Execution_cancelled_after_dispatch
  | Execution_provenance_mismatch
  | Domain_invalid_output
  | Invalid_structural_evidence
  | Invalid_structural_source_after_dispatch
  | Commit_admission_unavailable
  | Lifecycle_transition_failed_after_dispatch
  | Checkpoint_source_changed
  | Checkpoint_persistence_failed
  | Terminal_persistence_failed

type exact_execution_terminal =
  { cause : exact_execution_terminal_cause
  ; slot_id : string
  ; call_id : string
  ; plan_fingerprint : string
  ; request_body_sha256 : string
  }

type exact_source_action = Consume_source

type exact_settlement_semantic =
  | Exact_no_compaction
  | Exact_escalate

type exact_source_outcome = Terminal of exact_execution_terminal_cause

type exact_source_disposition =
  { disposition_id : string
  ; source : Keeper_checkpoint_ref.t
  ; slot_id : string
  ; call_id : string
  ; plan_fingerprint : string
  ; request_body_sha256 : string
  ; outcome : exact_source_outcome
  ; action : exact_source_action
  ; semantic : exact_settlement_semantic
  ; prepared_at : float
  }

type exact_execution_lease_status =
  | Dispatch_uncertain
  | Terminal_quarantined of exact_execution_terminal_cause
  | Disposition_prepared of exact_source_disposition

type exact_execution_binding =
  { lease_id : string
  ; lease_sequence : int64
  ; slot_id : string
  ; call_id : string
  ; plan_fingerprint : string
  ; request_body_sha256 : string
  ; status : exact_execution_lease_status
  }

type escalation_reason =
  | Failure_judgment_requested
  | Failure_judgment_boundary_failed of { detail : string }
  | Failure_judgment_external_input_requested of
      { judge_runtime_id : string
      ; rationale : string
      }
  | Compaction_exact_lane_unconfigured of { source : Keeper_checkpoint_ref.t }
  | Compaction_exact_output_terminal of
      { source : Keeper_checkpoint_ref.t
      ; terminal : exact_execution_terminal
      }
  | Compaction_retry_exhausted of
      { attempts : int
      ; detail : string
      }
    (* RFC-0351 S0 / #25461: a failing manual compaction previously settled as
       [Requeue Context_compaction_retry] with no attempt counter, so the same
       stimulus re-entered on every heartbeat cycle (measured: 102 failures /
       104 compaction LLM calls in 74 minutes). After
       [compaction_retry_escalation_threshold] consecutive failures the
       settlement escalates instead, surfacing the blocker rather than
       re-firing. *)
  | Compaction_floor_exceeded of
      { attempts : int
      ; detail : string
      }
    (* RFC-0351 S0 / #25538: consecutive provider-overflow episodes reached
       the threshold even though compactions were committing — the committed
       savings cannot bring the context under the provider window (an
       incompressible floor; measured: an LLM plan committing 920B, 0.07% of
       the checkpoint, reset the streak forever). Distinct from
       [Compaction_retry_exhausted] so the operator can tell "compaction keeps
       failing" from "compaction succeeds but cannot help". *)
  | Transcript_quarantine_retry_exhausted of
      { attempts : int
      ; detail : string
      }
    (* #25296: a quarantined poisoned checkpoint is preserved unmodified by
       design, so every re-lease reloads the same incomplete transcript and
       the admission rejects it again — an unbounded
       [Requeue Transcript_quarantine_retry] loop. After
       [transcript_quarantine_retry_escalation_threshold] consecutive
       quarantine settlements the settlement escalates instead, surfacing the
       suspended lane to the operator rather than re-firing the full turn
       pipeline on every heartbeat. *)

type no_compaction_reason =
  | No_eligible_history
  | Invalid_structural_source
  | Structurally_unchanged
  | Checkpoint_not_reduced
  | Exact_lane_unconfigured
  | Exact_execution_terminal of exact_execution_terminal

type no_compaction =
  { source : Keeper_checkpoint_ref.t
  ; reason : no_compaction_reason
  }

type accepted_cancellation =
  { source : Keeper_event_queue.stimulus
  ; source_revision : int64
  ; owner_nonce : int
  ; operator_operation_id : string
  ; reason : string
  }

type accepted_transfer =
  { source : Keeper_event_queue.stimulus
  ; source_revision : int64
  ; owner_nonce : int
  ; operator_operation_id : string
  ; from_keeper : string
  ; to_keeper : string
  }

type source_terminal_receipt =
  | Fusion_terminal of Keeper_event_queue.fusion_completion
  | Background_job_terminal of Keeper_event_queue.bg_job_completion
  | Hitl_terminal of Keeper_event_queue.hitl_resolution

type accepted_source_terminal =
  { source : Keeper_event_queue.stimulus
  ; source_revision : int64
  ; owner_nonce : int
  ; operator_operation_id : string
  ; source_receipt : source_terminal_receipt
  }

let escalation_reason_requests_external_input = function
  | Failure_judgment_external_input_requested _ -> true
  | Failure_judgment_requested
  | Failure_judgment_boundary_failed _
  | Compaction_exact_lane_unconfigured _
  | Compaction_exact_output_terminal _
  | Compaction_retry_exhausted _
  | Compaction_floor_exceeded _
  | Transcript_quarantine_retry_exhausted _ -> false
;;

type settlement =
  | Ack
  | No_compaction of no_compaction
  | Cancel_accepted of accepted_cancellation
  | Transfer_accepted of accepted_transfer
  | Settle_from_source_terminal of accepted_source_terminal
  | Settle_exact of exact_source_disposition
  | Requeue of requeue_reason
  | Escalate of
      { reason : escalation_reason
      ; successor : Keeper_event_queue.stimulus option
      }

type lease =
  { lease_id : string
  ; sequence : int64
  ; kind : lease_kind
  ; claimed_at : float option
  ; stimuli : Keeper_event_queue.stimulus list
  }

type transition_receipt =
  { transition_id : string
  ; event_id : string
  ; lease_id : string
  ; lease_sequence : int64
  ; settled_at : float
  ; settlement : settlement
  }

type outbox_entry =
  { receipt : transition_receipt
  ; stimuli : Keeper_event_queue.stimulus list
  }

type t =
  { revision : int64
  ; next_lease_sequence : int64
  ; pending : Keeper_event_queue.t
  ; leases : lease list
  ; last_settlement : transition_receipt option
  ; transition_outbox : outbox_entry list
  ; accepted_transfer_projections : accepted_transfer list
  ; exact_execution_bindings : exact_execution_binding list
  }

type settle_result =
  | Settled of transition_receipt
  | Already_settled of transition_receipt

type transfer_projection_result =
  | Transfer_projected
  | Transfer_already_projected

let schema = "keeper.event_queue.state.v5"

let empty =
  { revision = 0L
  ; next_lease_sequence = 1L
  ; pending = Keeper_event_queue.empty
  ; leases = []
  ; last_settlement = None
  ; transition_outbox = []
  ; accepted_transfer_projections = []
  ; exact_execution_bindings = []
  }
;;

let revision state = state.revision
let next_lease_sequence state = state.next_lease_sequence
let pending state = state.pending
let leases state = state.leases
let last_settlement state = state.last_settlement
let transition_outbox state = state.transition_outbox
let accepted_transfer_projections state = state.accepted_transfer_projections
let exact_execution_binding state =
  match state.exact_execution_bindings with
  | [] -> None
  | binding :: _ -> Some binding
;;
let lease_kind (lease : lease) = lease.kind
let active_lease state =
  match state.leases with
  | [] -> None
  | lease :: _ -> Some lease
;;

let accounted_stimuli state =
  Keeper_event_queue.to_list state.pending
  @ List.concat_map (fun (lease : lease) -> lease.stimuli) state.leases
  @ List.concat_map
      (fun (entry : outbox_entry) -> entry.stimuli)
      state.transition_outbox
;;

let project_accepted_transfer (transfer : accepted_transfer) state =
  let same_operation (candidate : accepted_transfer) =
    String.equal candidate.operator_operation_id transfer.operator_operation_id
  in
  match List.find_opt same_operation state.accepted_transfer_projections with
  | Some existing when existing = transfer -> Ok (state, Transfer_already_projected)
  | Some _ -> Error "target transfer operation ID conflicts with its durable projection"
  | None ->
    let same_source (candidate : accepted_transfer) =
      Keeper_event_queue.stimulus_identity_equal candidate.source transfer.source
    in
    (match List.find_opt same_source state.accepted_transfer_projections with
     | Some _ ->
       Error "target transfer source identity was already projected by another operation"
     | None ->
       let matching =
         accounted_stimuli state
         |> List.filter (fun candidate ->
           Keeper_event_queue.stimulus_identity_equal candidate transfer.source)
       in
       (match matching with
        | [] ->
          let pending = Keeper_event_queue.enqueue state.pending transfer.source in
          Ok
            ( { state with
                pending
              ; accepted_transfer_projections =
                  state.accepted_transfer_projections @ [ transfer ]
              }
            , Transfer_projected )
        | [ existing ] when existing = transfer.source ->
          Ok
            ( { state with
                accepted_transfer_projections =
                  state.accepted_transfer_projections @ [ transfer ]
              }
            , Transfer_already_projected )
        | [ _ ] ->
          Error "target transfer source identity has a different durable snapshot"
        | _ :: _ :: _ ->
          Error "target transfer source identity is duplicated in durable state"))
;;

let mark_transition_projected ~transition_id state =
  match state.transition_outbox with
  | [ entry ] when String.equal entry.receipt.transition_id transition_id ->
    Ok
      { state with
        last_settlement = Some entry.receipt
      ; transition_outbox = []
      }
  | [] ->
    (match state.last_settlement with
     | Some receipt when String.equal receipt.transition_id transition_id -> Ok state
     | Some _ | None ->
       Error (Printf.sprintf "event queue transition not found: %s" transition_id))
  | [ _ ] ->
    Error (Printf.sprintf "event queue transition not found: %s" transition_id)
  | _ :: _ :: _ -> Error "event queue state has multiple unprojected transitions"
;;
let with_pending pending state = { state with pending }
let with_revision revision state = { state with revision }

let rec queue_contains queue stimulus =
  match Keeper_event_queue.dequeue queue with
  | None -> false
  | Some (head, rest) ->
    Keeper_event_queue.stimulus_identity_equal head stimulus
    || queue_contains rest stimulus
;;

let enqueue_if_missing queue stimulus =
  if queue_contains queue stimulus
  then queue
  else Keeper_event_queue.enqueue queue stimulus
;;

let prepend_missing stimuli queue =
  let missing =
    List.filter (fun stimulus -> not (queue_contains queue stimulus)) stimuli
  in
  Keeper_event_queue.prepend_list missing queue
;;

let append_missing stimuli queue =
  List.fold_left
    (fun pending stimulus -> enqueue_if_missing pending stimulus)
    queue
    stimuli
;;

let remove_stimuli queue stimuli =
  let should_remove stimulus =
    List.exists
      (Keeper_event_queue.stimulus_identity_equal stimulus)
      stimuli
  in
  queue
  |> Keeper_event_queue.to_list
  |> List.filter (fun stimulus -> not (should_remove stimulus))
  |> List.fold_left Keeper_event_queue.enqueue Keeper_event_queue.empty
;;

let lease_id_of_sequence sequence = Printf.sprintf "lease:%Ld" sequence

let make_lease ~kind ~claimed_at stimuli state =
  match stimuli with
  | [] -> Ok (state, None)
  | _ when Int64.equal state.next_lease_sequence Int64.max_int ->
    Error "event queue lease sequence exhausted"
  | _ ->
    let sequence = state.next_lease_sequence in
    let lease =
      { lease_id = lease_id_of_sequence sequence; sequence; kind; claimed_at; stimuli }
    in
    Ok
      ( { state with
          next_lease_sequence = Int64.succ sequence
        ; leases = state.leases @ [ lease ]
        }
      , Some lease )
;;

let lease_admission_blocked state =
  state.leases <> [] || state.transition_outbox <> []
;;

let rec dequeue_first_ready ~ready skipped pending =
  match Keeper_event_queue.dequeue pending with
  | None -> None
  | Some (stimulus, rest) when ready stimulus ->
    Some (stimulus, Keeper_event_queue.prepend_list (List.rev skipped) rest)
  | Some (stimulus, rest) ->
    dequeue_first_ready ~ready (stimulus :: skipped) rest
;;

let claim_when ~claimed_at ~ready state =
  if lease_admission_blocked state
  then Ok (state, None)
  else match dequeue_first_ready ~ready [] state.pending with
  | None -> Ok (state, None)
  | Some (stimulus, pending) ->
    make_lease
      ~kind:Single
      ~claimed_at:(Some claimed_at)
      [ stimulus ]
      { state with pending }
;;

let claim_board ~claimed_at state =
  if lease_admission_blocked state
  then Ok (state, None)
  else (
    let stimuli, pending = Keeper_event_queue.drain_board_all state.pending in
    make_lease ~kind:Board_batch ~claimed_at:(Some claimed_at) stimuli { state with pending })
;;

let add_legacy_inflight stimuli state =
  if lease_admission_blocked state
  then Error "event queue cannot migrate legacy inflight work while a lease or outbox exists"
  else (
    let stimuli = Keeper_event_queue.uniq_stimuli stimuli in
    let pending = remove_stimuli state.pending stimuli in
    make_lease ~kind:Legacy_inflight ~claimed_at:None stimuli { state with pending })
;;

let lease_kind_label = function
  | Single -> "single"
  | Board_batch -> "board_batch"
  | Legacy_inflight -> "legacy_inflight"
;;

let lease_kind_of_label = function
  | "single" -> Ok Single
  | "board_batch" -> Ok Board_batch
  | "legacy_inflight" -> Ok Legacy_inflight
  | label -> Error (Printf.sprintf "unknown event queue lease kind: %s" label)
;;

let requeue_reason_label = function
  | Cycle_busy -> "cycle_busy"
  | Turn_not_scheduled -> "turn_not_scheduled"
  | Rotate_now -> "rotate_now"
  | Cancelled -> "cancelled"
  | Cycle_crashed -> "cycle_crashed"
  | Registration_recovery -> "registration_recovery"
  | Retry_after_observed -> "retry_after_observed"
  | Context_compaction_retry -> "context_compaction_retry"
  | Transcript_quarantine_retry -> "transcript_quarantine_retry"
  | Approval_grant_unconsumed -> "approval_grant_unconsumed"
  | Approval_grant_state_unavailable -> "approval_grant_state_unavailable"
;;

let requeue_reason_of_label = function
  | "cycle_busy" -> Ok Cycle_busy
  | "turn_not_scheduled" -> Ok Turn_not_scheduled
  | "rotate_now" -> Ok Rotate_now
  | "cancelled" -> Ok Cancelled
  | "cycle_crashed" -> Ok Cycle_crashed
  | "registration_recovery" -> Ok Registration_recovery
  | "retry_after_observed" -> Ok Retry_after_observed
  | "context_compaction_retry" -> Ok Context_compaction_retry
  | "transcript_quarantine_retry" -> Ok Transcript_quarantine_retry
  | "approval_grant_unconsumed" -> Ok Approval_grant_unconsumed
  | "approval_grant_state_unavailable" -> Ok Approval_grant_state_unavailable
  | label -> Error (Printf.sprintf "unknown event queue requeue reason: %s" label)
;;

let ( let* ) = Result.bind

let exact_execution_terminal_cause_label = function
  | Execution_failed_after_dispatch -> "execution_failed_after_dispatch"
  | Attempt_already_started -> "attempt_already_started"
  | Execution_cancelled_after_dispatch -> "execution_cancelled_after_dispatch"
  | Execution_provenance_mismatch -> "execution_provenance_mismatch"
  | Domain_invalid_output -> "domain_invalid_output"
  | Invalid_structural_evidence -> "invalid_structural_evidence"
  | Invalid_structural_source_after_dispatch ->
    "invalid_structural_source_after_dispatch"
  | Commit_admission_unavailable -> "commit_admission_unavailable"
  | Lifecycle_transition_failed_after_dispatch ->
    "lifecycle_transition_failed_after_dispatch"
  | Checkpoint_source_changed -> "checkpoint_source_changed"
  | Checkpoint_persistence_failed -> "checkpoint_persistence_failed"
  | Terminal_persistence_failed -> "terminal_persistence_failed"
;;

let exact_execution_terminal_cause_of_label = function
  | "execution_failed_after_dispatch" -> Ok Execution_failed_after_dispatch
  | "attempt_already_started" -> Ok Attempt_already_started
  | "execution_cancelled_after_dispatch" ->
    Ok Execution_cancelled_after_dispatch
  | "execution_provenance_mismatch" -> Ok Execution_provenance_mismatch
  | "domain_invalid_output" -> Ok Domain_invalid_output
  | "invalid_structural_evidence" -> Ok Invalid_structural_evidence
  | "invalid_structural_source_after_dispatch" ->
    Ok Invalid_structural_source_after_dispatch
  | "commit_admission_unavailable" -> Ok Commit_admission_unavailable
  | "lifecycle_transition_failed_after_dispatch" ->
    Ok Lifecycle_transition_failed_after_dispatch
  | "checkpoint_source_changed" -> Ok Checkpoint_source_changed
  | "checkpoint_persistence_failed" -> Ok Checkpoint_persistence_failed
  | "terminal_persistence_failed" -> Ok Terminal_persistence_failed
  | label -> Error (Printf.sprintf "unknown exact execution terminal cause: %s" label)
;;

let validate_exact_execution_terminal (terminal : exact_execution_terminal) =
  let validate_identity field value =
    let trimmed = String.trim value in
    if String.equal trimmed ""
    then Error (Printf.sprintf "exact execution terminal %s must not be blank" field)
    else if not (String.equal trimmed value)
    then Error (Printf.sprintf "exact execution terminal %s must be canonical" field)
    else Ok ()
  in
  let* () = validate_identity "slot_id" terminal.slot_id in
  let* () = validate_identity "call_id" terminal.call_id in
  let* () = validate_identity "plan_fingerprint" terminal.plan_fingerprint in
  validate_identity "request_body_sha256" terminal.request_body_sha256
;;

let exact_execution_terminal_to_string terminal =
  Printf.sprintf
    "%s:slot_id=%s:call_id=%s:plan_fingerprint=%s:request_body_sha256=%s"
    (exact_execution_terminal_cause_label terminal.cause)
    terminal.slot_id
    terminal.call_id
    terminal.plan_fingerprint
    terminal.request_body_sha256
;;

let checkpoint_source_reason_detail_to_yojson (source : Keeper_checkpoint_ref.t) =
  `Assoc
    [ "trace_id", `String (Keeper_id.Trace_id.to_string source.trace_id)
    ; "generation", `Int source.generation
    ; "turn_count", `Int source.turn_count
    ; "sha256", `String source.sha256
    ]
;;

let escalation_reason_label = function
  | Failure_judgment_requested -> "failure_judgment_requested"
  | Failure_judgment_boundary_failed _ -> "failure_judgment_boundary_failed"
  | Failure_judgment_external_input_requested _ ->
    "failure_judgment_external_input_requested"
  | Compaction_exact_lane_unconfigured _ ->
    "compaction_exact_lane_unconfigured"
  | Compaction_exact_output_terminal _ -> "compaction_exact_output_terminal"
  | Compaction_retry_exhausted _ -> "compaction_retry_exhausted"
  | Compaction_floor_exceeded _ -> "compaction_floor_exceeded"
  | Transcript_quarantine_retry_exhausted _ ->
    "transcript_quarantine_retry_exhausted"
;;

let escalation_reason_detail_to_yojson = function
  | Failure_judgment_requested -> `Null
  | Failure_judgment_boundary_failed { detail } ->
    `Assoc [ "detail", `String detail ]
  | Failure_judgment_external_input_requested { judge_runtime_id; rationale } ->
    `Assoc
      [ "judge_runtime_id", `String judge_runtime_id
      ; "rationale", `String rationale
      ]
  | Compaction_exact_lane_unconfigured { source } ->
    checkpoint_source_reason_detail_to_yojson source
  | Compaction_exact_output_terminal { source; terminal } ->
    `Assoc
      [ "source", checkpoint_source_reason_detail_to_yojson source
      ; "cause", `String (exact_execution_terminal_cause_label terminal.cause)
      ; "slot_id", `String terminal.slot_id
      ; "call_id", `String terminal.call_id
      ; "plan_fingerprint", `String terminal.plan_fingerprint
      ; "request_body_sha256", `String terminal.request_body_sha256
      ]
  | Compaction_retry_exhausted { attempts; detail } ->
    `Assoc [ "attempts", `Int attempts; "detail", `String detail ]
  | Compaction_floor_exceeded { attempts; detail } ->
    `Assoc [ "attempts", `Int attempts; "detail", `String detail ]
  | Transcript_quarantine_retry_exhausted { attempts; detail } ->
    `Assoc [ "attempts", `Int attempts; "detail", `String detail ]
;;

let required_nonempty_reason_string ~context name fields =
  match List.assoc_opt name fields with
  | Some (`String value) ->
    let value = String.trim value in
    if String.equal value ""
    then Error (Printf.sprintf "%s.%s must not be empty" context name)
    else Ok value
  | Some _ -> Error (Printf.sprintf "%s.%s must be a string" context name)
  | None -> Error (Printf.sprintf "%s.%s is required" context name)
;;

let exact_reason_fields ~context expected fields =
  let actual = List.map fst fields |> List.sort String.compare in
  let expected = List.sort String.compare expected in
  if actual = expected
  then Ok ()
  else
    Error
      (Printf.sprintf
         "%s fields must be exactly [%s], got [%s]"
         context
         (String.concat "," expected)
         (String.concat "," actual))
;;

let required_reason_int ~context name fields =
  match List.assoc_opt name fields with
  | Some (`Int value) -> Ok value
  | Some _ -> Error (Printf.sprintf "%s.%s must be an int" context name)
  | None -> Error (Printf.sprintf "%s.%s is required" context name)
;;

let checkpoint_source_of_reason_fields ~context fields =
  let* () =
    exact_reason_fields
      ~context
      [ "trace_id"; "generation"; "turn_count"; "sha256" ]
      fields
  in
  let* trace_id_value = required_nonempty_reason_string ~context "trace_id" fields in
  let* trace_id =
    Keeper_id.Trace_id.of_string trace_id_value
    |> Result.map_error (fun detail -> Printf.sprintf "%s.trace_id: %s" context detail)
  in
  let* generation = required_reason_int ~context "generation" fields in
  let* turn_count = required_reason_int ~context "turn_count" fields in
  let* sha256 = required_nonempty_reason_string ~context "sha256" fields in
  Keeper_checkpoint_ref.of_persisted ~trace_id ~generation ~turn_count ~sha256
  |> Result.map_error (function
    | Keeper_checkpoint_ref.Negative_generation value ->
      Printf.sprintf "%s.generation must not be negative: %d" context value
    | Negative_turn_count value ->
      Printf.sprintf "%s.turn_count must not be negative: %d" context value
    | Invalid_sha256 value ->
      Printf.sprintf "%s.sha256 is invalid: %s" context value)
;;

let escalation_reason_of_wire ~label ~detail_json =
  match label, detail_json with
  | "failure_judgment_requested", `Null -> Ok Failure_judgment_requested
  | "compaction_exact_output_terminal", `Assoc fields ->
    let context = "compaction_exact_output_terminal" in
    let* () =
      exact_reason_fields
        ~context
        [ "source"
        ; "cause"
        ; "slot_id"
        ; "call_id"
        ; "plan_fingerprint"
        ; "request_body_sha256"
        ]
        fields
    in
    let* source_json =
      match List.assoc_opt "source" fields with
      | Some value -> Ok value
      | None -> Error (context ^ ".source is required")
    in
    let* source_fields =
      match source_json with
      | `Assoc fields -> Ok fields
      | _ -> Error (context ^ ".source must be an object")
    in
    let* source =
      checkpoint_source_of_reason_fields
        ~context:(context ^ ".source")
        source_fields
    in
    let* cause_label = required_nonempty_reason_string ~context "cause" fields in
    let* cause = exact_execution_terminal_cause_of_label cause_label in
    let* slot_id = required_nonempty_reason_string ~context "slot_id" fields in
    let* call_id = required_nonempty_reason_string ~context "call_id" fields in
    let* plan_fingerprint =
      required_nonempty_reason_string ~context "plan_fingerprint" fields
    in
    let* request_body_sha256 =
      required_nonempty_reason_string ~context "request_body_sha256" fields
    in
    let terminal =
      { cause; slot_id; call_id; plan_fingerprint; request_body_sha256 }
    in
    let* () = validate_exact_execution_terminal terminal in
    Ok (Compaction_exact_output_terminal { source; terminal })
  | "compaction_exact_lane_unconfigured", `Assoc fields ->
    let* source =
      checkpoint_source_of_reason_fields
        ~context:"compaction_exact_lane_unconfigured"
        fields
    in
    Ok (Compaction_exact_lane_unconfigured { source })
  | "failure_judgment_boundary_failed", `Assoc fields ->
    let* () =
      exact_reason_fields
        ~context:"failure_judgment_boundary_failed"
        [ "detail" ]
        fields
    in
    let* detail =
      required_nonempty_reason_string
        ~context:"failure_judgment_boundary_failed"
        "detail"
        fields
    in
    Ok (Failure_judgment_boundary_failed { detail })
  | "compaction_retry_exhausted", `Assoc fields ->
    let* () =
      exact_reason_fields
        ~context:"compaction_retry_exhausted"
        [ "attempts"; "detail" ]
        fields
    in
    let* attempts =
      match List.assoc_opt "attempts" fields with
      | Some (`Int value) when value > 0 -> Ok value
      | Some (`Int _) ->
        Error "compaction_retry_exhausted.attempts must be positive"
      | Some _ -> Error "compaction_retry_exhausted.attempts must be an int"
      | None -> Error "compaction_retry_exhausted.attempts is required"
    in
    let* detail =
      required_nonempty_reason_string
        ~context:"compaction_retry_exhausted"
        "detail"
        fields
    in
    Ok (Compaction_retry_exhausted { attempts; detail })
  | "compaction_floor_exceeded", `Assoc fields ->
    let* () =
      exact_reason_fields
        ~context:"compaction_floor_exceeded"
        [ "attempts"; "detail" ]
        fields
    in
    let* attempts =
      match List.assoc_opt "attempts" fields with
      | Some (`Int value) when value > 0 -> Ok value
      | Some (`Int _) ->
        Error "compaction_floor_exceeded.attempts must be positive"
      | Some _ -> Error "compaction_floor_exceeded.attempts must be an int"
      | None -> Error "compaction_floor_exceeded.attempts is required"
    in
    let* detail =
      required_nonempty_reason_string
        ~context:"compaction_floor_exceeded"
        "detail"
        fields
    in
    Ok (Compaction_floor_exceeded { attempts; detail })
  | "transcript_quarantine_retry_exhausted", `Assoc fields ->
    let* () =
      exact_reason_fields
        ~context:"transcript_quarantine_retry_exhausted"
        [ "attempts"; "detail" ]
        fields
    in
    let* attempts =
      match List.assoc_opt "attempts" fields with
      | Some (`Int value) when value > 0 -> Ok value
      | Some (`Int _) ->
        Error "transcript_quarantine_retry_exhausted.attempts must be positive"
      | Some _ ->
        Error "transcript_quarantine_retry_exhausted.attempts must be an int"
      | None ->
        Error "transcript_quarantine_retry_exhausted.attempts is required"
    in
    let* detail =
      required_nonempty_reason_string
        ~context:"transcript_quarantine_retry_exhausted"
        "detail"
        fields
    in
    Ok (Transcript_quarantine_retry_exhausted { attempts; detail })
  | "failure_judgment_external_input_requested", `Assoc fields ->
    let* () =
      exact_reason_fields
        ~context:"failure_judgment_external_input_requested"
        [ "judge_runtime_id"; "rationale" ]
        fields
    in
    let* judge_runtime_id =
      required_nonempty_reason_string
        ~context:"failure_judgment_external_input_requested"
        "judge_runtime_id"
        fields
    in
    let* rationale =
      required_nonempty_reason_string
        ~context:"failure_judgment_external_input_requested"
        "rationale"
        fields
    in
    Ok (Failure_judgment_external_input_requested { judge_runtime_id; rationale })
  | "failure_judgment_requested", _ ->
    Error (Printf.sprintf "%s reason_detail must be null" label)
  | "compaction_exact_output_terminal", _ ->
    Error (Printf.sprintf "%s reason_detail must be an object" label)
  | ( "failure_judgment_boundary_failed"
    | "failure_judgment_external_input_requested"
    | "compaction_exact_lane_unconfigured" ), _ ->
    Error (Printf.sprintf "%s reason_detail must be an object" label)
  | unknown, _ ->
    Error (Printf.sprintf "unknown event queue escalation reason: %s" unknown)
;;

let settlement_kind_label = function
  | Ack -> "ack"
  | No_compaction _ -> "no_compaction"
  | Cancel_accepted _ -> "cancel_accepted"
  | Transfer_accepted _ -> "transfer_accepted"
  | Settle_from_source_terminal _ -> "settle_from_source_terminal"
  | Settle_exact _ -> "settle_exact"
  | Requeue _ -> "requeue"
  | Escalate _ -> "escalate"
;;

let transition_id (lease : lease) settlement =
  match settlement with
  | Settle_exact disposition ->
    Printf.sprintf "%s:settle_exact:%s" lease.lease_id disposition.disposition_id
  | Ack
  | No_compaction _
  | Cancel_accepted _
  | Transfer_accepted _
  | Settle_from_source_terminal _
  | Requeue _
  | Escalate _ ->
    Printf.sprintf "%s:%s" lease.lease_id (settlement_kind_label settlement)
;;

let event_id_of_transition transition_id =
  "keeper-event-queue-transition:" ^ transition_id
;;

let successor_equal left right =
  match left, right with
  | None, None -> true
  | Some left, Some right ->
    Keeper_event_queue.stimulus_identity_equal left right
  | None, Some _ | Some _, None -> false
;;

let settlement_equal left right =
  match left, right with
  | Ack, Ack -> true
  | No_compaction left, No_compaction right ->
    Keeper_checkpoint_ref.equal left.source right.source
    && left.reason = right.reason
  | Cancel_accepted left, Cancel_accepted right -> left = right
  | Transfer_accepted left, Transfer_accepted right -> left = right
  | Settle_from_source_terminal left, Settle_from_source_terminal right ->
    left = right
  | Settle_exact left, Settle_exact right -> left = right
  | Requeue left, Requeue right -> left = right
  | ( Escalate { reason = left_reason; successor = left_successor }
    , Escalate { reason = right_reason; successor = right_successor } ) ->
    left_reason = right_reason
    && successor_equal left_successor right_successor
  | _ -> false
;;

let transition_receipt_equal left right =
  String.equal left.transition_id right.transition_id
  && String.equal left.event_id right.event_id
  && String.equal left.lease_id right.lease_id
  && Int64.equal left.lease_sequence right.lease_sequence
  && Float.equal left.settled_at right.settled_at
  && left.settlement = right.settlement
;;

let validate_accepted_cancellation (cancellation : accepted_cancellation) =
  if String.equal (String.trim cancellation.source.post_id) ""
  then Error "accepted cancellation source post id must not be empty"
  else if Int64.compare cancellation.source_revision 0L < 0
  then Error "accepted cancellation source revision must not be negative"
  else if cancellation.owner_nonce < 0
  then Error "accepted cancellation owner generation must not be negative"
  else if String.equal (String.trim cancellation.operator_operation_id) ""
  then Error "accepted cancellation operator operation id must not be empty"
  else if String.equal (String.trim cancellation.reason) ""
  then Error "accepted cancellation reason must not be empty"
  else Ok ()
;;

let validate_accepted_transfer (transfer : accepted_transfer) =
  if String.equal (String.trim transfer.source.post_id) ""
  then Error "accepted transfer source post id must not be empty"
  else if Int64.compare transfer.source_revision 0L < 0
  then Error "accepted transfer source revision must not be negative"
  else if transfer.owner_nonce < 0
  then Error "accepted transfer owner generation must not be negative"
  else if String.equal (String.trim transfer.operator_operation_id) ""
  then Error "accepted transfer operator operation id must not be empty"
  else if String.equal (String.trim transfer.from_keeper) ""
  then Error "accepted transfer source Keeper must not be empty"
  else if String.equal (String.trim transfer.to_keeper) ""
  then Error "accepted transfer target Keeper must not be empty"
  else if String.equal transfer.from_keeper transfer.to_keeper
  then Error "accepted transfer source and target Keepers must differ"
  else Ok ()
;;

let source_terminal_receipt_of_stimulus source =
  match source.Keeper_event_queue.payload with
  | Keeper_event_queue.Fusion_completed completion ->
    Ok (Fusion_terminal completion)
  | Keeper_event_queue.Bg_completed completion ->
    Ok (Background_job_terminal completion)
  | Keeper_event_queue.Hitl_resolved resolution -> Ok (Hitl_terminal resolution)
  | Keeper_event_queue.Board_signal _
  | Keeper_event_queue.Board_attention _
  | Keeper_event_queue.Bootstrap
  | Keeper_event_queue.Schedule_due _
  | Keeper_event_queue.Connector_attention _
  | Keeper_event_queue.Failure_judgment _
  | Keeper_event_queue.Manual_compaction_requested
  | Keeper_event_queue.Goal_assigned _ ->
    Error "source event does not carry a typed terminal receipt"
;;

let validate_accepted_source_terminal source_terminal =
  if String.equal (String.trim source_terminal.source.post_id) ""
  then Error "source-terminal settlement source post id must not be empty"
  else if Int64.compare source_terminal.source_revision 0L < 0
  then Error "source-terminal settlement source revision must not be negative"
  else if source_terminal.owner_nonce < 0
  then Error "source-terminal settlement owner generation must not be negative"
  else if String.equal (String.trim source_terminal.operator_operation_id) ""
  then Error "source-terminal settlement operation id must not be empty"
  else
    let* receipt = source_terminal_receipt_of_stimulus source_terminal.source in
    if receipt = source_terminal.source_receipt
    then Ok ()
    else Error "source-terminal settlement receipt does not match source payload"
;;

let checkpoint_ref_identity (reference : Keeper_checkpoint_ref.t) =
  String.concat
    "\000"
    [ Keeper_id.Trace_id.to_string reference.trace_id
    ; string_of_int reference.generation
    ; string_of_int reference.turn_count
    ; reference.sha256
    ]
;;

let exact_source_outcome_identity = function
  | Terminal cause ->
    "terminal\000" ^ exact_execution_terminal_cause_label cause
;;

let exact_source_action_identity Consume_source = "consume_source"

let exact_settlement_semantic_label = function
  | Exact_no_compaction -> "no_compaction"
  | Exact_escalate -> "escalate"
;;

let exact_source_disposition_id_of_fields
      ~source
      ~slot_id
      ~call_id
      ~plan_fingerprint
      ~request_body_sha256
      ~outcome
      ~action
      ~semantic
      ~prepared_at:_
  =
  String.concat
    "\000"
    [ "keeper.exact_source_disposition.v1"
    ; checkpoint_ref_identity source
    ; slot_id
    ; call_id
    ; plan_fingerprint
    ; request_body_sha256
    ; exact_source_outcome_identity outcome
    ; exact_source_action_identity action
    ; exact_settlement_semantic_label semantic
    ]
  |> Digestif.SHA256.digest_string
  |> Digestif.SHA256.to_hex
;;

let validate_exact_source_disposition
      (disposition : exact_source_disposition)
  =
  let terminal =
    match disposition.outcome with
    | Terminal cause ->
      { cause
      ; slot_id = disposition.slot_id
      ; call_id = disposition.call_id
      ; plan_fingerprint = disposition.plan_fingerprint
      ; request_body_sha256 = disposition.request_body_sha256
      }
  in
  let* () = validate_exact_execution_terminal terminal in
  let expected_id =
    exact_source_disposition_id_of_fields
      ~source:disposition.source
      ~slot_id:disposition.slot_id
      ~call_id:disposition.call_id
      ~plan_fingerprint:disposition.plan_fingerprint
      ~request_body_sha256:disposition.request_body_sha256
      ~outcome:disposition.outcome
      ~action:disposition.action
      ~semantic:disposition.semantic
      ~prepared_at:disposition.prepared_at
  in
  if not (Float.is_finite disposition.prepared_at)
  then Error "exact source disposition preparation time must be finite"
  else if not (String.equal disposition.disposition_id expected_id)
  then Error "exact source disposition id does not match its immutable fields"
  else
    match disposition.semantic, disposition.action with
    | (Exact_no_compaction | Exact_escalate), Consume_source ->
      Ok ()
;;

let validate_settlement = function
  | Ack | Requeue _ -> Ok ()
  | No_compaction { reason = Exact_execution_terminal terminal; _ } ->
    validate_exact_execution_terminal terminal
  | No_compaction
      { reason =
          ( No_eligible_history
          | Invalid_structural_source
          | Structurally_unchanged
          | Checkpoint_not_reduced
          | Exact_lane_unconfigured )
      ; _
      } ->
    Ok ()
  | Cancel_accepted cancellation -> validate_accepted_cancellation cancellation
  | Transfer_accepted transfer -> validate_accepted_transfer transfer
  | Settle_from_source_terminal source_terminal ->
    validate_accepted_source_terminal source_terminal
  | Settle_exact disposition -> validate_exact_source_disposition disposition
  | Escalate
      { reason = Failure_judgment_requested
      ; successor =
          Some
            { Keeper_event_queue.payload =
                Keeper_event_queue.Failure_judgment _
            ; _
            }
      } ->
    Ok ()
  | Escalate
      { reason = Failure_judgment_boundary_failed { detail }
      ; successor = None
      }
    when String.equal (String.trim detail) "" ->
    Error "failure judgment boundary failure detail must not be empty"
  | Escalate
      { reason =
          Failure_judgment_external_input_requested
            { judge_runtime_id; rationale }
      ; successor = None
      }
    when
      String.equal (String.trim judge_runtime_id) ""
      || String.equal (String.trim rationale) "" ->
    Error "external-input failure judgment evidence must not be empty"
  | Escalate
      { reason =
          ( Failure_judgment_boundary_failed _
          | Failure_judgment_external_input_requested _ )
      ; successor = None
      } ->
    Ok ()
  | Escalate { reason = Failure_judgment_requested; successor = None } ->
    Error "failure judgment request settlement requires a typed successor"
  | Escalate { reason = Failure_judgment_requested; successor = Some _ } ->
    Error "failure judgment request successor has the wrong payload kind"
  | Escalate { reason = Failure_judgment_boundary_failed _; successor = Some _ } ->
    Error "failure judgment boundary failure must not enqueue a successor"
  | Escalate
      { reason = Failure_judgment_external_input_requested _; successor = Some _ }
    ->
    Error "external-input failure judgment must not enqueue a successor"
  | Escalate { reason = Compaction_retry_exhausted _; successor = None } -> Ok ()
  | Escalate { reason = Compaction_retry_exhausted _; successor = Some _ } ->
    Error "compaction retry exhaustion must not enqueue a successor"
  | Escalate { reason = Compaction_floor_exceeded _; successor = None } -> Ok ()
  | Escalate { reason = Compaction_floor_exceeded _; successor = Some _ } ->
    Error "compaction floor exhaustion must not enqueue a successor"
  | Escalate
      { reason =
          ( Compaction_exact_lane_unconfigured _
          )
      ; successor = None
      } ->
    Ok ()
  | Escalate
      { reason = Compaction_exact_output_terminal { terminal; _ }
      ; successor = None
      } ->
    validate_exact_execution_terminal terminal
  | Escalate
      { reason =
          ( Compaction_exact_lane_unconfigured _
          )
      ; successor = Some _
      } ->
    Error "terminal exact-output compaction must not enqueue a successor"
  | Escalate
      { reason = Compaction_exact_output_terminal _; successor = Some _ } ->
    Error "terminal exact-output compaction must not enqueue a successor"
  | Escalate { reason = Transcript_quarantine_retry_exhausted _; successor = None }
    ->
    Ok ()
  | Escalate
      { reason = Transcript_quarantine_retry_exhausted _; successor = Some _ } ->
    Error "transcript quarantine retry exhaustion must not enqueue a successor"
;;

(* Pure receipt-vs-stimuli invariant. Kept in ONE place so the live settle
   path (via [validate_settlement_for_lease]) and the persist decode boundary
   (via [outbox_entry_of_yojson]) enforce the same closed settlement/source
   rules. *)
let validate_settlement_for_stimuli settlement stimuli =
  match settlement, stimuli with
  | No_compaction _,
    [ { Keeper_event_queue.payload =
          Keeper_event_queue.Manual_compaction_requested
      ; _
      } ] ->
    Ok ()
  | No_compaction _, _ ->
    Error
      "no-compaction settlement requires one manual-compaction request stimulus"
  | Cancel_accepted cancellation, [ source ] when cancellation.source = source ->
    Ok ()
  | Cancel_accepted _, [ _ ] ->
    Error "accepted cancellation source does not match its exact event stimulus"
  | Cancel_accepted _, _ ->
    Error "accepted cancellation requires exactly one accepted event stimulus"
  | Transfer_accepted transfer, [ source ] when transfer.source = source -> Ok ()
  | Transfer_accepted _, [ _ ] ->
    Error "accepted transfer source does not match its exact event stimulus"
  | Transfer_accepted _, _ ->
    Error "accepted transfer requires exactly one accepted event stimulus"
  | Settle_from_source_terminal source_terminal, [ source ]
    when source_terminal.source = source -> Ok ()
  | Settle_from_source_terminal _, [ _ ] ->
    Error "source-terminal receipt does not match its exact event stimulus"
  | Settle_from_source_terminal _, _ ->
    Error "source-terminal settlement requires exactly one accepted event stimulus"
  | (Ack | Settle_exact _ | Requeue _ | Escalate _), _ -> Ok ()
;;

let validate_settlement_for_lease settlement (lease : lease) =
  validate_settlement_for_stimuli settlement lease.stimuli
;;

let receipt_for_lease ~settled_at ~settlement (lease : lease) =
  let transition_id = transition_id lease settlement in
  { transition_id
  ; event_id = event_id_of_transition transition_id
  ; lease_id = lease.lease_id
  ; lease_sequence = lease.sequence
  ; settled_at
  ; settlement
  }
;;

let find_prior_receipt lease_id state =
  match state.transition_outbox with
  | [ entry ] when String.equal entry.receipt.lease_id lease_id -> Some entry.receipt
  | [] | [ _ ] ->
    (match state.last_settlement with
     | Some receipt when String.equal receipt.lease_id lease_id -> Some receipt
     | Some _ | None -> None)
  | _ :: _ :: _ -> None
;;

let remove_lease lease_id leases =
  List.filter
    (fun (lease : lease) -> not (String.equal lease.lease_id lease_id))
    leases
;;

let committed_lease (lease : lease) state =
  List.find_opt
    (fun (current : lease) -> String.equal current.lease_id lease.lease_id)
    state.leases
;;

let lease_equal (left : lease) (right : lease) =
  Int64.equal left.sequence right.sequence
  && String.equal left.lease_id right.lease_id
  && left.kind = right.kind
  && List.length left.stimuli = List.length right.stimuli
  && List.for_all2 Keeper_event_queue.stimulus_identity_equal left.stimuli right.stimuli
;;

let binding_for_lease (lease : lease) state =
  List.find_opt
    (fun (binding : exact_execution_binding) ->
       String.equal binding.lease_id lease.lease_id
       && Int64.equal binding.lease_sequence lease.sequence)
    state.exact_execution_bindings
;;

let binding_call_identity_equal binding ~slot_id ~call_id =
  String.equal binding.slot_id slot_id && String.equal binding.call_id call_id
;;

let binding_identity_equal
      binding
      ~slot_id
      ~call_id
      ~plan_fingerprint
      ~request_body_sha256
  =
  binding_call_identity_equal binding ~slot_id ~call_id
  && String.equal binding.plan_fingerprint plan_fingerprint
  && String.equal binding.request_body_sha256 request_body_sha256
;;

let identity_bound_nonterminal_settlement = function
  | Ack -> true
  | Requeue Context_compaction_retry -> true
  | Escalate { reason = Compaction_floor_exceeded _; successor = None } -> true
  | Escalate
      { reason = Failure_judgment_requested
      ; successor =
          Some
            { Keeper_event_queue.payload = Keeper_event_queue.Failure_judgment _
            ; _
            }
      } ->
    true
  | No_compaction _
  | Cancel_accepted _
  | Transfer_accepted _
  | Settle_from_source_terminal _
  | Settle_exact _
  | Requeue _
  | Escalate _ ->
    false
;;

let validate_bound_settlement binding settlement =
  match binding.status, settlement with
  | Disposition_prepared disposition, Settle_exact requested
    when disposition = requested -> Ok ()
  | Disposition_prepared _, Settle_exact _ ->
    Error "exact source disposition proof conflicts with its durable binding"
  | Dispatch_uncertain, settlement
    when identity_bound_nonterminal_settlement settlement -> Ok ()
  | Dispatch_uncertain, _ ->
    Error
      (Printf.sprintf
         "exact execution lease %s call %s requires an identity-bound nonterminal settlement or a prepared full source disposition"
         binding.lease_id
         binding.call_id)
  | Terminal_quarantined _, _ ->
    Error
      (Printf.sprintf
         "quarantined exact execution lease %s call %s requires a prepared full source disposition"
         binding.lease_id
         binding.call_id)
  | Disposition_prepared _, _ ->
    Error
      (Printf.sprintf
         "exact execution lease %s call %s requires Settle_exact with its full durable proof"
         binding.lease_id
         binding.call_id)
;;

let validate_binding_arguments
      ~(lease : lease)
      ~slot_id
      ~call_id
      ~plan_fingerprint
      ~request_body_sha256
  =
  if String.trim slot_id = ""
  then Error "exact execution slot id must not be empty"
  else if String.trim call_id = ""
  then Error "exact execution call id must not be empty"
  else if String.trim plan_fingerprint = ""
  then Error "exact execution plan fingerprint must not be empty"
  else if String.trim request_body_sha256 = ""
  then Error "exact execution request body sha256 must not be empty"
  else if Int64.compare lease.sequence 1L < 0
  then Error "exact execution lease sequence must be positive"
  else if not (String.equal lease.lease_id (lease_id_of_sequence lease.sequence))
  then Error "exact execution lease id does not match its sequence"
  else Ok ()
;;

let bind_exact_execution
      ~(lease : lease)
      ~slot_id
      ~call_id
      ~plan_fingerprint
      ~request_body_sha256
      state
  =
  let* () =
    validate_binding_arguments
      ~lease
      ~slot_id
      ~call_id
      ~plan_fingerprint
      ~request_body_sha256
  in
  let* () =
    match committed_lease lease state with
    | Some committed when lease_equal committed lease -> Ok ()
    | Some _ -> Error (Printf.sprintf "event queue lease payload conflict: %s" lease.lease_id)
    | None -> Error (Printf.sprintf "event queue lease not found: %s" lease.lease_id)
  in
  match state.exact_execution_bindings with
  | [] ->
    Ok
      { state with
        exact_execution_bindings =
          [ { lease_id = lease.lease_id
            ; lease_sequence = lease.sequence
            ; slot_id
            ; call_id
            ; plan_fingerprint
            ; request_body_sha256
            ; status = Dispatch_uncertain
            }
          ]
      }
  | [ binding ]
    when String.equal binding.lease_id lease.lease_id
         && Int64.equal binding.lease_sequence lease.sequence
         && binding_identity_equal
              binding
              ~slot_id
              ~call_id
              ~plan_fingerprint
              ~request_body_sha256 ->
    (match binding.status with
     | Dispatch_uncertain -> Ok state
     | Terminal_quarantined _ ->
       Error
         (Printf.sprintf
            "exact execution lease %s call %s is already terminally quarantined"
            lease.lease_id
            call_id)
     | Disposition_prepared _ ->
       Error
         (Printf.sprintf
            "exact execution lease %s call %s already owns a source disposition"
            lease.lease_id
            call_id))
  | [ binding ] ->
    Error
      (Printf.sprintf
         "exact execution binding conflict: lease %s call %s is already bound"
         binding.lease_id
         binding.call_id)
  | _ :: _ :: _ -> Error "event queue state contains multiple exact execution bindings"
;;

(* TEL-OK: pure state transition; the persistence boundary and caller own
   release telemetry. *)
let release_exact_execution_before_dispatch
      ~(lease : lease)
      ~slot_id
      ~call_id
      ~plan_fingerprint
      ~request_body_sha256
      state
  =
  let* () =
    validate_binding_arguments
      ~lease
      ~slot_id
      ~call_id
      ~plan_fingerprint
      ~request_body_sha256
  in
  match binding_for_lease lease state with
  | None -> Error (Printf.sprintf "exact execution lease is not bound: %s" lease.lease_id)
  | Some binding
    when not
           (binding_identity_equal
              binding
              ~slot_id
              ~call_id
              ~plan_fingerprint
              ~request_body_sha256) ->
    Error (Printf.sprintf "exact execution binding identity conflict: %s" lease.lease_id)
  | Some { status = Terminal_quarantined _; _ } ->
    Error
      (Printf.sprintf
         "terminally quarantined exact execution lease cannot be released: %s"
         lease.lease_id)
  | Some
      { status = Disposition_prepared _; _ } ->
    Error
      (Printf.sprintf
         "source-disposition exact execution lease cannot be released: %s"
         lease.lease_id)
  | Some { status = Dispatch_uncertain; _ } ->
    Ok { state with exact_execution_bindings = [] }
;;

let quarantine_exact_execution
      ~(lease : lease)
      ~(terminal : exact_execution_terminal)
      state
  =
  let* () =
    validate_binding_arguments
      ~lease
      ~slot_id:terminal.slot_id
      ~call_id:terminal.call_id
      ~plan_fingerprint:terminal.plan_fingerprint
      ~request_body_sha256:terminal.request_body_sha256
  in
  let* () = validate_exact_execution_terminal terminal in
  match binding_for_lease lease state with
  | None -> Error (Printf.sprintf "exact execution lease is not bound: %s" lease.lease_id)
  | Some binding
    when not
           (binding_identity_equal
              binding
              ~slot_id:terminal.slot_id
              ~call_id:terminal.call_id
              ~plan_fingerprint:terminal.plan_fingerprint
              ~request_body_sha256:terminal.request_body_sha256) ->
    Error (Printf.sprintf "exact execution binding identity conflict: %s" lease.lease_id)
  | Some ({ status = Dispatch_uncertain; _ } as binding) ->
    Ok
      { state with
        exact_execution_bindings =
          [ { binding with status = Terminal_quarantined terminal.cause } ]
      }
  | Some { status = Terminal_quarantined cause; _ } when cause = terminal.cause -> Ok state
  | Some { status = Terminal_quarantined _; _ } ->
    Error (Printf.sprintf "exact execution terminal cause conflict: %s" lease.lease_id)
  | Some
      { status = Disposition_prepared disposition; _ } ->
    (match disposition.outcome with
     | Terminal cause when cause = terminal.cause -> Ok state
     | Terminal _ ->
       Error (Printf.sprintf "exact execution terminal cause conflict: %s" lease.lease_id))
;;

let prepare_exact_source_disposition
      ~(lease : lease)
      ~source
      ~(terminal : exact_execution_terminal)
      ~semantic
      ~prepared_at
      state
  =
  let slot_id = terminal.slot_id in
  let call_id = terminal.call_id in
  let plan_fingerprint = terminal.plan_fingerprint in
  let request_body_sha256 = terminal.request_body_sha256 in
  let outcome = Terminal terminal.cause in
  let action = Consume_source in
  let* () = validate_exact_execution_terminal terminal in
  let* () =
    validate_binding_arguments
      ~lease
      ~slot_id
      ~call_id
      ~plan_fingerprint
      ~request_body_sha256
  in
  let* () =
    if Float.is_finite prepared_at
    then Ok ()
    else Error "exact source disposition preparation time must be finite"
  in
  let* () =
    match committed_lease lease state with
    | Some committed when lease_equal committed lease -> Ok ()
    | Some _ -> Error (Printf.sprintf "event queue lease payload conflict: %s" lease.lease_id)
    | None -> Error (Printf.sprintf "event queue lease not found: %s" lease.lease_id)
  in
  match binding_for_lease lease state with
  | None -> Error (Printf.sprintf "exact execution lease is not bound: %s" lease.lease_id)
  | Some binding
    when not
           (binding_identity_equal
              binding
              ~slot_id
              ~call_id
              ~plan_fingerprint
              ~request_body_sha256) ->
    Error (Printf.sprintf "exact execution binding identity conflict: %s" lease.lease_id)
  | Some binding ->
    let disposition_id =
      exact_source_disposition_id_of_fields
        ~source
        ~slot_id
        ~call_id
        ~plan_fingerprint
        ~request_body_sha256
        ~outcome
        ~action
        ~semantic
        ~prepared_at
    in
    let disposition =
      { disposition_id
      ; source
      ; slot_id
      ; call_id
      ; plan_fingerprint
      ; request_body_sha256
      ; outcome
      ; action
      ; semantic
      ; prepared_at
      }
    in
    let* () = validate_exact_source_disposition disposition in
    let prepared_status = Disposition_prepared disposition in
    (match binding.status with
     | Dispatch_uncertain ->
       Ok
         ( { state with
             exact_execution_bindings =
               [ { binding with status = prepared_status } ]
           }
         , disposition )
     | Terminal_quarantined cause ->
       (match outcome with
        | Terminal requested when requested = cause ->
          Ok
            ( { state with
                exact_execution_bindings =
                  [ { binding with status = prepared_status } ]
              }
            , disposition )
        | Terminal _ ->
          Error
            (Printf.sprintf
               "exact execution terminal cause conflict: %s"
               lease.lease_id))
     | Disposition_prepared existing ->
       if String.equal existing.disposition_id disposition.disposition_id
       then Ok (state, existing)
       else
         Error
           (Printf.sprintf
              "exact source disposition conflict: %s"
              lease.lease_id))
;;

let settle_committed ~settled_at ~lease ~settlement state =
  let* () =
    if Float.is_finite settled_at
    then Ok ()
    else Error "event queue settlement time must be finite"
  in
  let* () = validate_settlement settlement in
  let* () =
    match binding_for_lease lease state with
    | None -> Ok ()
    | Some binding -> validate_bound_settlement binding settlement
  in
  match committed_lease lease state with
  | None ->
    (match find_prior_receipt lease.lease_id state with
     | Some receipt when settlement_equal receipt.settlement settlement ->
       Ok (state, Already_settled receipt)
     | Some receipt ->
       Error
         (Printf.sprintf
            "event queue lease %s already settled as %s; refusing %s"
            lease.lease_id
            (settlement_kind_label receipt.settlement)
            (settlement_kind_label settlement))
     | None -> Error (Printf.sprintf "event queue lease not found: %s" lease.lease_id))
  | Some committed when not (lease_equal committed lease) ->
    Error (Printf.sprintf "event queue lease payload conflict: %s" lease.lease_id)
  | Some committed ->
    let* () = validate_settlement_for_lease settlement committed in
    let pending =
      match settlement with
      | Ack | No_compaction _ | Cancel_accepted _ | Transfer_accepted _
      | Settle_from_source_terminal _ -> state.pending
      | Settle_exact { action = Consume_source; _ } -> state.pending
      | Requeue
          ( Retry_after_observed
          | Context_compaction_retry
          | Transcript_quarantine_retry
          | Approval_grant_unconsumed
          | Approval_grant_state_unavailable ) ->
        (* Retryable provider work, context repair handoffs, and a durable
           one-shot grant retain the exact leased stimuli without monopolizing
           the FIFO front. *)
        append_missing committed.stimuli state.pending
      | Requeue _ -> prepend_missing committed.stimuli state.pending
      | Escalate { successor = None; _ } -> state.pending
      | Escalate { successor = Some successor; _ } ->
        enqueue_if_missing state.pending successor
    in
    let receipt = receipt_for_lease ~settled_at ~settlement committed in
    let outbox_entry =
      { receipt
      ; stimuli = committed.stimuli
      }
    in
    Ok
      ( { state with
          pending
        ; leases = remove_lease committed.lease_id state.leases
        ; transition_outbox = [ outbox_entry ]
        ; exact_execution_bindings =
            List.filter
              (fun (binding : exact_execution_binding) ->
                 not (String.equal binding.lease_id committed.lease_id))
              state.exact_execution_bindings
        }
      , Settled receipt )
;;

let settle ~settled_at ~lease ~settlement state =
  match binding_for_lease lease state with
  | Some binding ->
    Error
      (Printf.sprintf
         "exact execution lease %s call %s requires identity-bound settlement"
         binding.lease_id
         binding.call_id)
  | None ->
    (match settlement with
     | Cancel_accepted _ | Transfer_accepted _ | Settle_from_source_terminal _
     | Settle_exact _ ->
       Error "accepted disposition requires its owner-fenced boundary"
     | Ack | No_compaction _ | Requeue _ | Escalate _ ->
       settle_committed ~settled_at ~lease ~settlement state)
;;

let settle_bound_exact_nonterminal
      ~settled_at
      ~lease
      ~slot_id
      ~call_id
      ~plan_fingerprint
      ~request_body_sha256
      ~settlement
      state
  =
  let* () =
    if identity_bound_nonterminal_settlement settlement
    then Ok ()
    else Error "bound exact terminal settlement requires a prepared full source disposition"
  in
  let* () =
    validate_binding_arguments
      ~lease
      ~slot_id
      ~call_id
      ~plan_fingerprint
      ~request_body_sha256
  in
  match binding_for_lease lease state with
  | Some binding
    when binding_identity_equal
           binding
           ~slot_id
           ~call_id
           ~plan_fingerprint
           ~request_body_sha256 ->
    settle_committed ~settled_at ~lease ~settlement state
  | Some _ -> Error (Printf.sprintf "exact execution binding identity conflict: %s" lease.lease_id)
  | None ->
    (match committed_lease lease state with
     | Some _ ->
       Error
         (Printf.sprintf
            "active exact execution lease is not durably bound: %s"
            lease.lease_id)
     | None -> settle_committed ~settled_at ~lease ~settlement state)
;;

let finalize_exact_source_disposition
      ~settled_at
      ~(lease : lease)
      ~disposition_id
      state
  =
  match binding_for_lease lease state with
  | Some { status = Disposition_prepared disposition; _ } ->
    if not (String.equal disposition.disposition_id disposition_id)
    then Error (Printf.sprintf "exact source disposition identity conflict: %s" lease.lease_id)
    else
      settle_committed
        ~settled_at
        ~lease
        ~settlement:(Settle_exact disposition)
        state
  | Some { status = Dispatch_uncertain; _ } ->
    Error "dispatch-uncertain exact execution has no source disposition"
  | Some { status = Terminal_quarantined _; _ } ->
    Error "source-less terminal quarantine has no source disposition"
  | None ->
    (match find_prior_receipt lease.lease_id state with
     | Some ({ settlement = Settle_exact disposition; _ } as receipt)
       when String.equal disposition.disposition_id disposition_id ->
       Ok (state, Already_settled receipt)
     | Some _ ->
       Error (Printf.sprintf "exact source disposition replay conflict: %s" lease.lease_id)
     | None -> Error (Printf.sprintf "exact execution lease is not bound: %s" lease.lease_id))
;;

let cancel_accepted
      ~current_owner_nonce
      ~settled_at
      ~(lease : lease)
      ~cancellation
      state
  =
  let settlement = Cancel_accepted cancellation in
  match find_prior_receipt lease.lease_id state with
  | Some _ -> settle_committed ~settled_at ~lease ~settlement state
  | None ->
    let* () = validate_accepted_cancellation cancellation in
    let* () =
      if Int.equal current_owner_nonce cancellation.owner_nonce
      then Ok ()
      else
        Error
          (Printf.sprintf
             "accepted cancellation owner generation changed: expected %d, current %d"
             cancellation.owner_nonce
             current_owner_nonce)
    in
    let* () =
      if Int64.equal state.revision cancellation.source_revision
      then Ok ()
      else
        Error
          (Printf.sprintf
             "accepted cancellation source revision changed: expected %Ld, current %Ld"
             cancellation.source_revision
             state.revision)
    in
    settle_committed ~settled_at ~lease ~settlement state
;;

let disposition_operation_id = function
  | Cancel_accepted cancellation -> Some cancellation.operator_operation_id
  | Transfer_accepted transfer -> Some transfer.operator_operation_id
  | Settle_from_source_terminal source_terminal ->
    Some source_terminal.operator_operation_id
  | Ack | No_compaction _ | Settle_exact _ | Requeue _ | Escalate _ -> None
;;

let prior_disposition_by_operation_id operation_id state =
  let is_same_operation receipt =
    match disposition_operation_id receipt.settlement with
    | Some committed -> String.equal committed operation_id
    | None -> false
  in
  match state.transition_outbox with
  | [ entry ] when is_same_operation entry.receipt -> Some entry.receipt
  | [] | [ _ ] ->
    (match state.last_settlement with
     | Some receipt when is_same_operation receipt -> Some receipt
     | Some _ | None -> None)
  | _ :: _ :: _ -> None
;;

let accepted_pending_cancellation_replay cancellation state =
  let requested = Cancel_accepted cancellation in
  match
    prior_disposition_by_operation_id cancellation.operator_operation_id state
  with
  | None -> Ok None
  | Some receipt when settlement_equal receipt.settlement requested ->
    Ok (Some receipt)
  | Some _ ->
    Error
      (Printf.sprintf
         "accepted cancellation operation conflict: %s"
         cancellation.operator_operation_id)
;;

let cancel_pending_accepted
      ~current_owner_nonce
      ~settled_at
      ~cancellation
      state
  =
  let settlement = Cancel_accepted cancellation in
  match accepted_pending_cancellation_replay cancellation state with
  | Error _ as error -> error
  | Ok (Some receipt) ->
    Ok (state, Already_settled receipt)
  | Ok None ->
    let* () = validate_accepted_cancellation cancellation in
    let* () =
      if Int.equal current_owner_nonce cancellation.owner_nonce
      then Ok ()
      else
        Error
          (Printf.sprintf
             "accepted cancellation owner generation changed: expected %d, current %d"
             cancellation.owner_nonce
             current_owner_nonce)
    in
    let* () =
      if Int64.equal state.revision cancellation.source_revision
      then Ok ()
      else
        Error
          (Printf.sprintf
             "accepted cancellation source revision changed: expected %Ld, current %Ld"
             cancellation.source_revision
             state.revision)
    in
    let* () =
      if lease_admission_blocked state
      then Error "event queue cannot cancel pending work while a lease or outbox exists"
      else Ok ()
    in
    let matching, retained =
      Keeper_event_queue.to_list state.pending
      |> List.partition (fun source ->
        Keeper_event_queue.stimulus_identity_equal cancellation.source source)
    in
    (match matching with
     | [] -> Error "accepted cancellation source is not pending"
     | _ :: _ :: _ -> Error "accepted cancellation source identity is duplicated"
     | [ source ] when source <> cancellation.source ->
       Error "accepted cancellation source snapshot changed"
     | [ source ] ->
       let pending =
         List.fold_left
           Keeper_event_queue.enqueue
           Keeper_event_queue.empty
           retained
       in
       let* claimed, lease =
         make_lease ~kind:Single ~claimed_at:None [ source ] { state with pending }
       in
       let* lease =
         match lease with
         | Some lease -> Ok lease
         | None -> Error "accepted cancellation did not create its synthetic lease"
       in
       settle_committed ~settled_at ~lease ~settlement claimed)
;;

let accepted_pending_transfer_replay transfer state =
  let requested = Transfer_accepted transfer in
  match prior_disposition_by_operation_id transfer.operator_operation_id state with
  | None -> Ok None
  | Some receipt when settlement_equal receipt.settlement requested ->
    Ok (Some receipt)
  | Some _ ->
    Error
      (Printf.sprintf
         "accepted transfer operation conflict: %s"
         transfer.operator_operation_id)
;;

let transfer_pending_accepted
      ~current_owner_nonce
      ~settled_at
      ~transfer
      state
  =
  let settlement = Transfer_accepted transfer in
  match accepted_pending_transfer_replay transfer state with
  | Error _ as error -> error
  | Ok (Some receipt) -> Ok (state, Already_settled receipt)
  | Ok None ->
    let* () = validate_accepted_transfer transfer in
    let* () =
      if Int.equal current_owner_nonce transfer.owner_nonce
      then Ok ()
      else
        Error
          (Printf.sprintf
             "accepted transfer owner generation changed: expected %d, current %d"
             transfer.owner_nonce
             current_owner_nonce)
    in
    let* () =
      if Int64.equal state.revision transfer.source_revision
      then Ok ()
      else
        Error
          (Printf.sprintf
             "accepted transfer source revision changed: expected %Ld, current %Ld"
             transfer.source_revision
             state.revision)
    in
    let* () =
      if lease_admission_blocked state
      then Error "event queue cannot transfer pending work while a lease or outbox exists"
      else Ok ()
    in
    let matching, retained =
      Keeper_event_queue.to_list state.pending
      |> List.partition (fun source ->
        Keeper_event_queue.stimulus_identity_equal transfer.source source)
    in
    (match matching with
     | [] -> Error "accepted transfer source is not pending"
     | _ :: _ :: _ -> Error "accepted transfer source identity is duplicated"
     | [ source ] when source <> transfer.source ->
       Error "accepted transfer source snapshot changed"
     | [ source ] ->
       let pending =
         List.fold_left
           Keeper_event_queue.enqueue
           Keeper_event_queue.empty
           retained
       in
       let* claimed, lease =
         make_lease ~kind:Single ~claimed_at:None [ source ] { state with pending }
       in
       let* lease =
         match lease with
         | Some lease -> Ok lease
         | None -> Error "accepted transfer did not create its synthetic lease"
       in
       settle_committed ~settled_at ~lease ~settlement claimed)
;;

let accepted_pending_source_terminal_replay source_terminal state =
  let requested = Settle_from_source_terminal source_terminal in
  match
    prior_disposition_by_operation_id
      source_terminal.operator_operation_id
      state
  with
  | None -> Ok None
  | Some receipt when settlement_equal receipt.settlement requested ->
    Ok (Some receipt)
  | Some _ ->
    Error
      (Printf.sprintf
         "source-terminal settlement operation conflict: %s"
         source_terminal.operator_operation_id)
;;

let settle_pending_from_source_terminal
      ~current_owner_nonce
      ~settled_at
      ~source_terminal
      state
  =
  let settlement = Settle_from_source_terminal source_terminal in
  match accepted_pending_source_terminal_replay source_terminal state with
  | Error _ as error -> error
  | Ok (Some receipt) -> Ok (state, Already_settled receipt)
  | Ok None ->
    let* () = validate_accepted_source_terminal source_terminal in
    let* () =
      if Int.equal current_owner_nonce source_terminal.owner_nonce
      then Ok ()
      else
        Error
          (Printf.sprintf
             "source-terminal settlement owner generation changed: expected %d, current %d"
             source_terminal.owner_nonce
             current_owner_nonce)
    in
    let* () =
      if Int64.equal state.revision source_terminal.source_revision
      then Ok ()
      else
        Error
          (Printf.sprintf
             "source-terminal settlement source revision changed: expected %Ld, current %Ld"
             source_terminal.source_revision
             state.revision)
    in
    let* () =
      if lease_admission_blocked state
      then Error "event queue cannot settle pending source while a lease or outbox exists"
      else Ok ()
    in
    let matching, retained =
      Keeper_event_queue.to_list state.pending
      |> List.partition (fun source ->
        Keeper_event_queue.stimulus_identity_equal source_terminal.source source)
    in
    (match matching with
     | [] -> Error "source-terminal settlement source is not pending"
     | _ :: _ :: _ ->
       Error "source-terminal settlement source identity is duplicated"
     | [ source ] when source <> source_terminal.source ->
       Error "source-terminal settlement source snapshot changed"
     | [ source ] ->
       let pending =
         List.fold_left
           Keeper_event_queue.enqueue
           Keeper_event_queue.empty
           retained
       in
       let* claimed, lease =
         make_lease ~kind:Single ~claimed_at:None [ source ] { state with pending }
       in
       let* lease =
         match lease with
         | Some lease -> Ok lease
         | None ->
           Error "source-terminal settlement did not create its synthetic lease"
       in
       settle_committed ~settled_at ~lease ~settlement claimed)
;;

let accepted_cancellation_replay (lease : lease) cancellation state =
  let requested = Cancel_accepted cancellation in
  match find_prior_receipt lease.lease_id state with
  | None -> Ok None
  | Some receipt when settlement_equal receipt.settlement requested ->
    Ok (Some receipt)
  | Some receipt ->
    Error
      (Printf.sprintf
         "event queue lease %s already settled as %s; refusing %s"
         lease.lease_id
         (settlement_kind_label receipt.settlement)
         (settlement_kind_label requested))
;;

let replay_transition_receipt receipt state =
  match
    List.find_opt
      (fun (lease : lease) -> Int64.equal lease.sequence receipt.lease_sequence)
      state.leases
  with
  | Some lease ->
    let* state, result =
      match receipt.settlement with
      | Settle_exact disposition ->
        finalize_exact_source_disposition
          ~settled_at:receipt.settled_at
          ~lease
          ~disposition_id:disposition.disposition_id
          state
      | Ack
      | No_compaction _
      | Cancel_accepted _
      | Transfer_accepted _
      | Settle_from_source_terminal _
      | Requeue _
      | Escalate _ ->
        (match binding_for_lease lease state with
         | Some _ ->
           Error
             (Printf.sprintf
                "generic WAL receipt cannot settle exact execution lease: %s"
                lease.lease_id)
         | None ->
           settle_committed
             ~settled_at:receipt.settled_at
             ~lease
             ~settlement:receipt.settlement
             state)
    in
    let actual =
      match result with
      | Settled actual | Already_settled actual -> actual
    in
    if transition_receipt_equal receipt actual
    then Ok state
    else Error (Printf.sprintf "event queue receipt replay conflict: %s" receipt.lease_id)
  | None ->
    (match find_prior_receipt receipt.lease_id state with
     | Some prior when transition_receipt_equal prior receipt -> Ok state
     | Some _ ->
       Error (Printf.sprintf "event queue receipt replay conflict: %s" receipt.lease_id)
     | None ->
         Error
           (Printf.sprintf
              "event queue receipt has no matching active lease: %s"
              receipt.lease_id))
;;

let replay_transition_outbox_entry entry state =
  match state.transition_outbox with
  | [ current ] ->
    if not (String.equal current.receipt.lease_id entry.receipt.lease_id)
    then
      Error
        (Printf.sprintf
           "event queue WAL conflicts with another checkpointed outbox: %s"
           current.receipt.transition_id)
    else if current <> entry
    then
      Error
        (Printf.sprintf
           "event queue WAL conflicts with checkpointed outbox: %s"
           entry.receipt.transition_id)
    else replay_transition_receipt entry.receipt state
  | _ :: _ :: _ -> Error "event queue checkpoint contains multiple outbox entries"
  | [] ->
    (match
       List.find_opt
         (fun (lease : lease) -> String.equal lease.lease_id entry.receipt.lease_id)
         state.leases
     with
     | Some lease when lease.stimuli <> entry.stimuli ->
       Error
         (Printf.sprintf
            "event queue WAL source conflicts with active lease: %s"
            entry.receipt.lease_id)
     | Some _ -> replay_transition_receipt entry.receipt state
     | None ->
       (match find_prior_receipt entry.receipt.lease_id state with
        | Some _ -> replay_transition_receipt entry.receipt state
        | None ->
          (match entry.receipt.settlement, entry.stimuli with
           | Cancel_accepted cancellation, [ source ]
             when source = cancellation.source ->
             if not (Int64.equal state.next_lease_sequence entry.receipt.lease_sequence)
             then
               Error
                 (Printf.sprintf
                    "pending cancellation WAL lease sequence changed: expected %Ld, current %Ld"
                    entry.receipt.lease_sequence
                    state.next_lease_sequence)
             else
               let* replayed, result =
                 cancel_pending_accepted
                   ~current_owner_nonce:cancellation.owner_nonce
                   ~settled_at:entry.receipt.settled_at
                   ~cancellation
                   state
               in
               let actual_receipt =
                 match result with
                 | Settled receipt | Already_settled receipt -> receipt
               in
               (match replayed.transition_outbox with
                | [ actual ]
                  when transition_receipt_equal entry.receipt actual_receipt
                       && actual = entry ->
                  Ok replayed
                | [] | [ _ ] | _ :: _ :: _ ->
                  Error
                    (Printf.sprintf
                       "pending cancellation WAL replay conflict: %s"
                       entry.receipt.transition_id))
           | Cancel_accepted _, [ _ ] ->
             Error "pending cancellation WAL source conflicts with its receipt"
           | Cancel_accepted _, ([] | _ :: _ :: _) ->
             Error "pending cancellation WAL must carry exactly one source"
           | Transfer_accepted transfer, [ source ] when source = transfer.source ->
             if not (Int64.equal state.next_lease_sequence entry.receipt.lease_sequence)
             then
               Error
                 (Printf.sprintf
                    "pending transfer WAL lease sequence changed: expected %Ld, current %Ld"
                    entry.receipt.lease_sequence
                    state.next_lease_sequence)
             else
               let* replayed, result =
                 transfer_pending_accepted
                   ~current_owner_nonce:transfer.owner_nonce
                   ~settled_at:entry.receipt.settled_at
                   ~transfer
                   state
               in
               let actual_receipt =
                 match result with
                 | Settled receipt | Already_settled receipt -> receipt
               in
               (match replayed.transition_outbox with
                | [ actual ]
                  when transition_receipt_equal entry.receipt actual_receipt
                       && actual = entry ->
                  Ok replayed
                | [] | [ _ ] | _ :: _ :: _ ->
                  Error
                    (Printf.sprintf
                       "pending transfer WAL replay conflict: %s"
                       entry.receipt.transition_id))
           | Transfer_accepted _, [ _ ] ->
             Error "pending transfer WAL source conflicts with its receipt"
           | Transfer_accepted _, ([] | _ :: _ :: _) ->
             Error "pending transfer WAL must carry exactly one source"
           | Settle_from_source_terminal source_terminal, [ source ]
             when source = source_terminal.source ->
             if not (Int64.equal state.next_lease_sequence entry.receipt.lease_sequence)
             then
               Error
                 (Printf.sprintf
                    "pending source-terminal WAL lease sequence changed: expected %Ld, current %Ld"
                    entry.receipt.lease_sequence
                    state.next_lease_sequence)
             else
               let* replayed, result =
                 settle_pending_from_source_terminal
                   ~current_owner_nonce:source_terminal.owner_nonce
                   ~settled_at:entry.receipt.settled_at
                   ~source_terminal
                   state
               in
               let actual_receipt =
                 match result with
                 | Settled receipt | Already_settled receipt -> receipt
               in
               (match replayed.transition_outbox with
                | [ actual ]
                  when transition_receipt_equal entry.receipt actual_receipt
                       && actual = entry ->
                  Ok replayed
                | [] | [ _ ] | _ :: _ :: _ ->
                  Error
                    (Printf.sprintf
                       "pending source-terminal WAL replay conflict: %s"
                       entry.receipt.transition_id))
           | Settle_from_source_terminal _, [ _ ] ->
             Error "pending source-terminal WAL source conflicts with its receipt"
           | Settle_from_source_terminal _, ([] | _ :: _ :: _) ->
             Error "pending source-terminal WAL must carry exactly one source"
           | (Ack | No_compaction _ | Settle_exact _ | Requeue _ | Escalate _), _ ->
             Error
               (Printf.sprintf
                  "event queue WAL receipt has no matching active lease: %s"
                  entry.receipt.lease_id))))
;;

let recover_leases ~settled_at state =
  let rec loop state = function
    | [] -> Ok state
    | lease :: rest ->
      (match
         settle
           ~settled_at
           ~lease
           ~settlement:(Requeue Registration_recovery)
           state
       with
       | Error _ as error -> error
       | Ok (state, (Settled _ | Already_settled _)) -> loop state rest)
  in
  loop state state.leases
;;

let remove_by_post_id post_id state =
  let removed_pending, pending =
    Keeper_event_queue.remove_by_post_id post_id state.pending
  in
  let removed_leases, leases =
    List.fold_right
      (fun (lease : lease) (removed, kept) ->
         match binding_for_lease lease state with
         | Some _ -> removed, lease :: kept
         | None ->
           let matched, remaining =
             List.partition
               (fun stimulus -> String.equal stimulus.Keeper_event_queue.post_id post_id)
               lease.stimuli
           in
           let kept =
             match remaining with
             | [] -> kept
             | _ -> { lease with stimuli = remaining } :: kept
           in
           matched @ removed, kept)
      state.leases
      ([], [])
  in
  ( Keeper_event_queue.uniq_stimuli (removed_pending @ removed_leases)
  , { state with pending; leases } )
;;

let release_legacy_inflight stimuli state =
  let should_release stimulus =
    List.exists
      (Keeper_event_queue.stimulus_identity_equal stimulus)
      stimuli
  in
  let leases =
    List.filter_map
      (fun (lease : lease) ->
         match binding_for_lease lease state with
         | Some _ -> Some lease
         | None ->
           let remaining =
             List.filter (fun stimulus -> not (should_release stimulus)) lease.stimuli
           in
           (match remaining with
            | [] -> None
            | _ :: _ -> Some { lease with stimuli = remaining }))
      state.leases
  in
  { state with leases }
;;

let assoc_fields ~context = function
  | `Assoc fields -> Ok fields
  | _ -> Error (context ^ " must be a JSON object")
;;

let required_field ~context name fields =
  match List.assoc_opt name fields with
  | Some value -> Ok value
  | None -> Error (Printf.sprintf "%s missing required field %s" context name)
;;

let exact_fields ~context ~expected fields =
  let rec loop seen = function
    | [] -> Ok ()
    | (name, _) :: rest ->
      if not (List.exists (String.equal name) expected)
      then Error (Printf.sprintf "%s contains unknown field %s" context name)
      else if List.exists (String.equal name) seen
      then Error (Printf.sprintf "%s contains duplicate field %s" context name)
      else loop (name :: seen) rest
  in
  loop [] fields
;;

let string_field ~context name fields =
  let* value = required_field ~context name fields in
  match value with
  | `String value -> Ok value
  | _ -> Error (Printf.sprintf "%s.%s must be a string" context name)
;;

let float_field ~context name fields =
  let* value = required_field ~context name fields in
  match value with
  | `Float value -> Ok value
  | `Int value -> Ok (float_of_int value)
  | _ -> Error (Printf.sprintf "%s.%s must be a number" context name)
;;

let int_field ~context name fields =
  let* value = required_field ~context name fields in
  match value with
  | `Int value -> Ok value
  | _ -> Error (Printf.sprintf "%s.%s must be an int" context name)
;;

(* Wire-compat (#25599): pre-rename persisted rows (snapshot "last_settlement",
   "transition_outbox", "accepted_transfer_projections" and every settlement
   WAL entry) carry the fencing counter under ["owner_generation"]; post-rename
   rows use ["owner_nonce"]. Read both — the new key wins when a row carries
   both — so replay of pre-rename state survives the rename boundary. The
   writer keeps emitting only ["owner_nonce"]. *)
let owner_nonce_field ~context fields =
  let parse name = function
    | `Int value -> Ok value
    | _ -> Error (Printf.sprintf "%s.%s must be an int" context name)
  in
  match List.assoc_opt "owner_nonce" fields with
  | Some value -> parse "owner_nonce" value
  | None ->
    (match List.assoc_opt "owner_generation" fields with
     | Some value -> parse "owner_generation" value
     | None ->
       Error
         (Printf.sprintf
            "%s missing required field owner_nonce (or legacy owner_generation)"
            context))
;;

let int64_field ~context name fields =
  let* value = required_field ~context name fields in
  match value with
  | `Int value -> Ok (Int64.of_int value)
  | `Intlit value ->
    (match Int64.of_string_opt value with
     | Some value -> Ok value
     | None -> Error (Printf.sprintf "%s.%s must be an int64" context name))
  | _ -> Error (Printf.sprintf "%s.%s must be an int64" context name)
;;

let list_field ~context name parse fields =
  let* value = required_field ~context name fields in
  match value with
  | `List values ->
    let rec loop acc = function
      | [] -> Ok (List.rev acc)
      | value :: rest ->
        let* parsed = parse value in
        loop (parsed :: acc) rest
    in
    loop [] values
  | _ -> Error (Printf.sprintf "%s.%s must be a list" context name)
;;

let int64_json value = `Intlit (Int64.to_string value)

let lease_to_yojson (lease : lease) =
  `Assoc
    [ "lease_id", `String lease.lease_id
    ; "sequence", int64_json lease.sequence
    ; "kind", `String (lease_kind_label lease.kind)
    ; ( "claimed_at_unix"
      , match lease.claimed_at with
        | None -> `Null
        | Some claimed_at -> `Float claimed_at )
    ; "stimuli", `List (List.map Keeper_event_queue.stimulus_to_yojson lease.stimuli)
    ]
;;

let lease_of_yojson json =
  let context = "event queue lease" in
  let* fields = assoc_fields ~context json in
  let* lease_id = string_field ~context "lease_id" fields in
  let* sequence = int64_field ~context "sequence" fields in
  let* kind_label = string_field ~context "kind" fields in
  let* kind = lease_kind_of_label kind_label in
  let* claimed_at =
    match List.assoc_opt "claimed_at_unix" fields with
    | None | Some `Null -> Ok None
    | Some (`Float value) -> Ok (Some value)
    | Some (`Int value) -> Ok (Some (float_of_int value))
    | Some _ -> Error "event queue lease.claimed_at_unix must be a number or null"
  in
  let* stimuli =
    list_field ~context "stimuli" Keeper_event_queue.stimulus_of_yojson fields
  in
  if Int64.compare sequence 1L < 0
  then Error "event queue lease sequence must be positive"
  else if stimuli = []
  then Error "event queue lease must contain at least one stimulus"
  else if kind = Single && List.length stimuli <> 1
  then Error "single event queue lease must contain exactly one stimulus"
  else if
    kind = Board_batch
    && not
         (List.for_all
            (fun (stimulus : Keeper_event_queue.stimulus) ->
               Keeper_event_queue.is_board_signal stimulus.payload)
            stimuli)
  then Error "board event queue lease contains a non-board stimulus"
  else if not (String.equal lease_id (lease_id_of_sequence sequence))
  then Error (Printf.sprintf "event queue lease id/sequence mismatch: %s" lease_id)
  else Ok { lease_id; sequence; kind; claimed_at; stimuli }
;;

let no_compaction_reason_label = function
  | No_eligible_history -> "no_eligible_history"
  | Invalid_structural_source -> "invalid_structural_source"
  | Structurally_unchanged -> "structurally_unchanged"
  | Checkpoint_not_reduced -> "checkpoint_not_reduced"
  | Exact_lane_unconfigured -> "exact_lane_unconfigured"
  | Exact_execution_terminal terminal ->
    exact_execution_terminal_cause_label terminal.cause
;;

let no_compaction_reason_to_string = function
  | Exact_execution_terminal terminal -> exact_execution_terminal_to_string terminal
  | reason -> no_compaction_reason_label reason
;;

let no_compaction_reason_of_label = function
  | "no_eligible_history" -> Ok No_eligible_history
  | "invalid_structural_source" -> Ok Invalid_structural_source
  | "structurally_unchanged" -> Ok Structurally_unchanged
  | "checkpoint_not_reduced" -> Ok Checkpoint_not_reduced
  | "exact_lane_unconfigured" -> Ok Exact_lane_unconfigured
  | reason ->
    (match exact_execution_terminal_cause_of_label reason with
     | Ok _ ->
       Error
         (Printf.sprintf
            "no-compaction reason %s requires exact execution provenance"
            reason)
     | Error _ -> Error (Printf.sprintf "unknown no-compaction reason: %s" reason))
;;

let exact_execution_terminal_to_yojson terminal =
  `Assoc
    [ "cause", `String (exact_execution_terminal_cause_label terminal.cause)
    ; "slot_id", `String terminal.slot_id
    ; "call_id", `String terminal.call_id
    ; "plan_fingerprint", `String terminal.plan_fingerprint
    ; "request_body_sha256", `String terminal.request_body_sha256
    ]
;;

let exact_execution_terminal_of_yojson json =
  let context = "exact execution terminal" in
  let* fields = assoc_fields ~context json in
  let* () =
    exact_fields
      ~context
      ~expected:
        [ "cause"
        ; "slot_id"
        ; "call_id"
        ; "plan_fingerprint"
        ; "request_body_sha256"
        ]
      fields
  in
  let* cause_label = string_field ~context "cause" fields in
  let* cause = exact_execution_terminal_cause_of_label cause_label in
  let* slot_id = string_field ~context "slot_id" fields in
  let* call_id = string_field ~context "call_id" fields in
  let* plan_fingerprint = string_field ~context "plan_fingerprint" fields in
  let* request_body_sha256 =
    string_field ~context "request_body_sha256" fields
  in
  let terminal =
    { cause; slot_id; call_id; plan_fingerprint; request_body_sha256 }
  in
  let* () = validate_exact_execution_terminal terminal in
  Ok terminal
;;

let checkpoint_source_to_yojson (source : Keeper_checkpoint_ref.t) =
  `Assoc
    [ "trace_id", `String (Keeper_id.Trace_id.to_string source.trace_id)
    ; "generation", `Int source.generation
    ; "turn_count", `Int source.turn_count
    ; "sha256", `String source.sha256
    ]
;;

let checkpoint_source_of_yojson json =
  let context = "no-compaction checkpoint source" in
  let* fields = assoc_fields ~context json in
  let* () =
    exact_fields
      ~context
      ~expected:[ "trace_id"; "generation"; "turn_count"; "sha256" ]
      fields
  in
  let* trace_id_raw = string_field ~context "trace_id" fields in
  let* trace_id = Keeper_id.Trace_id.of_string trace_id_raw in
  let* generation = int_field ~context "generation" fields in
  let* turn_count = int_field ~context "turn_count" fields in
  let* sha256 = string_field ~context "sha256" fields in
  Keeper_checkpoint_ref.of_persisted ~trace_id ~generation ~turn_count ~sha256
  |> Result.map_error (function
    | Keeper_checkpoint_ref.Negative_generation value ->
      Printf.sprintf "no-compaction checkpoint generation is negative: %d" value
    | Negative_turn_count value ->
      Printf.sprintf "no-compaction checkpoint turn count is negative: %d" value
    | Invalid_sha256 value ->
      Printf.sprintf "no-compaction checkpoint digest is invalid: %s" value)
;;

let exact_source_disposition_to_yojson disposition =
  let terminal_cause =
    match disposition.outcome with
    | Terminal cause ->
      `String (exact_execution_terminal_cause_label cause)
  in
  let action_kind =
    match disposition.action with
    | Consume_source -> "consume_source"
  in
  `Assoc
    [ "disposition_id", `String disposition.disposition_id
    ; "source", checkpoint_source_to_yojson disposition.source
    ; "slot_id", `String disposition.slot_id
    ; "call_id", `String disposition.call_id
    ; "plan_fingerprint", `String disposition.plan_fingerprint
    ; "request_body_sha256", `String disposition.request_body_sha256
    ; "terminal_cause", terminal_cause
    ; "action_kind", `String action_kind
    ; ( "settlement_semantic"
      , `String (exact_settlement_semantic_label disposition.semantic) )
    ; "prepared_at_unix", `Float disposition.prepared_at
    ]
;;

let exact_source_disposition_of_yojson json =
  let context = "exact source disposition" in
  let* fields = assoc_fields ~context json in
  let* () =
    exact_fields
      ~context
      ~expected:
        [ "disposition_id"
        ; "source"
        ; "slot_id"
        ; "call_id"
        ; "plan_fingerprint"
        ; "request_body_sha256"
        ; "terminal_cause"
        ; "action_kind"
        ; "settlement_semantic"
        ; "prepared_at_unix"
        ]
      fields
  in
  let* disposition_id = string_field ~context "disposition_id" fields in
  let* source_json = required_field ~context "source" fields in
  let* source = checkpoint_source_of_yojson source_json in
  let* slot_id = string_field ~context "slot_id" fields in
  let* call_id = string_field ~context "call_id" fields in
  let* plan_fingerprint = string_field ~context "plan_fingerprint" fields in
  let* request_body_sha256 = string_field ~context "request_body_sha256" fields in
  let* terminal_cause_json = required_field ~context "terminal_cause" fields in
  let* outcome =
    match terminal_cause_json with
    | `String cause ->
      let* cause = exact_execution_terminal_cause_of_label cause in
      Ok (Terminal cause)
    | _ -> Error "terminal exact source disposition requires one terminal cause"
  in
  let* action_kind = string_field ~context "action_kind" fields in
  let* action =
    match action_kind with
    | "consume_source" -> Ok Consume_source
    | unknown ->
      Error (Printf.sprintf "unknown exact source disposition action: %s" unknown)
  in
  let* semantic_label =
    string_field ~context "settlement_semantic" fields
  in
  let* semantic =
    match semantic_label with
    | "no_compaction" -> Ok Exact_no_compaction
    | "escalate" -> Ok Exact_escalate
    | unknown ->
      Error
        (Printf.sprintf
           "unknown exact source disposition settlement semantic: %s"
           unknown)
  in
  let* prepared_at = float_field ~context "prepared_at_unix" fields in
  let disposition =
    { disposition_id
    ; source
    ; slot_id
    ; call_id
    ; plan_fingerprint
    ; request_body_sha256
    ; outcome
    ; action
    ; semantic
    ; prepared_at
    }
  in
  let* () = validate_exact_source_disposition disposition in
  Ok disposition
;;

let settlement_to_yojson = function
  | Ack -> `Assoc [ "kind", `String "ack" ]
  | No_compaction { source; reason } ->
    let fields =
      [ "kind", `String "no_compaction"
      ; "reason", `String (no_compaction_reason_label reason)
      ; "source", checkpoint_source_to_yojson source
      ]
    in
    let fields =
      match reason with
      | Exact_execution_terminal terminal ->
        fields @ [ "exact_execution", exact_execution_terminal_to_yojson terminal ]
      | No_eligible_history
      | Invalid_structural_source
      | Structurally_unchanged
      | Checkpoint_not_reduced
      | Exact_lane_unconfigured ->
        fields
    in
    `Assoc fields
  | Cancel_accepted cancellation ->
    `Assoc
      [ "kind", `String "cancel_accepted"
      ; "source", Keeper_event_queue.stimulus_to_yojson cancellation.source
      ; "source_revision", int64_json cancellation.source_revision
      ; "owner_nonce", `Int cancellation.owner_nonce
      ; "operator_operation_id", `String cancellation.operator_operation_id
      ; "reason", `String cancellation.reason
      ]
  | Transfer_accepted transfer ->
    `Assoc
      [ "kind", `String "transfer_accepted"
      ; "source", Keeper_event_queue.stimulus_to_yojson transfer.source
      ; "source_revision", int64_json transfer.source_revision
      ; "owner_nonce", `Int transfer.owner_nonce
      ; "operator_operation_id", `String transfer.operator_operation_id
      ; "from_keeper", `String transfer.from_keeper
      ; "to_keeper", `String transfer.to_keeper
      ]
  | Settle_from_source_terminal source_terminal ->
    let receipt_kind =
      match source_terminal.source_receipt with
      | Fusion_terminal _ -> "fusion_terminal"
      | Background_job_terminal _ -> "background_job_terminal"
      | Hitl_terminal _ -> "hitl_terminal"
    in
    `Assoc
      [ "kind", `String "settle_from_source_terminal"
      ; "source", Keeper_event_queue.stimulus_to_yojson source_terminal.source
      ; "source_revision", int64_json source_terminal.source_revision
      ; "owner_nonce", `Int source_terminal.owner_nonce
      ; "operator_operation_id", `String source_terminal.operator_operation_id
       ; "source_receipt_kind", `String receipt_kind
       ]
  | Settle_exact disposition ->
    `Assoc
      [ "kind", `String "settle_exact"
      ; "disposition", exact_source_disposition_to_yojson disposition
      ]
  | Requeue reason ->
    `Assoc
      [ "kind", `String "requeue"
      ; "reason", `String (requeue_reason_label reason)
      ]
  | Escalate { reason; successor } ->
    `Assoc
      [ "kind", `String "escalate"
      ; "reason", `String (escalation_reason_label reason)
      ; "reason_detail", escalation_reason_detail_to_yojson reason
      ; ( "successor"
        , match successor with
          | None -> `Null
          | Some successor -> Keeper_event_queue.stimulus_to_yojson successor )
      ]
;;

let settlement_of_yojson json =
  let context = "event queue settlement" in
  let* fields = assoc_fields ~context json in
  let* kind = string_field ~context "kind" fields in
  match kind with
  | "ack" ->
    let* () = exact_fields ~context ~expected:[ "kind" ] fields in
    Ok Ack
  | "no_compaction" ->
    let* reason_label = string_field ~context "reason" fields in
    let* source_json = required_field ~context "source" fields in
    let* source = checkpoint_source_of_yojson source_json in
    (match exact_execution_terminal_cause_of_label reason_label with
     | Ok expected_cause ->
       let* () =
         exact_fields
           ~context
           ~expected:[ "kind"; "reason"; "source"; "exact_execution" ]
           fields
       in
       let* terminal_json = required_field ~context "exact_execution" fields in
       let* terminal = exact_execution_terminal_of_yojson terminal_json in
       let* () =
         if terminal.cause = expected_cause
         then Ok ()
         else Error "no-compaction reason does not match exact execution cause"
       in
       Ok
         (No_compaction
            { source; reason = Exact_execution_terminal terminal })
     | Error _ ->
       let* () =
         exact_fields ~context ~expected:[ "kind"; "reason"; "source" ] fields
       in
       let* reason = no_compaction_reason_of_label reason_label in
       Ok (No_compaction { source; reason }))
  | "cancel_accepted" ->
    let* () =
      exact_fields
        ~context
        ~expected:
          [ "kind"
          ; "source"
          ; "source_revision"
          ; "owner_nonce"
          ; "owner_generation"
          ; "operator_operation_id"
          ; "reason"
          ]
        fields
    in
    let* source_json = required_field ~context "source" fields in
    let* source = Keeper_event_queue.stimulus_of_yojson source_json in
    let* source_revision = int64_field ~context "source_revision" fields in
    let* owner_nonce = owner_nonce_field ~context fields in
    let* operator_operation_id =
      string_field ~context "operator_operation_id" fields
    in
    let* reason = string_field ~context "reason" fields in
    let cancellation =
      { source; source_revision; owner_nonce; operator_operation_id; reason }
    in
    let* () = validate_accepted_cancellation cancellation in
    Ok (Cancel_accepted cancellation)
  | "transfer_accepted" ->
    let* () =
      exact_fields
        ~context
        ~expected:
          [ "kind"
          ; "source"
          ; "source_revision"
          ; "owner_nonce"
          ; "owner_generation"
          ; "operator_operation_id"
          ; "from_keeper"
          ; "to_keeper"
          ]
        fields
    in
    let* source_json = required_field ~context "source" fields in
    let* source = Keeper_event_queue.stimulus_of_yojson source_json in
    let* source_revision = int64_field ~context "source_revision" fields in
    let* owner_nonce = owner_nonce_field ~context fields in
    let* operator_operation_id =
      string_field ~context "operator_operation_id" fields
    in
    let* from_keeper = string_field ~context "from_keeper" fields in
    let* to_keeper = string_field ~context "to_keeper" fields in
    let transfer =
      { source
      ; source_revision
      ; owner_nonce
      ; operator_operation_id
      ; from_keeper
      ; to_keeper
      }
    in
    let* () = validate_accepted_transfer transfer in
    Ok (Transfer_accepted transfer)
  | "settle_from_source_terminal" ->
    let* () =
      exact_fields
        ~context
        ~expected:
          [ "kind"
          ; "source"
          ; "source_revision"
          ; "owner_nonce"
          ; "owner_generation"
          ; "operator_operation_id"
          ; "source_receipt_kind"
          ]
        fields
    in
    let* source_json = required_field ~context "source" fields in
    let* source = Keeper_event_queue.stimulus_of_yojson source_json in
    let* source_revision = int64_field ~context "source_revision" fields in
    let* owner_nonce = owner_nonce_field ~context fields in
    let* operator_operation_id =
      string_field ~context "operator_operation_id" fields
    in
    let* source_receipt_kind =
      string_field ~context "source_receipt_kind" fields
    in
    let* source_receipt = source_terminal_receipt_of_stimulus source in
    let expected_kind =
      match source_receipt with
      | Fusion_terminal _ -> "fusion_terminal"
      | Background_job_terminal _ -> "background_job_terminal"
      | Hitl_terminal _ -> "hitl_terminal"
    in
    let* () =
      if String.equal source_receipt_kind expected_kind
      then Ok ()
      else Error "source-terminal receipt kind does not match source payload"
    in
    let source_terminal =
      { source
      ; source_revision
      ; owner_nonce
      ; operator_operation_id
      ; source_receipt
      }
    in
    let* () = validate_accepted_source_terminal source_terminal in
    Ok (Settle_from_source_terminal source_terminal)
  | "settle_exact" ->
    let* () =
      exact_fields ~context ~expected:[ "kind"; "disposition" ] fields
    in
    let* disposition_json = required_field ~context "disposition" fields in
    let* disposition = exact_source_disposition_of_yojson disposition_json in
    Ok (Settle_exact disposition)
  | "requeue" ->
    let* () = exact_fields ~context ~expected:[ "kind"; "reason" ] fields in
    let* reason = string_field ~context "reason" fields in
    let* reason = requeue_reason_of_label reason in
    Ok (Requeue reason)
  | "escalate" ->
    let* () =
      exact_fields
        ~context
        ~expected:[ "kind"; "reason"; "reason_detail"; "successor" ]
        fields
    in
    let* reason_label = string_field ~context "reason" fields in
    let* reason_detail = required_field ~context "reason_detail" fields in
    let* reason = escalation_reason_of_wire ~label:reason_label ~detail_json:reason_detail in
    let* successor =
      match List.assoc_opt "successor" fields with
      | Some `Null -> Ok None
      | Some json ->
        let* successor = Keeper_event_queue.stimulus_of_yojson json in
        Ok (Some successor)
      | None -> Error "event queue settlement missing required field successor"
    in
    let settlement = Escalate { reason; successor } in
    let* () = validate_settlement settlement in
    Ok settlement
  | kind -> Error (Printf.sprintf "unknown event queue settlement kind: %s" kind)
;;

let accepted_transfer_projection_to_yojson (transfer : accepted_transfer) =
  settlement_to_yojson (Transfer_accepted transfer)
;;

let accepted_transfer_projection_of_yojson json =
  let* settlement = settlement_of_yojson json in
  match settlement with
  | Transfer_accepted transfer -> Ok transfer
  | Ack
  | No_compaction _
  | Cancel_accepted _
  | Settle_from_source_terminal _
  | Settle_exact _
  | Requeue _
  | Escalate _ -> Error "target transfer projection must contain transfer_accepted"
;;

let transition_receipt_to_yojson receipt =
  `Assoc
    [ "transition_id", `String receipt.transition_id
    ; "event_id", `String receipt.event_id
    ; "lease_id", `String receipt.lease_id
    ; "lease_sequence", int64_json receipt.lease_sequence
    ; "settled_at_unix", `Float receipt.settled_at
    ; "settlement", settlement_to_yojson receipt.settlement
    ]
;;

let transition_receipt_of_yojson json =
  let context = "event queue transition receipt" in
  let* fields = assoc_fields ~context json in
  let* () =
    exact_fields
      ~context
      ~expected:
        [ "transition_id"
        ; "event_id"
        ; "lease_id"
        ; "lease_sequence"
        ; "settled_at_unix"
        ; "settlement"
        ]
      fields
  in
  let* transition_id = string_field ~context "transition_id" fields in
  let* event_id = string_field ~context "event_id" fields in
  let* lease_id = string_field ~context "lease_id" fields in
  let* lease_sequence = int64_field ~context "lease_sequence" fields in
  let* settled_at = float_field ~context "settled_at_unix" fields in
  let* settlement_json = required_field ~context "settlement" fields in
  let* settlement = settlement_of_yojson settlement_json in
  let expected_lease_id = lease_id_of_sequence lease_sequence in
  let expected_transition_id =
    match settlement with
    | Settle_exact disposition ->
      Printf.sprintf
        "%s:settle_exact:%s"
        expected_lease_id
        disposition.disposition_id
    | Ack
    | No_compaction _
    | Cancel_accepted _
    | Transfer_accepted _
    | Settle_from_source_terminal _
    | Requeue _
    | Escalate _ ->
      Printf.sprintf "%s:%s" expected_lease_id (settlement_kind_label settlement)
  in
  let expected_event_id = event_id_of_transition expected_transition_id in
  if Int64.compare lease_sequence 1L < 0
  then Error "event queue receipt lease sequence must be positive"
  else if not (Float.is_finite settled_at)
  then Error "event queue receipt settlement time must be finite"
  else if not (String.equal lease_id expected_lease_id)
  then Error (Printf.sprintf "event queue receipt lease id mismatch: %s" lease_id)
  else if not (String.equal transition_id expected_transition_id)
  then Error (Printf.sprintf "event queue receipt transition id mismatch: %s" transition_id)
  else if not (String.equal event_id expected_event_id)
  then Error (Printf.sprintf "event queue receipt event id mismatch: %s" event_id)
  else
    Ok
      { transition_id
      ; event_id
      ; lease_id
      ; lease_sequence
      ; settled_at
      ; settlement
      }
;;

let outbox_entry_to_yojson entry =
  `Assoc
    [ "receipt", transition_receipt_to_yojson entry.receipt
    ; "stimuli", `List (List.map Keeper_event_queue.stimulus_to_yojson entry.stimuli)
    ]
;;

let outbox_entry_of_yojson json =
  let context = "event queue outbox entry" in
  let* fields = assoc_fields ~context json in
  let* receipt_json = required_field ~context "receipt" fields in
  let* receipt = transition_receipt_of_yojson receipt_json in
  let* stimuli =
    list_field ~context "stimuli" Keeper_event_queue.stimulus_of_yojson fields
  in
  (* Re-enforce the settle-time receipt-vs-stimuli invariant at the decode
     boundary; malformed typed terminal receipts are rejected as [Error]. *)
  let* () = validate_settlement_for_stimuli receipt.settlement stimuli in
  Ok { receipt; stimuli }
;;

let exact_execution_binding_to_yojson binding =
  let status, terminal_cause, disposition =
    match binding.status with
    | Dispatch_uncertain -> "dispatch_uncertain", `Null, `Null
    | Terminal_quarantined cause ->
      ( "terminal_quarantined"
      , `String (exact_execution_terminal_cause_label cause)
      , `Null )
    | Disposition_prepared disposition ->
      "disposition_prepared", `Null, exact_source_disposition_to_yojson disposition
  in
  `Assoc
    [ "lease_id", `String binding.lease_id
    ; "lease_sequence", int64_json binding.lease_sequence
    ; "slot_id", `String binding.slot_id
    ; "call_id", `String binding.call_id
    ; "plan_fingerprint", `String binding.plan_fingerprint
    ; "request_body_sha256", `String binding.request_body_sha256
    ; "status", `String status
    ; "terminal_cause", terminal_cause
    ; "disposition", disposition
    ]
;;

let exact_execution_binding_of_yojson json =
  let context = "exact execution lease binding" in
  let* fields = assoc_fields ~context json in
  let has_disposition = List.mem_assoc "disposition" fields in
  let* () =
    exact_fields
      ~context
      ~expected:
        ([ "lease_id"
         ; "lease_sequence"
         ; "slot_id"
         ; "call_id"
         ; "plan_fingerprint"
         ; "request_body_sha256"
         ; "status"
         ; "terminal_cause"
         ]
         @ if has_disposition then [ "disposition" ] else [])
      fields
  in
  let* lease_id = string_field ~context "lease_id" fields in
  let* lease_sequence = int64_field ~context "lease_sequence" fields in
  let* slot_id = string_field ~context "slot_id" fields in
  let* call_id = string_field ~context "call_id" fields in
  let* plan_fingerprint = string_field ~context "plan_fingerprint" fields in
  let* request_body_sha256 = string_field ~context "request_body_sha256" fields in
  let* status_label = string_field ~context "status" fields in
  let* terminal_cause_json = required_field ~context "terminal_cause" fields in
  let disposition_json = List.assoc_opt "disposition" fields in
  let* status =
    match status_label, terminal_cause_json, disposition_json with
    | "dispatch_uncertain", `Null, (None | Some `Null) -> Ok Dispatch_uncertain
    | "terminal_quarantined", `String cause, (None | Some `Null) ->
      let* cause = exact_execution_terminal_cause_of_label cause in
      Ok (Terminal_quarantined cause)
    | "disposition_prepared", `Null, Some disposition_json ->
      let* disposition = exact_source_disposition_of_yojson disposition_json in
      (match disposition.outcome with
       | Terminal _ -> Ok (Disposition_prepared disposition))
    | "dispatch_uncertain", _, _ ->
      Error "dispatch-uncertain exact execution binding must not carry a terminal cause"
    | "terminal_quarantined", _, _ ->
      Error "terminally quarantined exact execution binding requires a terminal cause"
    | "disposition_prepared", _, _ ->
      Error "v5 exact execution binding status requires one source disposition"
    | status, _, _ ->
      Error (Printf.sprintf "unknown exact execution binding status: %s" status)
  in
  if Int64.compare lease_sequence 1L < 0
  then Error "exact execution binding lease sequence must be positive"
  else if not (String.equal lease_id (lease_id_of_sequence lease_sequence))
  then Error "exact execution binding lease id does not match its sequence"
  else if String.trim slot_id = ""
  then Error "exact execution binding slot id must not be empty"
  else if String.trim call_id = ""
  then Error "exact execution binding call id must not be empty"
  else if String.trim plan_fingerprint = ""
  then Error "exact execution binding plan fingerprint must not be empty"
  else if String.trim request_body_sha256 = ""
  then Error "exact execution binding request body sha256 must not be empty"
  else if
    match status with
    | Dispatch_uncertain | Terminal_quarantined _ -> false
    | Disposition_prepared disposition ->
      not
        (String.equal disposition.slot_id slot_id
         && String.equal disposition.call_id call_id
         && String.equal disposition.plan_fingerprint plan_fingerprint
         && String.equal disposition.request_body_sha256 request_body_sha256)
  then Error "exact source disposition does not match its full execution binding"
  else
    Ok
      { lease_id
      ; lease_sequence
      ; slot_id
      ; call_id
      ; plan_fingerprint
      ; request_body_sha256
      ; status
      }
;;

let to_yojson state =
  `Assoc
    [ "schema", `String schema
    ; "revision", int64_json state.revision
    ; "next_lease_sequence", int64_json state.next_lease_sequence
    ; "pending", Keeper_event_queue.queue_to_yojson state.pending
    ; "leases", `List (List.map lease_to_yojson state.leases)
    ; ( "last_settlement"
      , match state.last_settlement with
        | None -> `Null
        | Some receipt -> transition_receipt_to_yojson receipt )
    ; ( "transition_outbox"
      , `List (List.map outbox_entry_to_yojson state.transition_outbox) )
    ; ( "accepted_transfer_projections"
      , `List
          (List.map
             accepted_transfer_projection_to_yojson
             state.accepted_transfer_projections) )
    ; ( "exact_execution_bindings"
      , `List (List.map exact_execution_binding_to_yojson state.exact_execution_bindings) )
    ]
;;

let duplicate_by key values =
  let rec loop seen = function
    | [] -> None
    | value :: rest ->
      let key = key value in
      if List.exists (String.equal key) seen
      then Some key
      else loop (key :: seen) rest
  in
  loop [] values
;;

let duplicate_transfer_source (transfers : accepted_transfer list) =
  let rec loop seen (l : accepted_transfer list) =
    match l with
    | [] -> None
    | transfer :: rest ->
      (match
         List.find_opt
           (fun (prior : accepted_transfer) ->
              Keeper_event_queue.stimulus_identity_equal
                prior.source
                transfer.source)
           seen
       with
       | Some prior -> Some (prior, transfer)
       | None -> loop (transfer :: seen) rest)
  in
  loop [] transfers
;;

let validate_state state =
  if Int64.compare state.revision 0L < 0
  then Error "event queue revision must not be negative"
  else if Int64.compare state.next_lease_sequence 1L < 0
  then Error "event queue next lease sequence must be positive"
  else if List.length state.leases > 1
  then Error "event queue state must contain at most one active lease"
  else if List.length state.exact_execution_bindings > 1
  then Error "event queue state must contain at most one exact execution binding"
  else if
    List.exists
      (fun (binding : exact_execution_binding) ->
         Int64.compare binding.lease_sequence 1L < 0
         || not (String.equal binding.lease_id (lease_id_of_sequence binding.lease_sequence))
         || String.trim binding.slot_id = ""
         || String.trim binding.call_id = ""
         || String.trim binding.plan_fingerprint = ""
         || String.trim binding.request_body_sha256 = "")
      state.exact_execution_bindings
  then Error "event queue state contains an invalid exact execution binding"
  else if
    List.exists
      (fun (binding : exact_execution_binding) ->
         match binding.status with
         | Dispatch_uncertain | Terminal_quarantined _ -> false
         | Disposition_prepared disposition ->
           Result.is_error (validate_exact_source_disposition disposition)
           || not
                (String.equal binding.slot_id disposition.slot_id
                 && String.equal binding.call_id disposition.call_id
                 && String.equal
                      binding.plan_fingerprint
                      disposition.plan_fingerprint
                 && String.equal
                      binding.request_body_sha256
                      disposition.request_body_sha256)
           ||
           match disposition.outcome with
           | Terminal _ -> false)
      state.exact_execution_bindings
  then Error "event queue state contains an invalid exact source disposition"
  else if
    List.exists
      (fun (binding : exact_execution_binding) ->
         not
           (List.exists
              (fun (lease : lease) ->
                 String.equal lease.lease_id binding.lease_id
                 && Int64.equal lease.sequence binding.lease_sequence)
              state.leases))
      state.exact_execution_bindings
  then Error "exact execution binding has no matching active lease"
  else if List.length state.transition_outbox > 1
  then Error "event queue state must contain at most one unprojected transition"
  else if state.leases <> [] && state.transition_outbox <> []
  then Error "event queue state cannot contain both an active lease and an outbox transition"
  else if
    match state.last_settlement, state.transition_outbox with
    | Some receipt, [ entry ] ->
      String.equal receipt.transition_id entry.receipt.transition_id
    | None, _ | Some _, ([] | _ :: _ :: _) -> false
  then Error "event queue last settlement duplicates the unprojected transition"
  else
    match duplicate_by (fun (lease : lease) -> lease.lease_id) state.leases with
    | Some lease_id -> Error (Printf.sprintf "duplicate event queue lease id: %s" lease_id)
    | None ->
      (match
         duplicate_by
           (fun entry -> entry.receipt.transition_id)
           state.transition_outbox
       with
       | Some transition_id ->
         Error (Printf.sprintf "duplicate event queue transition id: %s" transition_id)
       | None ->
         (match
            duplicate_by
              (fun (transfer : accepted_transfer) -> transfer.operator_operation_id)
              state.accepted_transfer_projections
          with
          | Some operation_id ->
            Error
              (Printf.sprintf
                 "duplicate target transfer projection operation id: %s"
                 operation_id)
          | None ->
            (match duplicate_transfer_source state.accepted_transfer_projections with
             | Some _ -> Error "duplicate target transfer projection source identity"
             | None ->
               let max_sequence =
                 List.fold_left
                   (fun acc (lease : lease) -> Int64.max acc lease.sequence)
                   0L
                   state.leases
               in
               let max_sequence =
                 List.fold_left
                   (fun acc entry -> Int64.max acc entry.receipt.lease_sequence)
                   max_sequence
                   state.transition_outbox
               in
               let max_sequence =
                 match state.last_settlement with
                 | None -> max_sequence
                 | Some receipt -> Int64.max max_sequence receipt.lease_sequence
               in
               if Int64.compare state.next_lease_sequence max_sequence <= 0
               then
                 Error
                   "event queue next lease sequence must exceed every lease and receipt sequence"
               else Ok state)))
;;

let of_yojson json =
  let context = "keeper event queue state" in
  let* fields = assoc_fields ~context json in
  let* schema_value = string_field ~context "schema" fields in
  if not (String.equal schema_value schema)
  then
    Error
      (Printf.sprintf
         "unsupported keeper event queue state schema (reset required): %s"
         schema_value)
  else
    let expected_fields =
      [ "schema"
      ; "revision"
      ; "next_lease_sequence"
      ; "pending"
      ; "leases"
      ; "last_settlement"
      ; "transition_outbox"
      ; "accepted_transfer_projections"
      ; "exact_execution_bindings"
      ]
    in
    let* () = exact_fields ~context ~expected:expected_fields fields in
    let* revision = int64_field ~context "revision" fields in
    let* next_lease_sequence = int64_field ~context "next_lease_sequence" fields in
    let* pending_json = required_field ~context "pending" fields in
    let* pending = Keeper_event_queue.queue_of_yojson pending_json in
    let* leases = list_field ~context "leases" lease_of_yojson fields in
    let* last_settlement =
      match List.assoc_opt "last_settlement" fields with
      | Some `Null -> Ok None
      | Some json -> transition_receipt_of_yojson json |> Result.map Option.some
      | None -> Error "keeper event queue state missing required field last_settlement"
    in
    let* transition_outbox =
      list_field ~context "transition_outbox" outbox_entry_of_yojson fields
    in
    let* accepted_transfer_projections =
      list_field
        ~context
        "accepted_transfer_projections"
        accepted_transfer_projection_of_yojson
        fields
    in
    let* bindings_json =
      match List.assoc_opt "exact_execution_bindings" fields with
      | Some (`List bindings) -> Ok bindings
      | Some _ ->
        Error "keeper event queue state exact_execution_bindings must be a list"
      | None ->
        Error "keeper event queue state missing exact_execution_bindings"
    in
    let* () =
      if
        List.exists
          (function
            | `Assoc fields -> not (List.mem_assoc "disposition" fields)
            | _ -> true)
          bindings_json
      then Error "v5 exact execution binding requires disposition evidence field"
      else Ok ()
    in
    let rec decode_bindings acc = function
      | [] -> Ok (List.rev acc)
      | binding_json :: rest ->
        let* binding = exact_execution_binding_of_yojson binding_json in
        decode_bindings (binding :: acc) rest
    in
    let* exact_execution_bindings = decode_bindings [] bindings_json in
    validate_state
      { revision
      ; next_lease_sequence
      ; pending
      ; leases
      ; last_settlement
      ; transition_outbox
      ; accepted_transfer_projections
      ; exact_execution_bindings
      }
;;
