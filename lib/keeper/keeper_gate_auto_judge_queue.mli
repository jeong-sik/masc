(** Auto Judge bookkeeping that needs no worker: how a judgment resolves its
    approval, the outcomes and errors of a start or retry, the per-owner table
    of active judges, which pending approvals are ready and in what order, and
    the report of one drain over the owners. [Keeper_gate] includes this
    module. *)

type judgment_finalize_outcome =
  | Judgment_finalized
  | Judgment_skipped

val resolve_judgment :
  Keeper_approval_queue_rules_types.pending_approval ->
  approval_id:string ->
  Keeper_approval_queue_rules_types.hitl_context_summary ->
  (judgment_finalize_outcome, string) result

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

val auto_judge_retry_error_to_string : auto_judge_retry_error -> string

module Auto_judge_owner : sig
  type t = string * string

  val compare : t -> t -> int
end

module Auto_judge_owner_set :
  Set.S
    with type elt = Auto_judge_owner.t
     and type t = Set.Make(Auto_judge_owner).t

val auto_judge_owner :
  Keeper_approval_queue_rules_types.pending_approval -> Auto_judge_owner.t

val claim_auto_judge :
  Keeper_approval_queue_rules_types.pending_approval -> bool

val release_auto_judge :
  Keeper_approval_queue_rules_types.pending_approval -> unit

val auto_judge_entry_claimed :
  Keeper_approval_queue_rules_types.pending_approval -> bool

val active_auto_judges_for_owner :
  base_path:string -> keeper_name:string -> string list

type auto_judge_entry_class =
  | Auto_judge_not_requested
  | Auto_judge_pending_unbound
  | Auto_judge_finalizable of Keeper_approval_queue_rules_types.hitl_context_summary
  | Auto_judge_ineligible

val classify_auto_judge_entry :
  Keeper_approval_queue_rules_types.pending_approval ->
  auto_judge_entry_class

val auto_judge_entry_ready :
  Keeper_approval_queue_rules_types.pending_approval -> bool

val compare_auto_judge_entries :
  Keeper_approval_queue_rules_types.pending_approval ->
  Keeper_approval_queue_rules_types.pending_approval -> int

val owner_auto_judges_in_fifo_order :
  base_path:string ->
  keeper_name:string ->
  Keeper_approval_queue_rules_types.pending_approval list ->
  Keeper_approval_queue_rules_types.pending_approval list

val auto_judge_entry_has_start_reservation :
  string -> Keeper_approval_queue_rules_types.pending_approval -> bool

val ready_auto_judges_for_owner :
  ?reserved_id:string ->
  base_path:string ->
  keeper_name:string ->
  Keeper_approval_queue_rules_types.pending_approval list ->
  Keeper_approval_queue_rules_types.pending_approval list

type auto_judge_drain_blocker =
  | Drain_owner_at_capacity of string list
  | Drain_entry_changed of string
  | Drain_entry_missing of string
  | Drain_start_failed of string * string
  | Drain_mode_manual
  | Drain_mode_always_allow

val auto_judge_drain_blocker_to_string : auto_judge_drain_blocker -> string

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

val drain_auto_judge_owners_with :
  drain_owner:(base_path:'a ->
               keeper_name:string ->
               (string list * (string * string) list *
                auto_judge_drain_blocker option, string)
               result) ->
  ('a * string) list -> auto_judge_workspace_drain_report
