(** What the Channels pane says about one transport's connection. *)

val badge_word : Masc.Tui_decode.connector_connection -> string
(** The word the connection badge spells, in the case the pane draws it. *)

val badge_words : string list
(** Every word [badge_word] spells, one per connection. *)

val badge_column_cells : int
(** How wide the column that draws a badge word has to be for every word in
    [badge_words] to be drawn whole. A narrower column cuts the longest word,
    and [CONNECTED / UNAVAILABLE] cut short reads as a different state rather
    than as a cut row. *)

val name_cells_preferred : int
(** The cells the list row gives the transport's name when the frame has room
    for every column. *)

val list_row_name_cells : inner:int -> fixed_cells:int -> tail_cells:int -> int
(** The cells the list row gives the transport's name inside a frame of
    [inner] cells, once [fixed_cells] of padding and a [tail_cells] count
    clause are spoken for. The badge column is never the one that gives way:
    a cut name still names the transport, a cut state word names another
    state. Never below a floor, and never above {!name_cells_preferred}, so a
    wide frame draws the row it drew yesterday. *)

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
