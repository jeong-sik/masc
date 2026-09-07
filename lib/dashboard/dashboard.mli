
(** MASC Dashboard — operator-first status visualization.

    Renders a text dashboard for MASC operators showing agents, tasks,
    messages, keepers, and attention items.

    @since 0.4.0 *)

(** {1 Tunable Parameters} *)

val max_path_length : unit -> int
val max_message_length : unit -> int
val max_pending_tasks : unit -> int
val max_recent_messages : unit -> int
val min_border_length : unit -> int

(** {1 Types} *)

type section = {
  title : string;
  content : string list;
  empty_msg : string;
}

type scope = Tool_schemas_specs_types.dashboard_scope =
  | Dashboard_scope_all
  | Dashboard_scope_current
(** Same vocabulary the descriptor generator emits as the [scope] enum. *)

type workspace_snapshot = Dashboard_labels.workspace_snapshot = {
  workspace_id : string;
  agents : Masc_domain.agent list;
  tasks : Masc_domain.task list;
  messages : Masc_domain.message list;
  locks : int;
}

(** {1 Scope Helpers} *)

val valid_scope_strings : string list

val scope_of_string_opt : string -> scope option
(** Parses what the tool schema advertises. Exposed so a test can check
    the enum and the parser against each other. *)
(** {1 Formatting} *)

val format_section : section -> string
val parse_iso_timestamp : string -> float option
val truncate_path : string -> string
val truncate_message : string -> string

(** {1 Section Builders} *)

val agents_section : float -> Masc_domain.agent list -> section
val tasks_section : Masc_domain.task list -> section
val messages_section : Masc_domain.message list -> section
val keepers_section : float -> section

(** {1 Generation} *)

val generate : ?scope:scope -> Workspace_utils.config -> string
val generate_compact : ?scope:scope -> Workspace_utils.config -> string

val force_link : unit
