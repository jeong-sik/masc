(** Goal_store — shared planning goals with a dedicated
    lifecycle phase.

    Persists goals under [<base>/.masc/goals.json] with an
    integer [version] counter and an ISO-8601 [updated_at]
    stamp.  Each goal carries:

    - a {!Goal_phase.t} (canonical lifecycle: [Executing] / [Blocked] /
      [Completed] / [Paused] / [Dropped]) — the only persisted
      lifecycle representation.  The legacy [status] duplicate was
      removed in RFC-0352 slice 1 after a live-store measurement
      found zero phase-less rows; the decoder still accepts and
      ignores an incoming ["status"] field during the transition
      window.

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

(** {1 Parsers (string → variant option)} *)

val parse_goal_phase : string option -> Goal_phase.t option
(** Delegates to {!Goal_phase.parse}.  [None] passes
    through. *)

(** {1 Goal record} *)

type completion_receipt =
  { evaluator_runtime : string
  ; reviewed_at : string
  ; reviewed_goal_updated_at : string
  ; review_prompt_sha256 : string
  ; completion_claim : string
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
  phase : Goal_phase.t;
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
(** Reads {!goals_path}; returns an empty default state on
    missing file or parse failure.  Goals loaded from disk
    are passed through the internal normaliser ([priority]
    clamp + phase/status reconciliation). *)

val write_state : Workspace_utils.config -> state -> unit
(** Direct overwrite of {!goals_path} with the supplied state.
    Used by tests that need deterministic initial state without
    the read-modify-write cycle of {!update_state}.

    Does *not* acquire the file lock; callers that need atomicity
    should use {!update_state} instead. *)

val write_state_result :
  Workspace_utils.config -> state -> (unit, string) result
(** Result-returning variant of {!write_state}. *)

val update_state :
  Workspace_utils.config -> (state -> state) -> (state, string) result
(** Atomic read-modify-write under the goals file lock.
    [f] receives the current state and returns the next state.
    The file lock protects against concurrent truncation races
    (#17229). *)

(** {1 Single-goal operations} *)

val get_goal : Workspace_utils.config -> goal_id:string -> goal option

val update_goal :
  Workspace_utils.config ->
  goal_id:string ->
  (goal -> goal) ->
  (goal, string) result
(** Locks the state file, applies [f] to the matched goal
    (with [updated_at] pre-stamped), normalises the result,
    and writes back.  Errors when the [goal_id] is unknown. *)

type conditional_update_error =
  | Goal_not_found
  | Goal_snapshot_changed
  | Goal_persistence_failed of string

val conditional_update_error_to_string : conditional_update_error -> string

val update_goal_if_unchanged :
  Workspace_utils.config ->
  expected:goal ->
  (goal -> goal) ->
  (goal, conditional_update_error) result
(** Atomically updates one Goal only when its current persisted record exactly
    equals [expected]. The equality is structural over the typed record, not a
    serialized string or selected-field heuristic. *)

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
  ?phase:Goal_phase.t ->
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
