
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

type view =
  | Full
  | Compact
(** Which rendering a [masc_dashboard] call asks for. *)

type workspace_snapshot = Dashboard_labels.workspace_snapshot = {
  workspace_id : string;
  agents : Masc_domain.agent list;
  tasks : Masc_domain.task list;
  messages : Masc_domain.message list;
  locks : int;
}

(** {1 Tool Arguments} *)

val compact_argument : string
(** The one argument the tool takes: a boolean, [true] for {!Compact}. *)

val default_view : view
(** The view a call gets when it leaves {!compact_argument} out. *)

val compact_of_view : view -> bool
(** The {!compact_argument} value that asks for a view. *)

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

val cap_task_rows : ?max_rows:int -> pending_more:int -> string list -> string list
(** The Tasks rows with those past [max_rows] collapsed into one line that
    counts them, together with the [pending_more] pending tasks the pending cap
    already left out. Without [max_rows] only the pending line is added. *)

val render_within : limit:int -> row_count:int -> (int option -> string) -> string
(** [render_within ~limit ~row_count render]: [render None] when it is at most
    [limit] bytes, else [render (Some n)] for the largest [n < row_count] that
    fits, else [render (Some 0)]. *)

val generate : ?max_bytes:int -> Workspace_utils.config -> string
(** With [max_bytes] the Tasks section gives up rows from its tail until the
    text is at most that many bytes; the other sections stay whole. *)

val generate_compact : Workspace_utils.config -> string

val force_link : unit
