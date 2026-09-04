(** Durable, nonblocking HITL requests for Keeper external effects. *)

open Keeper_approval_queue_rules_types
open Keeper_approval_queue_rules

type storage_error =
  { path : string
  ; reason : string
  }

type summary_transition_rejection =
  | Summary_exact_attempt_bound of exact_attempt_binding

type summary_transition_error =
  | Summary_transition_storage_error of storage_error
  | Summary_transition_rejected of summary_transition_rejection

type summary_owner_retirement_error =
  | Summary_owner_retirement_storage_error of storage_error
  | Summary_owner_retirement_exact_attempt_unsettled of exact_attempt_binding

type exact_attempt_rejection =
  | Exact_attempt_not_found of string
  | Exact_attempt_key_mismatch of
      { approval_id : string
      ; input_hash : string
      ; sequence : int
      }
  | Exact_attempt_invalid_identity of string
  | Exact_attempt_summary_not_pending of string
  | Exact_attempt_unbound_state of string
  | Exact_attempt_disposition_conflict of
      { approval_id : string
      ; disposition : summary_attempt_disposition
      }
  | Exact_attempt_identity_conflict of exact_attempt_binding
  | Exact_attempt_status_conflict of exact_attempt_binding
  | Exact_attempt_provenance_mismatch of
      { approval_id : string
      ; expected_call_id : string
      ; actual_model_run_id : string
      }
  | Exact_attempt_content_conflict of string

type exact_attempt_error =
  | Exact_attempt_storage_error of storage_error
  | Exact_attempt_rejected of exact_attempt_rejection

type exact_write_outcome =
  Keeper_event_queue_persistence.exact_write_outcome =
  | Fsync_completed
  | Visible_sync_unconfirmed of string

type exact_attempt_transition =
  { changed : bool
  ; write_outcome : exact_write_outcome
  }

type approved_resolution_request =
  { keeper_name : string
  ; tool_name : string
  ; input : Yojson.Safe.t
  }

type grant_error =
  | Grant_store_unavailable of storage_error
  | Grant_replay_projection_unavailable of storage_error
  | Grant_workspace_mismatch of
      { approval_id : string
      ; requested_base_path : string
      ; stored_base_path : string
      }
  | Grant_still_pending of string
  | Grant_resolution_not_approved of string
  | Grant_resolution_missing of string
  | Grant_replay_not_consumed of string
  | Grant_replay_outcome_conflict of string

type approved_resolution_state =
  | Resolution_unconsumed
  | Resolution_consumed

type resolution_replay_outcome =
  | Replay_applied of Tool_output.artifact_ref
  | Replay_applied_with_warning of Tool_output.artifact_ref
  | Replay_failed of Tool_output.artifact_ref
  | Replay_indeterminate of Tool_output.artifact_ref

type approved_resolution_delivery =
  { request : approved_resolution_request
  ; state : approved_resolution_state
  ; replay_outcome : resolution_replay_outcome option
  }

type grant_consumption =
  | Consumption_committed of Keeper_approval.Audit.receipt
  | Consumption_already_committed
  | Consumption_not_matching

type pending_submission_disposition =
  | Pending_created of Keeper_approval.Audit.receipt
  | Pending_deduplicated
  | Folded_onto_unconsumed_grant

type pending_submission =
  { approval_id : string
  ; disposition : pending_submission_disposition
  }

type replay_recording =
  | Replay_recorded
  | Replay_already_recorded

type delivery_replay_failure =
  { approval_id : string
  ; reason : string
  }

type install_report =
  { loaded_pending : int
  ; replayed_deliveries : int
  ; delivery_replay_failures : delivery_replay_failure list
  ; replay_projection_error : storage_error option
  }

type install_error = Install_storage_failed of storage_error

type resolution_result =
  { remembered_rule : approval_rule option
  ; audit_receipts : Keeper_approval.Audit.receipt list
  }

type persisted_delivery =
  { entry : pending_approval
  ; decision : decision
  ; source : decision_source
  ; remember_rule : bool
  ; rule_expires_at : float option
  ; created_by : string option
  ; grant_consumed : bool
  ; replay_outcome : resolution_replay_outcome option
  }

let storage_error_to_string error =
  Printf.sprintf "%s: %s" error.path error.reason
;;

let approval_queue_unavailable_title =
  "Gate durable queue unavailable · runtime reset required"
;;

let approval_queue_unavailable_severity = "bad"
let approval_queue_unavailable_icon = "!"
let approval_queue_ready_state_json = `Assoc [ "state", `String "ready" ]

let summary_attempt_start_reserved_operator_detail =
  "Auto Judge worker start is durably reserved before exact attempt binding."
;;

let approval_queue_unavailable_state_json error =
  `Assoc
    [ "state", `String "unavailable"
    ; "code", `String "reset_required"
    ; "title", `String approval_queue_unavailable_title
    ; "operator_detail", `String (storage_error_to_string error)
    ; "severity", `String approval_queue_unavailable_severity
    ; "icon", `String approval_queue_unavailable_icon
    ]
;;

let exact_attempt_binding_to_string binding =
  let status =
    match binding.status with
    | Exact_quarantined cause ->
      Printf.sprintf
        "quarantined:%s"
        (exact_attempt_quarantine_cause_to_string cause)
    | Exact_dispatch_uncertain
    | Exact_released_before_dispatch
    | Exact_released_recovery_required
    | Exact_restart_quarantined
    | Exact_completed ->
      exact_attempt_status_to_string binding.status
  in
  Printf.sprintf
    "approval=%s input_hash=%s sequence=%d slot=%s call=%s plan=%s request=%s status=%s"
    binding.approval_id
    binding.input_hash
    binding.sequence
    binding.slot_id
    binding.call_id
    binding.plan_fingerprint
    binding.request_body_sha256
    status
;;

let summary_transition_error_to_string = function
  | Summary_transition_storage_error error -> storage_error_to_string error
  | Summary_transition_rejected (Summary_exact_attempt_bound binding) ->
    "unbound summary transition rejected for exact attempt: "
    ^ exact_attempt_binding_to_string binding
;;

let summary_owner_retirement_error_to_string = function
  | Summary_owner_retirement_storage_error error ->
    storage_error_to_string error
  | Summary_owner_retirement_exact_attempt_unsettled binding ->
    Printf.sprintf
      "approval summary owner retirement blocked by unsettled exact attempt: approval=%s slot=%s call=%s"
      binding.approval_id
      binding.slot_id
      binding.call_id
;;

let exact_attempt_error_to_string = function
  | Exact_attempt_storage_error error -> storage_error_to_string error
  | Exact_attempt_rejected (Exact_attempt_not_found approval_id) ->
    Printf.sprintf "exact attempt approval %s was not found" approval_id
  | Exact_attempt_rejected
      (Exact_attempt_key_mismatch { approval_id; input_hash; sequence }) ->
    Printf.sprintf
      "exact attempt key mismatch approval=%s input_hash=%s sequence=%d"
      approval_id
      input_hash
      sequence
  | Exact_attempt_rejected (Exact_attempt_invalid_identity field) ->
    Printf.sprintf "exact attempt identity field %s is invalid" field
  | Exact_attempt_rejected (Exact_attempt_summary_not_pending approval_id) ->
    Printf.sprintf "exact attempt approval %s summary is not pending" approval_id
  | Exact_attempt_rejected (Exact_attempt_unbound_state approval_id) ->
    Printf.sprintf "exact attempt approval %s has no bound identity" approval_id
  | Exact_attempt_rejected
      (Exact_attempt_disposition_conflict { approval_id; disposition }) ->
    let disposition =
      match disposition with
      | Summary_attempt_ready -> "ready"
      | Summary_attempt_in_flight -> "in_flight"
      | Summary_attempt_identity_unbound -> "identity_unbound"
      | Summary_attempt_persistence_uncertain -> "persistence_uncertain"
      | Summary_attempt_pre_worker_unavailable blocked ->
        "pre_worker_unavailable:"
        ^ summary_attempt_pre_worker_unavailable_code_to_string
            blocked.reason_code
      | Summary_attempt_settled -> "settled"
    in
    Printf.sprintf
      "exact attempt approval %s rejects dispatch from disposition %s"
      approval_id
      disposition
  | Exact_attempt_rejected (Exact_attempt_identity_conflict binding) ->
    "exact attempt identity conflicts with durable binding: "
    ^ exact_attempt_binding_to_string binding
  | Exact_attempt_rejected (Exact_attempt_status_conflict binding) ->
    "exact attempt status rejects this transition: "
    ^ exact_attempt_binding_to_string binding
  | Exact_attempt_rejected
      (Exact_attempt_provenance_mismatch
        { approval_id; expected_call_id; actual_model_run_id }) ->
    Printf.sprintf
      "exact attempt approval %s summary provenance mismatch: expected call_id=%s, \
       actual model_run_id=%s"
      approval_id
      expected_call_id
      actual_model_run_id
  | Exact_attempt_rejected (Exact_attempt_content_conflict approval_id) ->
    Printf.sprintf
      "exact attempt approval %s already completed with different content"
      approval_id
;;

let grant_error_to_string = function
  | Grant_store_unavailable error -> storage_error_to_string error
  | Grant_replay_projection_unavailable error ->
    Printf.sprintf
      "derived replay projection unavailable: %s"
      (storage_error_to_string error)
  | Grant_workspace_mismatch
      { approval_id; requested_base_path; stored_base_path } ->
    Printf.sprintf
      "approval %s belongs to workspace %s, not %s"
      approval_id
      stored_base_path
      requested_base_path
  | Grant_still_pending approval_id ->
    Printf.sprintf "approval %s has not been resolved" approval_id
  | Grant_resolution_not_approved approval_id ->
    Printf.sprintf "approval %s was not approved" approval_id
  | Grant_resolution_missing approval_id ->
    Printf.sprintf "approval %s has no durable resolution journal" approval_id
  | Grant_replay_not_consumed approval_id ->
    Printf.sprintf
      "approval %s cannot record a replay outcome before its grant is consumed"
      approval_id
  | Grant_replay_outcome_conflict approval_id ->
    Printf.sprintf
      "approval %s already has a different durable replay outcome"
      approval_id
;;

let install_error_to_string = function
  | Install_storage_failed error -> storage_error_to_string error
;;

(* Bumped to 9 by the goal_ids removal: #29256 dropped the field from the entry
   contract without moving the version, so an installed v8 store failed the
   field check with "contains unsupported field goal_ids" instead of the version
   check that tells an operator what to do about it. A format change the version
   does not record is a format change nobody can diagnose. *)
let pending_store_version = 9
let pending_store_surface = "keeper_gate_pending"
let replay_results_store_version = 1
let replay_results_store_surface = "keeper_gate_replay_results"
let pending_store_mutex = Cross_context_mutex.create ()
let deliveries : persisted_delivery SMap.t Atomic.t = Atomic.make SMap.empty
let unavailable_stores : storage_error SMap.t Atomic.t = Atomic.make SMap.empty
(* A partially readable snapshot remains unavailable for mutations, but its
   valid entries can still be shown to the operator. Keep the per-entry read
   errors separately so the projection distinguishes "no approvals" from
   "some approvals could not be read" without rewriting the source file. *)
let pending_read_errors : storage_error list SMap.t Atomic.t =
  Atomic.make SMap.empty
let replay_projection_errors : storage_error SMap.t Atomic.t =
  Atomic.make SMap.empty
;;

let store_revisions : int SMap.t Atomic.t = Atomic.make SMap.empty
(** Process projection of the next value persisted in each workspace snapshot. *)
let next_sequences : int SMap.t Atomic.t = Atomic.make SMap.empty
let first_sequence = 1

(** Serialize one durable pending/delivery snapshot transition across both Eio
    fibers and non-Eio callers.  A plain [Stdlib.Mutex.protect] is invalid here:
    snapshot publication uses [Eio.Path] and may suspend while the lock is held,
    letting another fiber on the same domain re-enter the OS mutex and raise
    [Sys_error "Mutex.lock: Resource deadlock avoided"].

    The shared cross-context authority keeps acquisition cancellable and defers
    cancellation only after both gates are held, so a published snapshot is not
    reported as an ambiguous cancelled operation. *)
let with_pending_store_lock f =
  Cross_context_mutex.with_durable_lock pending_store_mutex f
;;

let bump_store_revision_unlocked ~base_path =
  let revisions = Atomic.get store_revisions in
  let revision =
    match SMap.find_opt base_path revisions with
    | Some revision -> revision
    | None -> 0
  in
  Atomic.set store_revisions (SMap.add base_path (revision + 1) revisions)
;;

let mark_store_unavailable_unlocked ~base_path error =
  Atomic.set
    unavailable_stores
    (SMap.add base_path error (Atomic.get unavailable_stores));
  bump_store_revision_unlocked ~base_path
;;

let clear_store_unavailable_unlocked ~base_path =
  Atomic.set
    unavailable_stores
    (SMap.remove base_path (Atomic.get unavailable_stores));
  bump_store_revision_unlocked ~base_path
;;

let store_revision_unlocked ~base_path =
  Option.value
    (SMap.find_opt base_path (Atomic.get store_revisions))
    ~default:0
;;

let store_revision_for_workspace ~base_path =
  store_revision_unlocked ~base_path
;;

let pending_store_path ~base_path =
  Keeper_gate_path.pending ~base_path
;;

let replay_results_store_path ~base_path =
  Keeper_gate_path.replay_results ~base_path
;;

let report_pending_read_drop ~reason ~path ~detail =

  let reason_wire = Read_drop_reason.to_wire reason in
  Safe_ops.report_persistence_read_drop
    ~on_drop:(fun () ->
      Otel_metric_store.inc_counter
        Otel_metric_store.metric_persistence_read_drops
        ~labels:[ "surface", pending_store_surface; "reason", reason_wire ]
        ())
    ~surface:pending_store_surface
    ~reason
    ~path
    ~detail
;;

let report_replay_results_read_drop ~reason ~path ~detail =

  let reason_wire = Read_drop_reason.to_wire reason in
  Safe_ops.report_persistence_read_drop
    ~on_drop:(fun () ->
      Otel_metric_store.inc_counter
        Otel_metric_store.metric_persistence_read_drops
        ~labels:
          [ "surface", replay_results_store_surface
          ; "reason", reason_wire
          ]
        ())
    ~surface:replay_results_store_surface
    ~reason
    ~path
    ~detail
;;

let exact_request_context_version = 1

let pending_entry_to_yojson
      ?(include_request_context = true)
      (entry : pending_approval)
  =
  let request_context =
    if include_request_context then entry.request_context else None
  in
  `Assoc
    [ "id", `String entry.id
    ; "keeper_name", `String entry.keeper_name
    ; "tool_name", `String entry.tool_name
    ; "input_hash", `String entry.input_hash
    ; "input", entry.input
    ; "sequence", `Int entry.sequence
    ; "requested_at", `Float entry.requested_at
    ; "turn_id", Json_util.int_opt_to_json entry.turn_id
    ; ( "request_context"
      , match request_context with
        | Some context -> context
        | None -> `Null )
    ; ( "request_context_version"
      , match request_context with
        | Some _ -> `Int exact_request_context_version
        | None -> `Null )
    ; "task_id", Json_util.string_opt_to_json entry.task_id
    ; "goal_id", Json_util.string_opt_to_json entry.goal_id
      ; "continuation_channel", Keeper_continuation_channel.to_yojson entry.continuation_channel
      ; "summary_status", summary_status_to_yojson entry.summary_status
      ; "exact_attempt", exact_attempt_state_to_yojson entry.exact_attempt
      ; ( "summary_attempt_disposition"
        , summary_attempt_disposition_to_yojson
            entry.summary_attempt_disposition )
      ]
;;

let approval_decision_to_yojson = function
  | Decision.Approve -> `Assoc [ "kind", `String "approve" ]
  | Decision.Reject reason ->
    `Assoc [ "kind", `String "reject"; "reason", `String reason ]
;;

let resolution_replay_outcome_to_yojson = function
  | Replay_applied output_ref ->
    `Assoc
      [ "kind", `String "applied"
      ; "output_ref", Tool_output.normalized_artifact_ref_to_json output_ref
      ]
  | Replay_applied_with_warning detail_ref ->
    `Assoc
      [ "kind", `String "applied_with_warning"
      ; "detail_ref", Tool_output.normalized_artifact_ref_to_json detail_ref
      ]
  | Replay_failed detail_ref ->
    `Assoc
      [ "kind", `String "failed"
      ; "detail_ref", Tool_output.normalized_artifact_ref_to_json detail_ref
      ]
  | Replay_indeterminate detail_ref ->
    `Assoc
      [ "kind", `String "indeterminate"
      ; "detail_ref", Tool_output.normalized_artifact_ref_to_json detail_ref
      ]
;;

(* [request_context] is the Auto Judge / HITL summary input: request-local
   causal evidence (bounded history lead-up, the triggering user message,
   current dynamic context, and completed tool calls) captured at request time.
   It is not the whole Keeper turn or its system prompts. Its only reader is
   Hitl_summary_worker, which runs while the entry is still pending. A delivery
   is already resolved, so the context is dead weight there — and it dominated
   the store: 71 deliveries held ~30MB of duplicated context against 19 bytes
   of decision each.

   Dropping it on the delivery wire shape stays decode-compatible: the reader
   treats [request_context] as optional and keys the version field off its
   presence, so existing snapshots still load and re-save smaller. *)
let persisted_delivery_to_yojson delivery =
  `Assoc
    [ "entry", pending_entry_to_yojson ~include_request_context:false delivery.entry
    ; "decision", approval_decision_to_yojson delivery.decision
    ; "source", `String (decision_source_to_string delivery.source)
    ; "remember_rule", `Bool delivery.remember_rule
    ; "rule_expires_at", Json_util.float_opt_to_json delivery.rule_expires_at
    ; "created_by", Json_util.string_opt_to_json delivery.created_by
    ; "grant_consumed", `Bool delivery.grant_consumed
    ]
;;

let map_values_for_base ~base_path map project =
  SMap.bindings map
  |> List.filter_map (fun (_id, value) ->
    if String.equal (project value).audit_base_path base_path then Some value else None)
;;

let snapshot_to_yojson ~base_path ~next_sequence ~pending_map ~delivery_map =
  let pending_entries =
    map_values_for_base ~base_path pending_map Fun.id
    (* Wrapped rather than passed bare: [pending_entry_to_yojson] now leads with
       an optional argument, which OCaml only erases at application. *)
    |> List.map (fun entry -> pending_entry_to_yojson entry)
  in
  let delivery_entries =
    map_values_for_base ~base_path delivery_map (fun delivery -> delivery.entry)
    |> List.map persisted_delivery_to_yojson
  in
  `Assoc
    [ "version", `Int pending_store_version
    ; "next_sequence", `Int next_sequence
    ; "pending", `List pending_entries
    ; "deliveries", `List delivery_entries
    ]
;;

let replay_results_to_yojson ~base_path ~delivery_map =
  let outcomes =
    map_values_for_base
      ~base_path
      delivery_map
      (fun delivery -> delivery.entry)
    |> List.filter_map (fun delivery ->
      Option.map
        (fun outcome ->
           `Assoc
             [ "approval_id", `String delivery.entry.id
             ; "outcome", resolution_replay_outcome_to_yojson outcome
             ])
        delivery.replay_outcome)
  in
  `Assoc
    [ "version", `Int replay_results_store_version
    ; "outcomes", `List outcomes
    ]
;;

let save_snapshot_file_unlocked
      ~base_path
      ~next_sequence
      ~pending_map
      ~delivery_map
    =
    let path = pending_store_path ~base_path in
    try
      Fs_compat.mkdir_p (Filename.dirname path);
      let body =
        snapshot_to_yojson ~base_path ~next_sequence ~pending_map ~delivery_map
        |> Yojson.Safe.pretty_to_string
      in
      (match Fs_compat.save_file_atomic path body with
       | Ok () -> Ok ()
       | Error reason -> Error { path; reason })
    with
    | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn -> Error { path; reason = Printexc.to_string exn }
;;

let save_snapshot_file_strict_staged_unlocked
      ~save_file_atomic_strict_staged
      ~base_path
      ~next_sequence
      ~pending_map
      ~delivery_map
  =
  let path = pending_store_path ~base_path in
  try
    Fs_compat.mkdir_p (Filename.dirname path);
    let body =
      snapshot_to_yojson ~base_path ~next_sequence ~pending_map ~delivery_map
      |> Yojson.Safe.pretty_to_string
    in
    match save_file_atomic_strict_staged path body with
    | Ok () -> Ok Fsync_completed
    | Error (failure : Fs_compat.atomic_replace_failure) ->
      let reason = Fs_compat.atomic_replace_failure_to_string failure in
      (match failure.stage with
       | Fs_compat.Before_rename ->
         (match failure.exception_ with
          | Eio.Cancel.Cancelled _ ->
            Printexc.raise_with_backtrace failure.exception_ failure.backtrace
          | _ -> Error { path; reason })
       | Fs_compat.After_rename -> Ok (Visible_sync_unconfirmed reason))
  with
  | Eio.Cancel.Cancelled _ as exn ->
    let backtrace = Printexc.get_raw_backtrace () in
    Printexc.raise_with_backtrace exn backtrace
  | exn -> Error { path; reason = Printexc.to_string exn }
;;

let save_replay_results_file_unlocked ~base_path ~delivery_map =
  let path = replay_results_store_path ~base_path in
  try
    Fs_compat.mkdir_p (Filename.dirname path);
    let body =
      replay_results_to_yojson ~base_path ~delivery_map
      |> Yojson.Safe.pretty_to_string
    in
    match Fs_compat.save_file_atomic_strict_staged path body with
    | Ok () -> Ok Fsync_completed
    | Error (failure : Fs_compat.atomic_replace_failure) ->
      let reason = Fs_compat.atomic_replace_failure_to_string failure in
      (match failure.stage with
       | Fs_compat.Before_rename ->
         (match failure.exception_ with
          | Eio.Cancel.Cancelled _ ->
            Printexc.raise_with_backtrace failure.exception_ failure.backtrace
          | _ -> Error { path; reason })
       | Fs_compat.After_rename -> Ok (Visible_sync_unconfirmed reason))
  with
  | Eio.Cancel.Cancelled _ as exn ->
    let backtrace = Printexc.get_raw_backtrace () in
    Printexc.raise_with_backtrace exn backtrace
  | exn -> Error { path; reason = Printexc.to_string exn }
;;

(* Both publish paths below end the same way: a write that landed changed what
   this queue publishes, and a write that failed took the store out of service.
   The revision they move is what {!store_revision_for_workspace} answers, and
   the dashboard's Gate projection is cached under a key built from it.

   Until 2026-08-31 only the two availability transitions moved it, so a
   landed write -- an enqueue, a resolution, a completed delivery -- left the
   key unchanged and every reader kept the pre-write snapshot for the cache's
   whole life. A resolved approval was therefore republished as still pending,
   and an operator answering it from the TUI saw the row come back on the next
   poll and answered it again: one approval in the live workspace carries three
   [resolved] audit rows from a single actor minutes apart. *)
let publish_snapshot_outcome ~base_path result =
  (match result with
   | Ok _ -> bump_store_revision_unlocked ~base_path
   | Error error -> mark_store_unavailable_unlocked ~base_path error);
  result
;;

let persist_snapshot_with_sequence_unlocked
      ~base_path
      ~next_sequence
      ~pending_map
      ~delivery_map
  =
  match SMap.find_opt base_path (Atomic.get unavailable_stores) with
  | Some error -> Error error
  | None ->
    publish_snapshot_outcome
      ~base_path
      (save_snapshot_file_unlocked
         ~base_path
         ~next_sequence
         ~pending_map
         ~delivery_map)
;;

type store_lifecycle =
  | Uninstalled
  | Ready of int
  | Unavailable of storage_error

let next_sequence_lifecycle ~base_path =
  match SMap.find_opt base_path (Atomic.get unavailable_stores) with
  | Some error -> Unavailable error
  | None ->
    (match SMap.find_opt base_path (Atomic.get next_sequences) with
     | Some sequence -> Ready sequence
     | None -> Uninstalled)
;;

let persist_snapshot_unlocked ~base_path ~pending_map ~delivery_map =
  match next_sequence_lifecycle ~base_path with
  | Ready next_sequence ->
    persist_snapshot_with_sequence_unlocked
      ~base_path
      ~next_sequence
      ~pending_map
      ~delivery_map
  | Uninstalled ->
    Error
      { path = pending_store_path ~base_path
      ; reason =
          "gate_pending store is not installed; install_persistence must \
           complete before publishing"
      }
  | Unavailable error -> Error error
;;

let persist_snapshot_exact_unlocked
      ~save_file_atomic_strict_staged
      ~base_path
      ~pending_map
      ~delivery_map
  =
  match next_sequence_lifecycle ~base_path with
  | Ready next_sequence ->
    publish_snapshot_outcome
      ~base_path
      (save_snapshot_file_strict_staged_unlocked
         ~save_file_atomic_strict_staged
         ~base_path
         ~next_sequence
         ~pending_map
         ~delivery_map)
  | Uninstalled ->
    Error
      { path = pending_store_path ~base_path
      ; reason =
          "gate_pending store is not installed; install_persistence must \
           complete before publishing"
      }
  | Unavailable error -> Error error
;;

(* Assoc-field validators live in Json_util; these aliases keep the call
   sites in this module short. *)
let reject_unknown_fields = Json_util.reject_unknown_fields
let required_string = Json_util.require_field_string
let required_float = Json_util.require_field_float
let required_positive_int = Json_util.require_field_positive_int
let required_member ~surface field fields =
  match List.assoc_opt field fields with
  | Some value -> Ok value
  | None -> Error (Printf.sprintf "%s.%s is required" surface field)
;;

let optional_string ~surface field fields =
  match List.assoc_opt field fields with
  | None | Some `Null -> Ok None
  | Some (`String value) when String.trim value <> "" -> Ok (Some value)
  | Some (`String _) -> Error (Printf.sprintf "%s.%s must be non-blank" surface field)
  | Some _ -> Error (Printf.sprintf "%s.%s must be a string or null" surface field)
;;

let optional_nonnegative_int ~surface field fields =
  match List.assoc_opt field fields with
  | None | Some `Null -> Ok None
  | Some (`Int value) when value >= 0 -> Ok (Some value)
  | Some _ ->
    Error (Printf.sprintf "%s.%s must be a non-negative integer or null" surface field)
;;

let optional_float ~surface field fields =
  match List.assoc_opt field fields with
  | None | Some `Null -> Ok None
  | Some (`Float value) -> Ok (Some value)
  | Some (`Int value) -> Ok (Some (Float.of_int value))
  | Some _ -> Error (Printf.sprintf "%s.%s must be a number or null" surface field)
;;

let exact_attempt_identity_matches
      (left : exact_attempt_binding)
      (right : exact_attempt_binding)
  =
  String.equal left.approval_id right.approval_id
  && String.equal left.input_hash right.input_hash
  && Int.equal left.sequence right.sequence
  && String.equal left.slot_id right.slot_id
  && String.equal left.call_id right.call_id
  && String.equal left.plan_fingerprint right.plan_fingerprint
  && String.equal left.request_body_sha256 right.request_body_sha256
;;

let exact_attempt_quarantine_summary_status cause =
  Summary_failed
    { reason =
        Printf.sprintf
          "Auto Judge exact attempt quarantined: %s"
          (exact_attempt_quarantine_cause_to_string cause)
    }
;;

let validate_entry_exact_attempt
      ~id
      ~input_hash
      ~sequence
      ~summary_status
      ~summary_attempt_disposition
      exact_attempt
  =
  match summary_attempt_disposition, exact_attempt, summary_status with
  | Summary_attempt_ready, Exact_unbound,
    (Summary_not_requested | Summary_pending) ->
    Ok ()
  | Summary_attempt_identity_unbound, Exact_unbound, Summary_pending ->
    Ok ()
  | Summary_attempt_persistence_uncertain, Exact_unbound, Summary_pending ->
    Ok ()
  | Summary_attempt_pre_worker_unavailable blocked, Exact_unbound,
    (Summary_not_requested | Summary_pending)
    when
      let detail = String.trim blocked.operator_detail in
      not (String.equal detail "")
      && String.equal detail blocked.operator_detail ->
    Ok ()
  | _, Exact_bound binding, _
    when not
           (String.equal binding.approval_id id
            && String.equal binding.input_hash input_hash
            && Int.equal binding.sequence sequence) ->
    Error "exact attempt binding key does not match its approval entry"
  | (Summary_attempt_settled | Summary_attempt_persistence_uncertain),
    Exact_bound { status = Exact_completed; _ }, Summary_available _ ->
    Ok ()
  | (Summary_attempt_settled | Summary_attempt_persistence_uncertain),
    Exact_bound { status = Exact_quarantined cause; _ }, summary_status
    when summary_status = exact_attempt_quarantine_summary_status cause ->
    Ok ()
  | Summary_attempt_in_flight,
    Exact_bound
      { status =
          ( Exact_dispatch_uncertain
          | Exact_released_before_dispatch )
      ; _
      },
    Summary_pending ->
    Ok ()
  | Summary_attempt_persistence_uncertain,
    Exact_bound
      { status =
          ( Exact_dispatch_uncertain
          | Exact_released_before_dispatch
          | Exact_released_recovery_required
          | Exact_restart_quarantined )
      ; _
      },
    Summary_pending ->
    Ok ()
  | _, Exact_bound { status = Exact_completed; _ }, _ ->
    Error "completed exact attempt requires an available summary"
  | _ ->
    Error "exact attempt and summary status are not a valid current-schema pair"
;;

let summary_attempt_allows_exact_bind = function
  | Summary_attempt_ready
  | Summary_attempt_pre_worker_unavailable
      { reason_code = Summary_pre_worker_start_reserved; _ } ->
    true
  | Summary_attempt_in_flight
  | Summary_attempt_identity_unbound
  | Summary_attempt_persistence_uncertain
  | Summary_attempt_pre_worker_unavailable _
  | Summary_attempt_settled ->
    false
;;

let pending_entry_of_yojson ~base_path json =
  match json with
  | `Assoc fields ->
    let ( let* ) = Result.bind in
    let surface = "gate_pending.entry" in
    let* () =
      reject_unknown_fields
        ~surface
        ~allowed:
          [ "id"
          ; "keeper_name"
          ; "tool_name"
          ; "input_hash"
          ; "input"
          ; "sequence"
          ; "requested_at"
          ; "turn_id"
          ; "request_context"
          ; "request_context_version"
          ; "task_id"
          ; "goal_id"
          ; "continuation_channel"
          ; "summary_status"
          ; "exact_attempt"
          ; "summary_attempt_disposition"
          ]
        fields
    in
    let* id = required_string ~surface "id" fields in
    let* keeper_name = required_string ~surface "keeper_name" fields in
    let* tool_name = required_string ~surface "tool_name" fields in
    let* input_hash = required_string ~surface "input_hash" fields in
    let* input = required_member ~surface "input" fields in
    let expected_hash = request_fingerprint input in
    let* () =
      if String.equal input_hash expected_hash
      then Ok ()
      else Error (Printf.sprintf "%s.input_hash does not match input" surface)
    in
    let* sequence = required_positive_int ~surface "sequence" fields in
    let* requested_at = required_float ~surface "requested_at" fields in
    let* turn_id = optional_nonnegative_int ~surface "turn_id" fields in
    let* request_context =
      match
        List.assoc_opt "request_context" fields,
        List.assoc_opt "request_context_version" fields
      with
      | (None | Some `Null), (None | Some `Null) -> Ok None
      | Some context, Some (`Int version)
        when Int.equal version exact_request_context_version ->
        Ok (Some context)
      | Some _, (None | Some `Null) ->
        Error (surface ^ ".request_context requires request_context_version")
      | (None | Some `Null), Some (`Int version) ->
        Error
          (Printf.sprintf
             "%s.request_context_version=%d requires request_context"
             surface
             version)
      | Some _, Some (`Int version) ->
        Error
          (Printf.sprintf
             "%s.request_context_version=%d is unsupported"
             surface
             version)
      | _, Some _ ->
        Error
          (Printf.sprintf
             "%s.request_context_version must be an integer or null"
             surface)
    in
    let* task_id = optional_string ~surface "task_id" fields in
    let* goal_id = optional_string ~surface "goal_id" fields in
    let* continuation_json = required_member ~surface "continuation_channel" fields in
    let* continuation_channel = Keeper_continuation_channel.of_yojson continuation_json in
      let* summary_json = required_member ~surface "summary_status" fields in
      let* summary_status = summary_status_of_yojson_with_error summary_json in
      let* exact_attempt_json = required_member ~surface "exact_attempt" fields in
      let* exact_attempt = exact_attempt_state_of_yojson_with_error exact_attempt_json in
      let* summary_attempt_disposition_json =
        required_member ~surface "summary_attempt_disposition" fields
      in
      let* summary_attempt_disposition =
        summary_attempt_disposition_of_yojson_with_error
          summary_attempt_disposition_json
      in
      let* () =
        validate_entry_exact_attempt
          ~id
          ~input_hash
          ~sequence
          ~summary_status
          ~summary_attempt_disposition
          exact_attempt
      in
      Ok
        { id
      ; keeper_name
      ; tool_name
      ; input_hash
      ; input
      ; sequence
      ; requested_at
      ; turn_id
      ; request_context
      ; task_id
      ; goal_id
      ; continuation_channel
        ; audit_base_path = base_path
        ; summary_status
        ; exact_attempt
        ; summary_attempt_disposition
        }
  | _ -> Error "gate_pending.entry must be a JSON object"
;;

let pending_entry_invariant_error json =
  match json with
  | `Assoc fields ->
    (match
       List.assoc_opt "id" fields,
       List.assoc_opt "input_hash" fields,
       List.assoc_opt "sequence" fields,
       List.assoc_opt "summary_status" fields,
       List.assoc_opt "exact_attempt" fields,
       List.assoc_opt "summary_attempt_disposition" fields
     with
     | Some (`String id),
       Some (`String input_hash),
       Some (`Int sequence),
       Some summary_json,
       Some exact_attempt_json,
       Some summary_attempt_disposition_json ->
       (match
          summary_status_of_yojson_with_error summary_json,
          exact_attempt_state_of_yojson_with_error exact_attempt_json,
          summary_attempt_disposition_of_yojson_with_error
            summary_attempt_disposition_json
        with
        | Ok summary_status, Ok exact_attempt, Ok summary_attempt_disposition ->
          (match
             validate_entry_exact_attempt
               ~id
               ~input_hash
               ~sequence
               ~summary_status
               ~summary_attempt_disposition
               exact_attempt
           with
           | Ok () -> None
           | Error reason -> Some reason)
        | Error _, _, _
        | _, Error _, _
        | _, _, Error _ -> None)
     | _ -> None)
  | _ -> None
;;

let approval_decision_of_yojson json =
  match json with
  | `Assoc fields ->
    let ( let* ) = Result.bind in
    let* kind = required_string ~surface:"gate_pending.decision" "kind" fields in
    (match kind with
     | "approve" ->
       let* () =
         reject_unknown_fields
           ~surface:"gate_pending.decision"
           ~allowed:[ "kind" ]
           fields
       in
       Ok Decision.Approve
     | "reject" ->
       let* () =
         reject_unknown_fields
           ~surface:"gate_pending.decision"
           ~allowed:[ "kind"; "reason" ]
           fields
       in
       let* reason = required_string ~surface:"gate_pending.decision" "reason" fields in
       Ok (Decision.Reject reason)
     | other -> Error (Printf.sprintf "gate_pending.decision kind %S is unknown" other))
  | _ -> Error "gate_pending.decision must be a JSON object"
;;

let replay_artifact_ref_of_yojson ~surface field fields =
  match List.assoc_opt field fields with
  | None -> Error (Printf.sprintf "%s.%s is required" surface field)
  | Some json ->
    (match Tool_output.normalized_artifact_ref_of_json json with
     | Tool_output.Decoded_normalized_artifact_ref artifact_ref ->
       Ok artifact_ref
     | Tool_output.Not_normalized_artifact_ref ->
       Error
         (Printf.sprintf
            "%s.%s must be a normalized artifact reference"
            surface
            field)
     | Tool_output.Invalid_normalized_artifact_ref { detail } ->
       Error (Printf.sprintf "%s.%s: %s" surface field detail))
;;

let resolution_replay_outcome_of_yojson ~surface = function
  | `Assoc fields ->
    let ( let* ) = Result.bind in
    let* kind = required_string ~surface "kind" fields in
    (match kind with
     | "applied" ->
       let* () =
         reject_unknown_fields
           ~surface
           ~allowed:[ "kind"; "output_ref" ]
           fields
       in
       let* output_ref =
         replay_artifact_ref_of_yojson ~surface "output_ref" fields
       in
       Ok (Replay_applied output_ref)
     | "applied_with_warning" ->
       let* () =
         reject_unknown_fields
           ~surface
           ~allowed:[ "kind"; "detail_ref" ]
           fields
       in
       let* detail_ref =
         replay_artifact_ref_of_yojson ~surface "detail_ref" fields
       in
       Ok (Replay_applied_with_warning detail_ref)
     | "failed" ->
       let* () =
         reject_unknown_fields
           ~surface
           ~allowed:[ "kind"; "detail_ref" ]
           fields
       in
       let* detail_ref =
         replay_artifact_ref_of_yojson ~surface "detail_ref" fields
       in
       Ok (Replay_failed detail_ref)
     | "indeterminate" ->
       let* () =
         reject_unknown_fields
           ~surface
           ~allowed:[ "kind"; "detail_ref" ]
           fields
       in
       let* detail_ref =
         replay_artifact_ref_of_yojson ~surface "detail_ref" fields
       in
       Ok (Replay_indeterminate detail_ref)
     | other ->
       Error
         (Printf.sprintf
            "%s.kind %S is unknown"
            surface
            other))
  | _ -> Error (surface ^ " must be a JSON object")
;;

let persisted_delivery_of_yojson ~base_path json =
  match json with
  | `Assoc fields ->
    let ( let* ) = Result.bind in
    let surface = "gate_pending.delivery" in
    let* () =
      reject_unknown_fields
        ~surface
        ~allowed:
          [ "entry"
          ; "decision"
          ; "source"
          ; "remember_rule"
          ; "rule_expires_at"
          ; "created_by"
          ; "grant_consumed"
          ]
        fields
    in
    let* entry_json = required_member ~surface "entry" fields in
    let* entry = pending_entry_of_yojson ~base_path entry_json in
    let* decision_json = required_member ~surface "decision" fields in
    let* decision = approval_decision_of_yojson decision_json in
    let* source_raw = required_string ~surface "source" fields in
    let* source =
      match decision_source_of_string source_raw with
      | Some source -> Ok source
      | None -> Error (Printf.sprintf "%s.source %S is unknown" surface source_raw)
    in
    let* remember_rule =
      match List.assoc_opt "remember_rule" fields with
      | Some (`Bool value) -> Ok value
      | Some _ -> Error (surface ^ ".remember_rule must be a boolean")
      | None -> Error (surface ^ ".remember_rule is required")
    in
    let* rule_expires_at = optional_float ~surface "rule_expires_at" fields in
    let* created_by = optional_string ~surface "created_by" fields in
    let* grant_consumed =
      match List.assoc_opt "grant_consumed" fields with
      | Some (`Bool value) -> Ok value
      | Some _ -> Error (surface ^ ".grant_consumed must be a boolean")
      | None -> Error (surface ^ ".grant_consumed is required")
    in
    let* () =
      match decision, grant_consumed with
      | Decision.Approve, (true | false) -> Ok ()
      | Decision.Reject _, false -> Ok ()
      | Decision.Reject _, true ->
        Error (surface ^ ".grant_consumed is valid only for approve")
    in
    Ok
      { entry
      ; decision
      ; source
      ; remember_rule
      ; rule_expires_at
      ; created_by
      ; grant_consumed
      ; replay_outcome = None
      }
  | _ -> Error "gate_pending.delivery must be a JSON object"
;;

let map_of_unique_entries ~surface ~id_of entries =
  let rec build map = function
    | [] -> Ok map
    | entry :: rest ->
      let id = id_of entry in
      if SMap.mem id map
      then Error (Printf.sprintf "%s contains duplicate id %s" surface id)
      else build (SMap.add id entry map) rest
  in
  build SMap.empty entries
;;

let first_shared_id left right =
  SMap.fold
    (fun id _ found ->
       match found with
       | Some _ -> found
       | None -> if SMap.mem id right then Some id else None)
    left
    None
;;

let parse_list ~surface parse = function
  | `List values ->
    let rec loop index acc = function
      | [] -> Ok (List.rev acc)
      | value :: rest ->
        (match parse value with
         | Ok parsed -> loop (index + 1) (parsed :: acc) rest
         | Error reason -> Error (Printf.sprintf "%s[%d]: %s" surface index reason))
    in
    loop 0 [] values
  | _ -> Error (surface ^ " must be an array")
;;

let parse_list_with_entry_errors ~surface ?(fatal_error = fun _ -> None) parse = function
  | `List values ->
    let rec loop index acc errors = function
      | [] -> Ok (List.rev acc, List.rev errors)
      | value :: rest ->
        (match parse value with
         | Ok parsed -> loop (index + 1) (parsed :: acc) errors rest
         | Error reason ->
           (match fatal_error value with
            | Some fatal -> Error fatal
            | None ->
              loop
                (index + 1)
                acc
                (Printf.sprintf "%s[%d]: %s" surface index reason :: errors)
                rest))
    in
    loop 0 [] [] values
  | _ -> Error (surface ^ " must be an array")
;;

let replay_result_row_of_yojson json =
  match json with
  | `Assoc fields ->
    let ( let* ) = Result.bind in
    let surface = "gate_replay_results.outcomes[]" in
    let* () =
      reject_unknown_fields
        ~surface
        ~allowed:[ "approval_id"; "outcome" ]
        fields
    in
    let* approval_id = required_string ~surface "approval_id" fields in
    let* outcome_json = required_member ~surface "outcome" fields in
    let* outcome =
      resolution_replay_outcome_of_yojson
        ~surface:(surface ^ ".outcome")
        outcome_json
    in
    Ok (approval_id, outcome)
  | _ -> Error "gate_replay_results.outcomes[] must be a JSON object"
;;

let replay_results_of_yojson json =
  match json with
  | `Assoc fields ->
    let ( let* ) = Result.bind in
    let surface = "gate_replay_results" in
    let* () =
      reject_unknown_fields
        ~surface
        ~allowed:[ "version"; "outcomes" ]
        fields
    in
    let* () =
      match List.assoc_opt "version" fields with
      | Some (`Int version) when version = replay_results_store_version ->
        Ok ()
      | Some (`Int version) ->
        Error
          (Printf.sprintf
             "%s.version %d is unsupported (current %d)"
             surface
             version
             replay_results_store_version)
      | Some _ -> Error (surface ^ ".version must be an integer")
      | None -> Error (surface ^ ".version is required")
    in
    let* outcomes_json = required_member ~surface "outcomes" fields in
    let* outcomes =
      parse_list
        ~surface:"gate_replay_results.outcomes"
        replay_result_row_of_yojson
        outcomes_json
    in
    map_of_unique_entries
      ~surface:"gate_replay_results.outcomes"
      ~id_of:fst
      outcomes
    |> Result.map (SMap.map snd)
  | _ -> Error "gate_replay_results must be a JSON object"
;;

let validate_snapshot_sequences ~next_sequence pending_entries delivery_entries =
  let sequences =
    List.map (fun (entry : pending_approval) -> entry.sequence) pending_entries
    @ List.map
        (fun (delivery : persisted_delivery) -> delivery.entry.sequence)
        delivery_entries
    |> List.sort Int.compare
  in
  let rec check previous = function
    | [] -> Ok ()
    | sequence :: _ when sequence >= next_sequence ->
      Error
        (Printf.sprintf
           "gate_pending sequence %d must precede next_sequence %d"
           sequence
           next_sequence)
    | sequence :: _ when previous = Some sequence ->
      Error (Printf.sprintf "gate_pending contains duplicate sequence %d" sequence)
    | sequence :: rest -> check (Some sequence) rest
  in
  check None sequences
;;

let snapshot_of_yojson ~base_path json =
  match json with
  | `Assoc fields ->
    let ( let* ) = Result.bind in
    let surface = "gate_pending" in
    let* () =
      reject_unknown_fields
        ~surface
        ~allowed:[ "version"; "next_sequence"; "pending"; "deliveries" ]
        fields
    in
    let* () =
        match List.assoc_opt "version" fields with
        | Some (`Int version) when version = pending_store_version -> Ok ()
        | Some (`Int version) ->
          Error
            (Printf.sprintf
               "%s.version %d is unsupported (current %d); reset runtime state \
                before restarting MASC"
               surface
               version
               pending_store_version)
      | Some _ -> Error (surface ^ ".version must be an integer")
      | None -> Error (surface ^ ".version is required")
    in
    let* next_sequence = required_positive_int ~surface "next_sequence" fields in
    let* pending_json = required_member ~surface "pending" fields in
    let* delivery_json = required_member ~surface "deliveries" fields in
    let* pending_entries, pending_entry_errors =
      parse_list_with_entry_errors
        ~surface:"gate_pending.pending"
        ~fatal_error:pending_entry_invariant_error
        (pending_entry_of_yojson ~base_path)
        pending_json
    in
    let* delivery_entries =
      parse_list
          ~surface:"gate_pending.deliveries"
          (persisted_delivery_of_yojson ~base_path)
          delivery_json
    in
    let* pending_map =
      map_of_unique_entries
        ~surface:"gate_pending.pending"
        ~id_of:(fun (entry : pending_approval) -> entry.id)
        pending_entries
    in
    let* delivery_map =
      map_of_unique_entries
        ~surface:"gate_pending.deliveries"
        ~id_of:(fun (delivery : persisted_delivery) -> delivery.entry.id)
        delivery_entries
    in
    let* () =
      match first_shared_id pending_map delivery_map with
      | None -> Ok ()
      | Some id -> Error (Printf.sprintf "gate_pending id %s exists in both states" id)
    in
    let* () =
      validate_snapshot_sequences ~next_sequence pending_entries delivery_entries
    in
    Ok (pending_map, delivery_map, next_sequence, pending_entry_errors)
  | _ -> Error "gate_pending snapshot must be a JSON object"
;;

let classify_restarted_entry (entry : pending_approval) =
  match entry.exact_attempt, entry.summary_status with
  | Exact_bound
      ( { status =
            Exact_dispatch_uncertain
        ; _
        } as binding ),
    _ ->
    ( { entry with
        exact_attempt =
          Exact_bound
            (exact_attempt_binding_with_status
               binding
               Exact_restart_quarantined)
      ; summary_attempt_disposition =
          Summary_attempt_persistence_uncertain
      }
    , true )
  | Exact_bound
      ( { status =
            Exact_released_before_dispatch
        ; _
        } as binding ),
    Summary_pending ->
    ( { entry with
        exact_attempt =
          Exact_bound
            (exact_attempt_binding_with_status
               binding
               Exact_released_recovery_required)
      ; summary_attempt_disposition =
          Summary_attempt_persistence_uncertain
      }
    , true )
  | Exact_unbound, _
  | Exact_bound
      { status =
          ( Exact_released_before_dispatch
          | Exact_released_recovery_required
          | Exact_quarantined _
          | Exact_restart_quarantined
          | Exact_completed )
      ; _
      },
    _ ->
    entry, false
;;

let classify_restarted_pending map =
  SMap.fold
    (fun id entry (changed, classified) ->
       let entry, entry_changed = classify_restarted_entry entry in
       changed || entry_changed, SMap.add id entry classified)
    map
    (false, SMap.empty)
;;

let classify_restarted_deliveries map =
  SMap.fold
    (fun id delivery (changed, classified) ->
       let entry, entry_changed = classify_restarted_entry delivery.entry in
       ( changed || entry_changed
       , SMap.add id { delivery with entry } classified ))
    map
    (false, SMap.empty)
;;

let load_snapshot_unlocked ~base_path :
    (pending_approval SMap.t * persisted_delivery SMap.t * int * storage_error list,
     storage_error)
    result =
  let path = pending_store_path ~base_path in
  try
    if not (Sys.file_exists path)
    then Ok (SMap.empty, SMap.empty, first_sequence, [])
    else (
      match Safe_ops.read_json_file_safe path with
      | Error reason ->
        report_pending_read_drop
          ~reason:Read_drop_reason.Entry_load_error
          ~path
          ~detail:reason;
        Error { path; reason }
      | Ok json ->
        (match snapshot_of_yojson ~base_path json with
         | Ok
             ( loaded_pending
             , loaded_deliveries
             , loaded_next_sequence
             , pending_entry_errors ) ->
           let pending_read_errors =
             List.map (fun reason -> { path; reason }) pending_entry_errors
           in
           List.iter
             (fun (error : storage_error) ->
                report_pending_read_drop
                  ~reason:Read_drop_reason.Invalid_payload
                  ~path
                  ~detail:error.reason)
             pending_read_errors;
           let pending_changed, loaded_pending =
             classify_restarted_pending loaded_pending
           in
           let deliveries_changed, loaded_deliveries =
             classify_restarted_deliveries loaded_deliveries
           in
           if pending_read_errors = [] && (pending_changed || deliveries_changed)
           then
             (match
                save_snapshot_file_unlocked
                  ~base_path
                  ~next_sequence:loaded_next_sequence
                  ~pending_map:loaded_pending
                  ~delivery_map:loaded_deliveries
              with
              | Error _ as error -> error
              | Ok () ->
                Log.Server.warn
                  "gate_pending restart exact-state classification workspace=%s"
                  base_path;
                Ok
                  ( loaded_pending
                  , loaded_deliveries
                  , loaded_next_sequence
                  , pending_read_errors ))
           else
             Ok
               ( loaded_pending
               , loaded_deliveries
               , loaded_next_sequence
               , pending_read_errors )
         | Error reason ->
           report_pending_read_drop
             ~reason:Read_drop_reason.Invalid_payload
             ~path
             ~detail:reason;
           Error { path; reason }))
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
    let reason = Printexc.to_string exn in
    report_pending_read_drop
      ~reason:Read_drop_reason.Entry_load_error
      ~path
      ~detail:reason;
    Error { path; reason }
;;

let attach_replay_results ~delivery_map replay_results =
  SMap.fold
    (fun approval_id outcome result ->
       match result with
       | Error _ as error -> error
       | Ok deliveries ->
         (match SMap.find_opt approval_id deliveries with
          | None ->
            Error
              (Printf.sprintf
                 "gate_replay_results outcome %s has no matching delivery"
                 approval_id)
          | Some
              ( { decision = Decision.Approve
                ; grant_consumed = true
                ; replay_outcome = None
                ; _
                } as delivery ) ->
            Ok
              (SMap.add
                 approval_id
                 { delivery with replay_outcome = Some outcome }
                 deliveries)
          | Some { decision = Decision.Approve; grant_consumed = false; _ } ->
            Error
              (Printf.sprintf
                 "gate_replay_results outcome %s requires a consumed approve grant"
                 approval_id)
          | Some
              { decision = Decision.Reject _; _ } ->
            Error
              (Printf.sprintf
                 "gate_replay_results outcome %s belongs to a non-approved delivery"
                 approval_id)
          | Some { replay_outcome = Some _; _ } ->
            Error
              (Printf.sprintf
                 "gate_replay_results outcome %s is duplicated in memory"
                 approval_id)))
    replay_results
    (Ok delivery_map)
;;

let load_replay_results_unlocked ~base_path ~delivery_map =
  let path = replay_results_store_path ~base_path in
  try
    if not (Sys.file_exists path)
    then delivery_map, None
    else (
      match Safe_ops.read_json_file_safe path with
      | Error reason ->
        report_replay_results_read_drop
          ~reason:Read_drop_reason.Entry_load_error
          ~path
          ~detail:reason;
        delivery_map, Some { path; reason }
      | Ok json ->
        (match replay_results_of_yojson json with
         | Error reason ->
           report_replay_results_read_drop
             ~reason:Read_drop_reason.Invalid_payload
             ~path
             ~detail:reason;
           delivery_map, Some { path; reason }
         | Ok replay_results ->
           (match attach_replay_results ~delivery_map replay_results with
            | Ok delivery_map -> delivery_map, None
            | Error reason ->
              report_replay_results_read_drop
                ~reason:Read_drop_reason.Invalid_payload
                ~path
                ~detail:reason;
              delivery_map, Some { path; reason })))
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
    let reason = Printexc.to_string exn in
    report_replay_results_read_drop
      ~reason:Read_drop_reason.Entry_load_error
      ~path
      ~detail:reason;
    delivery_map, Some { path; reason }
;;

let remove_base_entries ~base_path map project =
  SMap.filter
    (fun _id value ->
       not (String.equal (project value).audit_base_path base_path))
    map
;;

let merge_loaded_map ~surface ~existing ~loaded =
  SMap.fold
    (fun id value result ->
       match result with
       | Error _ as error -> error
       | Ok map ->
         if SMap.mem id map
         then Error (Printf.sprintf "%s id %s collides with another workspace" surface id)
         else Ok (SMap.add id value map))
    loaded
    (Ok existing)
;;

(* ── Persistent audit log ────────────────────────────────── *)

(* Stdlib.Mutex: the store registry critical section only mutates an in-memory
   hashtable and creates a Dated_jsonl handle. It is also used by synchronous
   tests outside an Eio context, so an Eio mutex would either raise Get_context
   or poison the registry after a recoverable store-creation failure. *)
let approval_sse_pending_event = "approval:pending"
let approval_sse_resolved_event = "approval:resolved"
let approval_sse_summary_event = "approval:summary_updated"

let generate_id () = make_generated_id "appr"

let default_continuation_channel () =
  Keeper_continuation_channel.unrouted "no originating connector"
;;

let normalized_input_hash = request_fingerprint

type approved_delivery_lookup =
  | Approved_delivery_unconsumed of persisted_delivery
  | Approved_delivery_consumed of persisted_delivery

type grant_consumption_commit =
  | Consumption_without_audit of grant_consumption
  | Consumption_with_audit of persisted_delivery

let grant_workspace_mismatch ~base_path approval_id stored_base_path =
  Grant_workspace_mismatch
    { approval_id
    ; requested_base_path = base_path
    ; stored_base_path
    }
;;

let approved_delivery_unlocked ~base_path ~id =
  match SMap.find_opt base_path (Atomic.get unavailable_stores) with
  | Some error -> Error (Grant_store_unavailable error)
  | None ->
    (match SMap.find_opt id (Atomic.get deliveries) with
     | Some delivery ->
       let stored_base_path = delivery.entry.audit_base_path in
       if not (String.equal stored_base_path base_path)
       then Error (grant_workspace_mismatch ~base_path id stored_base_path)
       else
         (match delivery.decision with
          | Decision.Approve ->
            if delivery.grant_consumed
            then Ok (Approved_delivery_consumed delivery)
            else Ok (Approved_delivery_unconsumed delivery)
          | Decision.Reject _ ->
            Error (Grant_resolution_not_approved id))
     | None ->
       (match SMap.find_opt id (Atomic.get pending) with
        | Some entry ->
          if String.equal entry.audit_base_path base_path
          then Error (Grant_still_pending id)
          else
            Error
              (grant_workspace_mismatch
                 ~base_path
                 id
                 entry.audit_base_path)
        | None -> Error (Grant_resolution_missing id)))
;;

let approved_resolution_request ~base_path ~id =
  with_pending_store_lock (fun () ->
    match approved_delivery_unlocked ~base_path ~id with
    | Error _ as error -> error
    | Ok (Approved_delivery_consumed _) -> Ok None
    | Ok (Approved_delivery_unconsumed delivery) ->
      Ok
        (Some
           { keeper_name = delivery.entry.keeper_name
           ; tool_name = delivery.entry.tool_name
           ; input = delivery.entry.input
           }))
;;

let approved_resolution_state ~base_path ~id =
  with_pending_store_lock (fun () ->
    match approved_delivery_unlocked ~base_path ~id with
    | Error _ as error -> error
    | Ok (Approved_delivery_consumed _) -> Ok Resolution_consumed
    | Ok (Approved_delivery_unconsumed _) -> Ok Resolution_unconsumed)
;;

let approved_resolution_delivery ~base_path ~id =
  with_pending_store_lock (fun () ->
    match approved_delivery_unlocked ~base_path ~id with
    | Error _ as error -> error
    | Ok (Approved_delivery_unconsumed delivery) ->
      Ok
        { request =
            { keeper_name = delivery.entry.keeper_name
            ; tool_name = delivery.entry.tool_name
            ; input = delivery.entry.input
            }
        ; state = Resolution_unconsumed
        ; replay_outcome = delivery.replay_outcome
        }
    | Ok (Approved_delivery_consumed delivery) ->
      Ok
        { request =
            { keeper_name = delivery.entry.keeper_name
            ; tool_name = delivery.entry.tool_name
            ; input = delivery.entry.input
            }
        ; state = Resolution_consumed
        ; replay_outcome = delivery.replay_outcome
        })
;;

let resolution_replay_outcome_equal left right =
  match left, right with
  | Replay_applied left, Replay_applied right
  | Replay_applied_with_warning left, Replay_applied_with_warning right
  | Replay_failed left, Replay_failed right
  | Replay_indeterminate left, Replay_indeterminate right ->
    left = right
  | Replay_applied _, Replay_failed _
  | Replay_applied _, Replay_applied_with_warning _
  | Replay_applied _, Replay_indeterminate _
  | Replay_applied_with_warning _, Replay_applied _
  | Replay_applied_with_warning _, Replay_failed _
  | Replay_applied_with_warning _, Replay_indeterminate _
  | Replay_failed _, Replay_applied _
  | Replay_failed _, Replay_applied_with_warning _
  | Replay_failed _, Replay_indeterminate _
  | Replay_indeterminate _, Replay_applied _
  | Replay_indeterminate _, Replay_applied_with_warning _
  | Replay_indeterminate _, Replay_failed _ ->
    false
;;

let record_consumed_resolution_replay ~base_path ~id ~outcome =
  with_pending_store_lock (fun () ->
    match SMap.find_opt base_path (Atomic.get replay_projection_errors) with
    | Some error -> Error (Grant_replay_projection_unavailable error)
    | None ->
      (match approved_delivery_unlocked ~base_path ~id with
       | Error _ as error -> error
       | Ok (Approved_delivery_unconsumed _) ->
         Error (Grant_replay_not_consumed id)
       | Ok (Approved_delivery_consumed delivery) ->
         (match delivery.replay_outcome with
          | Some existing when resolution_replay_outcome_equal existing outcome ->
            Ok Replay_already_recorded
          | Some _ -> Error (Grant_replay_outcome_conflict id)
          | None ->
            let updated_delivery =
              { delivery with replay_outcome = Some outcome }
            in
            let updated_deliveries =
              SMap.add id updated_delivery (Atomic.get deliveries)
            in
            (match
               save_replay_results_file_unlocked
                 ~base_path
                 ~delivery_map:updated_deliveries
             with
             | Error error ->
               Error (Grant_replay_projection_unavailable error)
             | Ok Fsync_completed ->
               Atomic.set deliveries updated_deliveries;
               Ok Replay_recorded
             | Ok (Visible_sync_unconfirmed reason) ->
               let error =
                 { path = replay_results_store_path ~base_path
                 ; reason
                 }
               in
               Error (Grant_replay_projection_unavailable error)))))
;;

let consume_approved_resolution
      ~base_path
      ~id
      ~keeper_name
      ~tool_name
      ~input
  =
  let result =
    with_pending_store_lock (fun () ->
      match approved_delivery_unlocked ~base_path ~id with
      | Error error -> Error error
      | Ok (Approved_delivery_consumed _) ->
        Ok (Consumption_without_audit Consumption_already_committed)
      | Ok (Approved_delivery_unconsumed delivery) ->
        let entry = delivery.entry in
        if
          not
            (String.equal entry.keeper_name keeper_name
             && String.equal entry.tool_name tool_name
             && String.equal entry.input_hash (normalized_input_hash input))
        then Ok (Consumption_without_audit Consumption_not_matching)
        else
          let consumed_delivery = { delivery with grant_consumed = true } in
          let updated_deliveries =
            SMap.add id consumed_delivery (Atomic.get deliveries)
          in
          (match
             persist_snapshot_unlocked
               ~base_path
               ~pending_map:(Atomic.get pending)
               ~delivery_map:updated_deliveries
           with
           | Error error -> Error (Grant_store_unavailable error)
           | Ok () ->
             Atomic.set deliveries updated_deliveries;
             Ok (Consumption_with_audit delivery)))
  in
  match result with
  | Error _ as error -> error
  | Ok (Consumption_without_audit consumption) -> Ok consumption
  | Ok (Consumption_with_audit delivery) ->
    let entry = delivery.entry in
    let audit_receipt =
      Keeper_approval.Audit.record
        ~base_path
        ~event_type:Keeper_approval.Audit.Grant_consumed
        ~id
        ~keeper_name:entry.keeper_name
        ~tool_name:entry.tool_name
        ?turn_id:entry.turn_id
        ?task_id:entry.task_id
        ?goal_id:entry.goal_id
        ~source_approval_id:id
        ~decision_source:delivery.source
        ~decision:Decision.Approve
        ()
    in
    Ok (Consumption_committed audit_receipt)
;;

let input_preview_of_json (json : Yojson.Safe.t) =
  (* Per-leaf marker-aware truncation: a naive [String.sub] on the
     serialized form would chop a [masc:blob ...] marker mid-field and
     leave sha256/bytes/mime malformed so the approval-queue viewer
     cannot round-trip the preview. *)
  let json = Observability_redact.preview_json_strings ~max_len:200 json in
  let raw = Yojson.Safe.to_string json in
  Observability_redact.redact_preview ~max_len:200 raw
;;

let create_entry
      ~id
      ~sequence
      ~keeper_name
      ~tool_name
      ~input
      ?turn_id
      ?request_context
      ?task_id
      ?goal_id
      ~continuation_channel
      ~audit_base_path
      ()
  =
  let input_hash = normalized_input_hash input in
  { id
  ; keeper_name
  ; tool_name
  ; input_hash
  ; input
  ; sequence
  ; requested_at = Unix.gettimeofday ()
  ; turn_id
  ; request_context
  ; task_id
  ; goal_id
    ; continuation_channel
    ; audit_base_path
    ; summary_status = Summary_not_requested
    ; exact_attempt = Exact_unbound
    ; summary_attempt_disposition = Summary_attempt_ready
    }
;;

let pending_entry_json_fields
      ?(include_input = false)
      (entry : pending_approval)
  =
  [ "id", `String entry.id
  ; "keeper_name", `String entry.keeper_name
  ; "tool_name", `String entry.tool_name
  ; "input_hash", `String entry.input_hash
  ; "sequence", `Int entry.sequence
  ; "requested_at", `Float entry.requested_at
  ; "waiting_s", `Float (Unix.gettimeofday () -. entry.requested_at)
  ; "turn_id", Json_util.int_opt_to_json entry.turn_id
  ; "task_id", Json_util.string_opt_to_json entry.task_id
  ; "goal_id", Json_util.string_opt_to_json entry.goal_id
  ]
  @ (if include_input
     then
       [ "input", entry.input
       ; "input_preview", `String (input_preview_of_json entry.input)
       ]
     else [])
    (* The [include_input] conditional stays parenthesized so the trailing
       canonical [summary_status] field is present in every wire shape. *)
    @ [ "summary_status", summary_status_to_yojson entry.summary_status
      ; "exact_attempt", exact_attempt_state_to_yojson entry.exact_attempt
      ; ( "summary_attempt_disposition"
        , summary_attempt_disposition_to_yojson
            entry.summary_attempt_disposition )
      ]
;;

let broadcast_pending entry audit_receipt =
  try
    Sse.broadcast
      (`Assoc
          [ "type", `String approval_sse_pending_event
          ; ( "payload"
            , `Assoc
                (pending_entry_json_fields
                   ~include_input:true
                   entry
                 @ [ "audit", Keeper_approval.Audit.receipt_to_yojson audit_receipt ]) )
          ])
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    record_queue_failure
      ~keeper_name:entry.keeper_name
      ~site:"broadcast_pending"
      ~id:entry.id
      ~event_type:(Keeper_approval.Audit.event_to_string Keeper_approval.Audit.Pending)
      exn
;;

let publish_chat_projection_append ~keeper_name = function
  | Error _ as error -> error
  | Ok (Keeper_chat_store.Already_present _) -> Ok ()
  | Ok (Keeper_chat_store.Appended _) ->
    Keeper_chat_broadcast.chat_appended
      ~keeper_name
      ~source:"approval_lifecycle"
      ();
    Ok ()
;;

let append_chat_projection ~base_path ~keeper_name lifecycle =
  Keeper_chat_store.append_approval_lifecycle_once
    ~base_dir:base_path
    ~keeper_name
    ~lifecycle
  |> publish_chat_projection_append ~keeper_name
;;

(* A STATUS row answers "what was deferred", not only "which tool asked".
   The argv join keeps the operator-facing command in the operator's own
   words; an identity call names its provider surface. The cap is a rendering
   budget: the pane wraps, and a summary is a pointer, not the payload. *)
let call_summary_max_length = 80

let call_summary_of_input (input : Yojson.Safe.t) : string option =
  let member name = match input with
    | `Assoc fields -> List.assoc_opt name fields
    | _ -> None
  in
  let of_argv argv =
    let joined = String.concat " " argv in
    let first_line = match String.index_opt joined '\n' with
      | None -> joined
      | Some cut -> String.sub joined 0 cut
    in
    let trimmed = String.trim first_line in
    if trimmed = "" then None
    else if String.length trimmed <= call_summary_max_length then Some trimmed
    else
      (* A byte cut can split a multibyte char and persist a broken string;
         the boundary index keeps the cap without doing so. *)
      Some
        (String.sub trimmed 0
           (String_util.utf8_char_boundary trimmed call_summary_max_length))
  in
  let string_argv = function
    | `List items when List.for_all (function `String _ -> true | _ -> false) items ->
      Some (List.filter_map (function `String item -> Some item | _ -> None) items)
    | _ -> None
  in
  match member "input" with
  | Some (`Assoc inner) ->
    (match List.assoc_opt "argv" inner with
     | Some argv -> Option.bind (string_argv argv) of_argv
     | None -> None)
  | _ ->
    (match member "provider_id", member "remote_name" with
     | Some (`String provider), Some (`String remote) ->
       Some (provider ^ "/" ^ remote)
     | _ -> None)
;;

let record_pending (entry : pending_approval) =
  Log.Keeper.info
    "HITL_APPROVAL_PENDING: id=%s sequence=%d keeper=%s tool=%s"
    entry.id
    entry.sequence
    entry.keeper_name
    entry.tool_name;
  let audit_receipt =
    Keeper_approval.Audit.record
      ~base_path:entry.audit_base_path
      ~event_type:Keeper_approval.Audit.Pending
      ~id:entry.id
      ~keeper_name:entry.keeper_name
      ~tool_name:entry.tool_name
      ?turn_id:entry.turn_id
      ?task_id:entry.task_id
      ?goal_id:entry.goal_id
      ()
  in
  broadcast_pending entry audit_receipt;
  (* The parked call becomes visible before its answer does. The turn that
     asked keeps running, so without this row the operator sees a tool call
     and then nothing at all until the resolution lands. A projection failure
     is logged and dropped: it must not stop the approval from being queued. *)
  (match
     append_chat_projection
       ~base_path:entry.audit_base_path
       ~keeper_name:entry.keeper_name
       { Keeper_chat_store.approval_id = entry.id
       ; tool_name = Some entry.tool_name
       ; phase = Keeper_chat_store.Approval_requested
       ; artifact_ref = None
       ; call_summary = call_summary_of_input entry.input
       }
   with
   | Ok () -> ()
   | Error detail ->
     Log.Keeper.error
       "approval request chat projection failed approval=%s: %s"
       entry.id
       detail);
  audit_receipt
;;

let summary_audit_extras (entry : pending_approval) : (string * Yojson.Safe.t) list =
  match entry.summary_status with
  | Summary_available summary -> [ "model_run_id", `String summary.model_run_id ]
  | Summary_failed { reason } -> [ "failure_reason", `String reason ]
  | Summary_not_requested | Summary_pending -> []
;;

let record_summary_updated ~now (entry : pending_approval) =
  let event_ts =
    match entry.summary_status with
    | Summary_available summary -> summary.generated_at
    | Summary_not_requested | Summary_pending | Summary_failed _ -> now
  in
  ignore
    (Keeper_approval.Audit.record
       ~base_path:entry.audit_base_path
       ~event_type:Keeper_approval.Audit.Summary_updated
       ~id:entry.id
       ~keeper_name:entry.keeper_name
       ~tool_name:entry.tool_name
       ~summary_status:entry.summary_status
       ~exact_attempt:entry.exact_attempt
       ~summary_attempt_disposition:entry.summary_attempt_disposition
       ~timestamp:event_ts
       ~extra_fields:(summary_audit_extras entry)
       ());
  try
    Sse.broadcast
      (`Assoc
         [ "type", `String approval_sse_summary_event
         ; ( "payload"
           , `Assoc
               (pending_entry_json_fields
                  ~include_input:false
                  entry) )
         ])
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    record_queue_failure
      ~keeper_name:entry.keeper_name
      ~site:"broadcast_summary"
      ~id:entry.id
      ~event_type:approval_sse_summary_event
      exn
;;

(* ── Durable summary-state transitions ───────────────────── *)

(** Read a pending entry by id. Returns [None] if already resolved. *)
let find_pending_entry_unchecked ~id : pending_approval option =
  SMap.find_opt id (Atomic.get pending)
;;

let summary_transition_rejection (entry : pending_approval) =
  match entry.exact_attempt with
  | Exact_unbound -> None
  | Exact_bound binding -> Some (Summary_exact_attempt_bound binding)
;;

let persist_pending_entry_unlocked ~map ~(entry : pending_approval) updated_entry =
  let updated = SMap.add entry.id updated_entry map in
  match
    persist_snapshot_unlocked
      ~base_path:entry.audit_base_path
      ~pending_map:updated
      ~delivery_map:(Atomic.get deliveries)
  with
  | Error _ as error -> error
  | Ok () ->
    Atomic.set pending updated;
    Ok true
;;

let publish_summary_update ~id =
  let now = Time_compat.now () in
  match find_pending_entry_unchecked ~id with
  | Some updated -> record_summary_updated ~now updated
  | None -> ()
;;

let publish_summary_transition ~id = function
  | Ok true ->
    publish_summary_update ~id;
    Ok true
  | Ok false -> Ok false
  | Error error -> Error error
;;

let publish_exact_attempt_transition ~id = function
  | Ok ({ changed = true; _ } as transition) ->
    publish_summary_update ~id;
    Ok transition
  | Ok transition -> Ok transition
  | Error error -> Error error
;;

let validate_exact_attempt_candidate
      ~id
      ~input_hash
      ~sequence
      ~slot_id
      ~call_id
      ~plan_fingerprint
      ~request_body_sha256
  =
  let invalid field value =
    if String.trim value = ""
    then Error (Exact_attempt_rejected (Exact_attempt_invalid_identity field))
    else Ok ()
  in
  let ( let* ) = Result.bind in
  let* () = invalid "approval_id" id in
  let* () = invalid "input_hash" input_hash in
  let* () =
    if sequence > 0
    then Ok ()
    else Error (Exact_attempt_rejected (Exact_attempt_invalid_identity "sequence"))
  in
  let* () = invalid "slot_id" slot_id in
  let* () = invalid "call_id" call_id in
  let* () = invalid "plan_fingerprint" plan_fingerprint in
  let* () =
    if is_lowercase_sha256 request_body_sha256
    then Ok ()
    else
      Error
        (Exact_attempt_rejected
           (Exact_attempt_invalid_identity "request_body_sha256"))
  in
  Ok
    (make_exact_attempt_binding
       ~approval_id:id
       ~input_hash
       ~sequence
       ~slot_id
       ~call_id
       ~plan_fingerprint
       ~request_body_sha256
       ())
;;

let exact_attempt_entry_unlocked map (candidate : exact_attempt_binding) =
  match SMap.find_opt candidate.approval_id map with
  | None ->
    Error
      (Exact_attempt_rejected
         (Exact_attempt_not_found candidate.approval_id))
  | Some entry
    when not
           (String.equal entry.input_hash candidate.input_hash
            && Int.equal entry.sequence candidate.sequence) ->
    Error
      (Exact_attempt_rejected
         (Exact_attempt_key_mismatch
            { approval_id = candidate.approval_id
            ; input_hash = candidate.input_hash
            ; sequence = candidate.sequence
            }))
  | Some entry -> Ok entry
;;

let persist_exact_attempt_entry_unlocked
      ~save_file_atomic_strict_staged
      ~changed
      ~map
      ~(entry : pending_approval)
      updated_entry
  =
  let updated = SMap.add entry.id updated_entry map in
  match
    persist_snapshot_exact_unlocked
      ~save_file_atomic_strict_staged
      ~base_path:entry.audit_base_path
      ~pending_map:updated
      ~delivery_map:(Atomic.get deliveries)
  with
  | Error error -> Error (Exact_attempt_storage_error error)
  | Ok write_outcome ->
    Atomic.set pending updated;
    Ok { changed; write_outcome }
;;

let bind_summary_exact_attempt_with
      ~save_file_atomic_strict_staged
      ~id
      ~input_hash
      ~sequence
      ~slot_id
      ~call_id
      ~plan_fingerprint
      ~request_body_sha256
  =
  let result =
    match
      validate_exact_attempt_candidate
        ~id
        ~input_hash
        ~sequence
        ~slot_id
        ~call_id
        ~plan_fingerprint
        ~request_body_sha256
    with
    | Error _ as error -> error
    | Ok candidate ->
      with_pending_store_lock (fun () ->
        let map = Atomic.get pending in
        match exact_attempt_entry_unlocked map candidate with
        | Error _ as error -> error
        | Ok entry ->
          (match entry.summary_status with
           | Summary_not_requested
           | Summary_available _
           | Summary_failed _ ->
             Error
               (Exact_attempt_rejected
                  (Exact_attempt_summary_not_pending entry.id))
           | Summary_pending ->
             (match entry.exact_attempt with
               | Exact_unbound
                 when
                   not
                     (summary_attempt_allows_exact_bind
                        entry.summary_attempt_disposition) ->
                 Error
                   (Exact_attempt_rejected
                      (Exact_attempt_disposition_conflict
                         { approval_id = entry.id
                         ; disposition =
                             entry.summary_attempt_disposition
                         }))
               | Exact_unbound ->
                 persist_exact_attempt_entry_unlocked
                   ~save_file_atomic_strict_staged
                   ~changed:true
                   ~map
                   ~entry
                   { entry with
                     exact_attempt = Exact_bound candidate
                   ; summary_attempt_disposition =
                       Summary_attempt_in_flight
                   }
                | Exact_bound _
                  when entry.summary_attempt_disposition
                       <> Summary_attempt_in_flight ->
                  Error
                    (Exact_attempt_rejected
                       (Exact_attempt_disposition_conflict
                          { approval_id = entry.id
                          ; disposition =
                              entry.summary_attempt_disposition
                          }))
                | Exact_bound existing
                  when exact_attempt_identity_matches existing candidate ->
                  (match existing.status with
                   | Exact_dispatch_uncertain ->
                     persist_exact_attempt_entry_unlocked
                       ~save_file_atomic_strict_staged
                       ~changed:false
                       ~map
                       ~entry
                       entry
                   | Exact_released_before_dispatch
                   | Exact_released_recovery_required
                   | Exact_quarantined _
                   | Exact_restart_quarantined
                   | Exact_completed ->
                   Error
                     (Exact_attempt_rejected
                        (Exact_attempt_status_conflict existing)))
                | Exact_bound
                    ({ status = Exact_released_before_dispatch; _ } as _existing) ->
                  persist_exact_attempt_entry_unlocked
                    ~save_file_atomic_strict_staged
                    ~changed:true
                    ~map
                    ~entry
                    { entry with
                      exact_attempt = Exact_bound candidate
                    ; summary_attempt_disposition =
                        Summary_attempt_in_flight
                    }
              | Exact_bound existing ->
                Error
                  (Exact_attempt_rejected
                     (Exact_attempt_identity_conflict existing)))))
  in
  publish_exact_attempt_transition ~id result
;;

let bind_summary_exact_attempt =
  bind_summary_exact_attempt_with
    ~save_file_atomic_strict_staged:Fs_compat.save_file_atomic_strict_staged
;;

let release_summary_exact_attempt_before_dispatch_with
      ~save_file_atomic_strict_staged
      ~id
      ~input_hash
      ~sequence
      ~slot_id
      ~call_id
      ~plan_fingerprint
      ~request_body_sha256
  =
  let result =
    match
      validate_exact_attempt_candidate
        ~id
        ~input_hash
        ~sequence
        ~slot_id
        ~call_id
        ~plan_fingerprint
        ~request_body_sha256
    with
    | Error _ as error -> error
    | Ok candidate ->
      with_pending_store_lock (fun () ->
        let map = Atomic.get pending in
        match exact_attempt_entry_unlocked map candidate with
        | Error _ as error -> error
        | Ok entry ->
          (match entry.exact_attempt with
           | Exact_unbound ->
             Error
               (Exact_attempt_rejected
                  (Exact_attempt_unbound_state entry.id))
           | Exact_bound existing
             when not (exact_attempt_identity_matches existing candidate) ->
             Error
               (Exact_attempt_rejected
                  (Exact_attempt_identity_conflict existing))
           | Exact_bound existing ->
             (match existing.status with
              | Exact_dispatch_uncertain ->
                let released =
                  exact_attempt_binding_with_status
                    existing
                    Exact_released_before_dispatch
                in
                persist_exact_attempt_entry_unlocked
                    ~save_file_atomic_strict_staged
                    ~changed:true
                    ~map
                    ~entry
                    { entry with exact_attempt = Exact_bound released }
                | Exact_released_before_dispatch ->
                  persist_exact_attempt_entry_unlocked
                    ~save_file_atomic_strict_staged
                    ~changed:false
                    ~map
                    ~entry
                    entry
                | Exact_quarantined _
                | Exact_released_recovery_required
                | Exact_restart_quarantined
                | Exact_completed ->
                Error
                  (Exact_attempt_rejected
                     (Exact_attempt_status_conflict existing)))))
  in
  publish_exact_attempt_transition ~id result
;;

let release_summary_exact_attempt_before_dispatch =
  release_summary_exact_attempt_before_dispatch_with
    ~save_file_atomic_strict_staged:Fs_compat.save_file_atomic_strict_staged
;;

let quarantine_summary_exact_attempt_with
      ~save_file_atomic_strict_staged
      ~id
      ~input_hash
      ~sequence
      ~slot_id
      ~call_id
      ~plan_fingerprint
      ~request_body_sha256
      ~cause
  =
  let result =
    match
      validate_exact_attempt_candidate
        ~id
        ~input_hash
        ~sequence
        ~slot_id
        ~call_id
        ~plan_fingerprint
        ~request_body_sha256
    with
    | Error _ as error -> error
    | Ok candidate ->
      with_pending_store_lock (fun () ->
        let map = Atomic.get pending in
        match exact_attempt_entry_unlocked map candidate with
        | Error _ as error -> error
        | Ok entry ->
          (match entry.exact_attempt with
           | Exact_unbound ->
             Error
               (Exact_attempt_rejected
                  (Exact_attempt_unbound_state entry.id))
           | Exact_bound existing
             when not (exact_attempt_identity_matches existing candidate) ->
             Error
               (Exact_attempt_rejected
                  (Exact_attempt_identity_conflict existing))
           | Exact_bound existing ->
             (match existing.status with
              | Exact_dispatch_uncertain ->
                let quarantined =
                  exact_attempt_binding_with_status
                    existing
                    (Exact_quarantined cause)
                in
                persist_exact_attempt_entry_unlocked
                    ~save_file_atomic_strict_staged
                    ~changed:true
                    ~map
                    ~entry
                    { entry with
                      summary_status = exact_attempt_quarantine_summary_status cause
                    ; exact_attempt = Exact_bound quarantined
                    ; summary_attempt_disposition =
                        Summary_attempt_settled
                    }
                | Exact_quarantined durable_cause
                  when durable_cause = cause ->
                  let disposition_changed =
                    entry.summary_attempt_disposition
                    <> Summary_attempt_settled
                  in
                  persist_exact_attempt_entry_unlocked
                    ~save_file_atomic_strict_staged
                    ~changed:disposition_changed
                    ~map
                    ~entry
                    { entry with
                      summary_attempt_disposition =
                        Summary_attempt_settled
                    }
                | Exact_released_before_dispatch
                  when cause = Exact_terminal_persistence_failure
                       || cause = Exact_cancellation
                       || cause = Exact_flow_execution_failed ->
                  let quarantined =
                    exact_attempt_binding_with_status
                      existing
                      (Exact_quarantined cause)
                  in
                  persist_exact_attempt_entry_unlocked
                    ~save_file_atomic_strict_staged
                    ~changed:true
                    ~map
                    ~entry
                    { entry with
                      summary_status = exact_attempt_quarantine_summary_status cause
                    ; exact_attempt = Exact_bound quarantined
                    ; summary_attempt_disposition =
                        Summary_attempt_settled
                    }
                | Exact_quarantined _
                | Exact_released_before_dispatch
                | Exact_released_recovery_required
                | Exact_restart_quarantined
                | Exact_completed ->
            Error
              (Exact_attempt_rejected
                 (Exact_attempt_status_conflict existing)))))
  in
  publish_exact_attempt_transition ~id result
;;

let quarantine_summary_exact_attempt =
  quarantine_summary_exact_attempt_with
    ~save_file_atomic_strict_staged:Fs_compat.save_file_atomic_strict_staged
;;

let complete_summary_exact_attempt_with
      ~save_file_atomic_strict_staged
      ~id
      ~input_hash
      ~sequence
      ~slot_id
      ~call_id
      ~plan_fingerprint
      ~request_body_sha256
      ~summary
  =
  let result =
    match
      validate_exact_attempt_candidate
        ~id
        ~input_hash
        ~sequence
        ~slot_id
        ~call_id
        ~plan_fingerprint
        ~request_body_sha256
    with
    | Error _ as error -> error
    | Ok candidate ->
      with_pending_store_lock (fun () ->
        let map = Atomic.get pending in
        match exact_attempt_entry_unlocked map candidate with
        | Error _ as error -> error
        | Ok entry ->
          (match entry.exact_attempt with
           | Exact_unbound ->
             Error
               (Exact_attempt_rejected
                  (Exact_attempt_unbound_state entry.id))
           | Exact_bound existing
             when not (exact_attempt_identity_matches existing candidate) ->
             Error
               (Exact_attempt_rejected
                  (Exact_attempt_identity_conflict existing))
           | Exact_bound existing
             when not (String.equal summary.model_run_id existing.call_id) ->
             Error
               (Exact_attempt_rejected
                  (Exact_attempt_provenance_mismatch
                     { approval_id = entry.id
                     ; expected_call_id = existing.call_id
                     ; actual_model_run_id = summary.model_run_id
                     }))
           | Exact_bound existing ->
             (match existing.status, entry.summary_status with
              | Exact_dispatch_uncertain, Summary_pending ->
                  let completed =
                    exact_attempt_binding_with_status existing Exact_completed
                  in
                  persist_exact_attempt_entry_unlocked
                    ~save_file_atomic_strict_staged
                    ~changed:true
                    ~map
                    ~entry
                    { entry with
                    summary_status = Summary_available summary
                  ; exact_attempt = Exact_bound completed
                  ; summary_attempt_disposition =
                      Summary_attempt_settled
                  }
              | Exact_completed, Summary_available durable_summary ->
                if
                  Yojson.Safe.equal
                    (hitl_context_summary_to_yojson durable_summary)
                      (hitl_context_summary_to_yojson summary)
                  then
                    let disposition_changed =
                      entry.summary_attempt_disposition
                      <> Summary_attempt_settled
                    in
                    persist_exact_attempt_entry_unlocked
                      ~save_file_atomic_strict_staged
                      ~changed:disposition_changed
                      ~map
                      ~entry
                      { entry with
                        summary_attempt_disposition =
                          Summary_attempt_settled
                      }
                  else
                    Error
                    (Exact_attempt_rejected
                       (Exact_attempt_content_conflict entry.id))
              | ( Exact_released_before_dispatch
                | Exact_released_recovery_required
                | Exact_quarantined _
                | Exact_restart_quarantined
                | Exact_completed ),
                _ ->
                Error
                  (Exact_attempt_rejected
                     (Exact_attempt_status_conflict existing))
              | Exact_dispatch_uncertain, _ ->
                Error
                  (Exact_attempt_rejected
                     (Exact_attempt_summary_not_pending entry.id)))))
  in
  publish_exact_attempt_transition ~id result
;;

let complete_summary_exact_attempt =
  complete_summary_exact_attempt_with
    ~save_file_atomic_strict_staged:Fs_compat.save_file_atomic_strict_staged
;;

let mark_summary_pending ~id =
  let result =
    with_pending_store_lock (fun () ->
      let map = Atomic.get pending in
      match SMap.find_opt id map with
      | None -> Ok false
      | Some entry ->
        (match summary_transition_rejection entry with
         | Some rejection -> Error (Summary_transition_rejected rejection)
         | None ->
           (match entry.summary_status with
            | Summary_not_requested ->
              persist_pending_entry_unlocked
                ~map
                ~entry
                { entry with summary_status = Summary_pending }
              |> Result.map_error (fun error ->
                Summary_transition_storage_error error)
            | Summary_pending
            | Summary_available _
            | Summary_failed _ ->
              Ok false)))
  in
  publish_summary_transition ~id result
;;

let publish_summary_attempt_transition ~id = function
  | Ok true ->
    publish_summary_update ~id;
    Ok true
  | Ok false -> Ok false
  | Error error -> Error error
;;

let transition_summary_attempt
      ~base_path
      ~id
      ~input_hash
      ~sequence
      update
  =
  let result =
    with_pending_store_lock (fun () ->
      let map = Atomic.get pending in
      match SMap.find_opt id map with
      | None ->
        Error (Exact_attempt_rejected (Exact_attempt_not_found id))
      | Some entry
        when not (String.equal entry.audit_base_path base_path) ->
        Error (Exact_attempt_rejected (Exact_attempt_not_found id))
      | Some entry
        when not
               (String.equal entry.input_hash input_hash
                && Int.equal entry.sequence sequence) ->
        Error
          (Exact_attempt_rejected
             (Exact_attempt_key_mismatch
                { approval_id = id; input_hash; sequence }))
      | Some entry ->
        (match update entry with
         | None -> Ok false
         | Some updated_entry ->
           persist_pending_entry_unlocked
             ~map
             ~entry
             updated_entry
           |> Result.map_error (fun error ->
             Exact_attempt_storage_error error)))
  in
  publish_summary_attempt_transition ~id result
;;

let mark_summary_attempt_identity_unbound
      ~base_path
      ~id
      ~input_hash
      ~sequence
  =
  transition_summary_attempt
    ~base_path
    ~id
    ~input_hash
    ~sequence
    (fun (entry : pending_approval) ->
       match
         entry.summary_status,
         entry.exact_attempt,
         entry.summary_attempt_disposition
       with
       | Summary_pending, Exact_unbound,
         ( Summary_attempt_ready
         | Summary_attempt_pre_worker_unavailable
             { reason_code = Summary_pre_worker_start_reserved; _ } ) ->
         Some
           { entry with
             summary_attempt_disposition =
               Summary_attempt_identity_unbound
           }
       | Summary_pending, Exact_unbound,
         Summary_attempt_identity_unbound ->
         Some entry
       | _ -> None)
;;

let mark_summary_attempt_persistence_uncertain
      ~base_path
      ~id
      ~input_hash
      ~sequence
  =
  transition_summary_attempt
    ~base_path
    ~id
    ~input_hash
    ~sequence
    (fun (entry : pending_approval) ->
       match
         entry.summary_status,
         entry.summary_attempt_disposition
       with
       | Summary_not_requested, _
       | _, Summary_attempt_persistence_uncertain ->
         None
       | _ ->
         Some
           { entry with
             summary_attempt_disposition =
               Summary_attempt_persistence_uncertain
           })
;;

let mark_summary_attempt_pre_worker_unavailable
      ~base_path
      ~id
      ~input_hash
      ~sequence
      ~reason_code
      ~operator_detail
  =
  let trimmed_detail = String.trim operator_detail in
  if
    String.equal trimmed_detail ""
    || not (String.equal trimmed_detail operator_detail)
  then
    Error
      (Exact_attempt_rejected
         (Exact_attempt_invalid_identity "operator_detail"))
  else
    let blocked =
      Summary_attempt_pre_worker_unavailable
        { reason_code; operator_detail }
    in
    transition_summary_attempt
      ~base_path
      ~id
      ~input_hash
      ~sequence
      (fun (entry : pending_approval) ->
         match
           entry.summary_status,
           entry.exact_attempt,
           entry.summary_attempt_disposition
         with
         | (Summary_not_requested | Summary_pending), Exact_unbound,
           Summary_attempt_ready ->
           Some
             { entry with
               summary_attempt_disposition = blocked
             }
         | (Summary_not_requested | Summary_pending), Exact_unbound,
           Summary_attempt_pre_worker_unavailable
             { reason_code = Summary_pre_worker_start_reserved; _ } ->
           Some
             { entry with
               summary_attempt_disposition = blocked
             }
         | (Summary_not_requested | Summary_pending), Exact_unbound,
           current
           when current = blocked ->
           Some entry
         | _ -> None)
;;

let release_orphaned_start_reservation ~base_path ~id ~input_hash ~sequence =
  (* Boot-recovery reclaim of a start reservation that a hard process restart
     orphaned. [mark_summary_attempt_pre_worker_unavailable] writes the durable
     [Summary_pre_worker_start_reserved] row; the graceful in-memory settle to
     [Summary_attempt_identity_unbound] (worker terminates before binding) never
     runs when the whole process dies in the reserve->bind window, so the row is
     stranded. This is that arm's exact reverse: an unbound start reservation
     returns to [Summary_attempt_ready] so boot recovery re-activates a worker.
     Distinct from [reserve_summary_attempt_retry], the operator path that never
     reclaims a start reservation. Any other row shape is left untouched. *)
  transition_summary_attempt
    ~base_path
    ~id
    ~input_hash
    ~sequence
    (fun (entry : pending_approval) ->
       match
         entry.summary_status,
         entry.exact_attempt,
         entry.summary_attempt_disposition
       with
       | (Summary_not_requested | Summary_pending), Exact_unbound,
         Summary_attempt_pre_worker_unavailable
           { reason_code = Summary_pre_worker_start_reserved; _ } ->
         Some { entry with summary_attempt_disposition = Summary_attempt_ready }
       | _ -> None)
;;

let reserve_summary_attempt_retry
      ~base_path
      ~id
      ~input_hash
      ~sequence
      ~expected_exact_attempt
      ~expected_disposition
      ~requested_by
  =
  let exact_attempt_state_equal left right =
    match left, right with
    | Exact_unbound, Exact_unbound -> true
    | Exact_bound left, Exact_bound right ->
      exact_attempt_identity_matches left right
      && left.status = right.status
    | Exact_unbound, Exact_bound _
    | Exact_bound _, Exact_unbound ->
      false
  in
  if String.trim requested_by = ""
  then
    Error
      (Exact_attempt_rejected
         (Exact_attempt_invalid_identity "requested_by"))
  else
    let reserved =
      Summary_attempt_pre_worker_unavailable
        { reason_code = Summary_pre_worker_start_reserved
        ; operator_detail = summary_attempt_start_reserved_operator_detail
        }
    in
    transition_summary_attempt
      ~base_path
      ~id
      ~input_hash
      ~sequence
      (fun (entry : pending_approval) ->
         if
           entry.summary_attempt_disposition <> expected_disposition
           || not
                (exact_attempt_state_equal
                   entry.exact_attempt
                   expected_exact_attempt)
         then None
         else
           match
             entry.summary_attempt_disposition,
             entry.exact_attempt,
             entry.summary_status
           with
           | Summary_attempt_identity_unbound, Exact_unbound,
             Summary_pending
           | Summary_attempt_persistence_uncertain, Exact_unbound,
             Summary_pending ->
             Some
               { entry with
                 summary_status = Summary_pending
               ; summary_attempt_disposition = reserved
               }
           | Summary_attempt_pre_worker_unavailable
               { reason_code =
                   ( Summary_pre_worker_auto_judge_unavailable
                   | Summary_pre_worker_mode_state_invalid )
               ; _
               },
             Exact_unbound,
             (Summary_not_requested | Summary_pending) ->
             Some
               { entry with
                 summary_status = Summary_pending
               ; summary_attempt_disposition = reserved
               }
           | Summary_attempt_persistence_uncertain,
             Exact_bound
               { status = Exact_released_recovery_required; _ },
             Summary_pending ->
             Some
               { entry with
                 exact_attempt = Exact_unbound
               ; summary_status = Summary_pending
               ; summary_attempt_disposition = reserved
               }
           | _ -> None)
;;

let record_resolution_delivery_failure ~keeper_name ~approval_id reason =
  Otel_metric_store.inc_counter
    Keeper_metrics.(to_string ApprovalQueueFailures)
    ~labels:
      [ "keeper", keeper_name
      ; ( "site"
        , Keeper_approval_queue_failure_site.(to_label Resolution_delivery) )
      ]
    ();
  Log.Keeper.error
    ~keeper_name
    "hitl resolution delivery failed approval=%s: %s"
    approval_id
    reason
;;

let signal_resolution_after_commit ~base_path ~keeper_name ~approval_id =
  try
    let outcome =
      Keeper_registry.wakeup_running
        ~intent:Keeper_registry.Hitl_resolution
        ~base_path
        keeper_name
    in
    let outcome_label, detail =
      match outcome with
      | Keeper_registry.Signaled -> "signaled", "running"
      | Keeper_registry.Deferred_unregistered ->
        "deferred_unregistered", "unregistered"
      | Keeper_registry.Deferred_not_running phase ->
        "deferred_not_running", Keeper_state_machine.phase_to_string phase
      | Keeper_registry.Deferred_lifecycle denial ->
        ( "deferred_lifecycle"
        , Keeper_lifecycle_admission.autonomous_denial_to_wire denial )
    in
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string ApprovalResolutionSignal)
      ~labels:[ "keeper", keeper_name; "outcome", outcome_label ]
      ();
    Log.Keeper.info
      ~keeper_name
      "hitl resolution committed approval=%s signal=%s phase=%s"
      approval_id
      outcome_label
      detail
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string ApprovalQueueFailures)
      ~labels:
        [ "keeper", keeper_name
        ; "site", Keeper_approval_queue_failure_site.(to_label Resolution_signal)
        ]
      ();
    Log.Keeper.error
      ~keeper_name
      "hitl resolution signal failed after durable commit approval=%s: %s"
      approval_id
      (Printexc.to_string exn)
;;

let commit_keeper_approval_resolution
    ~base_path ~keeper_name ~approval_id ~decision
    ~(channel : Keeper_continuation_channel.t) =
  match
    try
      Keeper_registry_event_queue.enqueue_hitl_resolution_durable_result
        ~base_path
        ~keeper_name
        ~approval_id
        ~decision
        ~channel
    with
    | Eio.Cancel.Cancelled _ as exn -> raise exn
    | exn ->
      Error
        (Keeper_registry_event_queue.Hitl_enqueue_failed
           (Printexc.to_string exn))
  with
  | Ok () -> Ok ()
  | Error Keeper_registry_event_queue.Hitl_recipient_absent as error ->
    (* No Keeper exists with the addressed name. That is a terminal
       disposition the caller settles, not a delivery failure, so it gets
       neither the failure counter nor an ERROR log here. *)
    error
  | Error (Keeper_registry_event_queue.Hitl_enqueue_failed reason) as error ->
    record_resolution_delivery_failure ~keeper_name ~approval_id reason;
    error
;;

let hitl_resolution_decision_of_approval_decision = function
  | Decision.Approve -> Keeper_event_queue.Hitl_approved
  | Decision.Reject rationale -> Keeper_event_queue.Hitl_rejected rationale
;;

let deliver_resolution ~base_path (entry : pending_approval) decision =
  commit_keeper_approval_resolution
    ~base_path
    ~keeper_name:entry.keeper_name
    ~approval_id:entry.id
    ~decision:(hitl_resolution_decision_of_approval_decision decision)
    ~channel:entry.continuation_channel
;;

let ensure_resolution_chat_projection
      ~base_path
      ~keeper_name
      ~approval_id
      ~tool_name
      ~call_summary
      ~decision
  =
  let phase =
    match decision with
    | Decision.Approve -> Keeper_chat_store.Approval_resolved_approved
    | Decision.Reject _ -> Keeper_chat_store.Approval_resolved_rejected
  in
  append_chat_projection
    ~base_path
    ~keeper_name
    { Keeper_chat_store.approval_id
    ; tool_name
    ; phase
    ; artifact_ref = None
    ; call_summary
    }
;;

let ensure_replay_chat_projection
      ~base_path
      ~keeper_name
      ~approval_id
      ~tool_name
      ~call_summary
      ~outcome
  =
  let phase, artifact_ref =
    match outcome with
    | Replay_applied artifact_ref ->
      Keeper_chat_store.Approval_replay_applied, artifact_ref
    | Replay_applied_with_warning artifact_ref ->
      Keeper_chat_store.Approval_replay_applied_with_warning, artifact_ref
    | Replay_failed artifact_ref ->
      Keeper_chat_store.Approval_replay_failed, artifact_ref
    | Replay_indeterminate artifact_ref ->
      Keeper_chat_store.Approval_replay_indeterminate, artifact_ref
  in
  Keeper_chat_store.reconcile_approval_replay_lifecycle_once
    ~base_dir:base_path
    ~keeper_name
    ~lifecycle:
      { Keeper_chat_store.approval_id
      ; tool_name
      ; phase
      ; artifact_ref = Some artifact_ref
      ; call_summary
      }
  |> publish_chat_projection_append ~keeper_name
;;

let ensure_continuation_chat_projection
      ~base_path
      ~keeper_name
      ~approval_id
      ~tool_name
      ~call_summary
  =
  append_chat_projection
    ~base_path
    ~keeper_name
    { Keeper_chat_store.approval_id
    ; tool_name
    ; phase = Keeper_chat_store.Approval_continuation_recorded
    ; artifact_ref = None
    ; call_summary
    }
;;

let continuation_chat_projection_present
      ~base_path
      ~keeper_name
      ~approval_id
  =
  Keeper_chat_store.approval_lifecycle_phase_present
    ~base_dir:base_path
    ~keeper_name
    ~approval_id
    ~phase:Keeper_chat_store.Approval_continuation_recorded
;;

type continuation_projection_result =
  | Continuation_projection_recorded
  | Continuation_projection_not_ready

let ensure_settled_continuation_chat_projection
      ~base_path
      ~keeper_name
      ~(resolution : Keeper_event_queue.hitl_resolution)
  =
  let approval_id = resolution.approval_id in
  let ready_projection =
    match resolution.decision with
    | Keeper_event_queue.Hitl_rejected _ -> Ok (Some (None, None))
    | Keeper_event_queue.Hitl_approved ->
      (match approved_resolution_delivery ~base_path ~id:approval_id with
       | Ok
           { request
           ; state = Resolution_consumed
           ; replay_outcome = Some _
           } ->
         Ok
           (Some
              (Some request.tool_name, call_summary_of_input request.input))
       | Ok
           { state = (Resolution_unconsumed | Resolution_consumed)
           ; replay_outcome = None
           ; _
           }
       | Ok
           { state = Resolution_unconsumed
           ; replay_outcome = Some _
           ; _
           } ->
         Ok None
       | Error error -> Error (grant_error_to_string error))
  in
  match ready_projection with
  | Error _ as error -> error
  | Ok None -> Ok Continuation_projection_not_ready
  | Ok (Some (tool_name, call_summary)) ->
    Result.map
      (fun () -> Continuation_projection_recorded)
      (ensure_continuation_chat_projection
         ~base_path
         ~keeper_name
         ~approval_id
         ~tool_name
         ~call_summary)
;;

let resolve_entry
      ?(before_terminal_publish = fun () -> ())
      ?(project_chat = true)
      ~base_path
      (entry : pending_approval)
      ~(source : decision_source)
      ?actor
      (decision : decision)
  =
  let decision_str = approval_decision_to_string decision in
  Log.Keeper.info
    "HITL_APPROVAL_RESOLVED: id=%s keeper=%s tool=%s decision=%s"
    entry.id
    entry.keeper_name
    entry.tool_name
    decision_str;
  let audit_receipt =
    Keeper_approval.Audit.record
      ~base_path
      ~event_type:Keeper_approval.Audit.Resolved
      ~id:entry.id
      ~keeper_name:entry.keeper_name
      ~tool_name:entry.tool_name
      ?turn_id:entry.turn_id
      ?task_id:entry.task_id
      ?goal_id:entry.goal_id
      ?actor
      ~decision_source:source
      ~decision
      ~summary_status:entry.summary_status
      ~exact_attempt:entry.exact_attempt
      ()
  in
  (if project_chat
   then
     match
       ensure_resolution_chat_projection
         ~base_path
         ~keeper_name:entry.keeper_name
         ~approval_id:entry.id
         ~tool_name:(Some entry.tool_name)
         ~call_summary:(call_summary_of_input entry.input)
         ~decision
     with
     | Ok () -> ()
     | Error reason ->
       record_resolution_delivery_failure
         ~keeper_name:entry.keeper_name
         ~approval_id:entry.id
         ("chat projection: " ^ reason));
  before_terminal_publish ();
  (try
     Sse.broadcast
       (`Assoc
           [ "type", `String approval_sse_resolved_event
           ; ( "payload"
             , `Assoc
                 [ "id", `String entry.id
                 ; "keeper_name", `String entry.keeper_name
                 ; "tool_name", `String entry.tool_name
                 ; "decision", `String decision_str
                 ; "audit", Keeper_approval.Audit.receipt_to_yojson audit_receipt
                 ] )
           ])
   with
   | Eio.Cancel.Cancelled _ as e -> raise e
   | exn ->
     record_queue_failure
       ~keeper_name:entry.keeper_name
       ~site:"broadcast_resolved"
       ~id:entry.id
       ~event_type:(Keeper_approval.Audit.event_to_string Keeper_approval.Audit.Resolved)
       exn);
  audit_receipt
;;

(* The effect request's identity. [turn_id] is deliberately absent: it names
   the turn that asked, not the effect being asked for. Keeping it in this
   comparison made every next-turn retry of the same call a fresh approval —
   measured 2026-08-16: one identical web_search deferred in turns
   28959/28960/28961 produced three approvals, three auto-judge approvals,
   and three replays of the same 17,712-byte output into the same context
   (#28866). The turn that asked is still recorded on the entry for audit. *)
let pending_entry_matches
      (entry : pending_approval)
      ~base_path
      ~keeper_name
      ~tool_name
      ~input_hash
      ~task_id
      ~goal_id
      ~continuation_channel
  =
  String.equal entry.audit_base_path base_path
  && String.equal entry.keeper_name keeper_name
  && String.equal entry.tool_name tool_name
  && String.equal entry.input_hash input_hash
  && entry.task_id = task_id
  && entry.goal_id = goal_id
  && Yojson.Safe.equal
       (Keeper_continuation_channel.to_yojson entry.continuation_channel)
       (Keeper_continuation_channel.to_yojson continuation_channel)
;;

let find_pending_id_in_map
      (map : pending_approval SMap.t)
      ~base_path
      ~keeper_name
      ~tool_name
      ~input_hash
      ~task_id
      ~goal_id
      ~continuation_channel
  =
  SMap.fold
    (fun id (entry : pending_approval) acc ->
       match acc with
       | Some _ -> acc
       | None ->
         if
           pending_entry_matches
             entry
             ~base_path
             ~keeper_name
             ~tool_name
             ~input_hash
             ~task_id
             ~goal_id
             ~continuation_channel
         then Some id
         else None)
    map
    None
;;

(* An approved resolution whose one-shot grant is still unconsumed is the
   same effect request one step further along: the host owes the Keeper a
   replay of exactly this call. A resubmission folds onto it instead of
   opening a second approval — "an approval owns its effect" (RFC-0356)
   implies its dual, an effect has one approval. Rejected and
   grant-consumed deliveries never match: a retry after rejection is a new
   approval cycle, and a retry after the effect ran is a new effect. *)
let find_unconsumed_grant_id_in_deliveries
      (map : persisted_delivery SMap.t)
      ~base_path
      ~keeper_name
      ~tool_name
      ~input_hash
      ~task_id
      ~goal_id
      ~continuation_channel
  =
  SMap.fold
    (fun id (delivery : persisted_delivery) acc ->
       match acc with
       | Some _ -> acc
       | None ->
         (match delivery.decision with
          | Decision.Reject _ -> None
          | Decision.Approve ->
            if
              (not delivery.grant_consumed)
              && pending_entry_matches
                   delivery.entry
                   ~base_path
                   ~keeper_name
                   ~tool_name
                   ~input_hash
                   ~task_id
                   ~goal_id
                   ~continuation_channel
            then Some id
            else None))
    map
    None
;;

(* ── Nonblocking submission ───────────────────────────────── *)

let submit_pending
      ~keeper_name
      ~tool_name
      ~input
      ~base_path
      ?turn_id
      ?request_context
      ?task_id
      ?goal_id
      ?continuation_channel
      ()
  : (pending_submission, storage_error) result
  =
  let input_hash = normalized_input_hash input in
  let continuation_channel =
    Option.value continuation_channel ~default:(default_continuation_channel ())
  in
  let stored =
    with_pending_store_lock (fun () ->
      let map = Atomic.get pending in
      match next_sequence_lifecycle ~base_path with
      | Uninstalled ->
        Error
          { path = pending_store_path ~base_path
          ; reason =
              "gate_pending store is not installed; submit requires a completed install"
          }
      | Unavailable error -> Error error
      | Ready sequence ->
        (match
           find_pending_id_in_map
             map
             ~base_path
             ~keeper_name
             ~tool_name
             ~input_hash
             ~task_id
             ~goal_id
             ~continuation_channel
         with
         | Some id -> Ok (`Deduplicated id)
         | None ->
           (match
              find_unconsumed_grant_id_in_deliveries
                (Atomic.get deliveries)
                ~base_path
                ~keeper_name
                ~tool_name
                ~input_hash
                ~task_id
                ~goal_id
                ~continuation_channel
            with
            | Some id -> Ok (`Folded_onto_unconsumed_grant id)
            | None ->
           let id = generate_id () in
           if sequence = max_int
           then
             Error
               { path = pending_store_path ~base_path
               ; reason = "approval sequence exhausted its integer representation"
               }
           else
             let entry =
               create_entry
                 ~id
                 ~sequence
                 ~keeper_name
                 ~tool_name
                 ~input
                 ?turn_id
              ?request_context
              ?task_id
              ?goal_id
              ~continuation_channel
              ~audit_base_path:base_path
              ()
          in
          let updated = SMap.add id entry map in
          let following_sequence = sequence + 1 in
          (match
             persist_snapshot_with_sequence_unlocked
               ~base_path
               ~next_sequence:following_sequence
               ~pending_map:updated
               ~delivery_map:(Atomic.get deliveries)
           with
           | Error error -> Error error
           | Ok () ->
             Atomic.set pending updated;
             Atomic.set
               next_sequences
               (SMap.add base_path following_sequence (Atomic.get next_sequences));
             Ok (`Created entry)))))
  in
  match stored with
  | Error _ as error -> error
  | Ok (`Deduplicated approval_id) ->
    Ok { approval_id; disposition = Pending_deduplicated }
  | Ok (`Folded_onto_unconsumed_grant approval_id) ->
    Ok { approval_id; disposition = Folded_onto_unconsumed_grant }
  | Ok (`Created entry) ->
    let audit_receipt = record_pending entry in
    Ok
      { approval_id = entry.id
      ; disposition = Pending_created audit_receipt
      }
;;

(* ── Resolve (operator action) ────────────────────────────── *)

type resolve_error =
  | Not_found of string
  | Already_resolved of string
  | Delivery_failed of
      { approval_id : string
      ; reason : string
      }
  | Persistence_failed of
      { approval_id : string
      ; storage_error : storage_error
      }

let resolve_error_to_string = function
  | Not_found id -> Printf.sprintf "approval %s not found" id
  | Already_resolved id -> Printf.sprintf "approval %s already resolved" id
  | Delivery_failed { approval_id; reason } ->
    Printf.sprintf "approval %s resolution delivery failed: %s" approval_id reason
  | Persistence_failed { approval_id; storage_error } ->
    Printf.sprintf
      "approval %s queue persistence failed: %s"
      approval_id
      (storage_error_to_string storage_error)
;;

module Resolution_claims = Set_util.StringSet

let resolution_claims : Resolution_claims.t Atomic.t =
  Atomic.make Resolution_claims.empty
;;

let rec claim_resolution id =
  let claims = Atomic.get resolution_claims in
  if Resolution_claims.mem id claims
  then false
  else
    let claimed = Resolution_claims.add id claims in
    if Atomic.compare_and_set resolution_claims claims claimed
    then true
    else claim_resolution id
;;

let release_resolution_claim id =
  atomic_update resolution_claims (fun claims -> Resolution_claims.remove id claims)
;;

let resolve_store_readiness_error ~base_path ~approval_id =
  match next_sequence_lifecycle ~base_path with
  | Ready _ -> Ok ()
  | Unavailable storage_error ->
    Error (Persistence_failed { approval_id; storage_error })
  | Uninstalled ->
    let storage_error =
      { path = pending_store_path ~base_path
      ; reason =
          "gate_pending store is not installed; resolution requires a completed install"
      }
    in
    Error (Persistence_failed { approval_id; storage_error })
;;

type journal_error =
  | Journal_not_found
  | Journal_storage of storage_error

let journal_resolution ~id ~decision ~source ~remember_rule ~rule_expires_at ~created_by =
  with_pending_store_lock (fun () ->
    let pending_map = Atomic.get pending in
    match SMap.find_opt id pending_map with
    | None -> Error Journal_not_found
    | Some entry ->
      let delivery =
        { entry
        ; decision
        ; source
        ; remember_rule
        ; rule_expires_at
        ; created_by
        ; grant_consumed = false
        ; replay_outcome = None
        }
      in
      let updated_pending = SMap.remove id pending_map in
      let updated_deliveries = SMap.add id delivery (Atomic.get deliveries) in
      (match
         persist_snapshot_unlocked
           ~base_path:entry.audit_base_path
           ~pending_map:updated_pending
           ~delivery_map:updated_deliveries
       with
       | Error storage_error -> Error (Journal_storage storage_error)
       | Ok () ->
         Atomic.set pending updated_pending;
         Atomic.set deliveries updated_deliveries;
         Ok delivery))
;;

let remove_delivery_from_store delivery =
  with_pending_store_lock (fun () ->
    let delivery_map = Atomic.get deliveries in
    let updated_deliveries = SMap.remove delivery.entry.id delivery_map in
    match
      persist_snapshot_unlocked
        ~base_path:delivery.entry.audit_base_path
        ~pending_map:(Atomic.get pending)
        ~delivery_map:updated_deliveries
    with
    | Error _ as error -> error
    | Ok () ->
      Atomic.set deliveries updated_deliveries;
      Ok ())
;;

let approval_decision_equal left right =
  match left, right with
  | Decision.Approve, Decision.Approve -> true
  | Decision.Reject left, Decision.Reject right -> String.equal left right
  | (Decision.Approve | Decision.Reject _),
    (Decision.Approve | Decision.Reject _) ->
    false
;;

let remember_rule_for_entry ~base_path ?created_by ?rule_expires_at (entry : pending_approval) =
  try
    match
      Keeper_approval_queue_rules.upsert_rule
        ~base_path
        ~keeper_name:entry.keeper_name
        ~tool_name:entry.tool_name
        ~input:entry.input
        ?created_by
        ~source_approval_id:entry.id
        ?expires_at:rule_expires_at
        ()
    with
    | Ok (rule, created) ->
      let audit_receipts =
        if created
        then
          [ Keeper_approval.Audit.record_rule
              ~base_path
              ~event_type:Keeper_approval.Audit.Rule_created
              rule
          ]
        else []
      in
      Ok (rule, audit_receipts)
    | Error reason -> Error reason
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
    let reason = Printexc.to_string exn in
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string ApprovalQueueFailures)
      ~labels:
        [ "keeper", entry.keeper_name
        ; "site", Keeper_approval_queue_failure_site.(to_label Remember_rule)
        ]
      ();
    Log.Keeper.warn
      "approval_queue: remember rule failed id=%s err=%s"
      entry.id
      reason;
    Error
      ({ path = rules_path ~base_path ()
       ; reason
       }
       : rule_store_error)
;;

let remember_rule_for_delivery delivery =
  match delivery.decision, delivery.remember_rule with
  | Decision.Approve, true ->
    (match
       remember_rule_for_entry
         ~base_path:delivery.entry.audit_base_path
         ?created_by:delivery.created_by
         ?rule_expires_at:delivery.rule_expires_at
         delivery.entry
     with
     | Ok (rule, audit_receipts) -> Ok (Some rule, audit_receipts)
     | Error rule_error ->
       Error
         { path = rule_error.path
         ; reason = rule_error.reason
         })
  | (Decision.Approve | Decision.Reject _),
    false ->
    Ok (None, [])
  | Decision.Reject _, true -> Ok (None, [])
;;

let complete_delivery delivery =
  let id = delivery.entry.id in
  let base_path = delivery.entry.audit_base_path in
  match resolve_store_readiness_error ~base_path ~approval_id:id with
  | Error _ as error -> error
  | Ok () ->
    if delivery.grant_consumed
    then Ok { remembered_rule = None; audit_receipts = [] }
    else
      (match deliver_resolution ~base_path delivery.entry delivery.decision with
       | Error Keeper_registry_event_queue.Hitl_recipient_absent ->
         (* No Keeper exists with the addressed name, so this resolution has
            no consumer — ever. Record the resolution evidence and retire the
            durable delivery; keeping it would replay the same permanent
            failure at every boot. No always-allow rule is written: the
            operator approved a grant for a Keeper that is gone. *)
         (match remove_delivery_from_store delivery with
          | Error storage_error ->
            Error (Persistence_failed { approval_id = id; storage_error })
          | Ok () ->
            Log.Keeper.info
              ~keeper_name:delivery.entry.keeper_name
              "hitl delivery retired: no such keeper approval=%s"
              id;
            let actor =
              match delivery.created_by with
              | Some actor when String.trim actor <> "" -> Some actor
              | Some _ | None -> None
            in
            let resolution_audit_receipt =
              resolve_entry
                ~project_chat:false
                ~base_path
                delivery.entry
                ~source:delivery.source
                ?actor
                delivery.decision
            in
            Ok
              { remembered_rule = None
              ; audit_receipts = [ resolution_audit_receipt ]
              })
       | Error (Keeper_registry_event_queue.Hitl_enqueue_failed reason) ->
         Error (Delivery_failed { approval_id = id; reason })
       | Ok () ->
         (match remember_rule_for_delivery delivery with
          | Error storage_error ->
            Error (Persistence_failed { approval_id = id; storage_error })
          | Ok (remembered_rule, rule_audit_receipts) ->
            let finish () =
              let actor =
                match delivery.created_by with
                | Some actor when String.trim actor <> "" -> Some actor
                | Some _ | None -> None
              in
              let resolution_audit_receipt =
                resolve_entry
                  ~base_path
                  delivery.entry
                  ~source:delivery.source
                  ?actor
                  delivery.decision
              in
              signal_resolution_after_commit
                ~base_path
                ~keeper_name:delivery.entry.keeper_name
                ~approval_id:id;
              Ok
                { remembered_rule
                ; audit_receipts =
                    rule_audit_receipts @ [ resolution_audit_receipt ]
                }
            in
            (match delivery.decision with
             | Decision.Approve ->
               (* Keep the resolved journal entry until the exact Gate request
                  consumes it. The wake event is only a correlation message and
                  cannot become a second authorization SSOT. *)
               finish ()
             | Decision.Reject _ ->
               (match remove_delivery_from_store delivery with
                | Error storage_error ->
                  Error (Persistence_failed { approval_id = id; storage_error })
               | Ok () -> finish ()))))
;;

let delivery_wake_was_observed delivery =
  let resolution : Keeper_event_queue.hitl_resolution =
    { approval_id = delivery.entry.id
    ; decision =
        hitl_resolution_decision_of_approval_decision delivery.decision
    ; channel = delivery.entry.continuation_channel
    }
  in
  let post_id = Keeper_event_queue.hitl_resolution_post_id resolution in
  match
    Keeper_reaction_ledger.event_queue_delivery_seen_for_source_result
      ~base_path:delivery.entry.audit_base_path
      ~keeper_name:delivery.entry.keeper_name
      ~post_id
      ~stimulus_kind:Keeper_reaction_ledger.Hitl_resolved
  with
  | Ok observed -> observed
  | Error error ->
    Log.Keeper.warn
      ~keeper_name:delivery.entry.keeper_name
      "approval_queue: could not verify prior HITL wake delivery approval=%s; replaying safely: %s"
      delivery.entry.id
      (Keeper_reaction_ledger.event_queue_reaction_evidence_error_to_string
         error);
    false
;;

let compare_pending_order left right =
  match String.compare left.audit_base_path right.audit_base_path with
  | 0 ->
    let sequence_order = Int.compare left.sequence right.sequence in
    if sequence_order = 0 then String.compare left.id right.id else sequence_order
  | workspace_order -> workspace_order
;;

let install_persistence_internal ~after_load ~base_path =
  (* Snapshot read and installation are one transition. The hybrid pending
     store lock serializes Eio and non-Eio callers, cooperatively gates Eio
     waiters, and protects cancellation across the durable transition. Keeping
     the load inside this boundary prevents a same-workspace mutation from
     being published between the read and the replacement below. *)
  let installed =
    with_pending_store_lock (fun () ->
      Atomic.set
        pending_read_errors
        (SMap.remove base_path (Atomic.get pending_read_errors));
      let loaded_snapshot =
        match load_snapshot_unlocked ~base_path with
        | Error _ as error -> error
        | Ok
            ( loaded_pending
            , loaded_deliveries
            , loaded_next_sequence
            , pending_read_errors ) ->
          let loaded_deliveries, replay_projection_error =
            load_replay_results_unlocked
              ~base_path
              ~delivery_map:loaded_deliveries
          in
          Ok
            ( loaded_pending
            , loaded_deliveries
            , loaded_next_sequence
            , replay_projection_error
            , pending_read_errors )
      in
      after_load ();
      match loaded_snapshot with
      | Error storage_error ->
        mark_store_unavailable_unlocked ~base_path storage_error;
        Error storage_error
      | Ok
          ( loaded_pending
          , loaded_deliveries
          , loaded_next_sequence
          , replay_projection_error
          , pending_entry_read_errors ) ->
        let current_pending =
          remove_base_entries ~base_path (Atomic.get pending) Fun.id
        in
        let current_deliveries =
          remove_base_entries
            ~base_path
            (Atomic.get deliveries)
            (fun delivery -> delivery.entry)
        in
        (match
           merge_loaded_map
             ~surface:"gate_pending.pending"
             ~existing:current_pending
             ~loaded:loaded_pending,
           merge_loaded_map
             ~surface:"gate_pending.deliveries"
             ~existing:current_deliveries
             ~loaded:loaded_deliveries
         with
         | Error reason, _ | _, Error reason ->
           let path = pending_store_path ~base_path in
           report_pending_read_drop
             ~reason:Read_drop_reason.Invalid_payload
             ~path
             ~detail:reason;
           let error = { path; reason } in
           mark_store_unavailable_unlocked ~base_path error;
           Error error
         | Ok pending_map, Ok delivery_map ->
           (match first_shared_id pending_map delivery_map with
            | Some id ->
              let path = pending_store_path ~base_path in
              let reason =
                Printf.sprintf
                  "gate_pending id %s collides across pending and delivery states"
                  id
              in
              report_pending_read_drop
                ~reason:Read_drop_reason.Invalid_payload
                ~path
                ~detail:reason;
              let error = { path; reason } in
              mark_store_unavailable_unlocked ~base_path error;
              Error error
            | None ->
              (match pending_entry_read_errors with
               | [] -> clear_store_unavailable_unlocked ~base_path
               | first :: _ -> mark_store_unavailable_unlocked ~base_path first);
              Atomic.set
                pending_read_errors
                (match pending_entry_read_errors with
                 | [] -> SMap.remove base_path (Atomic.get pending_read_errors)
                 | errors -> SMap.add base_path errors (Atomic.get pending_read_errors));
              Atomic.set
                replay_projection_errors
                (match replay_projection_error with
                 | None ->
                   SMap.remove
                     base_path
                     (Atomic.get replay_projection_errors)
                 | Some error ->
                   SMap.add
                     base_path
                     error
                     (Atomic.get replay_projection_errors));
              Atomic.set pending pending_map;
              Atomic.set deliveries delivery_map;
              Atomic.set
                next_sequences
                (SMap.add
                   base_path
                   loaded_next_sequence
                   (Atomic.get next_sequences));
              Ok
                ( SMap.cardinal loaded_pending
                , SMap.bindings loaded_deliveries
                  |> List.map snd
                  |> List.sort (fun left right ->
                    compare_pending_order left.entry right.entry)
                , replay_projection_error ))))
  in
  match installed with
  | Error storage_error -> Error (Install_storage_failed storage_error)
  | Ok (loaded_pending, loaded_deliveries, replay_projection_error) ->
    let rec replay count failures = function
      | [] ->
        Ok
          { loaded_pending
          ; replayed_deliveries = count
          ; delivery_replay_failures = List.rev failures
          ; replay_projection_error
          }
      | delivery :: rest ->
        if delivery.grant_consumed
        then replay count failures rest
        else if delivery_wake_was_observed delivery
        then replay count failures rest
        else
          (match complete_delivery delivery with
           | Ok _ -> replay (count + 1) failures rest
           | Error error ->
             let failure =
               { approval_id = delivery.entry.id
               ; reason = resolve_error_to_string error
               }
             in
             replay count (failure :: failures) rest)
    in
    replay 0 [] loaded_deliveries
;;

let install_persistence ~base_path =
  install_persistence_internal ~after_load:(fun () -> ()) ~base_path
;;

module For_testing = struct
  type strict_snapshot_writer =
    string -> string -> (unit, Fs_compat.atomic_replace_failure) result

  let with_pending_store_lock = with_pending_store_lock
  let get_pending_entry_unchecked = find_pending_entry_unchecked

  let reset_runtime_state () =
    with_pending_store_lock (fun () ->
      Atomic.set pending SMap.empty;
      Atomic.set deliveries SMap.empty;
      Atomic.set unavailable_stores SMap.empty;
      Atomic.set pending_read_errors SMap.empty;
      Atomic.set replay_projection_errors SMap.empty;
      Atomic.set store_revisions SMap.empty;
      Atomic.set next_sequences SMap.empty)
  ;;

  let install_persistence_with_after_load_hook ~base_path ~after_load =
    install_persistence_internal ~after_load ~base_path
  ;;

  let pending_store_path = pending_store_path
  let replay_results_store_path = replay_results_store_path
  let always_allowed_store_path ~base_path = rules_path ~base_path ()

  let bind_summary_exact_attempt_with_writer = bind_summary_exact_attempt_with

  let release_summary_exact_attempt_before_dispatch_with_writer =
    release_summary_exact_attempt_before_dispatch_with
  ;;

  let quarantine_summary_exact_attempt_with_writer =
    quarantine_summary_exact_attempt_with
  ;;

  let complete_summary_exact_attempt_with_writer =
    complete_summary_exact_attempt_with
  ;;
end

let resolve_with_policy
      ~base_path
      ~id
      ~(decision : decision)
      ?(source = Human_operator)
      ?(remember_rule = false)
      ?rule_expires_at
      ?created_by
      ()
  : (resolution_result, resolve_error) result
  =
  match resolve_store_readiness_error ~base_path ~approval_id:id with
  | Error _ as error -> error
  | Ok () ->
    let belongs_to_workspace () =
      match SMap.find_opt id (Atomic.get pending) with
      | Some entry -> String.equal entry.audit_base_path base_path
      | None ->
        (match SMap.find_opt id (Atomic.get deliveries) with
         | Some delivery -> String.equal delivery.entry.audit_base_path base_path
         | None -> false)
    in
    if not (belongs_to_workspace ())
    then Error (Not_found id)
    else if not (claim_resolution id)
    then Error (Already_resolved id)
    else
      Fun.protect
        ~finally:(fun () -> release_resolution_claim id)
        (fun () ->
           if not (belongs_to_workspace ())
           then Error (Not_found id)
           else match SMap.find_opt id (Atomic.get pending) with
           | Some _ ->
             let remember_rule =
               match decision with
               | Decision.Approve -> remember_rule
               | Decision.Reject _ -> false
             in
             let rule_expires_at =
               if remember_rule then rule_expires_at else None
             in
             (match
                journal_resolution
                  ~id
                  ~decision
                  ~source
                  ~remember_rule
                  ~rule_expires_at
                  ~created_by
              with
              | Error Journal_not_found -> Error (Not_found id)
              | Error (Journal_storage storage_error) ->
                Error (Persistence_failed { approval_id = id; storage_error })
              | Ok delivery -> complete_delivery delivery)
           | None ->
             (match SMap.find_opt id (Atomic.get deliveries) with
              | None -> Error (Not_found id)
              | Some delivery ->
                let same_request =
                  approval_decision_equal decision delivery.decision
                  && source = delivery.source
                  && remember_rule = delivery.remember_rule
                  && rule_expires_at = delivery.rule_expires_at
                  && created_by = delivery.created_by
                in
                if same_request
                then complete_delivery delivery
                else Error (Already_resolved id)))
;;

(* ── Query ────────────────────────────────────────────────── *)

let retire_summary_owner ~base_path ~keeper_name ~reason =
  let result =
    with_pending_store_lock (fun () ->
      let current = Atomic.get pending in
      let ids, next, bound =
        SMap.fold
          (fun id (entry : pending_approval) (ids, map, bound) ->
             if
               String.equal entry.audit_base_path base_path
               && String.equal entry.keeper_name keeper_name
             then
               match entry.summary_status, entry.exact_attempt with
               | Summary_pending, Exact_bound attempt ->
                 ids, map, Some attempt
               | Summary_pending, Exact_unbound ->
                 ( id :: ids
                 , SMap.add
                     id
                     { entry with
                       summary_status = Summary_failed { reason }
                     }
                     map
                 , bound )
               | ( Summary_not_requested
                 | Summary_available _
                 | Summary_failed _ ),
                 _ ->
                 ids, map, bound
             else ids, map, bound)
          current
          ([], current, None)
      in
      match bound, ids with
      | Some attempt, _ ->
        Error (Summary_owner_retirement_exact_attempt_unsettled attempt)
      | None, [] -> Ok []
      | None, _ ->
        (match
           persist_snapshot_unlocked
             ~base_path
             ~pending_map:next
             ~delivery_map:(Atomic.get deliveries)
         with
         | Error error ->
           Error (Summary_owner_retirement_storage_error error)
         | Ok () ->
           Atomic.set pending next;
           Ok (List.rev ids)))
  in
  match result with
  | Error _ as error -> error
  | Ok ids ->
    List.iter (fun id -> publish_summary_update ~id) ids;
    Ok ids
;;

let pending_entries_in_sequence_order () =
  SMap.fold (fun _id entry acc -> entry :: acc) (Atomic.get pending) []
  |> List.sort compare_pending_order
;;

type pending_entries_snapshot =
  { revision : int
  ; entries : pending_approval list
  ; read_errors : storage_error list
  }

let pending_entries_snapshot_unlocked ~base_path =
  let entries =
    pending_entries_in_sequence_order ()
    |> List.filter (fun (entry : pending_approval) ->
      String.equal entry.audit_base_path base_path)
  in
  let revision = store_revision_unlocked ~base_path in
  match SMap.find_opt base_path (Atomic.get unavailable_stores) with
  | Some _ when SMap.mem base_path (Atomic.get pending_read_errors) ->
    Ok
      { revision
      ; entries
      ; read_errors =
          Option.value
            (SMap.find_opt base_path (Atomic.get pending_read_errors))
            ~default:[]
      }
  | Some error -> Error error
  | None -> Ok { revision; entries; read_errors = [] }
;;

let pending_entries_snapshot_for_workspace ~base_path =
  with_pending_store_lock (fun () ->
    pending_entries_snapshot_unlocked ~base_path)
;;

let list_pending_entries_with_read_errors_for_workspace ~base_path =
  pending_entries_snapshot_for_workspace ~base_path
  |> Result.map (fun snapshot -> snapshot.entries, snapshot.read_errors)
;;

let list_pending_entries_for_workspace ~base_path =
  list_pending_entries_with_read_errors_for_workspace ~base_path
  |> Result.map fst
;;

let get_pending_entry_for_workspace ~base_path ~id =
  with_pending_store_lock (fun () ->
    match SMap.find_opt base_path (Atomic.get unavailable_stores) with
    | Some error -> Error error
    | None ->
      (match SMap.find_opt id (Atomic.get pending) with
       | Some entry when String.equal entry.audit_base_path base_path ->
         Ok (Some entry)
       | Some _ | None -> Ok None))
;;

let list_pending_dashboard_json_for_workspace ~base_path =
  list_pending_entries_for_workspace ~base_path
  |> Result.map (fun entries ->
    entries
    |> List.map (fun entry ->
      `Assoc (pending_entry_json_fields ~include_input:true entry)))
;;

let pending_count_for_keeper_in_workspace ~base_path ~keeper_name =
  list_pending_entries_for_workspace ~base_path
  |> Result.map (fun entries ->
    List.fold_left
      (fun count (entry : pending_approval) ->
        if String.equal entry.keeper_name keeper_name then count + 1 else count)
      0
      entries)
;;
