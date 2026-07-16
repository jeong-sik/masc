(** Workspace_query -- Task/agent/message query and listing functions.

    Read-only operations on workspace state: raw list retrieval, orphan
    auditing, message collection, agent-session-bound checks, and formatted
    listing.

    Inherits types and helpers from {!Workspace_utils} and {!Workspace_state}. *)

include module type of Workspace_utils
include module type of Workspace_state

(** {1 Task Priority} *)

(** Update a task's priority.  Returns a human-readable status string. *)
val update_priority : config -> task_id:string -> priority:int -> string

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

(** Find claimed/in_progress tasks whose assignees are absent from explicit
    active workspace/session membership. [last_seen] is observational only.
    Returns [(task, assignee)] pairs for orphaned tasks. *)
val audit_orphan_tasks : config -> (Masc_domain.task * string) list

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

(** Return all raw messages after [since_seq], ordered
    from oldest unseen to newest unseen. *)
val get_all_messages_raw :
  config -> since_seq:int -> Masc_domain.message list

(** {1 Formatted Output} *)

(** List tasks with optional filters, returning a formatted string. *)
val list_tasks :
  ?include_done:bool -> ?include_cancelled:bool -> ?status:string ->
  config -> string

(** Return recent messages as a formatted string. *)
val get_messages : config -> since_seq:int -> limit:int -> string

(** {1 Filename Validation} *)

(** Check if a filename contains only safe characters
    (alphanumeric, underscore, hyphen, dot). *)
val is_valid_filename : string -> bool

(** Extract a sequence number from a message filename like
    ["000001885_unknown_broadcast.json"]. Returns 0 on parse failure. *)
val extract_seq_from_filename : string -> int

(** {1 Internal Helpers (used by sibling workspace modules)} *)

(** Yield the Eio fiber if running under Eio; no-op otherwise. *)
val safe_yield : unit -> unit

(** [take_first n xs] returns the first [n] elements of [xs]. *)
val take_first : int -> 'a list -> 'a list

(** Read most-recent messages from filesystem or PG backend without
    parsing the entire history directory. *)
val collect_recent_messages :
  config -> msgs_path:string -> since_seq:int -> limit:int ->
  warn_label:string -> Masc_domain.message list
