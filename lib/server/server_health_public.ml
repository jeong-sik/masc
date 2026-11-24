let server_field = "server"
let server_name = "masc"
let version_field = "version"
let auth_methods_field = "auth_methods"
let live_field = "live"
let ready_field = "ready"
let phase_field = "phase"

type auth_methods =
  { google : bool
  ; github : bool
  ; dev_token : bool
  }

let auth_methods_to_json { google; github; dev_token } =
  `Assoc
    [ "google", `Bool google
    ; "github", `Bool github
    ; "dev_token", `Bool dev_token
    ]
;;

let single_user_auth_methods ~dev_token =
  { google = false; github = false; dev_token }
;;

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
let health_json ~dev_token ~ready ~phase =
  `Assoc
    ([ server_field, `String server_name
     ; version_field, `String Build_version.current
     ; live_field, `Bool (Server_startup_state.is_live ())
     ; auth_methods_field, auth_methods_to_json (single_user_auth_methods ~dev_token)
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
