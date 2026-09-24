module Reading = Masc.Tui_decode

let badge_word : Reading.connector_connection -> string = function
  | Reading.Connector_connected -> "CONNECTED"
  | Connector_connected_unavailable -> "CONNECTED / UNAVAILABLE"
  | Connector_disconnected -> "DISCONNECTED"
  | Connector_offline -> "UNAVAILABLE"
  | Connector_stale -> "STALE"

(* Every word the badge can spell. The column that draws them asks this list
   how wide it has to be, rather than carrying a hand-written number beside
   it: a column narrower than the widest word cuts that word, and a cut state
   word is the worst thing this column can draw -- [CONNECTED / UNAVAILABLE]
   cut to twelve cells reads as [CONNECTED], which is a different state.
   OCaml does not enumerate a variant for us, so a new connection has to be
   added here as well; [test_tui_connector_state] pins the count. *)
let all_connections : Reading.connector_connection list =
  [ Reading.Connector_connected
  ; Connector_connected_unavailable
  ; Connector_disconnected
  ; Connector_offline
  ; Connector_stale
  ]

let badge_words = List.map badge_word all_connections

(* The words are ASCII, so a byte is a cell. *)
let badge_column_cells =
  List.fold_left
    (fun widest word -> max widest (String.length word))
    0 badge_words

(* The Channels list row draws three things: the transport's name, the badge
   word, and the counts of bindings. When the frame cannot hold all three,
   exactly one of them may be shortened, and it is the name: a cut name still
   names the transport, while a cut state word names a *different state* --
   [CONNECTED / UNAVAILABLE] cut to the twelve cells this row used to reserve
   reads as [CONNECTED], the opposite reading of the half that matters. So
   the badge column keeps [badge_column_cells] and the name column takes what
   is left, down to a floor, and past that the frame cuts the counts. *)
let name_cells_preferred = 14
let name_cells_floor = 8

let list_row_name_cells ~inner ~fixed_cells ~tail_cells =
  let left = inner - fixed_cells - badge_column_cells - tail_cells in
  min name_cells_preferred (max name_cells_floor left)

let gateway_word : Reading.connector_gateway_state -> string = function
  | Reading.Connector_gateway_disconnected -> "disconnected"
  | Connector_gateway_awaiting_hello -> "awaiting_hello"
  | Connector_gateway_identifying -> "identifying"
  | Connector_gateway_resuming -> "resuming"
  | Connector_gateway_connected -> "connected"
  | Connector_gateway_reconnect_pending -> "reconnect_pending"
  | Connector_gateway_failed -> "failed"

let poll_word : Reading.connector_poll_state -> string = function
  | Reading.Connector_poll_not_started -> "not_started"
  | Connector_poll_polling -> "polling"
  | Connector_poll_degraded -> "degraded"

(* A gateway says what the badge said when the badge already spells that word.
   Two badges spell CONNECTED: [CONNECTED], and [CONNECTED / UNAVAILABLE],
   which is that same word plus a second fact about availability. A connected
   gateway adds nothing under either -- under the compound badge it restates
   the half the badge already spelled, and leaves the reader to guess which
   half the row meant. Every other pair adds a reading: a resuming gateway
   under CONNECTED / UNAVAILABLE, a disconnected one under UNAVAILABLE. *)
let badge_says_gateway (connection : Reading.connector_connection) :
    Reading.connector_gateway_state -> bool = function
  | Reading.Connector_gateway_connected -> (
      match connection with
      | Reading.Connector_connected | Connector_connected_unavailable -> true
      | Connector_disconnected | Connector_offline | Connector_stale -> false)
  | Connector_gateway_disconnected -> (
      match connection with
      | Reading.Connector_disconnected -> true
      | Connector_connected | Connector_connected_unavailable
      | Connector_offline | Connector_stale ->
          false)
  | Connector_gateway_awaiting_hello | Connector_gateway_identifying
  | Connector_gateway_resuming | Connector_gateway_reconnect_pending
  | Connector_gateway_failed ->
      false

(* No badge speaks of polling, so a poll state always adds a reading. *)
let badge_says_poll (_ : Reading.connector_connection) :
    Reading.connector_poll_state -> bool = function
  | Reading.Connector_poll_not_started | Connector_poll_polling
  | Connector_poll_degraded ->
      false

let runtime_state_to_draw (connector : Reading.connector) =
  let connection = connector.Reading.cn_connection in
  match connector.Reading.cn_gateway_state, connector.Reading.cn_poll_state with
  | Some gateway, _ ->
      if badge_says_gateway connection gateway then None
      else Some (gateway_word gateway)
  | None, Some poll ->
      if badge_says_poll connection poll then None else Some (poll_word poll)
  | None, None -> None
