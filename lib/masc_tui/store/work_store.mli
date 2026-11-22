(** Work domain sub-store: Goals, Tasks (with unlinked-task diagnostics),
    Verifications & Criterion reviews, Schedules, Inbox Asks/Approvals +
    Recent 24h Decisions audit trail, and Fleet Candle Ledger. *)

open Masc_tui_core
open Masc_tui_keymap
open Masc_tui_protocol

module String_set : Set.S with type elt = string

type decision_kind =
  | Decision_ask_answered
  | Decision_tool_approved
  | Decision_tool_denied
  | Decision_gate_approved
  | Decision_gate_rejected
  | Decision_goal_confirmed
  | Decision_verification_approved
  | Decision_verification_rejected

type decision_audit_entry = {
  at_unix : float;
  kind : decision_kind;
  target_id : string;
  keeper : string option;
  summary : string;
}

type t = {
  active_tab : Nav.work_tab;
  planning : Wire_work.planning_snapshot Observed.t;
  backlog_counts : Wire_work.task_backlog_counts option;
  verifications : Wire_work.verification_request list Observed.t;
  schedules : (Wire_work.schedule_row list * string option) Observed.t;
  asks : Wire_work.ask_row list Observed.t;
  tool_approvals : Wire_work.held_tool_approval list Observed.t;
  gate_pending : Wire_work.gate_pending list Observed.t;
  recent_decisions_24h : decision_audit_entry list;
  candle_ledger : Wire_work.candle_ledger Observed.t;
  candle_fallback_404 : bool;
  selected_index : int;
  scroll_offset : int;
  filter_query : string;
  verification_view : [ `Pending | `All ];
  expanded_ids : String_set.t;
}

val empty : t

val set_tab : Nav.work_tab -> t -> t
val cycle_tab : Keymap.cycle_dir -> t -> t

val apply_planning :
  observed_at:Clock.Mono.t -> Wire_work.planning_snapshot -> t -> t
val apply_backlog_counts : Wire_work.task_backlog_counts -> t -> t
val apply_verifications :
  observed_at:Clock.Mono.t -> Wire_work.verification_request list -> t -> t
val apply_schedules :
  observed_at:Clock.Mono.t ->
  Wire_work.schedule_row list * string option ->
  t ->
  t
val apply_asks :
  observed_at:Clock.Mono.t -> Wire_work.ask_row list -> t -> t
val apply_tool_approvals :
  observed_at:Clock.Mono.t -> Wire_work.held_tool_approval list -> t -> t
val apply_gate_pending :
  observed_at:Clock.Mono.t -> Wire_work.gate_pending list -> t -> t
val apply_candle_ledger :
  observed_at:Clock.Mono.t -> Wire_work.candle_ledger -> t -> t
val apply_candle_ledger_fallback :
  observed_at:Clock.Mono.t ->
  summary:Wire_fleet.candle_summary_fallback option ->
  balances:(string * int) list ->
  t ->
  t
(** Synthesize a truthful fallback {!Wire_work.candle_ledger} from
    [/api/v1/gate/keepers] / [/api/v1/dashboard/execution] when
    [/api/v1/candle/ledger] returns HTTP 404 on older servers. *)

val effective_task_counts : t -> Wire_work.task_backlog_counts option
(** Aggregate task status counts from [backlog_counts] or decoded [tasks]. *)

val verification_pass_summary : t -> int * int * int
(** [(passed_count, rejected_count, awaiting_count)] from loaded verifications. *)

val record_decision :
  at_unix:float ->
  kind:decision_kind ->
  target_id:string ->
  keeper:string option ->
  summary:string ->
  t ->
  t

val goals : t -> Wire_work.goal list
val tasks : t -> Wire_work.task list
val verifications_list : t -> Wire_work.verification_request list
val schedules_list : t -> Wire_work.schedule_row list
val asks_list : t -> Wire_work.ask_row list
val open_asks : t -> Wire_work.ask_row list
val tool_approvals_list : t -> Wire_work.held_tool_approval list
val gate_pending_list : t -> Wire_work.gate_pending list

val unlinked_task_count : t -> int
val awaiting_confirmation_goals : t -> Wire_work.goal list

val selected_goal : t -> Wire_work.goal option
val selected_task : t -> Wire_work.task option
val selected_verification : t -> Wire_work.verification_request option
val selected_schedule : t -> Wire_work.schedule_row option
val selected_open_ask : t -> Wire_work.ask_row option

val move_selection : delta:int -> t -> t
val set_filter : string -> t -> t
val toggle_verification_view : t -> t
val toggle_expanded : string -> t -> t
val mark_stale_all : t -> t
