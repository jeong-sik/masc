(** Workspace_query -- Task/agent/message query and listing functions.

    Read-only operations on workspace state: raw list retrieval, orphan
    auditing, message collection, agent-session-bound checks, and formatted
    listing.

    Inherits types and helpers from {!Workspace_utils} and {!Workspace_state}. *)

include module type of Workspace_utils
include module type of Workspace_state

(** {1 Task Priority} *)

type update_priority_outcome =
  | Updated of
      { task_id : string
      ; old_priority : int
      ; new_priority : int
      }
  | Not_found of { task_id : string }

type update_priority_error =
  | Not_initialized
  | Backlog_read_error of string
  | Backlog_write_error of string
  | Lock_error of Masc_domain.masc_error
  | Unexpected_error of string

(** Update a task's priority without collapsing storage or lock failures into a
    successful string response. *)
val update_priority :
  config ->
  task_id:string ->
  priority:int ->
  (update_priority_outcome, update_priority_error) result

(** {1 Raw Data Retrieval} *)

(** Return raw task list (used by orchestrator).
    Requires initialization. *)
val get_tasks_raw : config -> Masc_domain.task list

(** Like {!get_tasks_raw} but returns [[]] when not initialized. *)
val get_tasks_safe : config -> Masc_domain.task list

(** Return all agents including inactive (for orchestrator).
    Requires initialization. *)
val get_agents_raw : config -> Masc_domain.agent list

(** Return active agents only.  Returns [[]] when MASC is not
    initialized — safe for dashboard and display contexts. *)
val get_active_agents : config -> Masc_domain.agent list

(** Like {!get_agents_raw} but returns [[]] when not initialized
    instead of raising.  Includes inactive agents.
    Useful for keeper backlog-triage enrollment. *)
val get_all_agents : config -> Masc_domain.agent list

(** Find owned tasks ([Claimed], [InProgress], [AwaitingVerification]) whose
    exact assignee identity is absent from explicit active workspace/session
    membership. [last_seen] is observational only. Returns [(task, assignee)]
    pairs for orphaned tasks. *)
val audit_orphan_tasks : config -> (Masc_domain.task * string) list

val audit_orphan_tasks_in_tasks
  :  config
  -> Masc_domain.task list
  -> (Masc_domain.task * string) list
(** Apply the orphan audit to an already-read backlog task snapshot. This keeps
    callers that project several backlog fields on one authoritative revision
    from triggering a second backlog read. *)

(** RFC-0294 PR-4: typed source of truth for orphan-status classification.
    [Some label] for an orphan-eligible status (Claimed / InProgress /
    AwaitingVerification), [None] otherwise. Exhaustive over [task_status] so a
    new constructor is a compile error here rather than a silent gauge drop. *)
val orphan_status_class_of_status : Masc_domain.task_status -> string option

(** RFC-0294 PR-4: the fixed set of orphan status classes (claimed /
    in_progress / awaiting_verification) — exactly the [Some]-range of
    {!orphan_status_class_of_status}. The orphan gauge reports every class
    so a cleared class resets to 0 instead of going stale. *)
val orphan_status_classes : string list

(** RFC-0294 PR-4: count orphan-audit results per status class over
    {!orphan_status_classes}. Pure (no I/O); the metric emitter is the
    single-owner orchestrator pulse. Always returns one entry per class. *)
val orphan_counts_by_status_class
  :  (Masc_domain.task * string) list
  -> (string * int) list

(** {1 Agent Membership} *)

(** Check if an agent has an active session the current workspace. *)
val is_agent_session_bound : config -> agent_name:string -> bool

(** {1 Messages} *)

(** Return raw messages since [since_seq], up to [limit]. *)
val get_messages_raw :
  config -> since_seq:int -> limit:int -> Masc_domain.message list

(** Return the newest [limit] messages for which [keep] holds, newest first.

    [limit] counts MATCHES, not messages read. A caller that filters after
    calling {!get_messages_raw} cannot say that: the store fills the window with
    every agent's messages and the caller's filter thins it to whatever is left,
    reaching zero once other agents are busier. Each such call site compensated
    with its own multiplier, and every multiplier is wrong at some fleet size. *)
val get_messages_matching :
  config ->
  since_seq:int ->
  limit:int ->
  keep:(Masc_domain.message -> bool) ->
  Masc_domain.message list

(** Return all raw messages after [since_seq], ordered
    from oldest unseen to newest unseen. *)
val get_all_messages_raw :
  config -> since_seq:int -> Masc_domain.message list

(** {1 Formatted Output} *)

(** List tasks with optional filters, returning a formatted string. *)
val list_tasks :
  ?include_done:bool -> ?include_cancelled:bool -> ?status:string ->
  config -> string
(** AwaitingVerification tasks expose request metadata only. Submitted evidence
    is available through the authenticated completion-authority boundary. *)

(** Return recent messages as a formatted string. *)
val get_messages : config -> since_seq:int -> limit:int -> string

(** {1 Filename Validation} *)

(** Check if a filename contains only safe characters
    (alphanumeric, underscore, hyphen, dot). *)
val is_valid_filename : string -> bool

(** {1 Internal Helpers (used by sibling workspace modules)} *)

(** Yield the Eio fiber if running under Eio; no-op otherwise. *)
val safe_yield : unit -> unit

(** [take_first n xs] returns the first [n] elements of [xs]. *)
val take_first : int -> 'a list -> 'a list

(** How far back a message read walks. [Newest_window] stops at [limit] names
    because each one is an answer; [Matching] keeps walking until [limit]
    messages satisfy the predicate. *)
type message_scan =
  | Newest_window
  | Matching of (Masc_domain.message -> bool)

