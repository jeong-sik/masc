(** Goal_store — shared planning goals with a dedicated lifecycle phase.

    Persists goals under [<base>/.masc/goals.json] with an integer [version]
    counter and an ISO-8601 [updated_at] stamp, and attempts to update
    [goals.json.last-good] after every committed write. Each goal carries a
    {!Goal_phase.t} — the only persisted lifecycle representation. The goal
    schema is closed: a row
    carrying any other field fails to decode.

    Reading (RFC-0444). The store is read through one closed sum,
    {!source}. There is no reader that returns a state or a list on its own:
    a store this build cannot read is {!Unavailable}, never an empty state,
    and the only empty state is {!Uninitialized} (neither goals.json nor its
    mirror exists). The mirror is reported inside {!unavailable} as evidence
    of drift and is never served as the current state. {!load_source} only
    inspects and reads: it creates no directory, moves no file and logs nothing.

    Writing. Every read-modify-write holds the goals file lock, calls
    {!load_source} under it, and on {!Unavailable} returns a typed error
    carrying the {!unavailable} value without touching either file. Acquiring
    the lock can itself fail before the source is read. The first write on an
    {!Uninitialized} store creates it.

    Every type is exposed concretely because external callers construct goal
    records by literal, pattern-match on every constructor and read record
    fields directly. *)

type goal_id_error = Goal_id_blank | Goal_id_padded of string

val goal_id_error_to_string : goal_id_error -> string
val validate_goal_id : string -> (unit, goal_id_error) result
(** Require a nonblank Goal ID without leading or trailing space, tab, line
    feed, carriage return or form feed (the [String.trim] characters). This
    validates the supplied identifier only; it does not prove Goal membership
    or that historical stored IDs follow this rule. *)

(** {1 Goal record} *)

type goal = Goal_document.goal = {
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

type notification_delivery =
  | Awaiting_recipients
  | Pending_recipients of Keeper_id.Keeper_name.t list

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

module Goal_id_map : Map.S with type key = string

type prepared_state = {
  state : state;
  goals_by_id : goal Goal_id_map.t;
  sorted_goals : goal list;
}
(** Immutable pre-indexed view of {!state}: [goals_by_id] provides O(log G)
    lookup by [goal_id], and [sorted_goals] provides goals sorted by
    [(priority asc, updated_at desc)]. Cached content-addressed by
    {!load_source}, {!list_goals_result}, and {!load_goals_by_id_result};
    callers must treat the returned record and its nested lists as immutable. *)

val prepare_state : state -> prepared_state
(** Build a {!prepared_state} from [state] in O(G log G). *)

(** {1 Rollup} *)

type rollup = {
  active_count : int;
  verifying_count : int;
  awaiting_confirmation_count : int;
  done_count : int;
  dropped_count : int;
  paused_count : int;
  blocked_count : int;
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

val goal_events_path : Workspace_utils.config -> string
(** [{!Workspace_utils.masc_dir} / "goal_events.jsonl"]: the Goal audit event
    ledger that {!append_audit_event} and {!flush_pending_events} append to. *)

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

and nonregular_kind = Goal_store_unavailable.nonregular_kind =
  | Nonregular_directory
  | Nonregular_character_device
  | Nonregular_block_device
  | Nonregular_symbolic_link
  | Nonregular_fifo
  | Nonregular_socket

and reason = Goal_store_unavailable.reason =
  | Missing_after_init  (** goals.json is absent and the mirror is not confirmed absent. *)
  | Unreadable of Unix.error
      (** An inspection, open or read error. Following [ENOENT], an observed
          non-directory ancestor can also be reported as [ENOTDIR]. *)
  | Nonregular of nonregular_kind
      (** The primary path or opened descriptor had this nonregular kind. *)
  | Not_json of string  (** The bytes are not JSON. *)
  | Schema_rejected of { field : string; detail : string }
      (** JSON, but this build's decoder refused member [field]. [field] is
          usually the JSON member name ([criterion_revision], [phase], …).
          ["$"] can name the document root, while ["goals"] can name a Goal
          row. A member name that is not plain printable ASCII is reported at
          its containing location. *)

and mirror_status = Goal_store_unavailable.mirror_status =
  | Mirror_absent
  | Mirror_unreadable of Unix.error
      (** The same error and ancestor-inspection meanings as {!Unreadable}. *)
  | Mirror_nonregular of nonregular_kind
      (** The mirror path or opened descriptor had this nonregular kind. *)
  | Mirror_decodes of { goal_count : int; updated_at : string }
      (** Evidence of how far the primary drifted from the last commit. *)
  | Mirror_rejected of reason

and reset_step = Goal_store_unavailable.reset_step =
  | Repair_field of string  (** Inspect and repair this named location. *)
  | Reset_goal_store  (** Move the store aside (RFC-0444 §2.6, PR-7). *)
  | Restore_permission  (** [Unreadable EACCES]. *)
  | Inspect_path  (** Inspect file paths, links and mounts before recovery. *)

val load_source : Workspace_utils.config -> source
(** Inspects and reads goals.json, and the mirror only when the primary did
    not decode. Regular files reached through symlinks remain readable;
    observed nonregular files are unavailable. Creates no directory, moves
    no file, writes nothing, logs nothing. Path inspection and open are not
    atomic against an unrelated process replacing the path: opening a FIFO
    that replaced a regular path can wake a writer, and a replacement device
    can run its open operation. *)

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
  Workspace_utils.config -> ?phase:Goal_phase.t -> ?kind:Goal_phase.Kind.t -> unit ->
  (goal list, unavailable) result
(** {!load_source} filtered by [phase] and sorted by
    [(priority asc, updated_at desc)]. {!Uninitialized} is [Ok []] — the one
    legitimate empty list; {!Unavailable} is the typed error. *)

val load_goals_by_id_result :
  Workspace_utils.config -> (goal Goal_id_map.t, unavailable) result
(** Immutable [goal_id -> goal] map from {!load_source}. {!Uninitialized} is
    [Ok Goal_id_map.empty]; {!Unavailable} is the typed error. *)

(** {1 State I/O} *)

val notify_projection_change : Workspace_utils.config -> unit
(** Tell the installed projection observer
    ([Workspace_hooks.on_goal_projection_mutation_fn]) that what the Goal
    readers project for [config]'s workspace changed. A store whose records
    those readers join calls it after its own write. The observer's failure
    is logged, a cancellation is re-raised. *)

val write_state : Workspace_utils.config -> state -> unit
(** Direct overwrite of {!goals_path}, then a best-effort mirror update with
    the supplied state. An observed mirror symlink is left in place and a
    mirror failure is logged after the primary write succeeds. Used by tests that need a
    deterministic initial state. Takes no lock and does not read first;
    production writers go through the locked read-modify-write operations below. *)

val notify_projection_change : Workspace_utils.config -> unit
(** Run the Goal projection mutation hook without advancing the projection
    generation: for a change the planning projection shows and the Goals tree
    does not, such as the verifier's in-process observations. *)

val projection_source_changed : Workspace_utils.config -> unit
(** A Goal projection source kept outside the Goal file (the audit event
    ledger, the verification ledger, the measurement store) was published. Advance the projection
    generation and run the Goal projection mutation hook. Callers run it under
    their store lock after the primary write; the hook must not yield or
    reenter the Goal store. *)

val write_state_result :
  Workspace_utils.config -> state -> (unit, string) result
(** Result-returning variant of {!write_state}. Publish through the shared local
    JSON writer for every workspace backend, matching {!load_source}'s local
    primary authority. Advance projection generation after primary publication;
    a subsequent recovery mirror failure is logged and still [Ok ()]. An
    observed mirror link is left in place and treated as a mirror failure.
    This check does not lock out unrelated processes replacing paths. *)

type write_error =
  | Store_unavailable of unavailable
      (** {!load_source} was {!Unavailable}; no file was touched. *)
  | Goal_not_found of string  (** The id; also on an {!Uninitialized} store. *)
  | Goal_identity_ambiguous of string
      (** The decoded primary has more than one row with this Goal ID. *)
  | Rejected of string
      (** The callback's own error, or a callback result the store refused
          (identity replaced, title or RFC-0387 B1 condition missing). *)
  | Persist_failed of string  (** The write after a successful read failed. *)

val write_error_to_string : write_error -> string

(** {1 Single-goal operations} *)

val transact_goal :
  ?effects:(goal -> 'a -> transition_effects) ->
  Workspace_utils.config -> goal_id:string ->
  (goal -> (goal * 'a, string) result) -> (goal * 'a, write_error) result
(** Holds the Goal file lock across an authoritative primary read, callback and
    conditional write. Refuses a duplicated decoded Goal ID before the callback
    or effects run. A callback may acquire the verification ledger lock;
    it must not acquire this Goal lock again. A callback [Error] is returned
    as {!Rejected} and an unchanged goal writes nothing. [effects] is a pure
    projection of a changed committed goal/result. Its audit and notification
    intents are written atomically with that goal; no delivery runs under the
    lock. Unchanged/replayed transactions do not create new intents. *)

type delete_goal_outcome =
  | Deleted
  | Deleted_with_orphaned_links of string

type delete_goal_error =
  | Unknown_goal of string
  | Ambiguous_goal of string  (** The decoded primary has multiple rows for the id. *)
  | Store_unavailable of unavailable
  | Persistence_failed of string  (** The write after a successful read failed. *)

val delete_goal_error_to_string : delete_goal_error -> string

val delete_goal :
  Workspace_utils.config ->
  goal_id:string ->
  (delete_goal_outcome, delete_goal_error) result
(** Removes the uniquely matched goal. A duplicate decoded id is refused before
    any Goal write or Goal-task link cleanup.

    Returns [Error (Unknown_goal _)] when the id is unknown (including on an
    {!Uninitialized} store) and no delete was committed. Goal-task link
    cleanup is best-effort across separate files; a cleanup failure returns
    [Ok (Deleted_with_orphaned_links _)] after the goal delete has already
    been committed. *)

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

type assignable_goal_error =
  | Assignment_source_unavailable of unavailable
  | Assignment_lock_failed of Masc_domain.masc_error
  | Assignment_goal_missing of string
  | Assignment_goal_ambiguous of string
  | Assignment_goal_closed of { goal_id : string; phase : Goal_phase.t }

val with_assignable_goals :
  Workspace_utils.config -> goal_ids:string list -> (unit -> 'a) ->
  ('a, assignable_goal_error) result
(** Validate every canonical Goal ID against one primary-store observation
    and hold the Goal lock through the callback. Each ID must name exactly one
    row with no whitespace alias, and the Goal must not be completed or
    dropped. The first invalid ID is reported in input order. An empty list
    performs no Goal store access. The callback follows the Goal -> backlog ->
    links lock order and must not re-enter the Goal store. *)

val with_assignable_goal :
  Workspace_utils.config -> goal_id:string -> (unit -> 'a) ->
  ('a, assignable_goal_error) result
(** Single-Goal form of {!with_assignable_goals}. *)

val validate_state_json : Yojson.Safe.t -> (unit, string) result
(** Pure current-schema validation for the setup CLI. Does not read, repair
    or write a store; the rejection is rendered as one sentence naming the
    member. *)

(** Persist audit attribution atomically with the upsert. Events retain the
    store revision assigned under the Goal lock and survive every mutation. *)
type upsert_precondition = Unconditional | Require_absent

val upsert_goal_with_events :
  Workspace_utils.config -> actor:string -> ?id:string -> ?title:string ->
  ?metric:string -> ?target_value:string -> ?due_date:string -> ?priority:int ->
  ?precondition:upsert_precondition ->
  unit -> (goal * [ `created | `updated of goal ] * pending_event list, write_error) result
(** Creates a new goal when [id] is omitted (mints [goal-<ms>-<4 hex digits>]
    internally), updates the matched row otherwise. Returns the resolved goal
    paired with [`created], or [`updated previous] carrying the row as it was
    before this write, read inside the write lock. The caller records what
    changed. Multiple decoded rows for the resolved ID return
    {!Goal_identity_ambiguous} without a write. Every accepted upsert commits a new store version, including an
    update whose editable fields are unchanged. An edit to the title,
    [metric] or [target_value] moves a
    [Verifying], [Awaiting_confirmation] or [Completed] goal back to
    [Executing]. Suspended Goals stay suspended with restore target [Executing].
    An edit to [due_date] or [priority] moves no phase.

    {!Rejected}:
    - [title] required for new goals (omit / blank on a new goal id).
    - [due_date] that {!Goal_due.read} cannot read, on a create and on an
      update alike. Nothing is written. [None] leaves the stored due date as
      it is; there is no way to clear one here.
    - RFC-0387 B1: [metric] and [target_value] are both required (non-blank)
      whenever the upsert creates a new row — including an explicit
      previously-unknown [id]. The create/update split is decided inside the
      write lock on the freshly decoded state, so an undecodable store is
      {!Store_unavailable}, never this one.
    - An actual change to an existing row's [title], [metric] or
      [target_value] requires all three effective fields to be non-blank.
      Omitted fields retain their stored values. The merged criterion is
      checked inside the write lock before minting its revision or writing
      events. This is an input invariant, not semantic feasibility admission.
      Unchanged historical criteria do not prevent priority/due-date updates
      or lifecycle operations; a criterion edit must repair the whole
      effective condition. Rejection preserves the store, proof identity and
      pending events.
    - Creation input check: a new row needs a
      non-blank [title] on every create path, including an explicit unknown
      [id]. The due date is a UTC calendar day and falls due at 23:59:59
      UTC, independent of the operator's time zone.

    [Require_absent] refuses an existing raw ID or its trimmed alias under the
    Goal write lock. It never updates an existing Goal. *)

(** Idempotently publish pending audit rows and acknowledge them under the Goal
    lock. A failed append keeps all intents; an acknowledgement failure retains
    already-published IDs for a safe retry. When rows are appended, the Goal
    projection mutation hook runs under the lock; it must not yield or reenter
    the Goal store. *)
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
  recipient:Keeper_id.Keeper_name.t -> (unit, write_error) result
val acknowledge_notification : Workspace_utils.config -> pending_notification -> (unit, write_error) result
(** Acknowledge only after the exact workspace row is committed and every
    snapshotted recipient was durably accepted. Refuses uninitialised/nonempty
    recipient obligations. External delivery always happens outside the Goal lock. *)

val goals_filename : string
(** The goal ledger below [<base>/.masc]. *)

val goal_events_filename : string
(** The goal event log below [<base>/.masc]. *)
