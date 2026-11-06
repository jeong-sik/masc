open Alcotest

(** RFC-0084 PR-12 — Host_config typed record invariants.

    PR-12 introduces the typed [Host_config.t] record; the 11 hardcode-site
    migrations are scoped to *follow-up cleanup PRs* (one per sub-domain).

    Tests cover:
    - host defaults and host-derived temporary directories
    - is_test_mode round-trips through the typed sum (no
      String.starts_with leak)
*)

let test_host_field_values () =
  let d = Host_config.host () in
  let temp_keeper_creds =
    Filename.concat (Filename.get_temp_dir_name ()) "keeper-creds"
  in
  (check string)
    "host.cred_root pins temp keeper-creds"
    temp_keeper_creds
    d.cred_root;
  (check string)
    "host.agent_runtime_root follows host temp dir"
    (Filename.get_temp_dir_name ())
    d.agent_runtime_root;
  (check string)
    "host.host_bash pins /bin/bash \
     (keeper_tool_execute_runtime.ml:745, 802)"
    "/bin/bash"
    d.host_bash;
  (check string)
    "host.host_zsh pins /bin/zsh \
     (gh-family 5 sites)"
    "/bin/zsh"
    d.host_zsh
;;

let test_is_test_mode_typed () =
  (check bool)
    "is_test_mode Test = true (typed replacement for String.starts_with \"test_\")"
    true
    (Host_config.is_test_mode Host_config.Test);
  (check bool)
    "is_test_mode Production = false"
    false
    (Host_config.is_test_mode Host_config.Production)
;;

let () =
  Alcotest.run
    "RFC-0084 PR-12 Host_config typed"
    [ ( "host-config"
      , [ test_case
            "host-default-field-values"
            `Quick
            test_host_field_values

        ; test_case "is-test-mode-typed" `Quick test_is_test_mode_typed
        ] )
    ]
;;
