(** What the Channels pane says about one transport's connection. *)

val badge_word : Masc.Tui_decode.connector_connection -> string
(** The word the connection badge spells, in the case the pane draws it. *)

val runtime_state_to_draw : Masc.Tui_decode.connector -> string option
(** The gateway state, or the poll state for a transport without a gateway,
    when it says something the badge does not. [None] where the transport
    reports no state of its own, or where the state is a word the badge
    already spells -- a connected gateway under [CONNECTED] or under
    [CONNECTED / UNAVAILABLE], a disconnected one under [DISCONNECTED]. A
    badge that spells two words spells both of them, so the compound badge
    answers for a connected gateway the same way the plain one does. The
    Discord row read ["Connection ● CONNECTED"] above ["Runtime state
    connected"], while Slack's read ["○ UNAVAILABLE"] above ["disconnected"],
    which is the reading this row exists for. *)
