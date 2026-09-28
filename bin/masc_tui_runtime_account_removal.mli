(** The Config > runtime.toml screen that removes a Claude Code, Codex or
    Antigravity account and what routes to it.

    It lists the accounts the file declares and shows, for the chosen one,
    what {!Runtime_account_removal.remove} would delete and edit, or why it
    refuses. Enter asks the caller to remove the account from the file as the
    server holds it at that moment. When that file would change differently
    from what the screen showed -- a keeper assigned to the account meanwhile
    -- nothing is saved: the screen shows the new changes and waits for Enter
    again. The login store the account signed in at is named, not removed. *)

type t

val open_on : string -> (t, string) result
(** [Error] says why there is nothing to remove: the text does not parse, or
    it declares no Claude Code, Codex or Antigravity provider. *)

val chosen : t -> string
(** The id of the account on screen. *)

type outcome =
  | Choosing of t
  | Cancelled
  | Submitted of t
      (** Enter on a removal the file allows: remove it with {!remove_on}. *)

val key : t -> string -> outcome
(** One decoded key. [left] and [right] choose another account. Enter
    submits when the removal on screen is allowed and does nothing when it is
    refused. Esc abandons. Every other key is ignored: nothing is typed
    here. *)

val remove_on : t -> string -> (Runtime_account_removal.removed, t) result
(** Removes the chosen account from [current], the file as it is now. A
    refusal comes back as the screen with the reason on it; a removal whose
    changes differ from those on screen comes back as the screen showing the
    new ones. *)

val refused : t -> string -> t
(** The screen kept open with a reason the server gave for not saving. *)

val rows : width:int -> t -> string list
(** The screen as rows of a pane [width] cells wide. Names read from the file
    are drawn on one line, and the heading, the changes and a refusal wrap to
    [width]. The keys it reads are the footer's, not a row. *)
