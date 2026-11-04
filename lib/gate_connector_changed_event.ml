let event_type = "gate_connector_changed"

let json ~connector ~ts_unix =
  `Assoc [ "type", `String event_type; "connector", `String connector; "ts_unix", `Float ts_unix ]
