module Reading = Masc.Tui_decode

let badge_word : Reading.connector_connection -> string = function
  | Reading.Connector_connected -> "CONNECTED"
  | Connector_connected_unavailable -> "CONNECTED / UNAVAILABLE"
  | Connector_disconnected -> "DISCONNECTED"
  | Connector_offline -> "UNAVAILABLE"
  | Connector_stale -> "STALE"

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
