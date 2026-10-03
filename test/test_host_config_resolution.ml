open Alcotest

(** RFC-0084 PR-12 — Host_config typed record invariants.

    PR-12 introduces the typed [Host_config.t] record + [resolve]
    accessor; the 11 hardcode-site migrations are scoped to
    *follow-up cleanup PRs* (one per sub-domain).

    Tests cover:
    - host defaults and host-derived temporary directories
    - is_test_mode round-trips through the typed sum (no
      String.starts_with leak)
    - resolve ~base_path returns base-path-relative runtime roots
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

let test_legacy_coreutils_match_macos () =
  let d = Host_config.host () in
  (check string) "ls = /bin/ls" "/bin/ls" d.coreutils.ls;
  (check string) "cat = /bin/cat" "/bin/cat" d.coreutils.cat;
  (check string) "pwd = /bin/pwd" "/bin/pwd" d.coreutils.pwd;
  (check string) "head = /usr/bin/head" "/usr/bin/head" d.coreutils.head;
  (check string) "tail = /usr/bin/tail" "/usr/bin/tail" d.coreutils.tail;
  (check string) "wc = /usr/bin/wc" "/usr/bin/wc" d.coreutils.wc
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

let test_resolve_with_base_path () =
  match Host_config.resolve ~base_path:"/tmp/test-masc" () with
  | Error msg -> failf "resolve failed: %s" msg
  | Ok t ->
    (check bool)
      "agent_runtime_root is base-path-relative \
       (RFC-0084 §1.5 typed runtime root)"
      true
      (String.length t.agent_runtime_root > 0
       && String.starts_with ~prefix:"/tmp/test-masc/" t.agent_runtime_root);
    (check bool)
      "cred_root is base-path-relative when explicit base provided"
      true
      (t.cred_root <> "/tmp/keeper-creds")
;;

let test_resolve_default_base_path () =
  match Host_config.resolve () with
  | Error msg -> failf "resolve (default base) failed: %s" msg
  | Ok _ ->
    (* Default-base resolve must succeed; concrete path content is
       host-specific. *)
    ()
;;

let () =
  Alcotest.run
    "RFC-0084 PR-12 Host_config typed"
    [ ( "host-config"
      , [ test_case
            "legacy-macos-default-field-values"
            `Quick
            test_host_field_values
        ; test_case
            "legacy-coreutils-match-macos"
            `Quick
            test_legacy_coreutils_match_macos
        ; test_case "is-test-mode-typed" `Quick test_is_test_mode_typed
        ; test_case "resolve-with-base-path" `Quick test_resolve_with_base_path
        ; test_case "resolve-default-base-path" `Quick test_resolve_default_base_path
        ] )
    ]
;;
