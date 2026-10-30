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
val listed : t -> read -> (Masc.Tui_decode.play_invites, string) result -> t
(** Only the latest read of this view may replace its inventory. *)
val notice : t -> string -> t
val settled : t -> mutation -> t
(** Release only the pending mutation whose receipt arrived. Notices and
    inventory refreshes cannot settle a mutation. *)
val text_input_active : t -> bool
val paste : t -> string -> t
(** Append single-line field text without submitting. Browsing and revoke
    confirmation discard pasted text. Validation remains on Enter. *)
val key : t -> string -> t * action
val hints : t -> string
val controller_note : Masc.Tui_decode.play_controller -> string -> string
(** The suffix the invite row named by the string shows when it holds the DOS
    controller. Shared by the Collab list and the chat [/play] list. *)
val controller_summary : Masc.Tui_decode.play_controller -> string list
(** The line the invite list shows about the DOS controller, if any: who
    holds it, that no machine is loaded, or why it could not be asked. *)
val lines : height:int -> t -> string list
