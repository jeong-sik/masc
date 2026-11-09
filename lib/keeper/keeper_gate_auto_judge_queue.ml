type judgment_finalize_outcome =
  | Judgment_finalized
  | Judgment_skipped

let resolve_judgment (entry : Keeper_approval_queue_rules_types.pending_approval) ~approval_id
      (summary : Keeper_approval_queue_rules_types.hitl_context_summary) =
  let decision =
    match summary.Keeper_approval_queue_rules_types.judgment with
    | Keeper_approval_queue_rules_types.Approve -> Some Keeper_approval_queue_rules_types.Decision.Approve
    | Keeper_approval_queue_rules_types.Deny ->
      Some (Keeper_approval_queue_rules_types.Decision.Reject summary.rationale)
    | Keeper_approval_queue_rules_types.Require_human -> None
  in
  match decision with
  | None -> Ok Judgment_skipped
  | Some decision ->
    (match
       Keeper_approval_queue.resolve_with_policy
         ~base_path:entry.audit_base_path
         ~id:approval_id
         ~decision
         ~source:Keeper_approval_queue_rules_types.Auto_judge
         ~created_by:("auto_judge:" ^ summary.model_run_id)
         ()
     with
     | Ok _ -> Ok Judgment_finalized
     | Error (Keeper_approval_queue.Not_found _ | Keeper_approval_queue.Already_resolved _) ->
       Ok Judgment_skipped
     | Error
         (( Keeper_approval_queue.Delivery_failed _
          | Keeper_approval_queue.Persistence_failed _ ) as error) ->
       Error (Keeper_approval_queue.resolve_error_to_string error))
;;

type auto_judge_start_outcome =
  | Started
  | Skipped

type auto_judge_retry_outcome =
  | Retry_started
  | Retry_skipped

(* One typed failure per distinct cause of an operator retry, so HTTP
   surfaces can map failure to status without matching on rendered text.
   [retry_blocked_auto_judge] keeps its string contract by mapping these
   through [auto_judge_retry_error_to_string]. *)
type auto_judge_retry_error =
  | Retry_mode_unreadable of string
      (** The workspace or owner mode store could not be read. *)
  | Retry_row_missing of string
      (** No pending approval carries this id in the workspace. *)
  | Retry_row_lookup_failed of Keeper_approval_queue_result.storage_error
      (** The pending row could not be read. *)
  | Retry_not_auto_judge of string
      (** The owner's effective mode is not auto_judge. *)
  | Retry_not_blocked of string
      (** The CAS predicate did not hold: the row is not a blocked summary. *)
  | Retry_cas_rejected of Keeper_approval_queue_result.exact_attempt_error
      (** The exact-attempt CAS refused the write (identity or state). *)
  | Retry_drain_failed of string
      (** The reservation landed but the drain could not start the summary;
          the row was re-blocked durably with this operator detail. *)

let auto_judge_retry_error_to_string = function
  | Retry_mode_unreadable detail -> detail
  | Retry_row_missing approval_id ->
    "pending approval not found: " ^ approval_id
  | Retry_row_lookup_failed detail ->
    Keeper_approval_queue_result.storage_error_to_string detail
  | Retry_not_auto_judge keeper_name ->
    Printf.sprintf
      "Auto Judge retry requires auto_judge mode for keeper %s"
      keeper_name
  | Retry_not_blocked approval_id ->
    "approval summary is not blocked or is already active: " ^ approval_id
  | Retry_cas_rejected error ->
    Keeper_approval_queue_result.exact_attempt_error_to_string error
  | Retry_drain_failed reason -> reason

module Auto_judge_owner = struct
  type t = string * string

  let compare (left_base, left_keeper) (right_base, right_keeper) =
    let by_base = String.compare left_base right_base in
    if by_base <> 0 then by_base else String.compare left_keeper right_keeper
  ;;
end

module Auto_judge_owners = Map.Make (Auto_judge_owner)
module Auto_judge_owner_set = Set.Make (Auto_judge_owner)
module Auto_judge_ids = Set.Make (String)

let auto_judge_owner (entry : Keeper_approval_queue_rules_types.pending_approval) =
  entry.audit_base_path, entry.keeper_name
;;

(** Immutable process projection of the bounded active approvals for each exact
    workspace/Keeper owner. The durable approval queue remains the work SSOT;
    this map is only atomic admission state. *)
let active_auto_judges : Auto_judge_ids.t Auto_judge_owners.t Atomic.t =
  Atomic.make Auto_judge_owners.empty
;;

let rec claim_auto_judge (entry : Keeper_approval_queue_rules_types.pending_approval) =
  let active = Atomic.get active_auto_judges in
  let owner = auto_judge_owner entry in
  let active_ids =
    Auto_judge_owners.find_opt owner active
    |> Option.value ~default:Auto_judge_ids.empty
  in
  if Auto_judge_ids.mem entry.id active_ids
     || Auto_judge_ids.cardinal active_ids
        >= Keeper_config.keeper_hitl_max_concurrent_per_keeper ()
  then false
  else
    let claimed =
      Auto_judge_owners.add
        owner
        (Auto_judge_ids.add entry.id active_ids)
        active
    in
    if Atomic.compare_and_set active_auto_judges active claimed
    then true
    else claim_auto_judge entry
;;

let rec release_auto_judge (entry : Keeper_approval_queue_rules_types.pending_approval) =
  let active = Atomic.get active_auto_judges in
  let owner = auto_judge_owner entry in
  match Auto_judge_owners.find_opt owner active with
  | Some active_ids when Auto_judge_ids.mem entry.id active_ids ->
    let remaining = Auto_judge_ids.remove entry.id active_ids in
    let released =
      if Auto_judge_ids.is_empty remaining
      then Auto_judge_owners.remove owner active
      else Auto_judge_owners.add owner remaining active
    in
    if not (Atomic.compare_and_set active_auto_judges active released)
    then release_auto_judge entry
  | Some _ | None -> ()
;;

(* Whether this process holds a live in-memory admission for [entry]. Because
   [claim_auto_judge] precedes every [reserve_pre_worker_start] and the set is
   reset empty on process start, a durable start reservation is live iff its id
   is admitted here. A stranded reservation (its claiming process gone) is
   absent, which is what boot recovery relies on to reclaim only orphans. *)
let auto_judge_entry_claimed
      (entry : Keeper_approval_queue_rules_types.pending_approval)
  =
  let active = Atomic.get active_auto_judges in
  match Auto_judge_owners.find_opt (auto_judge_owner entry) active with
  | Some active_ids -> Auto_judge_ids.mem entry.id active_ids
  | None -> false
;;

let active_auto_judges_for_owner ~base_path ~keeper_name =
  Auto_judge_owners.find_opt
    (base_path, keeper_name)
    (Atomic.get active_auto_judges)
  |> Option.value ~default:Auto_judge_ids.empty
  |> Auto_judge_ids.elements
;;

type auto_judge_entry_class =
  | Auto_judge_not_requested
  | Auto_judge_pending_unbound
  | Auto_judge_finalizable of Keeper_approval_queue_rules_types.hitl_context_summary
  | Auto_judge_ineligible

let classify_auto_judge_entry
      (entry : Keeper_approval_queue_rules_types.pending_approval)
  =
  match
    entry.summary_attempt_disposition,
    entry.exact_attempt,
    entry.summary_status
  with
  | Keeper_approval_queue_rules_types.Summary_attempt_ready,
    Keeper_approval_queue_rules_types.Exact_unbound,
    Keeper_approval_queue_rules_types.Summary_not_requested ->
    Auto_judge_not_requested
  | Keeper_approval_queue_rules_types.Summary_attempt_ready,
    Keeper_approval_queue_rules_types.Exact_unbound,
    Keeper_approval_queue_rules_types.Summary_pending ->
    Auto_judge_pending_unbound
  | ( Keeper_approval_queue_rules_types.Summary_attempt_settled
    | Keeper_approval_queue_rules_types.Summary_attempt_persistence_uncertain ),
    Keeper_approval_queue_rules_types.Exact_bound
      { status = Keeper_approval_queue_rules_types.Exact_completed; _ },
    Keeper_approval_queue_rules_types.Summary_available summary ->
    Auto_judge_finalizable summary
  | (Keeper_approval_queue_rules_types.Summary_attempt_settled, Keeper_approval_queue_rules_types.Exact_bound { status = Keeper_approval_queue_rules_types.Exact_completed;_}, (Keeper_approval_queue_rules_types.Summary_not_requested | (Keeper_approval_queue_rules_types.Summary_pending | Keeper_approval_queue_rules_types.Summary_failed _)))
  | (Keeper_approval_queue_rules_types.Summary_attempt_settled, Keeper_approval_queue_rules_types.Exact_bound { status = (Keeper_approval_queue_rules_types.Exact_dispatch_uncertain | (Keeper_approval_queue_rules_types.Exact_released_before_dispatch | (Keeper_approval_queue_rules_types.Exact_released_recovery_required | (Keeper_approval_queue_rules_types.Exact_restart_quarantined | Keeper_approval_queue_rules_types.Exact_quarantined _))));_}, _)
  | (Keeper_approval_queue_rules_types.Summary_attempt_settled, Keeper_approval_queue_rules_types.Exact_unbound, _)
  | (Keeper_approval_queue_rules_types.Summary_attempt_persistence_uncertain, Keeper_approval_queue_rules_types.Exact_bound { status = Keeper_approval_queue_rules_types.Exact_completed;_}, (Keeper_approval_queue_rules_types.Summary_not_requested | (Keeper_approval_queue_rules_types.Summary_pending | Keeper_approval_queue_rules_types.Summary_failed _)))
  | (Keeper_approval_queue_rules_types.Summary_attempt_persistence_uncertain, Keeper_approval_queue_rules_types.Exact_bound { status = (Keeper_approval_queue_rules_types.Exact_dispatch_uncertain | (Keeper_approval_queue_rules_types.Exact_released_before_dispatch | (Keeper_approval_queue_rules_types.Exact_released_recovery_required | (Keeper_approval_queue_rules_types.Exact_restart_quarantined | Keeper_approval_queue_rules_types.Exact_quarantined _))));_}, _)
  | (Keeper_approval_queue_rules_types.Summary_attempt_persistence_uncertain, Keeper_approval_queue_rules_types.Exact_unbound, _)
  | (Keeper_approval_queue_rules_types.Summary_attempt_ready, Keeper_approval_queue_rules_types.Exact_unbound, (Keeper_approval_queue_rules_types.Summary_available _ | Keeper_approval_queue_rules_types.Summary_failed _))
  | (Keeper_approval_queue_rules_types.Summary_attempt_ready, Keeper_approval_queue_rules_types.Exact_bound _, _)
  | ((Keeper_approval_queue_rules_types.Summary_attempt_in_flight | (Keeper_approval_queue_rules_types.Summary_attempt_identity_unbound | Keeper_approval_queue_rules_types.Summary_attempt_pre_worker_unavailable _)), _, _) -> Auto_judge_ineligible
;;

let auto_judge_entry_ready entry =
  match classify_auto_judge_entry entry with
  | Auto_judge_not_requested
  | Auto_judge_pending_unbound ->
    true
  | Auto_judge_finalizable _
  | Auto_judge_ineligible ->
    false
;;

let compare_auto_judge_entries
      (left : Keeper_approval_queue_rules_types.pending_approval)
      (right : Keeper_approval_queue_rules_types.pending_approval)
  =
  Int.compare left.sequence right.sequence
;;

(* Every pending approval for the owner, in durable sequence order. Selection
   ranges over this list; [ready_auto_judges_for_owner] decides which member
   Auto Judge may start. *)
let owner_auto_judges_in_fifo_order ~base_path ~keeper_name entries =
  entries
  |> List.filter (fun (entry : Keeper_approval_queue_rules_types.pending_approval) ->
    String.equal entry.audit_base_path base_path
    && String.equal entry.keeper_name keeper_name)
  |> List.sort compare_auto_judge_entries
;;

let auto_judge_entry_has_start_reservation
      reserved_id
      (entry : Keeper_approval_queue_rules_types.pending_approval)
  =
  String.equal entry.id reserved_id
  &&
  match
    entry.summary_status,
    entry.exact_attempt,
    entry.summary_attempt_disposition
  with
  | Keeper_approval_queue_rules_types.Summary_pending,
    Keeper_approval_queue_rules_types.Exact_unbound,
    Keeper_approval_queue_rules_types.Summary_attempt_pre_worker_unavailable
      { reason_code =
          Keeper_approval_queue_rules_types.Summary_pre_worker_start_reserved
      ; _
      } ->
    true
  | (Keeper_approval_queue_rules_types.Summary_pending, Keeper_approval_queue_rules_types.Exact_unbound, Keeper_approval_queue_rules_types.Summary_attempt_pre_worker_unavailable { reason_code = (Keeper_approval_queue_rules_types.Summary_pre_worker_auto_judge_unavailable | Keeper_approval_queue_rules_types.Summary_pre_worker_mode_state_invalid);_})
  | (Keeper_approval_queue_rules_types.Summary_pending, Keeper_approval_queue_rules_types.Exact_unbound, (Keeper_approval_queue_rules_types.Summary_attempt_ready | (Keeper_approval_queue_rules_types.Summary_attempt_in_flight | (Keeper_approval_queue_rules_types.Summary_attempt_identity_unbound | (Keeper_approval_queue_rules_types.Summary_attempt_persistence_uncertain | Keeper_approval_queue_rules_types.Summary_attempt_settled)))))
  | (Keeper_approval_queue_rules_types.Summary_pending, Keeper_approval_queue_rules_types.Exact_bound _, _)
  | ((Keeper_approval_queue_rules_types.Summary_not_requested | (Keeper_approval_queue_rules_types.Summary_available _ | Keeper_approval_queue_rules_types.Summary_failed _)), _, _) -> false
;;

(* Sequence order is kept, but selection ranges over the entries Auto Judge can
   still start instead of testing only the FIFO head. A head that is not
   startable is not always transient. An entry whose judgment concluded in
   [Require_human] keeps [Summary_attempt_settled] with [Summary_available]
   for as long as it stays pending, because [resolve_judgment] persists no
   transition for that verdict; a [Summary_attempt_pre_worker_unavailable]
   entry waits for an explicit operator retry. Both classify as not ready, so
   testing only the head stops the whole owner queue at the first such entry
   and no drain trigger can restart it. Observed on 2026-07-28: 18 approvals
   across two Keepers sat behind two heads of exactly these two kinds, the
   oldest for 2416s, while new submissions kept firing the drain. Concurrency
   remains bounded by [claim_auto_judge], not by this ordering. Selection fills
   the owner's currently available slots in durable sequence order. *)
let ready_auto_judges_for_owner
      ?reserved_id
      ~base_path
      ~keeper_name
      entries
  =
  let startable (entry : Keeper_approval_queue_rules_types.pending_approval) =
    auto_judge_entry_ready entry
    ||
    (match reserved_id with
     | Some reserved_id ->
       auto_judge_entry_has_start_reservation reserved_id entry
     | None -> false)
  in
  let available =
    Keeper_config.keeper_hitl_max_concurrent_per_keeper ()
    - List.length (active_auto_judges_for_owner ~base_path ~keeper_name)
    |> max 0
  in
  let candidates =
    owner_auto_judges_in_fifo_order ~base_path ~keeper_name entries
    |> List.filter startable
  in
  let rec take n acc = function
    | _ when n <= 0 -> List.rev acc
    | [] -> List.rev acc
    | entry :: rest -> take (n - 1) (entry :: acc) rest
  in
  match reserved_id with
  | Some reserved_id when available > 0 ->
    (match
       List.find_opt
         (fun (entry : Keeper_approval_queue_rules_types.pending_approval) ->
            String.equal entry.id reserved_id)
         candidates
     with
     | Some entry -> [ entry ]
     | None -> [])
  | Some _ -> []
  | None -> take available [] candidates
;;

type auto_judge_drain_blocker =
  | Drain_owner_at_capacity of string list
  | Drain_entry_changed of string
  | Drain_entry_missing of string
  | Drain_start_failed of string * string
  | Drain_mode_manual
  | Drain_mode_always_allow

let auto_judge_drain_blocker_to_string = function
  | Drain_owner_at_capacity approval_ids ->
    Printf.sprintf
      "Auto Judge retry could not start because the owner has %d active worker(s): %s"
      (List.length approval_ids)
      (String.concat "," approval_ids)
  | Drain_entry_changed approval_id ->
    Printf.sprintf
      "Auto Judge retry could not start because approval %s changed before worker start"
      approval_id
  | Drain_entry_missing approval_id ->
    Printf.sprintf
      "Auto Judge retry could not start because approval %s is no longer pending"
      approval_id
  | Drain_start_failed (approval_id, reason) ->
    Printf.sprintf
      "Auto Judge retry could not start because approval %s failed before worker start: %s"
      approval_id
      reason
  | Drain_mode_manual ->
    "Auto Judge retry could not start because Gate mode changed to manual"
  | Drain_mode_always_allow ->
    "Auto Judge retry could not start because Gate mode changed to always_allow"
;;

(* Declared before [auto_judge_drain_outcome] and [auto_judge_owner_failure]
   so those records stay the last definitions of the shared [blocker] and
   [keeper_name] labels. *)
type auto_judge_owner_blocker =
  { keeper_name : string
  ; blocker : auto_judge_drain_blocker
  }

type auto_judge_drain_outcome =
  { started_ids : string list
  ; failures : (string * string) list
  ; blocker : auto_judge_drain_blocker option
  }

type auto_judge_owner_failure =
  { keeper_name : string
  ; approval_id : string option
  ; operator_detail : string
  }

type auto_judge_workspace_drain_report =
  { started_ids : string list
  ; failures : auto_judge_owner_failure list
  ; blockers : auto_judge_owner_blocker list
  }

let drain_auto_judge_owners_with ~drain_owner owners =
  let started_ids, failures, blockers =
    List.fold_left
      (fun (started_ids, failures, blockers) (base_path, keeper_name) ->
         match drain_owner ~base_path ~keeper_name with
         | Error operator_detail ->
           ( started_ids
           , ({ keeper_name; approval_id = None; operator_detail }
              : auto_judge_owner_failure)
             :: failures
           , blockers )
         | Ok (owner_started_ids, owner_failures, owner_blocker) ->
           let started_ids = List.rev_append owner_started_ids started_ids in
           let failures =
             List.fold_left
               (fun failures (approval_id, operator_detail) ->
                  { keeper_name
                  ; approval_id = Some approval_id
                  ; operator_detail
                  }
                  :: failures)
               failures
               owner_failures
           in
           (* The owner's typed blocker is why its drain stopped short; the
              operator report carries it so a stalled owner is explained
              rather than showing only a started count (#25979). *)
           let blockers =
             match owner_blocker with
             | None -> blockers
             | Some blocker ->
               ({ keeper_name; blocker } : auto_judge_owner_blocker) :: blockers
           in
           started_ids, failures, blockers)
      ([], [], [])
      owners
  in
  { started_ids = List.rev started_ids
  ; failures = List.rev failures
  ; blockers = List.rev blockers
  }
;;
