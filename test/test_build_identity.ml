open Masc_mcp

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

let test_current_started_at_is_stable () =
  let first = Build_identity.current () in
  Unix.sleepf 0.01;
  let second = Build_identity.current () in
  Alcotest.(check string) "stable started_at" first.started_at second.started_at;
  Alcotest.(check bool) "uptime monotonic" true
    (second.uptime_seconds >= first.uptime_seconds)

let () =
  Alcotest.run "build_identity"
    [
      ( "identity",
        [
          Alcotest.test_case "resolve commit prefers env" `Quick
            test_resolve_commit_prefers_env;
          Alcotest.test_case "resolve commit falls back to probe" `Quick
            test_resolve_commit_uses_probe_when_env_missing;
          Alcotest.test_case "current started_at stable" `Quick
            test_current_started_at_is_stable;
        ] );
    ]
