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

type verification_read_failure = {
  reason : string;
  coverage : Wire_work.verification_coverage option;
}

type task_status_filter =
  | Status_all
  | Status_active
  | Status_awaiting_verification
  | Status_todo
  | Status_unlinked
  | Status_done
(** Tasks status filter chip on [2 Work > Tasks]. *)

type goal_phase_filter =
  | Goal_filter_all
  | Goal_filter_active
  | Goal_filter_verifying
  | Goal_filter_held
  | Goal_filter_closed
(** Goals phase filter chip on [2 Work > Goals]. *)

type goal_sort_mode =
  | Goal_sort_default
  | Goal_sort_phase
  | Goal_sort_progress
  | Goal_sort_recent
(** Goals sort order on [2 Work > Goals]. *)

type verification_dive_tab =
  | Verif_tab_evidence
  | Verif_tab_summary
  | Verif_tab_specs
  | Verif_tab_tlc

type inbox_subview =
  | Inbox_queue
  | Inbox_rules
  | Inbox_history

type t = {
  active_tab : Nav.work_tab;
  inbox_subview : inbox_subview;
  planning : Wire_work.planning_snapshot Observed.t;
  planning_goals : Wire_work.goal list Observed.t;
  backlog_counts : Wire_work.task_backlog_counts option;
  verifications : Wire_work.verification_snapshot Observed.t;
  verification_failure : verification_read_failure option;
  harness_health : Wire_work.harness_health Observed.t;
  harness_read : unit Observed.t;
  harness_selected_index : int option;
  harness_scroll_offset : int;
  verification_evidence :
    (string * Wire_work.verification_evidence_bundle) Observed.t;
  verification_evidence_auth_denied : bool;
  verification_summary : Wire_work.verification_summary Observed.t;
  verification_specs : Wire_work.verification_specs Observed.t;
  verification_tlc_results : Wire_work.verification_tlc_results Observed.t;
  verification_dive_tab : verification_dive_tab;
  schedules : (Wire_work.schedule_row list * string option) Observed.t;
  asks : Wire_work.ask_row list Observed.t;
  tool_approvals : Wire_work.held_tool_approval list Observed.t;
  gate_pending : Wire_work.gate_pending list Observed.t;
  gate_snapshot : Wire_work.gate_snapshot Observed.t;
  tool_approval_modes : Wire_work.tool_approval_modes_snapshot Observed.t;
  tool_approval_modes_absent : bool;
  late_approval_attempts : Wire_work.late_approval_attempt list Observed.t;
  late_approval_absent : bool;
  late_approval_auth_denied : bool;
  recent_decisions_24h : decision_audit_entry list;
  candle_ledger : Wire_work.candle_ledger Observed.t;
  candle_fallback_404 : bool;
  selected_index : int;
  scroll_offset : int;
  rule_selected_index : int;
  rule_scroll_offset : int;
  history_selected_index : int;
  history_scroll_offset : int;
  verif_selected_index : int;
  verif_scroll_offset : int;
  detail_scroll_offset : int;
  ledger_scroll_offset : int;
  goal_dive_task_index : int;
  goal_dive_task_scroll : int;
  goal_dive_verif_index : int;
  goal_dive_verif_scroll : int;
  task_dive_desc_scroll : int;
  task_dive_verif_scroll : int;
  pulse_goal_index : int;
  schedules_scroll_offset : int;
  filter_query : string;
  goal_phase_filter : goal_phase_filter;
  goal_sort_mode : goal_sort_mode;
  task_status_filter : task_status_filter;
  verification_view : [ `Pending | `All ];
  verification_generation : int;
  expanded_ids : String_set.t;
}

val empty : t

val set_tab : Nav.work_tab -> t -> t
val cycle_tab : Keymap.cycle_dir -> t -> t

val apply_planning :
  observed_at:Clock.Mono.t -> Wire_work.planning_snapshot -> t -> t

val start_planning_tasks : now:Clock.Mono.t -> t -> t

val apply_planning_tasks :
  observed_at:Clock.Mono.t -> Wire_work.planning_snapshot -> t -> t
(** Apply a Tasks receipt after an independent Goals receipt. *)

val apply_backlog_counts : Wire_work.task_backlog_counts -> t -> t
val apply_verifications :
  ?coverage:Wire_work.verification_coverage ->
  observed_at:Clock.Mono.t -> Wire_work.verification_request list -> t -> t
val invalidate_verifications : t -> t
val fail_verifications :
  ?coverage:Wire_work.verification_coverage ->
  now:Clock.Mono.t -> reason:string -> retryable:bool -> t -> t
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
  summary:Wire_fleet.candle_observation option ->
  balances:(string * int) list ->
  t ->
  t
(** Synthesize a fallback {!Wire_work.candle_ledger} from
    [/api/v1/gate/keepers] / [/api/v1/dashboard/execution] when
    [/api/v1/candle/ledger] returns HTTP 404 on older servers. Only
    [Candle_ready] yields a ledger: [Candle_off] is [Absent],
    [Candle_disabled] is [Failed] with its reason, and no summary is
    [Unreported]. *)

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

val goals_read : t -> Wire_work.goal list Observed.t
val goals : t -> Wire_work.goal list
val filtered_goals : t -> Wire_work.goal list
val tasks : t -> Wire_work.task list
val filtered_tasks : t -> Wire_work.task list
(** Tasks in [task_status_filter] whose title or id contains [filter_query]. *)
val verifications_list : t -> Wire_work.verification_request list
val verification_read_allows_verdict : t -> (unit, Say.t) result
(** The current awaiting join must confirm the request from the primary backlog. *)
val verification_read_notices : t -> Say.t list
val verification_notice_rows : max_rows:int -> t -> int
val filtered_verifications : t -> Wire_work.verification_request list
val schedules_list : t -> Wire_work.schedule_row list
val filtered_schedules : t -> Wire_work.schedule_row list
val filtered_candle_balances : t -> Wire_work.candle_balance_row list
val pulse_active_goals : t -> Wire_work.goal list
val selected_pulse_goal : t -> Wire_work.goal option
val move_pulse_goal : ?viewport_rows:int -> delta:int -> t -> t
val asks_list : t -> Wire_work.ask_row list
val open_asks : t -> Wire_work.ask_row list
val tool_approvals_list : t -> Wire_work.held_tool_approval list
val gate_pending_list : t -> Wire_work.gate_pending list

val unlinked_task_count : t -> int
val awaiting_confirmation_goals : t -> Wire_work.goal list

val apply_planning_goals :
  observed_at:Clock.Mono.t -> Wire_work.goal list -> t -> t

val selected_goal : t -> Wire_work.goal option
val selected_task : t -> Wire_work.task option
val selected_verification : t -> Wire_work.verification_request option
val selected_schedule : t -> Wire_work.schedule_row option
val selected_open_ask : t -> Wire_work.ask_row option

val move_selection :
  ?pane_index:int ->
  ?has_linked_card:bool ->
  ?viewport_rows:int ->
  ?max_detail_scroll:int ->
  delta:int ->
  t ->
  t
val reset_detail_scroll : t -> t
val set_filter : string -> t -> t
val equal_task_status_filter : task_status_filter -> task_status_filter -> bool
val all_task_status_filters : task_status_filter list
(** Chip order on the Tasks tab. *)

val set_task_status_filter : task_status_filter -> t -> t
val cycle_task_status_filter : t -> t
(** Next chip in {!all_task_status_filters} order, wrapping to [Status_all]. *)

val equal_goal_phase_filter : goal_phase_filter -> goal_phase_filter -> bool
val all_goal_phase_filters : goal_phase_filter list
val set_goal_phase_filter : goal_phase_filter -> t -> t
val cycle_goal_phase_filter : t -> t

val equal_goal_sort_mode : goal_sort_mode -> goal_sort_mode -> bool
val set_goal_sort_mode : goal_sort_mode -> t -> t
val cycle_goal_sort_mode : t -> t

val goal_linked_tasks : goal_id:string -> t -> Wire_work.task list
val linked_task_completion : t -> Wire_work.task list -> (int * int) option
(** Completed and total counts among the currently observed linked rows.
    The Execution snapshot includes only a bounded history of terminal tasks. *)

val goal_linked_verifications :
  goal_id:string -> t -> Wire_work.verification_request list
val selected_goal_dive_task : goal_id:string -> t -> Wire_work.task option
val selected_goal_dive_verification :
  goal_id:string -> t -> Wire_work.verification_request option
val reset_goal_dive_state : t -> t
val select_goal_by_id : goal_id:string -> t -> (t, [ `Not_listed ]) result
(** Select a goal on the Pipeline tab, clearing the text and phase filters only
    as far as needed to list it. [Error `Not_listed] when no filter setting
    lists the goal (for example before planning data loads); the caller must
    not act as if it were selected. *)

val select_task_by_id : task_id:string -> t -> (t, [ `Not_listed ]) result
(** As {!select_goal_by_id}, for a task on the Tasks tab. *)
val move_goal_dive_task :
  goal_id:string -> ?viewport_rows:int -> delta:int -> t -> t
val move_goal_dive_verif :
  goal_id:string -> ?viewport_rows:int -> delta:int -> t -> t

val verification_for_task :
  task_id:string -> t -> Wire_work.verification_request option
val reset_task_dive_scroll : t -> t
val scroll_task_dive_desc : max_scroll:int -> delta:int -> t -> t
val scroll_task_dive_verif : max_scroll:int -> delta:int -> t -> t

val harness_verdicts_list : t -> Wire_work.harness_verdict_row list

val toggle_verification_view : t -> t
val toggle_expanded : string -> t -> t
val mark_stale_all : t -> t

val equal_verification_dive_tab :
  verification_dive_tab -> verification_dive_tab -> bool
val cycle_verification_dive_tab : t -> t
val set_verification_dive_tab : verification_dive_tab -> t -> t
val apply_harness_health :
  observed_at:Clock.Mono.t -> Wire_work.harness_health -> t -> t
val start_harness_read : since_ns:Clock.Mono.t -> t -> t
val fail_harness_read : at:Clock.Mono.t -> reason:string -> retryable:bool -> t -> t
val detach_harness : t -> t
val filtered_harness_verdicts : t -> Wire_work.harness_verdict_row list
val selected_harness_verdict : t -> Wire_work.harness_verdict_row option
val apply_verification_evidence :
  observed_at:Clock.Mono.t ->
  verification_id:string ->
  Wire_work.verification_evidence_bundle ->
  t ->
  t
val mark_verification_evidence_denied :
  at:Clock.Mono.t -> reason:string -> t -> t
val verification_evidence_for :
  verification_id:string -> t -> Wire_work.verification_evidence_bundle option
val apply_verification_summary :
  observed_at:Clock.Mono.t -> Wire_work.verification_summary -> t -> t
val apply_verification_specs :
  observed_at:Clock.Mono.t -> Wire_work.verification_specs -> t -> t
val apply_verification_tlc_results :
  observed_at:Clock.Mono.t -> Wire_work.verification_tlc_results -> t -> t

val equal_inbox_subview : inbox_subview -> inbox_subview -> bool
val inbox_subview_rects : Rect.t -> Rect.t * Rect.t

type inbox_source = Inbox_approvals | Inbox_asks | Inbox_gate | Inbox_goals

val inbox_queue_reads : t -> (inbox_source * unit Observed.t) list
val inbox_queue_rects : Rect.t -> t -> Rect.t * Rect.t
(** The Queue/Rules/History tab bar and the content viewport beneath it. *)

val set_inbox_subview : inbox_subview -> t -> t
val cycle_inbox_subview : t -> t

val apply_gate_snapshot :
  observed_at:Clock.Mono.t -> Wire_work.gate_snapshot -> t -> t
val apply_tool_approval_modes :
  observed_at:Clock.Mono.t -> Wire_work.tool_approval_modes_snapshot -> t -> t
val apply_late_approval_attempts :
  observed_at:Clock.Mono.t -> Wire_work.late_approval_attempt list -> t -> t

val gate_rules_list : t -> Wire_work.gate_rule list
val filtered_gate_rules : t -> Wire_work.gate_rule list
val selected_gate_rule : t -> Wire_work.gate_rule option
val gate_resolved_list : t -> Wire_work.gate_resolved_row list
val filtered_gate_resolved : t -> Wire_work.gate_resolved_row list
val late_approval_attempts_list : t -> Wire_work.late_approval_attempt list
val retry_meta_for_id : id:string -> t -> Wire_work.gate_retry_meta option
val hitl_status : t -> Wire_work.hitl_status option
val tool_approval_mode_for :
  keeper:string -> t -> Wire_work.keeper_tool_approval_mode
