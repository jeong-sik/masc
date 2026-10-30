open Keeper_approval_queue_rules_types

type read_stage =
  | Read_recent
  | List_recent_resolved

type read_error =
  { stage : read_stage
  ; detail : string
  }

val read_stage_to_string : read_stage -> string
val read_error_to_string : read_error -> string

(** Typed approval audit events persisted under the workspace MASC root. *)
type event =
  | Pending
  | Resolved
  | Summary_updated
  | Rule_created
  | Rule_renewed
  | Rule_deleted
  | Grant_consumed
  | Gate_allowed
  | Gate_exact_rule_expired
  | Gate_exact_rule_store_degraded
  | Gate_grant_unavailable
  | Auto_judge_operator_retry_started
  | Auto_judge_block_observation_superseded
  | Auto_judge_restart_worker_recovered
  | Auto_judge_restart_judgment_recovered

val event_to_string : event -> string
val event_of_string : string -> event option

type write_stage =
  | Store_create
  | Append
  | Append_cleanup

type write_failure =
  { stage : write_stage
  ; detail : string
  }

type receipt =
  { event_type : event
  ; write_result : (unit, write_failure) result
  ; cleanup_failure : write_failure option
  }

val receipt_to_yojson : receipt -> Yojson.Safe.t

type decision_kind =
  | Decision_approve
  | Decision_reject

val decision_kind_to_string : decision_kind -> string
val decision_kind_of_string : string -> decision_kind option

(** Observation-only write boundary. Store creation, append, and cooperative
    cancellation failures are contained in the typed receipt; none may erase
    or invite replay of the authoritative mutation that selected this event. *)
val record :
  base_path:string ->
  event_type:event ->
  id:string ->
  keeper_name:string ->
  tool_name:string ->
  ?turn_id:int ->
  ?task_id:string ->
  ?goal_id:string ->
  ?rule_match:rule_match ->
  ?source_approval_id:string ->
  ?actor:string ->
  ?decision_source:decision_source ->
  ?authorization_source:authorization_source ->
  ?decision:decision ->
  ?summary_status:summary_status ->
  ?exact_attempt:exact_attempt_state ->
  ?summary_attempt_disposition:summary_attempt_disposition ->
  ?timestamp:float ->
  ?extra_fields:(string * Yojson.Safe.t) list ->
  unit ->
  receipt

val record_rule_created : base_path:string -> approval_rule -> receipt
(** [Rule_created] row. Its actor is the rule's own [created_by]: the
    principal whose remembered approval made the rule. *)

val record_rule_renewed :
  base_path:string ->
  ?renewed_by:string ->
  source_approval_id:string ->
  previous_expires_at:float option ->
  approval_rule ->
  receipt
(** [Rule_renewed] row with the current approving actor and approval identity.
    The rule retains its original creation metadata. Both expiry options are
    recorded; [None] means permanent. *)

val record_rule_deleted :
  base_path:string -> deleted_by:string -> approval_rule -> receipt
(** [Rule_deleted] row. [deleted_by] is the authenticated principal that
    removed the rule, which is not the rule's author. *)

val recent_resolved_history_limit : int
val recent_resolved_max_limit : int
val recent_resolved_default_window_minutes : int
val recent_resolved_min_window_minutes : int
val recent_resolved_max_window_minutes : int

val read_recent_max_rows : int
(** The largest [n] {!read_recent} answers. *)

(** Newest [n] rows in physical append order (newest first). A Keeper-scoped
    read counts matching rows; unrelated traffic cannot truncate the result.
    Each read first advances an in-process index over the day files written
    since an earlier read, so the answer is the store's content at that read;
    a file rewritten in place is read again from its first byte. Reads that
    arrive together share one such advance and wait for it on a promise. The
    index keeps the newest {!read_recent_max_rows} rows of each Keeper and of
    the whole store; a larger [n] is refused.
    Failures are the ones a backward scan that stops at the [n]-th match would
    meet: malformed JSON, an unreadable month listing or day file newer than the
    [n]-th selected row, or anywhere when fewer than [n] rows match, return
    [Read_recent] errors. For a scoped read a JSON row that does not name
    exactly one string Keeper is such a failure, never an omitted row.
    Corruption older than a complete selected suffix is not an error. The
    store's month directories are validated on every read.
    [n <= 0] returns [Ok []] without opening the store. *)
val read_recent :
  base_path:string ->
  ?keeper_name:string ->
  ?n:int ->
  unit ->
  (Yojson.Safe.t list, read_error) result

val day_string_of_ts : float -> string

type resolved_history =
  { resolved_rows : Yojson.Safe.t list
  ; resolved_matched : int
  ; resolved_limit : int
  ; resolved_window_minutes : int
  ; resolved_scan_exhausted : bool
  }

val list_recent_resolved :
  base_path:string ->
  now_ts:float ->
  ?limit:int ->
  ?window_minutes:int ->
  unit ->
  (resolved_history, read_error) result

module For_testing : sig
  val reset_store : unit -> unit
  val set_store_create_probe : (base_path:string -> unit) -> unit
  val set_append_jsonl : (string -> Yojson.Safe.t -> unit) -> unit
  val set_append_jsonl_cleanup_failure : string -> unit
  val with_audit_io_lock : (unit -> unit) -> unit
end
