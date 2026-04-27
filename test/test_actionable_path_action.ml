(** test_actionable_path_action — Phase B PR-5 precursor.

    [actionable_path_action_for_class] is the typed action mapping
    extracted from [actionable_path_error].  Callers that already hold a
    [Keeper_failure_circuit_breaker.error_class] use this directly and
    skip the string → class round-trip.  This test pins the action
    string for each class so a copy-paste rename or reorder fails at
    the test boundary, not in production operator-facing output. *)

open Masc_mcp.Keeper_exec_shared
module CB = Masc_mcp.Keeper_failure_circuit_breaker

let r = Alcotest.(check string)

let pg = ".masc/playground/test"

let test_path_not_found () =
  let action =
    actionable_path_action_for_class
      ~playground:pg ~raw_path:"missing.ml" CB.Path_not_found
  in
  Alcotest.(check bool) "mentions ls hint" true
    (try
       ignore (Str.search_forward (Str.regexp_string "keeper_shell op=ls") action 0);
       true
     with Not_found -> false);
  Alcotest.(check bool) "mentions playground" true
    (try
       ignore (Str.search_forward (Str.regexp_string pg) action 0);
       true
     with Not_found -> false)

let test_path_not_allowed () =
  let action =
    actionable_path_action_for_class
      ~playground:pg ~raw_path:"/etc/passwd" CB.Path_not_allowed
  in
  Alcotest.(check bool) "mentions allowed-roots constraint" true
    (try
       ignore (Str.search_forward (Str.regexp_string "outside your allowed roots") action 0);
       true
     with Not_found -> false)

let test_cwd_not_directory () =
  r "cwd guidance"
    "The cwd is not a directory. Omit cwd to use your default playground root."
    (actionable_path_action_for_class
       ~playground:pg ~raw_path:"foo" CB.Cwd_not_directory)

let test_shell_exit_nonzero_falls_back () =
  let action =
    actionable_path_action_for_class
      ~playground:pg ~raw_path:"foo" CB.Shell_exit_nonzero
  in
  Alcotest.(check bool) "uses generic fallback for non-path classes" true
    (try
       ignore (Str.search_forward (Str.regexp_string "Check the path") action 0);
       true
     with Not_found -> false)

let test_other_falls_back () =
  let action =
    actionable_path_action_for_class
      ~playground:pg ~raw_path:"foo" CB.Other
  in
  Alcotest.(check bool) "Other == Shell_exit_nonzero on action surface" true
    (try
       ignore (Str.search_forward (Str.regexp_string "Check the path") action 0);
       true
     with Not_found -> false)

let test_empty_raw_path_overrides_class () =
  (* The "provide a path" guidance fires regardless of class when the
     caller passed an empty raw_path — Phase A F4 preserved this
     behavior; this PR re-asserts it under the typed surface. *)
  let action =
    actionable_path_action_for_class
      ~playground:pg ~raw_path:"" CB.Path_not_found
  in
  Alcotest.(check bool) "empty raw_path -> 'Provide a path' guidance" true
    (try
       ignore (Str.search_forward (Str.regexp_string "Provide a path") action 0);
       true
     with Not_found -> false)

let () =
  Alcotest.run "actionable_path_action"
    [
      ( "by_error_class",
        [
          Alcotest.test_case "Path_not_found" `Quick test_path_not_found;
          Alcotest.test_case "Path_not_allowed" `Quick test_path_not_allowed;
          Alcotest.test_case "Cwd_not_directory" `Quick
            test_cwd_not_directory;
          Alcotest.test_case "Shell_exit_nonzero falls back" `Quick
            test_shell_exit_nonzero_falls_back;
          Alcotest.test_case "Other falls back" `Quick test_other_falls_back;
        ] );
      ( "raw_path_override",
        [
          Alcotest.test_case "empty raw_path -> Provide a path" `Quick
            test_empty_raw_path_overrides_class;
        ] );
    ]
