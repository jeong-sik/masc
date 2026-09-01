(** Goal_store — shared planning goals with a dedicated
    lifecycle phase.

    Persists goals under [<base>/.masc/goals.json] with an
    integer [version] counter and an ISO-8601 [updated_at]
    stamp.  Each goal carries:

    - a {!Goal_phase.t} (canonical lifecycle: [Executing] / [Blocked] /
      [Completed] / [Paused] / [Dropped]) — the only persisted
      lifecycle representation.  The goal schema is closed: a row
      carrying any other field fails to decode, and {!read_state} then
      applies the corrupt-store policy (recovery mirror if usable,
      otherwise an empty state plus a warning).

    Every type is exposed concretely because external
    callers ([test/test_dashboard_goals],
    [test_keeper_task_dispatch],
    [lib/workspace_goals],
    [lib/server/server_dashboard_http]) construct goal records
    by literal, pattern-match on every variant constructor,
    and access record fields ([.id], [.phase],
    [.updated_at], [.title], …) directly.

    Internal helpers that stay private: [now_ms],
    [gen_goal_id], [find_goal], [replace_goal], [update_state],
    [sort_goals], [ensure_dirs],
    [default_state], [clamp_priority]. *)

(** {1 Parsers (string → variant option)} *)

val parse_goal_phase : string option -> Goal_phase.t option
(** Delegates to {!Goal_phase.parse}.  [None] passes
    through. *)

(** {1 Goal record} *)

type goal = {
  id : string;
  title : string;
  metric : string option;
  target_value : string option;
  due_date : string option;
  priority : int;
  phase : Goal_phase.t;
  last_review_note : string option;
  last_review_at : string option;
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
  verifying_count : int;
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
    [Verifying] → verifying, [Completed] → done,
    [Dropped] → dropped).  Single
    pass; no allocation beyond the result record. *)

(** {1 Persistence paths} *)

val goals_path : Workspace_utils.config -> string
(** [{!Workspace_utils.masc_dir} / "goals.json"]. *)

(** {1 State I/O} *)

val read_state : Workspace_utils.config -> state
(** Reads {!goals_path}; returns an empty default state on
    missing file or parse failure.  Goals loaded from disk
    are passed through the internal normaliser ([priority]
    clamp). *)

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

type conditional_update =
  | Goal_updated of goal
  | Goal_phase_mismatch of Goal_phase.t

val update_goal_if_phase :
  Workspace_utils.config ->
  goal_id:string ->
  expected_phase:Goal_phase.t ->
  (goal -> goal) ->
  (conditional_update, string) result
(** Atomic compare-and-update under the goals file lock. A phase mismatch is
    returned without writing, so recovery cannot overwrite a concurrent
    lifecycle transition. *)

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
  ?phase:Goal_phase.t ->
  unit ->
  (goal * [ `created | `updated ], string) result
(** Creates a new goal when [id] is omitted (mints
    [goal-<ms>-<4 hex digits>] internally), updates the
    matched row otherwise.  Returns the resolved goal
    paired with [`created] / [`updated] so callers can
    branch on the outcome.

    Errors:
    - [title] required for new goals (omit / empty string
      on a new goal id).
    - RFC-0387 B1: [metric] and [target_value] are both required
      (non-blank) whenever the upsert creates a new row —
      including an explicit previously-unknown [id].  The
      create/update split is decided inside the write lock on
      the freshly decoded state, so an undecodable store hits
      the fail-closed persistence error, never this one.
      Updating an existing row is not gated. *)
