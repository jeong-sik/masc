open Alcotest

let identity ~state_ready : Masc.Tui_decode.server_identity =
  { Masc.Tui_decode.sid_version = "0.31.0"
  ; sid_binary_commit = "deadbeef"
  ; sid_binary_commit_age_s = None
  ; sid_base_path = "/tmp/base"
  ; sid_masc_root = "/tmp/base/.masc"
  ; sid_executable_in_worktree = None
  ; sid_state_ready = state_ready
  ; sid_uptime = None
  ; sid_sse_clients = None
  ; sid_gc = None
  ; sid_scheduler = None
  }
;;

let test_booting_only_when_the_probe_says_not_ready () =
  let booting reading = Masc_tui_types.server_is_booting reading in
  check bool "not ready is booting" true (booting (Ok (identity ~state_ready:(Some false))));
  check bool "ready is not" false (booting (Ok (identity ~state_ready:(Some true))));
  check bool "an older server without the field is not" false
    (booting (Ok (identity ~state_ready:None)));
  check bool "a failed probe is not booting, it is unreachable" false
    (booting (Error "connection refused"))
;;

let test_booting_has_its_own_label () =
  check string "label" "server booting..."
    (Masc_tui_types.connection_status_label Masc_tui_types.Booting)
;;

let () =
  run
    "tui_connection_status"
    [ ( "booting"
      , [ test_case "only when the probe says not ready" `Quick
            test_booting_only_when_the_probe_says_not_ready
        ; test_case "has its own label" `Quick test_booting_has_its_own_label
        ] )
    ]
;;
