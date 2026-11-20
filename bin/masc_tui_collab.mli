(** Shared-machine observation and invite management, independent of Keeper chat.
    This model never stores bearer tokens; the existing invite card owns them. *)
type t
type read
type mutation
type write_access = Writable | Pending of string | Uncertain of { request_id : string; notice : string } | Read_only of string
type action =
  | Stay
  | Close
  | Watch of Masc.Machine_lane.t
  | Game_menu
  | Refresh
  | Issue of mutation * string * int
  | Revoke of mutation * string
  | Open_link of string
  | Resolve_unknown of string

val create : unit -> t
val owner : t -> unit ref
val write_access : t -> write_access -> t
(** Refresh mutation authority before opening a form or consuming its input.
    Losing it closes issue/revoke forms. An unknown outcome needs explicit
    operator confirmation that the original server request has finished.
    The confirmation retains that request ID; a different unknown request
    withdraws the old confirmation. *)
val loading : t -> t * read
(** Retain the last inventory and selection while its replacement is pending.
    Browsing can move through retained rows; opening a link or starting a revoke
    from a row requires a successfully completed current read. *)
val listed : t -> read -> (Masc.Tui_decode.play_invites, string) result -> t
(** Only the latest read of this view may replace its inventory. Failed reads
    retain the previous inventory for observation, with its failure attached.
    A successful empty inventory clears the retained rows. *)
val kept_back : t -> read -> string -> t
(** The workspace guard stopped the latest read before it left; [notice] is
    the caller's kept-back notice, drawn in place of the inventory. A refusal
    for a superseded read leaves the current observation unchanged. *)
val notice : t -> string -> t
val settled : t -> mutation -> t
(** Release only the pending mutation whose receipt arrived. Notices and
    inventory refreshes cannot settle a mutation. *)
val text_input_active : t -> bool
val progress_status : t -> [ `Idle | `Pending_write | `Write_access_pending of string | `Loading ]
(** Active blocking or refresh state for bottom-sheet progress rendering. *)
val paste : t -> string -> t
(** Append single-line field text without submitting. Browsing and revoke
    confirmation discard pasted text. Validation remains on Enter. *)
val key : t -> string -> t * action
val hints : ?ko:bool -> t -> string
val controller_note : ?ko:bool -> Masc.Tui_decode.play_controller -> string -> string
(** The suffix the invite row named by the string shows when it holds the DOS
    controller. Shared by the Collab list and the chat [/play] list. *)
val controller_summary : ?ko:bool -> Masc.Tui_decode.play_controller -> string list
(** The line the invite list shows about the DOS controller, if any: who
    holds it, that no machine is loaded, or why it could not be asked. *)
val position : t -> Masc_tui_value.Position.t option
(** The selected invite among the invites listed, for the title row; [None]
    with none listed. *)

val lines : ?ko:bool -> height:int -> width:int -> t -> string list
val lines_with_selection : ?ko:bool -> height:int -> width:int -> t -> (bool * string) list
(** The overlay body at [width] cells. Prose wraps at spaces and the three
    machine keys stack when they do not fit one row, so nothing is cut at the
    frame's edge. Each invite takes the rows its text needs; the list shows the
    selected invite and as many of its neighbours as [height] allows. When the
    text is taller than [height], the heading (two explanatory sentences with
    the keys between them) stays whole only while the rows left by the form,
    the messages, the other fixed text and the selected invite hold it, less
    one row for the frame's note. Below that the sentences go together and the
    keys stay, and below that the keys go too. The closing sentence is always
    returned and is not counted, so the frame's cut at the end takes it first.
    When retained invites compete with refresh errors for space, the selected
    invite takes priority over error details. Retained rows carry their last-read
    label even when there is no room for the separate status summary.
    The form, the messages and the selected invite stay while [height] has rows
    for them. The frame says how many rows it cut, but not that the sentences
    or the keys gave way: when what is left fits without a cut, nothing says
    they are missing. Every text is sanitized before it is measured, so every
    row returned is already clean terminal text. *)
