(** What the Channels pane says about one transport's connection. *)

val badge_word : Masc.Tui_decode.connector_connection -> string
(** The word the connection badge spells, in the case the pane draws it. *)

val runtime_state_to_draw :
  connection:Masc.Tui_decode.connector_connection ->
  string option ->
  string option
(** The gateway or poll state, when it says something the badge does not.
    [None] where the transport reports no state of its own, or reports the
    word the badge already spells -- the Discord row read
    ["Connection ● CONNECTED"] above ["Runtime state connected"], while
    Slack's read ["○ UNAVAILABLE"] above ["disconnected"], which is the
    reading this row exists for. *)
