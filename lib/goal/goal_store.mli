(** Goal_store — shared planning goals with a dedicated lifecycle phase.

    Persists goals under [<base>/.masc/goals.json] with an integer [version]
    counter and an ISO-8601 [updated_at] stamp, and mirrors every committed
    write to [goals.json.last-good]. Each goal carries a {!Goal_phase.t} — the
    only persisted lifecycle representation. The goal schema is closed: a row
    carrying any other field fails to decode.

    Reading (RFC-0444). The store is read through one closed sum,
    {!source}. There is no reader that returns a state or a list on its own:
    a store this build cannot read is {!Unavailable}, never an empty state,
    and the only empty state is {!Uninitialized} (neither goals.json nor its
    mirror exists). The mirror is reported inside {!unavailable} as evidence
    of drift and is never served as the current state. {!load_source} only
    opens and reads: it creates no directory, moves no file and logs nothing.

    Writing. Every read-modify-write holds the goals file lock, calls
    {!load_source} under it, and on {!Unavailable} returns a typed error
    carrying the {!unavailable} value without touching either file. The
    first write on an {!Uninitialized} store creates it.

    Every type is exposed concretely because external callers construct goal
    records by literal, pattern-match on every constructor and read record
    fields directly. *)

(** {1 Parsers (string → variant option)} *)

val parse_goal_phase : string option -> Goal_phase.t option
(** Delegates to {!Goal_phase.parse}.  [None] passes through. *)

(** {1 Goal record} *)

type goal = {
  id : string;
  criterion_revision : string;
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
(** A workspace-shared goal. Creation and transition actors are event
    provenance. [priority] is clamped to [1..5] on every write. *)

type criterion = Criterion of {
  revision : string;
  title : string;
  metric : string option;
  target_value : string option;
}

val criterion_of_goal : goal -> criterion
val criterion_equal : criterion -> criterion -> bool
val criterion_to_yojson : criterion -> Yojson.Safe.t
val criterion_of_yojson : Yojson.Safe.t -> (criterion, string) result

val goal_to_yojson : goal -> Yojson.Safe.t

(** {1 State} *)

type event_kind = Created | Updated | Phase | Edited

type pending_event = {
  event_id : string;
  goal_id : string;
  store_revision : int;
  recorded_at : string;
  kind : event_kind;
  payload : Yojson.Safe.t;
}

val event_kind_to_string : event_kind -> string
val pending_event_to_yojson : pending_event -> Yojson.Safe.t

type notification_delivery = Awaiting_recipients | Pending_recipients of string list

type pending_notification = {
  notification_id : string;
  goal_id : string;
  sender : string;
  content : string;
  delivery : notification_delivery;
}
(** Immutable message identity and content. The first successful recipient
    snapshot is persisted; acknowledgements remove only those exact recipients. *)

type transition_effects = {
  events : (event_kind * Yojson.Safe.t) list;
  notifications : (string * string) list; (** sender, literal content *)
}

type state = {
  version : int;
  updated_at : string;
  goals : goal list;
  pending_events : pending_event list;
  pending_notifications : pending_notification list;
}
(** On-disk shape persisted to {!goals_path}. [version] increments on every
    write so concurrent readers detect drift. *)

(** {1 Rollup} *)

type rollup = {
  active_count : int;
  verifying_count : int;
  awaiting_confirmation_count : int;
  done_count : int;
  dropped_count : int;
}
(** Aggregate counts produced by {!compute_rollup}. Consumed by
    [workspace_goals.ml] and the dashboard HTTP endpoint. *)

val rollup_to_yojson : rollup -> Yojson.Safe.t

val compute_rollup : goal list -> rollup
(** Field-wise count of goals per {!Goal_phase.t}. Single pass. *)

(** {1 Persistence paths} *)

val goals_path : Workspace_utils.config -> string
(** [{!Workspace_utils.masc_dir} / "goals.json"]. The mirror is this path
    with [".last-good"] appended. *)

(** {1 Source (RFC-0444 §2.1)} *)

type source =
  | Uninitialized
      (** Neither goals.json nor its mirror exists. The only empty state. *)
  | Available of state
      (** goals.json decoded. The mirror was not opened. *)
  | Unavailable of unavailable

(** Re-exported from {!Goal_store_unavailable} (masc_types) with a manifest,
    so the task-creation contract below this library can carry the same
    value while every constructor stays addressable as [Goal_store.X]. *)
and unavailable = Goal_store_unavailable.t =
  { file : string  (** {!goals_path}. *)
  ; reason : reason
  ; mirror : mirror_status
      (** The mirror at the same moment. Shown, never served. *)
  ; reset_step : reset_step
  }

and reason = Goal_store_unavailable.reason =
  | Missing_after_init  (** goals.json is absent while the mirror exists. *)
  | Unreadable of Unix.error
      (** open/read failed; EACCES, EISDIR and EIO each survive. *)
  | Not_json of string  (** The bytes are not JSON. *)
  | Schema_rejected of { field : string; detail : string }
      (** JSON, but this build's decoder refused member [field]. [field] is
          the JSON member name ([criterion_revision], [phase], …); ["$"]
          names the document root when the whole document is not an
          object. *)

and mirror_status = Goal_store_unavailable.mirror_status =
  | Mirror_absent
  | Mirror_unreadable of Unix.error
  | Mirror_decodes of { goal_count : int; updated_at : string }
      (** Evidence of how far the primary drifted from the last commit. *)
  | Mirror_rejected of reason

and reset_step = Goal_store_unavailable.reset_step =
  | Repair_field of string  (** Fill or fix this member and it reads again. *)
  | Reset_goal_store  (** Move the store aside (RFC-0444 §2.6, PR-7). *)
  | Restore_permission  (** [Unreadable EACCES]. *)

val load_source : Workspace_utils.config -> source
(** Opens and reads goals.json, and the mirror only when the primary did not
    decode. Creates no directory, moves no file, writes nothing, logs
    nothing. Two calls on the same bytes return the same value. *)

type lookup =
  | Goal_found of goal
  | Goal_absent  (** The store read ({!Available} or {!Uninitialized}) and holds no such id. *)
  | Store_unavailable of unavailable

val find_goal : Workspace_utils.config -> goal_id:string -> lookup

val unavailable_to_string : unavailable -> string
(** {!Goal_store_unavailable.to_string}: one line naming the reason
    constructor, the field when there is one, the file, the mirror status and
    the reset step. For surfaces whose terminus is a string (the verifier's
    WARN line, a test's failure message). Render
    at the very end; never branch on the output. The typed tool/HTTP envelope
    is {!Goal_unavailable_envelope}. *)

val list_goals_result :
  Workspace_utils.config -> ?phase:Goal_phase.t -> unit ->
  (goal list, unavailable) result
(** {!load_source} filtered by [phase] and sorted by
    [(priority asc, updated_at desc)]. {!Uninitialized} is [Ok []] — the one
    legitimate empty list; {!Unavailable} is the typed error. *)

(** {1 State I/O} *)

val write_state : Workspace_utils.config -> state -> unit
(** Direct overwrite of {!goals_path} and its mirror with the supplied state.
    Used by tests that need a deterministic initial state. Takes no lock and
    does not read first; production writers go through the locked
    read-modify-write operations below. *)

val write_state_result :
  Workspace_utils.config -> state -> (unit, string) result
(** Result-returning variant of {!write_state}. A mirror write failure after
    the primary committed is logged and still [Ok ()]. *)

type write_error =
  | Store_unavailable of unavailable
      (** {!load_source} was {!Unavailable}; no file was touched. *)
  | Goal_not_found of string  (** The id; also on an {!Uninitialized} store. *)
  | Rejected of string
      (** The callback's own error, or a callback result the store refused
          (identity replaced, title or RFC-0387 B1 condition missing). *)
  | Persist_failed of string  (** The write after a successful read failed. *)

val write_error_to_string : write_error -> string

val update_state :
  Workspace_utils.config -> (state -> state) -> (state, write_error) result
(** Atomic read-modify-write under the goals file lock. [f] receives the
    current state ({!Uninitialized} reads as an empty first state) and
    returns the next state. When [f] returns the state it was given
    (physically the same value) nothing is written, so a refused first write
    leaves an {!Uninitialized} store without a file. Never {!Goal_not_found}
    or {!Rejected}. *)

(** {1 Single-goal operations} *)

val transact_goal :
  ?effects:(goal -> 'a -> transition_effects) ->
  Workspace_utils.config -> goal_id:string ->
  (goal -> (goal * 'a, string) result) -> (goal * 'a, write_error) result
(** Holds the Goal file lock across an authoritative primary read, callback and
    conditional write. A callback may acquire the verification ledger lock;
    it must not acquire this Goal lock again. A callback [Error] is returned
    as {!Rejected} and an unchanged goal writes nothing. [effects] is a pure
    projection of a changed committed goal/result. Its audit and notification
    intents are written atomically with that goal; no delivery runs under the
    lock. Unchanged/replayed transactions do not create new intents. *)

type conditional_update =
  | Goal_updated of goal
  | Goal_phase_mismatch of Goal_phase.t

val update_goal_if_phase :
  Workspace_utils.config ->
  goal_id:string ->
  expected_phase:Goal_phase.t ->
  (goal -> goal) ->
  (conditional_update, write_error) result
(** Atomic compare-and-update under the goals file lock. A phase mismatch is
    returned without writing, so recovery cannot overwrite a concurrent
    lifecycle transition. Never {!Rejected}. *)

type delete_goal_outcome =
  | Deleted
  | Deleted_with_orphaned_links of string

type delete_goal_error =
  | Unknown_goal of string
  | Store_unavailable of unavailable
  | Persistence_failed of string  (** The write after a successful read failed. *)

val delete_goal_error_to_string : delete_goal_error -> string

val delete_goal :
  Workspace_utils.config ->
  goal_id:string ->
  (delete_goal_outcome, delete_goal_error) result
(** Removes the goal whose [.id] matches.

    Returns [Error (Unknown_goal _)] when the id is unknown (including on an
    {!Uninitialized} store) and no delete was committed. Goal-task link
    cleanup is best-effort across separate files; a cleanup failure returns
    [Ok (Deleted_with_orphaned_links _)] after the goal delete has already
    been committed. *)

(** {1 Upsert} *)

val upsert_goal_with_revision :
  Workspace_utils.config ->
  ?id:string ->
  ?title:string ->
  ?metric:string ->
  ?target_value:string ->
  ?due_date:string ->
  ?priority:int ->
  unit ->
  (goal * [ `created | `updated of goal ] * int, write_error) result
(** The upsert outcome with the exact committed store version from the same
    locked write. Snapshot event readers use this witness to order commits
    independently of event append order. It is never a later store read. *)

val upsert_goal :
  Workspace_utils.config ->
  ?id:string ->
  ?title:string ->
  ?metric:string ->
  ?target_value:string ->
  ?due_date:string ->
  ?priority:int ->
  unit ->
  (goal * [ `created | `updated of goal ], write_error) result
(** Creates a new goal when [id] is omitted (mints [goal-<ms>-<4 hex digits>]
    internally), updates the matched row otherwise. Returns the resolved goal
    paired with [`created], or [`updated previous] carrying the row as it was
    before this write, read inside the write lock. The caller records what
    changed. An edit to the title, [metric] or [target_value] moves a
    [Verifying], [Awaiting_confirmation] or [Completed] goal back to
    [Executing]. An edit to [due_date] or [priority] moves no phase.

    {!Rejected}:
    - [title] required for new goals (omit / empty string on a new goal id).
    - [due_date] that {!Goal_due.read} cannot read, on a create and on an
      update alike. Nothing is written. [None] leaves the stored due date as
      it is; there is no way to clear one here.
    - RFC-0387 B1: [metric] and [target_value] are both required (non-blank)
      whenever the upsert creates a new row — including an explicit
      previously-unknown [id]. The create/update split is decided inside the
      write lock on the freshly decoded state, so an undecodable store is
      {!Store_unavailable}, never this one. Updating an existing row is not
      gated. *)

(** Run a dependent mutation while all referenced Goals exist in the primary
    store. Lock order: Goal, backlog, goal-task links. The callback must not
    acquire the Goal lock again. An empty list performs no Goal store access. *)
type goal_reference_error =
  | Goal_source_unavailable of unavailable
  | Goal_lock_failed of Masc_domain.masc_error
      (** The goals file lock could not be taken; the store was not read. *)
  | Goal_missing of string
      (** The first id absent from the store (every id, on {!Uninitialized}). *)

val with_existing_goals :
  Workspace_utils.config -> goal_ids:string list -> (unit -> 'a) ->
  ('a, goal_reference_error) result

val validate_state_json : Yojson.Safe.t -> (unit, string) result
(** Pure current-schema validation for the setup CLI. Does not read, repair
    or write a store; the rejection is rendered as one sentence naming the
    member. *)

(** Persist audit attribution atomically with the upsert. Events retain the
    store revision assigned under the Goal lock and survive every mutation. *)
val upsert_goal_with_events :
  Workspace_utils.config -> actor:string -> ?id:string -> ?title:string ->
  ?metric:string -> ?target_value:string -> ?due_date:string -> ?priority:int ->
  unit -> (goal * [ `created | `updated of goal ] * pending_event list, write_error) result

(** Idempotently publish pending audit rows and acknowledge them under the Goal
    lock. A failed append keeps all intents; an acknowledgement failure retains
    already-published IDs for a safe retry. No external callback is invoked. *)
val flush_pending_events : Workspace_utils.config -> (unit, string) result

(** Append to the shared Goal audit ledger with the same cross-process durable
    lock as outbox delivery. Does not acquire the Goal lock and may be called
    from an existing Goal transaction. *)
val append_audit_event : Workspace_utils.config -> Yojson.Safe.t -> (unit, string) result

(** Publish existing outbox intents before appending a later ordinary event,
    under the Goal lock. Do not call from an existing Goal transaction; use
    [append_audit_event_after_pending_locked] there to avoid acquiring the Goal lock again. *)
val append_audit_event_after_pending :
  Workspace_utils.config -> Yojson.Safe.t -> (unit, string) result

(** Requires the caller to hold the Goal lock. Flush older intents before this event. *)
val append_audit_event_after_pending_locked : Workspace_utils.config -> Yojson.Safe.t -> (unit, string) result

(** Read only authoritative pending notifications, independently of current Goal
    phase or existence. An unavailable store is an error, never an empty queue. *)
val pending_notifications : Workspace_utils.config -> (pending_notification list, write_error) result

(** These operations re-read under the Goal lock and require the same immutable
    id/goal/sender/content. An absent intent is already acknowledged. The first
    snapshot wins; concurrent later snapshots cannot replace its audience. *)
val snapshot_notification_recipients : Workspace_utils.config -> pending_notification ->
  recipients:string list -> (pending_notification option, write_error) result
val acknowledge_notification_recipient : Workspace_utils.config -> pending_notification ->
  recipient:string -> (unit, write_error) result
val acknowledge_notification : Workspace_utils.config -> pending_notification -> (unit, write_error) result
(** Acknowledge only after the exact workspace row is committed and every
    snapshotted recipient was durably accepted. Refuses uninitialised/nonempty
    recipient obligations. External delivery always happens outside the Goal lock. *)
