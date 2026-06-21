(** Pin the default-on semantics and disable knob of
    {!Env_config_runtime.Keeper_max_turn_watchdog}.

    The PR flips the default from opt-in (0.0 / disabled) to default-on
    (1800.0). These tests make that behavioral change explicit and guard
    against accidental regression to the old opt-in default. *)

open Alcotest

module W = Env_config_runtime.Keeper_max_turn_watchdog

let env_key = "MASC_KEEPER_MAX_TURN_WATCHDOG_TIMEOUT_SEC"

let with_env key value f =
  let prev = Sys.getenv_opt key in
  (match value with
   | Some v -> Unix.putenv key v
   | None -> Unix.putenv key "");
  Fun.protect
    ~finally:(fun () ->
      match prev with
      | Some v -> Unix.putenv key v
      | None -> Unix.putenv key "")
    f
;;

let test_default_is_on () =
  with_env env_key None (fun () ->
    check (option (float 0.001)) "unset env returns Some 1800.0"
      (Some 1800.0)
      (W.timeout_sec_opt ()))
;;

let test_zero_disables () =
  with_env env_key (Some "0") (fun () ->
    check (option (float 0.001)) "env=0 disables watchdog"
      None
      (W.timeout_sec_opt ()))
;;

let test_positive_override () =
  with_env env_key (Some "600.0") (fun () ->
    check (option (float 0.001)) "env override wins"
      (Some 600.0)
      (W.timeout_sec_opt ()))
;;

let test_negative_disables () =
  with_env env_key (Some "-1.0") (fun () ->
    check (option (float 0.001)) "negative value disables watchdog"
      None
      (W.timeout_sec_opt ()))
;;

let () =
  run "env_config_keeper_max_turn_watchdog"
    [
      ( "default-on semantics",
        [
          test_case "unset returns Some 1800.0" `Quick test_default_is_on;
        ] );
      ( "disable knob",
        [
          test_case "env=0 returns None" `Quick test_zero_disables;
          test_case "negative returns None" `Quick test_negative_disables;
        ] );
      ( "env override",
        [
          test_case "positive override returns Some" `Quick test_positive_override;
        ] );
    ]
;;
