(** Goal_store — shared planning goals with a dedicated
    lifecycle phase.

    Persists goals under [<base>/.masc/goals.json] with an
    integer [version] counter and an ISO-8601 [updated_at]
    stamp.  Each goal carries:

    - a {!Goal_phase.t} (canonical lifecycle: [Executing] /
      [Awaiting_verification] / [Awaiting_approval] /
      [Blocked] / [Completed] / [Paused] / [Dropped]),
    - a legacy {!goal_status} kept for backward-compat with
      consumers that have not migrated to phases yet
      (derived from phase on write, inferred on read for
      old rows),
    - an optional {!Goal_verification.goal_verifier_policy}
      that gates entry into [Goal_phase.Completed].

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
    [normalize_goal], [sort_goals], [active_goals], [ensure_dirs],
    [default_state], [clamp_priority]. *)

(** {1 Status variants} *)

type goal_status =
  | Active
  | Paused
  | Done
  | Dropped
  (** Legacy lifecycle status.  Persisted alongside
      {!Goal_phase.t} for backward-compat; derived from the
      phase on write via {!goal_status_of_phase} and
      inferred on read for old rows.  New code paths should
      branch on [.phase] instead of [.status]. *)

val goal_status_to_yojson : goal_status -> Yojson.Safe.t
val goal_status_of_yojson :
  Yojson.Safe.t -> (goal_status, string) result

(** {1 Parsers (string → variant option)} *)

val parse_goal_status : string option -> goal_status option
(** Same shape as {!parse_horizon}. *)

val parse_goal_phase : string option -> Goal_phase.t option
(** Delegates to {!Goal_phase.parse}.  [None] passes
    through. *)

(** {1 Phase ↔ legacy status bridge} *)

val goal_status_of_phase : Goal_phase.t -> goal_status
(** Forward derivation used on write.  Maps every phase to
    its canonical legacy status:
    - [Executing] / [Awaiting_verification] /
      [Awaiting_approval] → [Active]
    - [Paused] → [Paused]
    - [Completed] → [Done]
    - [Blocked] / [Dropped] → [Dropped] *)

val phase_of_goal_status : goal_status -> Goal_phase.t
(** Reverse inference used on read for rows persisted
    before phases existed.  Maps [Active] → [Executing],
    [Paused] → [Paused], [Done] → [Completed], [Dropped] →
    [Dropped]. *)

(** {1 Goal record} *)

type goal = {
  id : string;
  title : string;
  metric : string option;
  target_value : string option;
  due_date : string option;
  priority : int;
  status : goal_status;
  phase : Goal_phase.t;
  verifier_policy : Goal_verification.goal_verifier_policy option;
  require_completion_approval : bool;
  active_verification_request_id : string option;
  parent_goal_id : string option;
  last_review_note : string option;
  last_review_at : string option;
  created_at : string;
  updated_at : string;
}
(** A single goal entry.  [priority] is clamped to [1..5]
    on every write through the internal [normalize_goal]
    pass.  [active_verification_request_id] tracks an open
    {!Goal_verification.goal_verification_request} when the
    phase is [Awaiting_verification]; cleared on every
    phase transition out of the verification path. *)

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
(** Field-wise count of goals per legacy status.  Single
    pass; no allocation beyond the result record. *)

(** {1 Persistence paths} *)

val goals_path : Workspace_utils.config -> string
(** [{!Workspace_utils.masc_dir} / "goals.json"]. *)

(** {1 State I/O} *)

val read_state : Workspace_utils.config -> state
(** Reads {!goals_path}; returns an empty default state when no primary or
    recovery file exists.  Missing, parse, or read failures try
    [goals_path ^ ".last-good"] before falling back to the default state for
    legacy read-only projections.  Goals loaded from disk are passed through
    the internal normaliser ([priority] clamp + phase/status reconciliation).
    Read-modify-write operations use {!read_state_result} and fail closed on an
    unrecoverable corrupt state. *)

val read_state_result : Workspace_utils.config -> (state, string) result
(** Fail-closed state reader for mutating goal-store operations and read-only
    surfaces that must distinguish "no goals" from "goal ledger unreadable". *)

val write_state : Workspace_utils.config -> state -> unit
(** Direct overwrite of {!goals_path} with the supplied state.
    Used by tests that need deterministic initial state without
    the read-modify-write cycle of {!update_state}.

    Does *not* acquire the file lock; callers that need atomicity
    should use {!update_state} instead. *)

val update_state : Workspace_utils.config -> (state -> state) -> state
(** Atomic read-modify-write under the goals file lock.
    [f] receives the current state and returns the next state.
    The file lock protects against concurrent truncation races
    (#17229). Raises [Invalid_argument] when the current goal ledger is
    unreadable without recovery, before calling [f] or writing a new state. *)

val update_state_result :
  Workspace_utils.config -> (state -> (state, string) result) -> (state, string) result
(** Result-returning form of {!update_state}. On [Error _], including an
    unreadable current ledger, no write is committed. *)

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

val update_goal_checked :
  Workspace_utils.config ->
  goal_id:string ->
  (goal -> (goal, string) result) ->
  (goal, string) result
(** Same lock/write contract as {!update_goal}, but [f] can fail after reading
    the current goal and before writing the next state. On [Error _], the state
    file is left untouched and its version is not bumped. *)

type delete_goal_outcome =
  | Deleted
  | Deleted_with_orphaned_links of string

type delete_goal_error =
  | Unknown_goal of string
  | Store_unreadable of string

val delete_goal_error_to_string : delete_goal_error -> string

val delete_goal :
  Workspace_utils.config ->
  goal_id:string ->
  (delete_goal_outcome, delete_goal_error) result
(** Removes the goal whose [.id] matches.

    Returns [Error (Unknown_goal _)] when the id is unknown and no delete was
    committed. Returns [Error (Store_unreadable _)] when the goal ledger cannot
    be read without falling back to an empty default. Goal-task link cleanup is
    best-effort across separate files; a cleanup failure returns
    [Ok (Deleted_with_orphaned_links _)] after the goal delete has already been
    committed. *)

(** {1 List + upsert} *)

val list_goals :
  Workspace_utils.config ->
  ?status:goal_status ->
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
  ?status:goal_status ->
  ?phase:Goal_phase.t ->
  ?parent_goal_id:string ->
  ?verifier_policy:Goal_verification.goal_verifier_policy ->
  ?require_completion_approval:bool ->
  unit ->
  (goal * [ `created | `updated ], string) result
(** Creates a new goal when [id] is omitted (mints
    [goal-<128-bit-random-hex>] internally), updates the
    matched row otherwise.  Returns the resolved goal
    paired with [`created] / [`updated] so callers can
    branch on the outcome.

    Errors:
    - [title] required for new goals (omit / empty string
      on a new goal id).
    - [phase] and legacy [status] disagree (when both are
      supplied and {!goal_status_of_phase} of [phase] does
      not equal [status]). *)
