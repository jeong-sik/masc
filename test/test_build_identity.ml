open Masc

let test_resolve_commit_prefers_embedded () =
  let probe_called = ref false in
  let commit =
    Build_identity.resolve_commit
      ~embedded:(Some " feed0123 ")
      ~probe:(fun () ->
        probe_called := true;
        Some "deadbeef")
  in
  Alcotest.(check (option string)) "embedded wins" (Some "feed0123") commit;
  Alcotest.(check bool) "probe not called" false !probe_called

let test_resolve_commit_uses_probe_when_embedded_missing () =
  let commit =
    Build_identity.resolve_commit
      ~embedded:None
      ~probe:(fun () -> Some "deadbeef")
  in
  Alcotest.(check (option string)) "probe used" (Some "deadbeef") commit

let test_resolve_commit_details_prefers_embedded_binary () =
  let details =
    Build_identity.resolve_commit_details
      ~embedded:(Some " feed0123 ")
      ~probe:(fun () -> Some "deadbeef")
  in
  Alcotest.(check (option string)) "binary commit is embedded"
    (Some "feed0123") details.binary_commit;
  Alcotest.(check (option string)) "binary source is embedded"
    (Some "embedded") details.binary_commit_source;
  Alcotest.(check (option string)) "compat commit uses embedded"
    (Some "feed0123") details.commit;
  Alcotest.(check (option string)) "commit source is embedded"
    (Some "embedded") details.commit_source;
  Alcotest.(check (option string)) "repo head still surfaced"
    (Some "deadbeef") details.repo_head_commit

let test_resolve_commit_details_marks_repo_head_fallback () =
  let details =
    Build_identity.resolve_commit_details
      ~embedded:None
      ~probe:(fun () -> Some "deadbeef")
  in
  Alcotest.(check (option string)) "compat commit falls back to repo head"
    (Some "deadbeef") details.commit;
  Alcotest.(check (option string)) "commit source is repo head"
    (Some "runtime_repo_head") details.commit_source;
  Alcotest.(check (option string)) "binary commit absent" None
    details.binary_commit;
  Alcotest.(check (option string)) "repo head commit present"
    (Some "deadbeef") details.repo_head_commit;
  Alcotest.(check (option string)) "repo head source"
    (Some "runtime_repo_head") details.repo_head_commit_source

let test_binary_identity_ignores_mismatched_ambient_checkout () =
  let details =
    Build_identity.resolve_commit_details
      ~embedded:(Some "canary-build-source")
      ~probe:(fun () -> Some "ambient-checkout-head")
  in
  Alcotest.(check (option string))
    "canary identity remains its build source"
    (Some "canary-build-source")
    details.binary_commit;
  Alcotest.(check (option string))
    "ambient checkout remains separately observable"
    (Some "ambient-checkout-head")
    details.repo_head_commit

let test_binary_identity_survives_without_checkout () =
  let details =
    Build_identity.resolve_commit_details
      ~embedded:(Some "packaged-canary-source")
      ~probe:(fun () -> None)
  in
  Alcotest.(check (option string))
    "packaged canary keeps its build source"
    (Some "packaged-canary-source")
    details.binary_commit;
  Alcotest.(check (option string)) "no ambient checkout" None details.repo_head_commit

let test_current_started_at_is_stable () =
  let first = Build_identity.current () in
  Unix.sleepf 0.01;
  let second = Build_identity.current () in
  Alcotest.(check string) "stable started_at" first.started_at second.started_at;
  Alcotest.(check string)
    "stable runtime instance id"
    first.runtime_instance_id
    second.runtime_instance_id;
  Alcotest.(check bool)
    "runtime instance id has canonical UUID width"
    true
    (String.length first.runtime_instance_id = 36);
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
    (match json |> member "repo_root" with `Null | `String _ -> true | _ -> false);
  Alcotest.(check string)
    "runtime instance id projected"
    current.runtime_instance_id
    (json |> member "runtime_instance_id" |> to_string)

let executable_provenance_json ?(extra = []) ~commit ~fingerprint ~sha256 () =
  `Assoc
    ([ "schema", `String "masc.run-local-executable-identity.v1"
     ; "binary_commit", `String commit
     ; "build_input_fingerprint", `String fingerprint
     ; "executable_sha256", `String sha256
     ]
     @ extra)
  |> Yojson.Safe.to_string
;;

let test_executable_provenance_requires_exact_identity () =
  let commit = String.make 40 'a' in
  let fingerprint = String.make 64 'b' in
  let sha256 = String.make 64 'c' in
  let raw = executable_provenance_json ~commit ~fingerprint ~sha256 () in
  let expected : Build_identity.executable_provenance =
    { binary_commit = commit
    ; build_input_fingerprint = fingerprint
    ; executable_sha256 = sha256
    }
  in
  Alcotest.(check (result (testable (fun ppf (value : Build_identity.executable_provenance) ->
    Format.fprintf ppf "%s/%s/%s"
      value.Build_identity.binary_commit
      value.build_input_fingerprint
      value.executable_sha256) ( = )) string))
    "exact sidecar accepted"
    (Ok expected)
    (Build_identity.parse_executable_provenance
       ~expected_binary_commit:commit
       ~expected_executable_sha256:sha256
       raw)
;;

let test_executable_provenance_rejects_mismatches () =
  let commit = String.make 40 'a' in
  let fingerprint = String.make 64 'b' in
  let sha256 = String.make 64 'c' in
  let parse raw =
    Build_identity.parse_executable_provenance
      ~expected_binary_commit:commit
      ~expected_executable_sha256:sha256
      raw
  in
  let check_error label expected raw =
    match parse raw with
    | Error actual -> Alcotest.(check string) label expected actual
    | Ok _ -> Alcotest.fail (label ^ ": malformed sidecar was accepted")
  in
  check_error
    "digest mismatch"
    "executable provenance executable digest differs"
    (executable_provenance_json
       ~commit
       ~fingerprint
       ~sha256:(String.make 64 'd')
       ());
  check_error
    "invalid build fingerprint"
    "executable provenance build-input fingerprint is invalid"
    (executable_provenance_json ~commit ~fingerprint:"not-a-digest" ~sha256 ());
  check_error
    "unknown fields"
    "executable provenance has unsupported fields"
    (executable_provenance_json
       ~extra:[ "unexpected", `Bool true ]
       ~commit
       ~fingerprint
       ~sha256
       ())
;;

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

let () =
  Alcotest.run "build_identity"
    [
      ( "identity",
        [
          Alcotest.test_case "resolve commit prefers embedded" `Quick
            test_resolve_commit_prefers_embedded;
          Alcotest.test_case "resolve commit details prefers embedded binary"
            `Quick test_resolve_commit_details_prefers_embedded_binary;
          Alcotest.test_case "resolve commit falls back to probe" `Quick
            test_resolve_commit_uses_probe_when_embedded_missing;
          Alcotest.test_case
            "resolve commit details marks repo head fallback" `Quick
            test_resolve_commit_details_marks_repo_head_fallback;
          Alcotest.test_case
            "binary identity ignores mismatched ambient checkout" `Quick
            test_binary_identity_ignores_mismatched_ambient_checkout;
          Alcotest.test_case
            "binary identity survives without checkout" `Quick
            test_binary_identity_survives_without_checkout;
          Alcotest.test_case "current started_at stable" `Quick
            test_current_started_at_is_stable;
          Alcotest.test_case "executable provenance requires exact identity" `Quick
            test_executable_provenance_requires_exact_identity;
          Alcotest.test_case "executable provenance rejects mismatches" `Quick
            test_executable_provenance_rejects_mismatches;
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
        ] );
    ]
