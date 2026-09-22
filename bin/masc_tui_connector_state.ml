module Reading = Masc.Tui_decode

let badge_word : Reading.connector_connection -> string = function
  | Reading.Connector_connected -> "CONNECTED"
  | Connector_connected_unavailable -> "CONNECTED / UNAVAILABLE"
  | Connector_disconnected -> "DISCONNECTED"
  | Connector_offline -> "UNAVAILABLE"
  | Connector_stale -> "STALE"

let runtime_state_to_draw ~connection state =
  match state with
  | None -> None
  | Some value ->
      let spoken text =
        String.lowercase_ascii (String.trim text)
      in
      if String.equal (spoken value) (spoken (badge_word connection)) then None
      else Some value
