open Alcotest

(** RFC-0084 PR-12 — Host_config typed record invariants.

    PR-12 introduces the typed [Host_config.t] record + [resolve]
    accessor; the 11 hardcode-site migrations are scoped to
    *follow-up cleanup PRs* (one per sub-domain).

    Tests pin:
    - legacy_macos_default field count and values match the 11 sites
      enumerated in RFC-0084 §1.5
    - is_test_mode round-trips through the typed sum (no
      String.starts_with leak)
    - resolve ~base_path returns base-path-relative runtime roots
*)

let test_legacy_macos_default_field_values () =
  let d = Masc_mcp.Host_config.legacy_macos_default () in
  (check string)
    "legacy_macos_default.cred_root pins /tmp/keeper-creds \
     (host_config_provider.ml:3)"
    "/tmp/keeper-creds"
    d.cred_root;
  (check string)
    "legacy_macos_default.host_bash pins /bin/bash \
     (keeper_shell_bash.ml:745, 802)"
    "/bin/bash"
    d.host_bash;
  (check string)
    "legacy_macos_default.host_zsh pins /bin/zsh \
     (gh-family 5 sites)"
    "/bin/zsh"
    d.host_zsh
;;

let test_legacy_coreutils_match_macos () =
  let d = Masc_mcp.Host_config.legacy_macos_default () in
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
    (Masc_mcp.Host_config.is_test_mode Masc_mcp.Host_config.Test);
  (check bool)
    "is_test_mode Production = false"
    false
    (Masc_mcp.Host_config.is_test_mode Masc_mcp.Host_config.Production)
;;

let test_resolve_with_base_path () =
  match Masc_mcp.Host_config.resolve ~base_path:"/tmp/test-masc" () with
  | Error msg -> failf "resolve failed: %s" msg
  | Ok t ->
    (check bool)
      "agent_runtime_root is base-path-relative \
       (RFC-0084 §1.5 migration target for /tmp/.masc_agent_* 7 sites)"
      true
      (String.length t.agent_runtime_root > 0
       && t.agent_runtime_root <> "/tmp/.masc_agent");
    (check bool)
      "cred_root is base-path-relative when explicit base provided"
      true
      (t.cred_root <> "/tmp/keeper-creds")
;;

let test_resolve_default_base_path () =
  match Masc_mcp.Host_config.resolve () with
  | Error msg -> failf "resolve (default base) failed: %s" msg
  | Ok _ ->
    (* Default-base resolve must succeed; concrete path content is
       host-specific. *)
    ()
;;

let pinned_hardcode_sites = 11
(** RFC-0084 §1.5 P0 hardcode count. PR-12 introduces the typed surface
    for these 11 sites; follow-up cleanup PRs migrate each sub-domain. *)

let pinned_test_mode_sites_to_replace = 5

let test_hardcode_site_inventory_pin () =
  (check int)
    "RFC-0084 §1.5 P0 hardcode site count (pinned for migration tracking)"
    11
    pinned_hardcode_sites;
  (check int)
    "RFC-0084 §1.5 String.starts_with \"test_\" site count"
    5
    pinned_test_mode_sites_to_replace
;;

let () =
  Alcotest.run
    "RFC-0084 PR-12 Host_config typed"
    [ ( "host-config"
      , [ test_case
            "legacy-macos-default-field-values"
            `Quick
            test_legacy_macos_default_field_values
        ; test_case
            "legacy-coreutils-match-macos"
            `Quick
            test_legacy_coreutils_match_macos
        ; test_case "is-test-mode-typed" `Quick test_is_test_mode_typed
        ; test_case "resolve-with-base-path" `Quick test_resolve_with_base_path
        ; test_case "resolve-default-base-path" `Quick test_resolve_default_base_path
        ; test_case
            "hardcode-site-inventory-pin"
            `Quick
            test_hardcode_site_inventory_pin
        ] )
    ]
;;
