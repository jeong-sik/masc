let event_type = "runtime_config_changed"

let json ~ts_unix = `Assoc [ "type", `String event_type; "ts_unix", `Float ts_unix ]
