# task-238 bounded regression evidence

Source: `test/keeper_github_identity/test_keeper_github_identity.ml`
Commit: `aaff0e753eea072f2ad1eae402335c6999686bed`

```ocaml
let test_capture_timeout_reaps_hung_status_probe () =
  with_temp_base @@ fun base_path ->
  let hanging_gh =
    write_executable_script base_path "hanging-gh" hanging_gh_script
  in
  let started_at = Unix.gettimeofday () in
  let status, _, _ =
    Github.For_testing.run_capture
      ~timeout_sec:0.05
      ~env:(Unix.environment ())
      [ hanging_gh ]
  in
  let elapsed = Unix.gettimeofday () -. started_at in
  (match status with
   | Unix.WEXITED code ->
     Alcotest.(check int) "capture timeout status" 124 code
   | _ -> Alcotest.fail "capture timeout did not reap with exit 124");
  Alcotest.(check bool) "capture timeout is bounded" true (elapsed < 1.0)
;;

let test_inherited_timeout_reaps_hung_logout () =
  with_temp_base @@ fun base_path ->
  let hanging_gh =
    write_executable_script base_path "hanging-gh" hanging_gh_script
  in
  let started_at = Unix.gettimeofday () in
  let status =
    Github.For_testing.run_inherited
      ~timeout_sec:0.05
      ~env:(Unix.environment ())
      [ hanging_gh ]
  in
  let elapsed = Unix.gettimeofday () -. started_at in
  (match status with
   | Unix.WEXITED code ->
     Alcotest.(check int) "inherited timeout status" 124 code
   | _ -> Alcotest.fail "inherited timeout did not reap with exit 124");
  Alcotest.(check bool) "inherited timeout is bounded" true (elapsed < 1.0)
;;
```

Both tests execute a hanging executable with a 50ms bound and assert exit 124 plus sub-second completion.
