open Masc

let process_exit_code = function
  | Unix.WEXITED code -> code
  | Unix.WSIGNALED _ | Unix.WSTOPPED _ -> 255

let git_output repo_root args =
  let argv = Array.of_list ("git" :: "-C" :: repo_root :: args) in
  let ic = Unix.open_process_args_in "git" argv in
  let output = In_channel.input_all ic in
  match Unix.close_process_in ic with
  | status when process_exit_code status = 0 -> String_util.trim_to_option output
  | _ -> None

let test_resolve_commit_prefers_env () =
  let probe_called = ref false in
  let commit =
    Build_identity.resolve_commit
      ~env_value:(Some " abc12345 ")
      ~probe:(fun () ->
        probe_called := true;
        Some "deadbeef")
  in
  Alcotest.(check (option string)) "env wins" (Some "abc12345") commit;
  Alcotest.(check bool) "probe not called" false !probe_called

let test_resolve_commit_uses_probe_when_env_missing () =
  let commit =
    Build_identity.resolve_commit
      ~env_value:None
      ~probe:(fun () -> Some "deadbeef")
  in
  Alcotest.(check (option string)) "probe used" (Some "deadbeef") commit

let test_resolve_commit_details_splits_env_and_repo_head () =
  let details =
    Build_identity.resolve_commit_details
      ~env_value:(Some " abc12345 ")
      ~stamp_value:(Some " cafebabe ")
      ~probe:(fun () -> Some "deadbeef")
  in
  Alcotest.(check (option string)) "compat commit uses env"
    (Some "abc12345") details.commit;
  Alcotest.(check (option string)) "commit source is env"
    (Some "env:MASC_BUILD_GIT_COMMIT") details.commit_source;
  Alcotest.(check (option string)) "binary commit uses env"
    (Some "abc12345") details.binary_commit;
  Alcotest.(check (option string)) "binary source is env"
    (Some "env:MASC_BUILD_GIT_COMMIT") details.binary_commit_source;
  Alcotest.(check (option string)) "repo head still surfaced"
    (Some "deadbeef") details.repo_head_commit;
  Alcotest.(check (option string)) "repo head source"
    (Some "runtime_repo_head") details.repo_head_commit_source

let test_resolve_commit_details_uses_build_stamp_when_env_missing () =
  let details =
    Build_identity.resolve_commit_details
      ~env_value:None
      ~stamp_value:(Some " cafebabe ")
      ~probe:(fun () -> Some "deadbeef")
  in
  Alcotest.(check (option string)) "compat commit uses stamped binary"
    (Some "cafebabe") details.commit;
  Alcotest.(check (option string)) "commit source is stamp"
    (Some "executable_build_commit_stamp") details.commit_source;
  Alcotest.(check (option string)) "binary commit uses stamp"
    (Some "cafebabe") details.binary_commit;
  Alcotest.(check (option string)) "binary source is stamp"
    (Some "executable_build_commit_stamp") details.binary_commit_source;
  Alcotest.(check (option string)) "repo head still surfaced"
    (Some "deadbeef") details.repo_head_commit

let test_resolve_commit_details_marks_repo_head_fallback () =
  let details =
    Build_identity.resolve_commit_details
      ~env_value:None
      ~probe:(fun () -> Some "deadbeef")
  in
  Alcotest.(check (option string)) "compat commit falls back to repo head"
    (Some "deadbeef") details.commit;
  Alcotest.(check (option string)) "commit source is repo head"
    (Some "runtime_repo_head") details.commit_source;
  Alcotest.(check (option string)) "binary commit absent" None
    details.binary_commit;
  Alcotest.(check (option string)) "repo head commit present"
    (Some "deadbeef") details.repo_head_commit

let test_current_started_at_is_stable () =
  let first = Build_identity.current () in
  Unix.sleepf 0.01;
  let second = Build_identity.current () in
  Alcotest.(check string) "stable started_at" first.started_at second.started_at;
  Alcotest.(check bool) "uptime monotonic" true
    (second.uptime_seconds >= first.uptime_seconds)

let test_runtime_cwd_is_resolver_backed_snapshot () =
  let cwd = Build_identity.For_testing.runtime_cwd () in
  Alcotest.(check bool) "cwd snapshot populated" true (String.length cwd > 0);
  Alcotest.(check bool) "cwd snapshot absolute" true (not (Filename.is_relative cwd))

let test_current_json_exposes_runtime_binary_identity () =
  let current = Build_identity.current () in
  let json = Build_identity.to_yojson current in
  let open Yojson.Safe.Util in
  Alcotest.(check bool) "binary version populated" true
    (String.length (json |> member "binary_version" |> to_string) > 0);
  Alcotest.(check bool) "repo version field present" true
    (match json |> member "repo_version" with `Null | `String _ -> true | _ -> false);
  Alcotest.(check bool) "commit source field present" true
    (match json |> member "commit_source" with `Null | `String _ -> true | _ -> false);
  Alcotest.(check bool) "binary commit field present" true
    (match json |> member "binary_commit" with `Null | `String _ -> true | _ -> false);
  Alcotest.(check bool) "repo head commit field present" true
    (match json |> member "repo_head_commit" with `Null | `String _ -> true | _ -> false);
  Alcotest.(check bool) "executable path populated" true
    (String.length (json |> member "executable_path" |> to_string) > 0);
  Alcotest.(check bool) "executable dir populated" true
    (String.length (json |> member "executable_dir" |> to_string) > 0);
  Alcotest.(check bool) "repo_root field present" true
    (match json |> member "repo_root" with `Null | `String _ -> true | _ -> false)

let test_pick_repo_candidates_exe_first_when_distinct () =
  (* Regression for the bug where running `cd ~/me && .../masc/main_eio.exe`
     reported ~/me's commit instead of masc's. exe_dir must come first. *)
  let result =
    Build_identity.pick_repo_candidates
      ~exe_dir:"/Users/dev/masc/_build/default/bin"
      ~cwd:"/Users/dev/me"
  in
  Alcotest.(check (list string))
    "exe_dir before cwd"
    [ "/Users/dev/masc/_build/default/bin"; "/Users/dev/me" ]
    result

let test_pick_repo_candidates_dedups_equal () =
  let result =
    Build_identity.pick_repo_candidates
      ~exe_dir:"/Users/dev/masc"
      ~cwd:"/Users/dev/masc"
  in
  Alcotest.(check (list string))
    "single entry when equal"
    [ "/Users/dev/masc" ]
    result

let test_pick_repo_candidates_not_sorted_alphabetically () =
  (* The old implementation used List.sort_uniq String.compare which
     sorted alphabetically, causing /Users/dancer/me to win over
     /Users/dancer/me/workspace/yousleepwhen/masc/_build/default/bin
     because the shorter prefix is lexicographically smaller. Assert
     that we now preserve the logical order instead. *)
  let result =
    Build_identity.pick_repo_candidates
      ~exe_dir:"/Users/dancer/me/workspace/yousleepwhen/masc/_build/default/bin"
      ~cwd:"/Users/dancer/me"
  in
  match result with
  | first :: _ ->
      Alcotest.(check string)
        "exe_dir wins over shorter cwd prefix"
        "/Users/dancer/me/workspace/yousleepwhen/masc/_build/default/bin"
        first
  | [] -> Alcotest.fail "pick_repo_candidates returned empty list"

let test_parse_commit_unix_ts_output () =
  Alcotest.(check (option (float 0.001)))
    "valid timestamp"
    (Some 1_712_000_000.0)
    (Build_identity.parse_commit_unix_ts_output " 1712000000\n");
  Alcotest.(check (option (float 0.001)))
    "valid timestamp above 32-bit int max"
    (Some 4_102_444_800.0)
    (Build_identity.parse_commit_unix_ts_output "4102444800\n");
  Alcotest.(check (option (float 0.001)))
    "invalid timestamp"
    None
    (Build_identity.parse_commit_unix_ts_output "not-a-timestamp\n");
  List.iter
    (fun raw ->
      Alcotest.(check (option (float 0.001)))
        ("reject non-integer timestamp " ^ raw)
        None
        (Build_identity.parse_commit_unix_ts_output raw))
    [ "nan"; "inf"; "-1"; "1.0"; "1e9"; "0x660b7d80"; "4102444801" ]

let test_parse_dune_project_version () =
  Alcotest.(check (option string)) "version parsed"
    (Some "0.19.20")
    (Build_identity.parse_dune_project_version
       "(lang dune 3.22)\n\n(name masc)\n(version 0.19.20)\n");
  Alcotest.(check (option string)) "missing version" None
    (Build_identity.parse_dune_project_version "(lang dune 3.22)\n")

let build_identity_probe_failure_count site =
  Otel_metric_store.metric_value_or_zero
    Otel_metric_store.metric_build_identity_probe_failures
    ~labels:[("site", site)]
    ()

let test_probe_failure_observer_increments_metric () =
  let before = build_identity_probe_failure_count "commit_ts_parse" in
  Build_identity.For_testing.observe_probe_failure
    ~site:"commit_ts_parse"
    (Failure "synthetic parse failure");
  let after = build_identity_probe_failure_count "commit_ts_parse" in
  Alcotest.(check (float 0.0001))
    "probe failure counted"
    (before +. 1.0)
    after

let test_commit_ts_git_status_failure_is_observed () =
  match Build_identity.repo_root () with
  | None -> ()
  | Some _ ->
      let before = build_identity_probe_failure_count "commit_ts_git_status" in
      let result =
        Build_identity.For_testing.probe_commit_unix_ts
          (Some "definitely-not-a-real-commit")
      in
      let after = build_identity_probe_failure_count "commit_ts_git_status" in
      Alcotest.(check (option (float 0.001)))
        "invalid commit has no timestamp"
        None
        result;
      Alcotest.(check bool)
        "non-zero git status counted at least once"
        true
        (after >= before +. 1.0)

let test_stamp_commit_verifier_requires_git_commit_object () =
  match Build_identity.repo_root () with
  | None -> ()
  | Some repo_root ->
      (match git_output repo_root [ "rev-parse"; "--short"; "HEAD" ] with
       | None -> ()
       | Some head ->
           Alcotest.(check bool)
             "current HEAD is accepted as a commit object"
             true
             (Build_identity.For_testing.stamp_commit_exists_in_runtime_repo_roots
                head));
      Alcotest.(check bool)
        "arbitrary stamp text is rejected"
        false
        (Build_identity.For_testing.stamp_commit_exists_in_runtime_repo_roots
           "not-a-commit")

let () =
  Alcotest.run "build_identity"
    [
      ( "identity",
        [
          Alcotest.test_case "resolve commit prefers env" `Quick
            test_resolve_commit_prefers_env;
          Alcotest.test_case "resolve commit falls back to probe" `Quick
            test_resolve_commit_uses_probe_when_env_missing;
          Alcotest.test_case "resolve commit details splits env and repo head"
            `Quick test_resolve_commit_details_splits_env_and_repo_head;
          Alcotest.test_case "resolve commit details uses build stamp" `Quick
            test_resolve_commit_details_uses_build_stamp_when_env_missing;
          Alcotest.test_case
            "resolve commit details marks repo head fallback" `Quick
            test_resolve_commit_details_marks_repo_head_fallback;
          Alcotest.test_case "current started_at stable" `Quick
            test_current_started_at_is_stable;
          Alcotest.test_case "runtime cwd snapshot is resolver backed" `Quick
            test_runtime_cwd_is_resolver_backed_snapshot;
          Alcotest.test_case "current JSON exposes runtime binary identity" `Quick
            test_current_json_exposes_runtime_binary_identity;
          Alcotest.test_case
            "pick_repo_candidates exe first when distinct" `Quick
            test_pick_repo_candidates_exe_first_when_distinct;
          Alcotest.test_case
            "pick_repo_candidates dedups equal" `Quick
            test_pick_repo_candidates_dedups_equal;
          Alcotest.test_case
            "pick_repo_candidates not sorted alphabetically" `Quick
            test_pick_repo_candidates_not_sorted_alphabetically;
          Alcotest.test_case "parse commit timestamp output" `Quick
            test_parse_commit_unix_ts_output;
          Alcotest.test_case "parse dune-project version" `Quick
            test_parse_dune_project_version;
          Alcotest.test_case "probe failure observer increments metric" `Quick
            test_probe_failure_observer_increments_metric;
          Alcotest.test_case "git status failure increments metric" `Quick
            test_commit_ts_git_status_failure_is_observed;
          Alcotest.test_case "stamp commit verifier requires git commit object"
            `Quick test_stamp_commit_verifier_requires_git_commit_object;
        ] );
    ]
