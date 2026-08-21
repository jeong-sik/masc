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

val record_rule : base_path:string -> event_type:event -> approval_rule -> receipt

val recent_resolved_history_limit : int
val recent_resolved_max_limit : int
val recent_resolved_default_window_minutes : int
val recent_resolved_min_window_minutes : int
val recent_resolved_max_window_minutes : int

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
