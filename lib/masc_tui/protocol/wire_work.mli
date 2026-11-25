(** Work domain wire codecs: Goals (strict [goal_phase], rejecting legacy
    [status]), Tasks ([task_status] + [goal_id] link checks), Verifications &
    Criterion Reviews, Schedules, Approvals/Asks Inbox, and Fleet Candle Ledger. *)

open Masc_tui_core

val planning_path : string
val execution_tasks_path : string
val goals_path : string
val goal_confirmation_path : string
val mcp_path : string
val mcp_protocol_version : string
val task_link_goal_path : task_id:string -> string
val verification_requests_path :
  view:string -> limit:int -> offset:int -> string
val verification_verdict_path : string
val schedules_path : ?cursor:string -> unit -> string
val keeper_asks_path : ?keeper:string -> ?include_resolved:bool -> unit -> string
val keeper_ask_answer_path : string
val keeper_tool_approvals_path : string
val keeper_tool_approval_path : string
val gate_path : string
val gate_resolve_path : string
val gate_mode_path : string
val gate_external_mode_path : string
val gate_rules_delete_path : string
val gate_retry_path : string
val gate_tool_events_path : ?window_minutes:int -> unit -> string
val keeper_tool_approval_mode_path : string
val hitl_late_approval_attempts_path : string
val hitl_late_approval_restore_path : string
val hitl_approval_recover_path : approval_id:string -> string
val candle_ledger_path : ?limit:int -> unit -> string
val harness_health_path : string
val verification_evidence_path :
  task_id:string -> verification_id:string -> string
val verification_summary_path : string
val verification_specs_path : string
val verification_tlc_results_path : string

(** {1 Goals (Strict [goal_phase], Legacy [status] Forbidden)} *)

type goal_resumable =
  | Resume_executing
  | Resume_verifying
  | Resume_awaiting_confirmation

type goal_phase =
  | Executing
  | Verifying
  | Awaiting_confirmation
  | Completed
  | Dropped
  | Paused of goal_resumable
  | Blocked of goal_resumable

type goal_action =
  | Request_complete
  | Drop
  | Reopen
  | Pause
  | Resume
  | Block
  | Unblock

type goal_criterion_verdict =
  | Criterion_pending
  | Criterion_valid
  | Criterion_invalid of string
  | Criterion_unavailable of string

type goal = {
  id : string;
  title : string;
  phase : goal_phase;
  priority : int;
  due_date : string option;
  measure : string;
  procedure : string;
  criterion_revision : string option;
  criterion_verdict : goal_criterion_verdict;
  last_review_note : string option;
  last_review_at : string option;
  created_at : string option;
  updated_at : string option;
  linked_task_count : int Observed.t;
}

type expected_workspace = {
  base_path : string;
  masc_root : string;
}

type goal_confirmation_request = {
  goal_id : string;
  criterion_revision : string;
  request_id : string;
  verification_run_id : string;
  expected_workspace : expected_workspace;
  expected_operator_id : string;
  expected_runtime_instance_id : string;
}

val goal_phase_to_string : goal_phase -> string
val goal_action_to_string : goal_action -> string
val decode_goal_phase : Yojson.Safe.t -> (goal_phase, string) result
(** Decode [phase] + [resume_phase] from a Goal object. Strictly rejects any
    object carrying a legacy [status] field. *)

val decode_goal :
  observed_at:Clock.Mono.t -> Yojson.Safe.t -> (goal, string) result

val encode_goal_transition :
  goal_id:string ->
  action:goal_action ->
  note:string option ->
  expected_workspace:expected_workspace ->
  Yojson.Safe.t
(** Body for [POST /api/v1/tools/masc_goal_transition]. The route refuses a
    transition whose body does not name the workspace the operator saw. *)

val encode_goal_confirmation : goal_confirmation_request -> Yojson.Safe.t
(** Encode strict allowlist request body for [POST /api/v1/goals/confirmation]. *)

type goal_measure_direction =
  | At_least
  | At_most

type goal_measure =
  | Measure_done_when of { condition : string }
  | Measure_count of {
      noun : string;
      total : int;
    }
  | Measure_quantity of {
      unit : string;
      direction : goal_measure_direction;
      target : float;
    }

val parse_goal_measure_input :
  kind:string -> spec:string -> (goal_measure, string) result
(** Parse operator modal fields into a closed {!goal_measure} matching
    [config/tools/masc_goal_upsert.toml] ([done_when], [count], [quantity]). *)

val encode_goal_measure : goal_measure -> Yojson.Safe.t

val encode_goal_upsert :
  ?id:string ->
  title:string ->
  ?measure:goal_measure ->
  procedure:string ->
  ?priority:int ->
  ?due_date:string ->
  ?expected_workspace:expected_workspace ->
  unit ->
  Yojson.Safe.t
(** Arguments object for MCP [masc_goal_upsert]. Strictly omits [status] and
    [phase] ([additional_properties = false]). *)

val encode_mcp_tool_call :
  id:string -> tool_name:string -> arguments:Yojson.Safe.t -> Yojson.Safe.t
(** Stateless MCP 2026-07-28 JSON-RPC 2.0 [tools/call] request envelope for
    [POST /mcp]. *)

val decode_mcp_tool_call_ack : string -> (unit, string) result
(** Validate a [POST /mcp] response (JSON or SSE [data:] frame), returning
    [Error] if JSON-RPC [error], [result.isError = true], or
    [structuredContent.ok = false] is reported. *)

(** {1 Tasks & Goal Link Checks} *)

type task_status =
  | Todo
  | Claimed of { assignee : string; claimed_at : string }
  | InProgress of { assignee : string; started_at : string }
  | AwaitingVerification of {
      assignee : string;
      started_at : string;
      submitted_at : string;
      verification_id : string;
    }
  | Done of {
      assignee : string;
      completed_at : string;
      notes : string option;
    }
  | Cancelled of {
      cancelled_by : string;
      cancelled_at : string;
      reason : string option;
    }

type task_goal_link =
  | Unlinked
  | Linked of string

type task = {
  id : string;
  title : string;
  description : string option;
  priority : int;
  status : task_status;
  goal_link : task_goal_link;
  created_at : string option;
  updated_at : string option;
}

type planning_snapshot = {
  goals : goal list;
  tasks : task list;
}

type task_backlog_counts = {
  todo : int;
  claimed : int;
  in_progress : int;
  awaiting_verification : int;
  done_total : int;
  cancelled : int;
}

val decode_task : Yojson.Safe.t -> (task, string) result

val check_goal_link_assignable : task -> (unit, string) result
(** Per constitution [goal_link]: goalless tasks may be linked once; tasks
    already carrying a [goal_id] are refused with [Already_assigned]. *)

val encode_task_cancel :
  task_id:string ->
  reason:string option ->
  expected_workspace:expected_workspace ->
  Yojson.Safe.t
(** Body for [POST /api/v1/dashboard/tasks/cancel]: [task_id], the trimmed
    [reason] when it is not blank, and the required [expected_workspace]. *)

type task_transition_action =
  | Task_claim
  | Task_start
  | Task_release
  | Task_submit_for_verification

val equal_task_transition_action :
  task_transition_action -> task_transition_action -> bool

val task_transition_action_to_string : task_transition_action -> string
val task_transition_action_of_string : string -> task_transition_action option

val encode_task_create :
  title:string ->
  priority:int ->
  ?description:string ->
  ?goal_id:string ->
  ?expected_workspace:expected_workspace ->
  unit ->
  Yojson.Safe.t
(** Arguments object for MCP [masc_add_task]. *)

val encode_task_transition :
  task_id:string ->
  action:task_transition_action ->
  ?notes:string ->
  ?expected_workspace:expected_workspace ->
  unit ->
  Yojson.Safe.t
(** Arguments object for MCP [masc_transition]. *)

val encode_task_link_goal :
  goal_id:string -> expected_workspace:expected_workspace -> Yojson.Safe.t
(** Strict 2-field allowlist body for [POST /api/v1/tasks/:task_id/link-goal]. *)

val decode_planning_snapshot :
  observed_at:Clock.Mono.t -> Yojson.Safe.t -> (planning_snapshot, string) result

val decode_planning_backlog_counts :
  Yojson.Safe.t -> (task_backlog_counts option, string) result
(** Extract aggregate [task_backlog] counts summary from
    [GET /api/v1/dashboard/planning] (used to populate Pulse completed/active
    counts on servers omitting [counts.tasks_done_24h]). *)

val decode_execution_tasks : Yojson.Safe.t -> (task list, string) result
(** Decode the [tasks] array from [GET /api/v1/dashboard/execution?light=true]. *)

val enrich_planning_with_tasks :
  observed_at:Clock.Mono.t ->
  planning_snapshot ->
  task list ->
  planning_snapshot
(** Attach decoded tasks onto a planning snapshot and populate missing
    [linked_task_count] fields on goals from matching [Linked goal_id] tasks. *)

(** {1 Verifications & Criterion Reviews} *)

type review_observation_state =
  | Review_unobserved
  | Review_running
  | Review_approved
  | Review_rejected
  | Review_unavailable
  | Review_not_reviewed
  | Review_commit_failed
  | Review_execution_pending
  | Review_execution_repair_required
  | Review_failed
  | Review_cancelled
  | Review_superseded

type review_observation = {
  state : review_observation_state;
  detail : string;
  actor : string;
}

type verification_request = {
  request_id : string;
  task_id : string;
  task_title : string;
  submitted_by : string;
  created_at_unix : float option;
  completion_contract : string list;
  required_artifacts : string list;
  submitted_evidence : string list;
  evidence_projection_error : string option;
  review_observation : review_observation option;
}

type operator_verdict =
  | Verdict_approve
  | Verdict_reject of { reason : string }

val decode_verification_request :
  Yojson.Safe.t -> (verification_request, string) result

val decode_verification_snapshot :
  Yojson.Safe.t -> (verification_request list, string) result

val encode_verification_verdict :
  task_id:string ->
  verification_id:string ->
  verdict:operator_verdict ->
  notes:string option ->
  Yojson.Safe.t
(** Encode strict allowlist request body for [POST /api/v1/verification/verdict]. *)

(** {1 Schedules ([GET /api/v1/dashboard/scheduled-automation])} *)

type schedule_status =
  | Sched_scheduled
  | Sched_due
  | Sched_running
  | Sched_succeeded
  | Sched_failed
  | Sched_cancelled
  | Sched_expired

(* The server's wake statuses are running / succeeded / failed
   (Schedule_contract_values.wake_status_to_string). A failed wake carries its
   reason in the wake's [error] field, which may be absent. *)
type wake_disposition =
  | Wake_succeeded
  | Wake_failed of string option
  | Wake_running
  | Wake_never

type schedule_row = {
  schedule_instance_id : string;
  schedule_id : string;
  status : schedule_status;
  source : string;
  due_at_unix : float;
  next_due_at_unix : float option;
  recurrence_kind : string;
  recurrence_summary : string;
  payload_kind : string option;
  payload_support : string;
  payload_target : string option;
  payload_keeper_name : string option;
  payload_summary : string option;
  last_wake_unix : float option;
  last_disposition : wake_disposition;
}

val decode_schedules_snapshot :
  Yojson.Safe.t -> (schedule_row list * string option, string) result
(** Decode [GET /api/v1/dashboard/scheduled-automation] ([requests] array +
    [next_cursor]). *)

type schedule_repeat =
  | Repeat_once
  | Repeat_every of { interval_sec : int }

(** A Keeper wake the Schedule form creates. [first_due_in_sec] is a delay
    from when the server receives the request. *)
type schedule_create_request = {
  keeper_name : string;
  message : string;
  first_due_in_sec : int;
  repeat : schedule_repeat;
}

val encode_schedule_create : schedule_create_request -> Yojson.Safe.t
(** Body for [POST /api/v1/tools/masc_schedule_create]: [keeper_name],
    [message], [due_in_sec] and the recurrence ([one_shot], or [interval] with
    [recurrence_interval_sec]). *)

(** {1 Approvals & Asks Inbox} *)

type ask_mode =
  | Ask_single
  | Ask_multi

type ask_choice = {
  choice_id : string;
  label : string;
  description : string option;
}

type ask_question = {
  question_id : string;
  header : string;
  prompt : string;
  mode : ask_mode;
  allow_free_text : bool;
  free_text_hint : string option;
  choices : ask_choice list;
}

type ask_resolution =
  | Ask_open
  | Ask_answered of { answered_at : float; question_ids : string list }
  | Ask_withdrawn of { reason : string; withdrawn_at : float }

type ask_row = {
  ask_id : string;
  keeper : string;
  asked_at : float;
  context : string option;
  questions : ask_question list;
  resolution : ask_resolution;
}

type ask_response =
  | Ask_chose of string list
  | Ask_wrote of string
  | Ask_skipped

type held_tool_approval = {
  approval_id : string;
  tool_call_id : string;
  keeper : string;
  tool : string;
  args_preview : string;
  question : string;
  because : string option;
  asked_at : float;
  timeout_sec : float;
}

type tool_approval_decision =
  | Tool_approve
  | Tool_deny

type gate_pending = {
  id : string;
  keeper : string;
  tool_name : string;
  input_preview : string option;
  waiting_s : float option;
  phase : string;
}

val decode_asks_snapshot : Yojson.Safe.t -> (ask_row list, string) result
val decode_ask_question : Yojson.Safe.t -> (ask_question, string) result
val decode_ask_resolution : Yojson.Safe.t -> (ask_resolution, string) result
val decode_ask_answers : Yojson.Safe.t -> ((string * ask_response) list, string) result
val encode_ask_response : ask_response -> Yojson.Safe.t
val decode_tool_approvals : Yojson.Safe.t -> (held_tool_approval list, string) result
val decode_gate_pending_list : Yojson.Safe.t -> (gate_pending list, string) result

val encode_ask_answer :
  keeper:string ->
  ask_id:string ->
  ?session_id:string ->
  answers:(string * ask_response) list ->
  unit ->
  Yojson.Safe.t
(** Encode [POST /api/v1/keepers/ask-answer] with server key ["name"],
    ["ask_id"], and tagged ["answers"] items. *)

val encode_tool_approval_decision :
  keeper:string ->
  tool_call_id:string ->
  approval_id:string ->
  decision:tool_approval_decision ->
  ?expected_workspace:expected_workspace ->
  unit ->
  Yojson.Safe.t
(** Encode [POST /api/v1/keepers/tool-approval] with server keys ["name"],
    ["tool_call_id"], ["approval_id"], and ["decision"] (["approve"|"deny"]). *)

type tool_approval_outcome =
  | Tool_approval_settled  (** The waiting call received the decision. *)
  | Tool_approval_remembered
      (** The wait had ended. The decision stands for the identical retried
          call. *)
  | Tool_approval_no_waiting_call
      (** No call was waiting and no matching ask was found, so the decision
          reached nothing. *)

val decode_tool_approval_outcome :
  Yojson.Safe.t -> (tool_approval_outcome, string) result
(** Decode the [{settled, remembered}] answer of
    [POST /api/v1/keepers/tool-approval]. Both true is an error. *)

val encode_gate_resolution :
  id:string -> approved:bool -> reason:string option -> Yojson.Safe.t

(** {1 Fleet Candle Ledger ([/api/v1/candle/ledger])} *)

type candle_ledger_state =
  | Ledger_present
  | Ledger_missing
  | Ledger_unavailable of string

type candle_allocation = {
  keeper : string;
  amount_milli : int;
  weight : int;
}

type candle_event_kind =
  | Candle_paid of {
      goal_id : string;
      total_milli : int;
      allocations : candle_allocation list;
    }
  | Candle_purchased of { keeper : string; item : string; amount_milli : int }
  | Candle_granted of { keeper : string; amount_milli : int; reason : string }
  | Candle_gifted of {
      from_keeper : string;
      to_keeper : string;
      amount_milli : int;
      reason : string;
    }
  | Candle_gifted_item of {
      from_keeper : string;
      to_keeper : string;
      item : string;
    }
  | Candle_equipped of { keeper : string; slot : string; choice : string }
  | Candle_half_life_set of {
      mode : string;
      half_life_hours : int option;
      half_life_sec : float option;
    }
  | Candle_snapshot of {
      goal_id : string;
      title : string;
      linked_task_count : int;
    }
  | Candle_payout_owed of { goal_id : string }
  | Candle_candidates of {
      goal_id : string;
      observation : string;
      candidate_task_count : int;
      candidate_keeper_count : int;
    }
  | Candle_candidates_fenced of {
      goal_id : string;
      observation : string;
      candidate_task_count : int;
      candidate_keeper_count : int;
    }
  | Candle_window_held of { goal_id : string; task_count : int }
  | Candle_window_released of { goal_id : string }
  | Candle_unattributed of {
      goal_id : string;
      reason : string;
      observation : string;
      diagnostic_hint : string option;
    }
  | Candle_payout_failed of { goal_id : string; due_date : string }

type candle_event = {
  seq : int;
  at_unix : float;
  kind : candle_event_kind;
}

type candle_balance_row = {
  keeper : string;
  balance_milli : int;
  decayed_milli : string;
  last_event_unix : float option;
  owned_items : string list;
}

type candle_diagnostics = {
  unattributed_count : int;
  backlog_fenced_count : int;
  zero_linked_tasks_goals : int;
  held_windows_count : int;
}

type candle_ledger = {
  ledger_state : candle_ledger_state;
  total_events : int;
  balance_error : string option;
  policy_configuration : string;
  pricing_mode : string;
  disabled_reason : string option;
  half_life_sec : float option;
  issued_milli : string;
  burned_milli : string;
  circulating_milli : string;
  total_supply_milli : string;
  active_keepers : int;
  diagnostics : candle_diagnostics;
  balances : candle_balance_row list;
  recent_events : candle_event list;
}

val decode_candle_ledger : Yojson.Safe.t -> (candle_ledger, string) result

(** {1 Wave 3: Harness Health & Verification Evidence / Summary / Specs / TLC} *)

type harness_verdict_row = {
  timestamp : float;
  task_id : string;
  task_title : string;
  agent_name : string;
  gate : string;
  verdict : string;
  evaluator_runtime : string;
  fallback_reason : string option;
  notes_hash : string;
}

type harness_calibration = {
  total_verdicts : int;
  approve_count : int;
  reject_count : int;
  labeled_count : int;
  false_positive_count : int;
  false_negative_count : int;
  agreement_rate : float;
  fallback_count : int;
  distinct_runtime_count : int;
  verdicts_with_generator_runtime : int;
  distinct_runtime_rate : float option;
  recent_fallback_reasons : string list;
  unreadable_record_count : int;
}

type harness_health = {
  generated_at : float;
  scope_note : string;
  evaluator_status : string;
  fallback_ratio : float;
  last_signal_at : float option;
  calibration : harness_calibration;
  recent_verdicts : harness_verdict_row list;
  unreadable_verdicts_count : int;
}

val is_valid_notes_hash : string -> bool
(** Strict 64-character lowercase hexadecimal validator matching server
    [POST /api/v1/dashboard/harness-label]. *)

val decode_harness_health : Yojson.Safe.t -> (harness_health, string) result

type verification_evidence_item =
  | Verif_ev_note of string
  | Verif_ev_artifact of {
      reference : string;
      content : string;
      bytes : int;
      truncated : bool;
    }
  | Verif_ev_binary of {
      reference : string;
      bytes : int;
      sha256 : string;
      format : string;
      body : string option;
    }
  | Verif_ev_collab of {
      reference : string;
      content : string;
      sha256 : string;
    }
  | Verif_ev_unreadable of {
      reference : string option;
      code : string;
      detail : string option;
    }

type verification_evidence_bundle = {
  task_id : string;
  verification_id : string;
  producer : string option;
  authority_kind : string;
  authority_actor : string;
  available : bool;
  unavailable_reason : string option;
  items : verification_evidence_item list;
}

type verification_summary = {
  updated_at : string;
  total : int;
  pending : int option;
  approved : int option;
  rejected : int option;
  raw : Yojson.Safe.t;
}

type tla_spec_entry = {
  name : string;
  path : string;
  category : string;
  has_clean_cfg : bool;
  has_buggy_cfg : bool;
  mtime_iso : string;
}

type verification_specs = {
  updated_at : string;
  specs_dir : string option;
  entries : tla_spec_entry list;
}

type tlc_result_entry = {
  spec_name : string;
  cfg_name : string;
  category : string;
  status : string;
  states_explored : int option;
  distinct_states : int option;
  diameter : int option;
  last_run_at : string option;
  violation : string option;
  log_path : string option;
}

type verification_tlc_results = {
  updated_at : string;
  results_dir : string option;
  entries : tlc_result_entry list;
}

val decode_verification_evidence :
  Yojson.Safe.t -> (verification_evidence_bundle, string) result
val decode_verification_summary :
  Yojson.Safe.t -> (verification_summary, string) result
val decode_verification_specs :
  Yojson.Safe.t -> (verification_specs, string) result
val decode_verification_tlc_results :
  Yojson.Safe.t -> (verification_tlc_results, string) result

(** {1 Wave 4 Layer 2: HITL Gate Policy, Rules CRUD, Modes, Retry & Recovery} *)

type gate_mode =
  | Gate_manual
  | Gate_auto_judge
  | Gate_always_allow

val gate_mode_of_string : string -> gate_mode option
val gate_mode_to_string : gate_mode -> string
val equal_gate_mode : gate_mode -> gate_mode -> bool

type gate_mode_status = {
  mode : gate_mode;
  configured : bool;
  state : string;
  read_error : string option;
}

type judge_lane_status =
  | Judge_lane_available of { lane_id : string; slots : string list }
  | Judge_lane_unavailable of { lane_id : string; reason : string }

type hitl_status = {
  gate_mode : gate_mode_status;
  external_gate_mode : gate_mode_status;
  judge_lane : judge_lane_status;
}

type gate_retry_meta = {
  id : string;
  input_hash : string;
  sequence : int;
  exact_attempt : Yojson.Safe.t;
  summary_attempt_disposition : Yojson.Safe.t;
  summary_text : string option;
  summary_judgment : string option;
}

type gate_rule = {
  id : string;
  keeper_name : string;
  tool_name : string;
  request_fingerprint : string;
  created_at : float;
  created_by : string option;
  source_approval_id : string option;
  expires_at : float option;
}

type gate_resolved_row = {
  id : string;
  event : string;
  keeper : string;
  tool : string;
  decision : string;
  decision_kind : string option;
  decision_reason : string option;
  decision_source : string option;
  authorization_source : string option;
  actor : string option;
  ts : float;
}

type gate_snapshot = {
  generated_at : string option;
  pending : gate_pending list;
  retry_meta : gate_retry_meta list;
  rules : gate_rule list;
  rules_error : string option;
  recent_resolved : gate_resolved_row list;
  recent_resolved_error : string option;
  hitl : hitl_status option;
}

val decode_gate_snapshot : Yojson.Safe.t -> (gate_snapshot, string) result

val encode_gate_resolution_with_policy :
  id:string ->
  approved:bool ->
  reason:string option ->
  remember_rule:bool ->
  ?rule_expires_at:float ->
  ?expected_workspace:expected_workspace ->
  unit ->
  Yojson.Safe.t

val encode_gate_mode : mode:gate_mode -> Yojson.Safe.t
val encode_gate_rule_delete : id:string -> Yojson.Safe.t

val encode_gate_retry :
  ?expected_workspace:expected_workspace -> gate_retry_meta -> Yojson.Safe.t

type keeper_tool_approval_mode =
  | Approval_auto
  | Approval_yolo

val keeper_tool_approval_mode_of_string :
  string -> keeper_tool_approval_mode option
val keeper_tool_approval_mode_to_string : keeper_tool_approval_mode -> string
val equal_keeper_tool_approval_mode :
  keeper_tool_approval_mode -> keeper_tool_approval_mode -> bool

type tool_approval_modes_snapshot = {
  overrides : (string * keeper_tool_approval_mode) list;
  default_mode : keeper_tool_approval_mode;
  restore_error : string option;
}

val decode_tool_approval_modes :
  Yojson.Safe.t -> (tool_approval_modes_snapshot, string) result

val encode_tool_approval_mode_set :
  keeper:string -> mode:keeper_tool_approval_mode -> Yojson.Safe.t

type late_approval_attempt = {
  consume_id : string;
  keeper_name : string;
  tool_name : string;
  args_fingerprint : string;
  consumed_at : float;
  outcome : string;
}

val decode_late_approval_attempts :
  Yojson.Safe.t -> (late_approval_attempt list, string) result

val encode_hitl_ack_uncertain :
  keeper_name:string -> consume_id:string -> Yojson.Safe.t

type gate_tool_rejection_row = {
  tool : string;
  reason : string;
  count : int;
}

type gate_queue_latency_summary = {
  depth : int;
  p50_wait_sec : float option;
  p95_wait_sec : float option;
  oldest_pending_sec : float option;
}

type gate_tool_events_snapshot = {
  generated_at : string;
  window_minutes : int;
  tool_rejections : gate_tool_rejection_row list;
  queue_summary : gate_queue_latency_summary option;
  queue_error : string option;
}

val decode_gate_tool_events :
  Yojson.Safe.t -> (gate_tool_events_snapshot, string) result
