(** What the Channels pane says about one transport's connection. *)

val badge_word : Masc.Tui_decode.connector_connection -> string
(** The word the connection badge spells, in the case the pane draws it. *)

val runtime_state_to_draw : Masc.Tui_decode.connector -> string option
(** The gateway state, or the poll state for a transport without a gateway,
    when it says something the badge does not. [None] where the transport
    reports no state of its own, or where the state is the one the badge
    already names -- a connected gateway under [CONNECTED], a disconnected
    one under [DISCONNECTED]. The Discord row read ["Connection ● CONNECTED"]
    above ["Runtime state connected"], while Slack's read ["○ UNAVAILABLE"]
    above ["disconnected"], which is the reading this row exists for. *)
