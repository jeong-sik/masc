(** Server hibernation capability surface.

    This is intentionally a status contract, not a fake implementation. The
    current runtime is long-running; pause/resume affects keeper turns, and
    graceful shutdown drains the process, but neither is scale-to-zero
    hibernation. *)

let status_json () =
  `Assoc
    [ "schema", `String "masc.server_hibernation.v1"
    ; "status", `String "not_implemented"
    ; "mode", `String "long_running"
    ; "scale_to_zero_supported", `Bool false
    ; "suspend_on_idle_supported", `Bool false
    ; "resume_orchestrator_present", `Bool false
    ; "serverless_provider", `Null
    ; "operator_action_required", `Bool false
    ; "terminal_reason", `String "no_hibernation_orchestrator"
    ; ( "supported_controls"
      , `List
          [ `String "operator_pause_resume"
          ; `String "graceful_shutdown"
          ] )
    ; ( "unsupported_controls"
      , `List [ `String "scale_to_zero"; `String "suspend_on_idle"; `String "cold_resume" ]
      )
    ; ( "next_action"
      , `String
          "Implement a MASC-owned suspend/resume orchestrator before claiming \
           serverless hibernation support." )
    ]
;;
