open Alcotest

module Poller = Host_fd_pressure_poller

external unsetenv : string -> unit = "masc_test_unsetenv"

let canonical_env = Env_config_core.host_fd_pressure_state_file_env_key
let legacy_env = Env_config_core.legacy_host_fd_pressure_state_file_env_key
let base_path = Filename.concat (Filename.get_temp_dir_name ()) "masc-fd-pressure-test"

let default_path =
  Filename.concat
    (Workspace_utils.masc_dir_from_base_path ~base_path)
    "masc-host-pressure.state"

let restore_env name = function
  | Some value -> Unix.putenv name value
  | None -> unsetenv name

let with_env bindings f =
  let names = List.map fst bindings in
  let original = List.map (fun name -> name, Sys.getenv_opt name) names in
  List.iter
    (fun (name, value) ->
      match value with
      | Some value -> Unix.putenv name value
      | None -> unsetenv name)
    bindings;
  Fun.protect f ~finally:(fun () ->
    List.iter (fun (name, value) -> restore_env name value) original)

let check_resolution label expected_path expected_source =
  let actual = Poller.resolve_state_file_path ~base_path () in
  check string (label ^ " path") expected_path actual.path;
  check bool (label ^ " source") true (actual.source = expected_source)

let test_default_path () =
  with_env [ canonical_env, None; legacy_env, None ] (fun () ->
    check_resolution "default" default_path Poller.Default)

let test_canonical_env_wins () =
  with_env
    [ canonical_env, Some "/var/run/masc/fd-pressure.json"
    ; legacy_env, Some "/tmp/sysmon-pressure.json"
    ]
    (fun () ->
      check_resolution
        "canonical"
        "/var/run/masc/fd-pressure.json"
        Poller.Canonical_env)

let test_legacy_env_is_ignored () =
  with_env [ canonical_env, None; legacy_env, Some "/tmp/sysmon-pressure.json" ] (fun () ->
    check_resolution "legacy" "/tmp/sysmon-pressure.json" Poller.Legacy_env)

let test_conflicting_envs_are_detected () =
  with_env
    [ canonical_env, Some "/var/run/masc/fd-pressure.json"
    ; legacy_env, Some "/tmp/sysmon-pressure.json"
    ]
    (fun () ->
      check_resolution
        "canonical conflict"
        "/var/run/masc/fd-pressure.json"
        Poller.Canonical_env;
      check
        (option (pair string string))
        "conflict"
        (Some ("/var/run/masc/fd-pressure.json", "/tmp/sysmon-pressure.json"))
        (Poller.state_file_env_conflict ()))

let test_empty_env_is_absent () =
  with_env [ canonical_env, Some ""; legacy_env, Some "" ] (fun () ->
    check_resolution "empty" default_path Poller.Default)

let () =
  run
    "Host_fd_pressure_poller"
    [ ( "state path"
      , [ test_case "default path" `Quick test_default_path
        ; test_case "canonical env wins" `Quick test_canonical_env_wins
        ; test_case "legacy env falls back" `Quick test_legacy_env_is_ignored
        ; test_case
            "conflicting envs are detected"
            `Quick
            test_conflicting_envs_are_detected
        ; test_case "empty env is absent" `Quick test_empty_env_is_absent
        ] )
    ]
