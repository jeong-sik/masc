(** MASC Dashboard — operator-first status visualization.

    Renders a text dashboard for MASC operators showing agents, tasks,
    messages, keepers, worktrees, and attention items.

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

type scope =
  | All
  | Current

type room_snapshot = Dashboard_labels.room_snapshot = {
  room_id : string;
  is_current : bool;
  agents : Types.agent list;
  tasks : Types.task list;
  messages : Types.message list;
  locks : int;
}

(** {1 Scope Helpers} *)

val scope_to_string : scope -> string
val valid_scope_strings : string list
val scope_of_string_opt : string -> scope option

(** {1 Formatting} *)

val format_section : section -> string
val parse_iso_timestamp : string -> float option
val format_elapsed : float -> string -> string -> string
val truncate_path : string -> string
val truncate_message : string -> string

(** {1 Section Builders} *)

val agents_section : float -> Types.agent list -> section
val tasks_section : Types.task list -> section
val messages_section : Types.message list -> section
val keepers_section : float -> section
val worktrees_section : Coord_utils.config -> section
val parse_worktrees : Yojson.Safe.t -> (string * string) list

(** {1 Generation} *)

val generate : ?scope:scope -> Coord_utils.config -> string
val generate_compact : ?scope:scope -> Coord_utils.config -> string
