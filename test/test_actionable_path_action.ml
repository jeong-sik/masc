(** test_actionable_path_action — Phase B PR-5 precursor.

    [actionable_path_action_for_class] is the typed action mapping
    extracted from [actionable_path_error].  Callers that already hold a
    [Keeper_failure_circuit_breaker.error_class] use this directly and
    skip the string → class round-trip.  This test pins the action
    string for each class so a copy-paste rename or reorder fails at
    the test boundary, not in production operator-facing output. *)

open Masc.Keeper_tool_shared_runtime
module CB = Masc.Keeper_failure_circuit_breaker
module Json = Yojson.Safe.Util

let r = Alcotest.(check string)

let pg = ".masc/playground/test"

let make_meta () =
  let json =
    `Assoc
      [ "name", `String "test"
      ; "agent_name", `String "keeper-test-agent"
      ; "trace_id", `String "trace-test"
      ; "goal", `String "actionable path test"
      ; "sandbox_profile", `String "local"
      ]
  in
  match Masc_test_deps.meta_of_json_fixture json with
  | Ok meta -> meta
  | Error e -> Alcotest.fail e
;;

let test_path_not_found () =
  let action =
    actionable_path_action_for_class
      ~playground:pg ~raw_path:"missing.ml" CB.Path_not_found
  in
  Alcotest.(check bool) "mentions visible path inspection" true
    (try
       ignore (Str.search_forward (Str.regexp_string "Inspect visible paths") action 0);
       true
     with Not_found -> false);
  Alcotest.(check bool) "does not mention Execute" false
    (try
       ignore (Str.search_forward (Str.regexp_string "Execute") action 0);
       true
     with Not_found -> false);
  Alcotest.(check bool) "does not invent Grep op syntax" false
    (try
       ignore (Str.search_forward (Str.regexp_string "Grep op=") action 0);
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
    "The cwd is not a directory. Omit cwd to use your default playground root, or create/repair the repo checkout first and then retry with cwd=repos/<repo>."
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

let test_actionable_path_error_marks_path_not_found_deterministic () =
  let raw =
    actionable_path_error
      ~op:"rg"
      ~meta:(make_meta ())
      ~raw_path:"repos/masc-mcp/lib"
      ~error:"path_not_found_under_allowed_roots: repos/masc-mcp/lib"
  in
  let json = Yojson.Safe.from_string raw in
  let retry = Json.member "deterministic_retry" json in
  Alcotest.(check (option string))
    "retry reason"
    (Some "path_not_found")
    (Json.member "reason" retry |> Json.to_string_option);
  Alcotest.(check (option bool))
    "same args retry disabled"
    (Some false)
    (Json.member "retry_same_args" retry |> Json.to_bool_option)

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
      ( "error_json",
        [
          Alcotest.test_case
            "path not found marks deterministic retry boundary"
            `Quick
            test_actionable_path_error_marks_path_not_found_deterministic;
        ] );
    ]
