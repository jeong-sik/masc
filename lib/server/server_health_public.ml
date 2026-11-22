let server_field = "server"
let server_name = "masc"
let version_field = "version"
let live_field = "live"
let ready_field = "ready"
let phase_field = "phase"

let readiness_fields ~ready ~phase =
  [ ready_field, `Bool ready
  ; phase_field, `String (Server_startup_state.phase_to_string phase)
  ]
;;

(* HIGH-RISK-UNREVIEWED [H3]: this is the whole answer to a requester the
   server gives no read. A key added here is said to every requester on every
   listener, one that asks for a credential on its other routes included. It
   never carries the account mode: [Server_accounts.health_version] and
   masc-tui ([Tui_decode.decode_server_reading]) read that key to know an
   account server, and would take this server for one or refuse it. *)
let health_json ~ready ~phase =
  `Assoc
    ([ server_field, `String server_name
     ; version_field, `String Build_version.current
     ; live_field, `Bool (Server_startup_state.is_live ())
     ]
     @ readiness_fields ~ready ~phase)
;;

let liveness_json = `Assoc [ live_field, `Bool true ]
let readiness_json ~ready ~phase = `Assoc (readiness_fields ~ready ~phase)

let capabilities =
  [ "memory_v2"
  ; "infra_sandboxes"
  ; "candle_ledger"
  ; "config_schema"
  ; "task_goal_link"
  ]
;;

let capabilities_json = `List (List.map (fun cap -> `String cap) capabilities)
