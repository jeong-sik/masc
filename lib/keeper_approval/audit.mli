open Keeper_approval_queue_rules_types

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

type decision_kind =
  | Decision_approve
  | Decision_reject
  | Decision_edit

val decision_kind_to_string : decision_kind -> string
val decision_kind_of_string : string -> decision_kind option

val record :
  base_path:string ->
  event_type:event ->
  id:string ->
  keeper_name:string ->
  tool_name:string ->
  ?turn_id:int ->
  ?task_id:string ->
  ?goal_id:string ->
  ?goal_ids:string list ->
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
  unit

val record_rule : base_path:string -> event_type:event -> approval_rule -> unit

val recent_resolved_history_limit : int
val recent_resolved_max_limit : int
val recent_resolved_default_window_minutes : int
val recent_resolved_min_window_minutes : int
val recent_resolved_max_window_minutes : int

val read_recent :
  base_path:string -> ?keeper_name:string -> ?n:int -> unit -> Yojson.Safe.t list

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
  resolved_history

module For_testing : sig
  val reset_store : unit -> unit
end
