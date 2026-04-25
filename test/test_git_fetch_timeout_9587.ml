(* test/test_git_fetch_timeout_9587.ml

   #9587: lock the git_fetch_timeout_sec contract.  The previous
   hardcoded 30s budget at Coord_worktree.run_argv_exit timed out
   legitimately slow [git fetch origin] inside the Docker keeper
   sandbox; the fix introduces a configurable timeout via
   [MASC_GIT_FETCH_TIMEOUT_SEC] with a 120s default and a 10s
   floor (so a [0] override does not silently disable the cap). *)

open Masc_mcp

let with_env key value f =
  let prev = Sys.getenv_opt key in
  (match value with
   | Some v -> Unix.putenv key v
   | None ->
       (match prev with
        | Some _ -> Unix.putenv key ""
        | None -> ()));
  Fun.protect
    ~finally:(fun () ->
      match prev with
      | Some v -> Unix.putenv key v
      | None -> Unix.putenv key "")
    f

let env_key = "MASC_GIT_FETCH_TIMEOUT_SEC"

let test_default () =
  with_env env_key None (fun () ->
    Alcotest.(check (float 0.0001))
      "default budget = 120s"
      120.0
      (Env_config_core.git_fetch_timeout_sec ()))

let test_env_override () =
  with_env env_key (Some "300") (fun () ->
    Alcotest.(check (float 0.0001))
      "env override 300s honoured"
      300.0
      (Env_config_core.git_fetch_timeout_sec ()))

let test_env_override_floats () =
  with_env env_key (Some "60.5") (fun () ->
    Alcotest.(check (float 0.0001))
      "fractional seconds honoured"
      60.5
      (Env_config_core.git_fetch_timeout_sec ()))

let test_floor_clamps_zero () =
  (* MASC_GIT_FETCH_TIMEOUT_SEC=0 was the most plausible footgun
     setting (operator trying to "disable" the cap).  Floor must
     keep a non-trivial budget so the call cannot block forever. *)
  with_env env_key (Some "0") (fun () ->
    Alcotest.(check (float 0.0001))
      "floor 10s prevents zero-disable"
      10.0
      (Env_config_core.git_fetch_timeout_sec ()))

let test_floor_clamps_negative () =
  with_env env_key (Some "-5") (fun () ->
    Alcotest.(check (float 0.0001))
      "negative override clamped to floor"
      10.0
      (Env_config_core.git_fetch_timeout_sec ()))

let test_invalid_env_falls_back_to_default () =
  with_env env_key (Some "not-a-number") (fun () ->
    Alcotest.(check (float 0.0001))
      "garbage env reverts to default"
      120.0
      (Env_config_core.git_fetch_timeout_sec ()))

let () =
  Alcotest.run "git_fetch_timeout_9587"
    [
      ( "defaults",
        [
          Alcotest.test_case "default 120s" `Quick test_default;
        ] );
      ( "env override",
        [
          Alcotest.test_case "300s" `Quick test_env_override;
          Alcotest.test_case "fractional" `Quick test_env_override_floats;
        ] );
      ( "floor",
        [
          Alcotest.test_case "zero clamped" `Quick test_floor_clamps_zero;
          Alcotest.test_case "negative clamped" `Quick test_floor_clamps_negative;
        ] );
      ( "robustness",
        [
          Alcotest.test_case "invalid env falls back" `Quick
            test_invalid_env_falls_back_to_default;
        ] );
    ]
