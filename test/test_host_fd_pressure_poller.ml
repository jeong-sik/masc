open Alcotest

module Poller = Host_fd_pressure_poller

let canonical_env = "MASC_HOST_FD_PRESSURE_STATE_FILE"
let legacy_env = "MASC_SYSMON_PRESSURE_STATE"
let default_path = "/tmp/masc-host-pressure.state"

let getenv bindings name =
  match List.assoc_opt name bindings with
  | Some value -> value
  | None -> None
;;

let check_resolution label expected_path expected_source expected_ignored bindings =
  let actual = Poller.resolve_state_file_path ~getenv:(getenv bindings) in
  check string (label ^ " path") expected_path actual.path;
  check bool (label ^ " source") true (actual.source = expected_source);
  check (option string) (label ^ " ignored") expected_ignored actual.ignored_legacy_path

let test_default_path () =
  check_resolution
    "default"
    default_path
    Poller.Default
    None
    []

let test_canonical_env_wins () =
  check_resolution
    "canonical"
    "/var/run/masc/fd-pressure.json"
    Poller.Canonical_env
    None
    [ canonical_env, Some "/var/run/masc/fd-pressure.json" ]

let test_legacy_env_fallback () =
  check_resolution
    "legacy"
    "/tmp/sysmon-pressure.json"
    Poller.Legacy_sysmon_env
    None
    [ legacy_env, Some "/tmp/sysmon-pressure.json" ]

let test_canonical_conflict_reports_ignored_legacy () =
  check_resolution
    "conflict"
    "/var/run/masc/fd-pressure.json"
    Poller.Canonical_env
    (Some "/tmp/sysmon-pressure.json")
    [ canonical_env, Some "/var/run/masc/fd-pressure.json"
    ; legacy_env, Some "/tmp/sysmon-pressure.json"
    ]

let test_empty_env_is_absent () =
  check_resolution
    "empty"
    default_path
    Poller.Default
    None
    [ canonical_env, Some ""; legacy_env, Some "" ]

let () =
  run
    "Host_fd_pressure_poller"
    [ ( "state path"
      , [ test_case "default path" `Quick test_default_path
        ; test_case "canonical env wins" `Quick test_canonical_env_wins
        ; test_case "legacy env fallback" `Quick test_legacy_env_fallback
        ; test_case
            "canonical conflict reports ignored legacy"
            `Quick
            test_canonical_conflict_reports_ignored_legacy
        ; test_case "empty env is absent" `Quick test_empty_env_is_absent
        ] )
    ]
