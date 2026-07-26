(** Goal_store — shared planning goals with a dedicated
    lifecycle phase.

    Persists goals under [<base>/.masc/goals.json] with an
    integer [version] counter and an ISO-8601 [updated_at]
    stamp.  Each goal carries:

    - an abstract {!Phase.t}; [Completed] is observable through {!Phase.view}
      but its stored constructor is owned only by this module.

    Every type is exposed concretely because external
    callers ([test/test_dashboard_goals],
    [test_keeper_task_dispatch],
    [lib/workspace_goals],
    [lib/server/server_dashboard_http]) construct goal records
    by literal, pattern-match on every variant constructor,
    and access record fields ([.id], [.phase],
    [.updated_at], [.title], …) directly.

    RFC-0294 removed the workspace-goal [horizon] and its dead
    refresh/snapshot scheduler ([refresh_mode], [snapshot_mode],
    [snapshot], [refresh_result], [refresh], [parse_refresh_mode],
    [parse_snapshot_mode], [snapshot_mode_of_refresh_mode],
    [should_refresh_goal], [reprioritize], [has_scheduler_state],
    [scheduler_state_path], [snapshots_dir], [parse_yyyy_mm_dd],
    [days_until]).

    Internal helpers that stay private: [normalize_lower], [now_ms],
    [gen_goal_id], [find_goal], [replace_goal], [update_state],
    [sort_goals], [active_goals], [ensure_dirs],
    [default_state], [clamp_priority]. *)

(** {1 Lifecycle} *)

module Phase : sig
  type t

  type view =
    | Executing
    | Blocked
    | Paused
    | Completed
    | Dropped

  type nonterminal =
    | N_executing
    | N_blocked
    | N_paused
    | N_dropped

  val view : t -> view
  val to_string : t -> string
  val view_to_string : view -> string
  val view_of_string : string -> view option
  val parse_view : string -> view option
  val view_to_yojson : view -> Yojson.Safe.t
  val view_of_yojson : Yojson.Safe.t -> (view, string) result
  val all_views : view list
  val nonterminal_to_view : nonterminal -> view
  val executing : t
  val blocked : t
  val paused : t
  val dropped : t
  val is_executing : t -> bool
  val is_blocked : t -> bool
  val is_paused : t -> bool
  val is_completed : t -> bool
  val is_dropped : t -> bool
  val admits_self_directed_progress : t -> bool

  type action =
    | Request_complete
    | Pause
    | Resume
    | Block
    | Unblock
    | Drop
    | Reopen

  val action_to_string : action -> string
  val action_of_string : string -> action option
  val parse_action : string -> action option
  val all_actions : action list

  type transition_outcome =
    | Move_to of nonterminal
    | Complete

  val decide_transition :
    phase:t -> action:action -> (transition_outcome, string) result
end

(** {1 Parsers (string -> observation option)} *)

val parse_goal_phase : string option -> Phase.view option
(** Delegates to {!Phase.parse_view}.  [None] passes
    through. *)

(** {1 Goal record} *)

type completion_receipt = private
  { workspace_identity : string
  ; expected_state_version : int
  ; operation_id : string
  ; completion_digest : string
  ; review_evidence_sha256 : string
  ; evaluator_runtime : string
  ; reviewed_at : string
  ; reviewed_goal_updated_at : string
  ; review_prompt_sha256 : string
  ; completion_claim : string
  ; requesting_agent : string
  ; linked_task_ids : string list
  }
(** Durable proof that the configured semantic reviewer approved the exact Goal
    snapshot committed as [Completed]. Runtime identity is a provider-neutral
    route id; no provider or model name is persisted here. *)

val completion_receipt_to_yojson : completion_receipt -> Yojson.Safe.t

type completion_review_failure =
  | Rejected
  | Unavailable
(** Typed reason why the most recent completion attempt remained nonterminal.
    The detailed durable explanation remains in [last_review_note]. *)

type goal = {
  id : string;
  title : string;
  metric : string option;
  target_value : string option;
  due_date : string option;
  priority : int;
  phase : Phase.t;
  parent_goal_id : string option;
  last_review_note : string option;
  last_review_at : string option;
  completion_review_failure : completion_review_failure option;
  completion_receipt : completion_receipt option;
  created_at : string;
  updated_at : string;
}
(** A single goal entry. [priority] is clamped to [1..5] on every
    write. *)

val goal_to_yojson : goal -> Yojson.Safe.t

(** {1 State} *)

type state = {
  version : int;
  updated_at : string;
  goals : goal list;
}
(** On-disk shape persisted to {!goals_path}.  [version]
    increments on every write so concurrent readers detect
    drift. *)

(** {1 Rollup} *)

type rollup = {
  active_count : int;
  paused_count : int;
  done_count : int;
  dropped_count : int;
}
(** Aggregate counts produced by {!compute_rollup}.
    Consumed by [workspace_goals.ml] and the dashboard HTTP
    endpoint to render the goal-tree summary. *)

val rollup_to_yojson : rollup -> Yojson.Safe.t

val compute_rollup : goal list -> rollup
(** Field-wise count of goals per lifecycle bucket
    ([Executing] → active, [Paused]/[Blocked] → paused,
    [Completed] → done, [Dropped] → dropped).  Single
    pass; no allocation beyond the result record. *)

(** {1 Persistence paths} *)

val goals_path : Workspace_utils.config -> string
(** [{!Workspace_utils.masc_dir} / "goals.json"]. *)

(** {1 State I/O} *)

val read_state : Workspace_utils.config -> state
(** Reads the current schema. A missing file starts a fresh state; malformed or
    obsolete state raises {!Current_state_invalid} and requires an explicit
    pre-1.0 runtime reset rather than compatibility interpretation. *)

(** {1 Single-goal operations} *)

val get_goal : Workspace_utils.config -> goal_id:string -> goal option

val get_goal_with_version :
  Workspace_utils.config -> goal_id:string -> (goal * int) option
(** Returns the Goal and the exact enclosing store version from one read. *)

type conditional_update_error =
  | Goal_not_found
  | Goal_snapshot_changed
  | Goal_approval_invalid
  | Goal_persistence_failed of string

val conditional_update_error_to_string : conditional_update_error -> string

val set_nonterminal_phase_if_unchanged :
  Workspace_utils.config ->
  expected:goal ->
  phase:Phase.nonterminal ->
  review_note:string option ->
  (goal, conditional_update_error) result
(** Atomically writes a nonterminal lifecycle phase only when the current
    persisted record exactly equals [expected]. *)

val record_completion_review_failure_if_unchanged :
  Workspace_utils.config ->
  expected:goal ->
  failure:completion_review_failure ->
  review_note:string ->
  reviewed_at:string ->
  (goal, conditional_update_error) result
(** Persists a failed completion review without exposing a generic goal-record
    mutation callback. *)

val complete_goal :
  Workspace_utils.config ->
  expected:goal ->
  expected_state_version:int ->
  operation_id:string ->
  approval:Goal_completion_reviewer.approval ->
  read_current_linked_tasks:
    (unit -> (Yojson.Safe.t * string list, string) result) ->
  (goal, conditional_update_error) result
(** Consumes an exact semantic-review approval and persists [Completed] in one
    lock/CAS transaction. This is the only completion mutation authority. *)

type delete_goal_outcome =
  | Deleted
  | Deleted_with_orphaned_links of string

type delete_goal_error =
  | Unknown_goal of string
  | Persistence_failed of string

val delete_goal_error_to_string : delete_goal_error -> string

val delete_goal :
  Workspace_utils.config ->
  goal_id:string ->
  (delete_goal_outcome, delete_goal_error) result
(** Removes the goal whose [.id] matches.

    Returns [Error (Unknown_goal _)] when the id is unknown and no delete was
    committed. Goal-task link cleanup is best-effort across separate files; a
    cleanup failure returns [Ok (Deleted_with_orphaned_links _)] after the goal
    delete has already been committed. *)

(** {1 List + upsert} *)

val list_goals :
  Workspace_utils.config ->
  ?phase:Goal_phase.view ->
  unit ->
  goal list
(** Reads the state, applies optional filters, then sorts
    by [(priority, updated_at desc)]. *)

val upsert_goal :
  Workspace_utils.config ->
  ?id:string ->
  ?title:string ->
  ?metric:string ->
  ?target_value:string ->
  ?due_date:string ->
  ?priority:int ->
  ?parent_goal_id:string ->
  unit ->
  (goal * [ `created | `updated ], string) result
(** Creates a new goal when [id] is omitted (mints
    [goal-<ms>-<4 hex digits>] internally), updates the
    matched row otherwise.  Returns the resolved goal
    paired with [`created] / [`updated] so callers can
    branch on the outcome.

    New Goals always start [Executing]. Lifecycle changes are deliberately
    absent from this API and must go through the transition boundary.

    Errors when [title] is omitted or empty for a new Goal, or when a caller
    tries to mutate a completed Goal before reopening it. *)
exception Current_state_invalid of string
(** Raised when a present primary/recovery file is not the exact current
    schema. Invalid state is never projected as an empty Goal set. *)

val canonical_workspace_identity :
  Workspace_utils.config -> (string, string) result
(** Stable hash of the canonical cluster-aware workspace root. *)

module For_testing : sig
  val write_state : Workspace_utils.config -> state -> unit
  val write_state_result :
    Workspace_utils.config -> state -> (unit, string) result
end
