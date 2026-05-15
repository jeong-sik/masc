open Alcotest

(** RFC-0084 host-config-cleanup-F — test-mode predicate migration.

    PR-F migrates the typed [Host_config.test_mode_kind] surface into
    the only call-site that lives in the [masc_mcp] main library:
    [lib/config_dir_resolver.ml:55] [running_under_test_executable].

    The other 4 sites enumerated in PR-12 mli §1.5 live in lower-level
    sub-libraries ([masc_config], [masc_coord], [fs_compat]) which
    cannot call [Masc_mcp.Host_config] without inverting the dune
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

let read_file path =
  match In_channel.with_open_text path In_channel.input_all with
  | exception _ -> ""
  | content -> content
;;

let count_substring ~haystack ~needle =
  let rec loop i acc =
    let next = String.index_from_opt haystack i needle.[0] in
    match next with
    | None -> acc
    | Some j ->
      let len = String.length needle in
      if j + len <= String.length haystack
         && String.sub haystack j len = needle
      then loop (j + len) (acc + 1)
      else loop (j + 1) acc
  in
  loop 0 0
;;

let test_no_test_prefix_literal_in_config_dir_resolver () =
  let content = read_file "lib/config_dir_resolver.ml" in
  let occurrences =
    count_substring ~haystack:content
      ~needle:{|String.starts_with ~prefix:"test_"|}
  in
  (check int)
    "literal `String.starts_with ~prefix:\"test_\"` in \
     lib/config_dir_resolver.ml must be 0 after PR-F"
    pinned_test_prefix_literal_count occurrences
;;

let test_helper_takes_no_argument () =
  let content = read_file "lib/config_dir_resolver.ml" in
  let old_signature_occurrences =
    count_substring ~haystack:content
      ~needle:"running_under_test_executable executable_name"
  in
  let new_signature_occurrences =
    count_substring ~haystack:content
      ~needle:"running_under_test_executable ()"
  in
  (check bool)
    "helper signature must be `unit -> bool` (no `executable_name` parameter) \
     after PR-F"
    pinned_helper_takes_no_argument
    (old_signature_occurrences = 0 && new_signature_occurrences >= 1)
;;

let test_host_config_is_test_mode_called () =
  let content = read_file "lib/config_dir_resolver.ml" in
  let occurrences =
    count_substring ~haystack:content
      ~needle:"Host_config.is_test_mode"
  in
  (check bool)
    "Host_config.is_test_mode must be called from \
     lib/config_dir_resolver.ml after PR-F"
    true (occurrences >= 1)
;;

let test_is_test_mode_round_trips () =
  (check bool)
    "Host_config.is_test_mode Test = true"
    true
    (Masc_mcp.Host_config.is_test_mode Masc_mcp.Host_config.Test);
  (check bool)
    "Host_config.is_test_mode Production = false"
    false
    (Masc_mcp.Host_config.is_test_mode Masc_mcp.Host_config.Production)
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
