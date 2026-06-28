open Alcotest

(** RFC-0084 host-config-cleanup-F — test-mode predicate migration.

    PR-F migrates the typed [Host_config.test_mode_kind] surface into
    the only call-site that lives in the [masc] main library:
    [running_under_test_executable] in config_dir_resolver.

    The other 4 sites enumerated in PR-12 mli §1.5 live in lower-level
    sub-libraries ([masc_config], [masc_workspace], [fs_compat]) which
    cannot call [Host_config] without inverting the dune
    dependency graph; their migration is deferred to a separate RFC
    (Host_config extraction to a shared lower-level library).  The 6th
    site ([cdal/adversarial_eval]) is a *file-classification*
    pattern unrelated to current-binary test-mode and is excluded
    from PR-F scope by design.

    The pins guard against:
    - the literal [String.starts_with ~prefix:"test_"] regressing into
      [config_dir_resolver.ml]
      ([pinned_test_prefix_literal_count = 0])
    - the [running_under_test_executable] helper signature drifting
      back to [string -> bool]
      ([pinned_takes_no_argument = true])
    - [Host_config.is_test_mode] not being called from the migrated
      site (positive assertion). *)

let pinned_test_prefix_literal_count = 0
let pinned_helper_takes_no_argument = true

let config_dir_resolver_source_path =
  Masc_test_deps.config_dir_resolver_source_path
;;

let test_no_test_prefix_literal_in_config_dir_resolver () =
  let occurrences =
    Ast_grep.count_string_literals
      ~module_path:config_dir_resolver_source_path
      ~needle:"test_"
  in
  (check int)
    "literal `String.starts_with ~prefix:\"test_\"` in \
     config_dir_resolver source must be 0 after PR-F"
    pinned_test_prefix_literal_count occurrences
;;

let test_helper_takes_no_argument () =
  let unit_arg_bindings =
    Ast_grep.count_value_bindings_with_unit_arg
      ~module_path:config_dir_resolver_source_path
      ~name:"running_under_test_executable"
  in
  (check bool)
    "helper signature must be `unit -> bool` (no `executable_name` parameter) \
     after PR-F"
    pinned_helper_takes_no_argument
    (unit_arg_bindings = 1)
;;

let test_host_config_is_test_mode_called () =
  let occurrences =
    Ast_grep.count_calls
      ~module_path:config_dir_resolver_source_path
      ~callee:"Host_config.is_test_mode"
  in
  (check bool)
    "Host_config.is_test_mode must be called from \
     config_dir_resolver source after PR-F"
    true (occurrences >= 1)
;;

let test_is_test_mode_round_trips () =
  (check bool)
    "Host_config.is_test_mode Test = true"
    true
    (Host_config.is_test_mode Host_config.Test);
  (check bool)
    "Host_config.is_test_mode Production = false"
    false
    (Host_config.is_test_mode Host_config.Production)
;;

let () =
  run
    "PR-F host-config-cleanup-F (test-mode predicate)"
    [ ( "pr-f-test-mode"
      , [ test_case "no-test-prefix-literal-in-config-dir-resolver" `Quick
            test_no_test_prefix_literal_in_config_dir_resolver
        ; test_case "helper-takes-no-argument" `Quick
            test_helper_takes_no_argument
        ; test_case "host-config-is-test-mode-called" `Quick
            test_host_config_is_test_mode_called
        ; test_case "is-test-mode-round-trips" `Quick
            test_is_test_mode_round_trips
        ] )
    ]
;;
