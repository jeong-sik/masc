(** The words a /collab command leaves in the chat pane.

    Pure, so a test can read the exact lines an operator sees for a
    hosted room and a stop — including the one thing a share must never
    hide: which link steers (control) and which only watches (view). *)

val hosted_lines : Masc.Tui_decode.collab_host_session -> string list
(** The share card: a headline, the four links (terminal view/control,
    browser view/control), and a scannable QR of the browser view link.
    A loopback base earns a warning that remote guests need
    [/collab https://host:port] re-run on a public base (the live room
    resumes; only the printed links change). *)

val hosted_view_lines : Masc.Tui_decode.collab_host_session -> string list
(** The view-only card: the view links and their QR, no control link
    anywhere — for pasting where steering must never leak. *)

val stopped_lines : Masc.Tui_decode.collab_stop_report -> string list
(** One line naming the keeper and how many rooms stopped — including
    the nothing-was-sharing case, which is an answer, not an error. *)
