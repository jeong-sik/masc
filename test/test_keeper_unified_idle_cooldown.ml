open Alcotest

module WO = Masc.Keeper_world_observation

let set_runtime_param key json =
  match Masc.Runtime_params.set_by_key key json with
  | Ok () -> ()
  | Error msg -> failf "set runtime param %s failed: %s" key msg
;;

let clear_runtime_param key =
  match Masc.Runtime_params.clear_by_key key with
  | Ok () -> ()
  | Error msg -> failf "clear runtime param %s failed: %s" key msg
;;

let with_runtime_param key json f =
  Fun.protect
    ~finally:(fun () -> clear_runtime_param key)
    (fun () ->
       set_runtime_param key json;
       f ())
;;

let test_effective_cooldown_no_decay_within_base () =
  let result =
    WO.effective_scheduled_autonomous_cooldown ~base_cooldown:1800 ~since_last:900 ()
  in
  check int "no decay within base" 1800 result
;;

let test_effective_cooldown_at_boundary () =
  let result =
    WO.effective_scheduled_autonomous_cooldown ~base_cooldown:1800 ~since_last:1800 ()
  in
  check int "no decay at boundary" 1800 result
;;

let test_effective_cooldown_first_decay () =
  let result =
    WO.effective_scheduled_autonomous_cooldown ~base_cooldown:1800 ~since_last:3600 ()
  in
  check int "first decay halves cooldown" 900 result
;;

let test_effective_cooldown_second_decay () =
  let result =
    WO.effective_scheduled_autonomous_cooldown ~base_cooldown:1800 ~since_last:5400 ()
  in
  check int "second decay quarters cooldown" 450 result
;;

let test_effective_cooldown_floor () =
  let result =
    WO.effective_scheduled_autonomous_cooldown ~base_cooldown:1800 ~since_last:10800 ()
  in
  check int "decay floors at min_cooldown" 300 result
;;

let test_effective_cooldown_max_int () =
  let result =
    WO.effective_scheduled_autonomous_cooldown ~base_cooldown:1800 ~since_last:max_int ()
  in
  check int "max_int hits floor" 300 result
;;

let test_noop_backoff_doubles_cooldown () =
  let result =
    WO.effective_scheduled_autonomous_cooldown
      ~base_cooldown:1800
      ~since_last:900
      ~consecutive_noop_count:1
      ()
  in
  check int "1 noop doubles effective base" 3600 result
;;

let test_noop_backoff_quadruples_cooldown () =
  let result =
    WO.effective_scheduled_autonomous_cooldown
      ~base_cooldown:1800
      ~since_last:900
      ~consecutive_noop_count:2
      ()
  in
  check int "2 noops quadruples effective base" 7200 result
;;

let test_noop_backoff_caps_at_4x () =
  let result =
    WO.effective_scheduled_autonomous_cooldown
      ~base_cooldown:1800
      ~since_last:900
      ~consecutive_noop_count:5
      ()
  in
  check int "noop backoff caps at 4x" 7200 result
;;

let test_noop_backoff_cap_uses_runtime_policy () =
  with_runtime_param "keeper.proactive.noop_backoff_max_shift" (`Int 1) (fun () ->
    let result =
      WO.effective_scheduled_autonomous_cooldown
        ~base_cooldown:1800
        ~since_last:900
        ~consecutive_noop_count:5
        ()
    in
    check int "noop backoff cap comes from runtime policy" 3600 result)
;;

let test_idle_decay_period_cap_uses_runtime_policy () =
  with_runtime_param "keeper.proactive.idle_decay_max_periods" (`Int 1) (fun () ->
    let result =
      WO.effective_scheduled_autonomous_cooldown
        ~base_cooldown:1800
        ~since_last:10800
        ()
    in
    check int "idle decay period cap comes from runtime policy" 900 result)
;;

let test_noop_backoff_zero_noops_unchanged () =
  let result =
    WO.effective_scheduled_autonomous_cooldown
      ~base_cooldown:1800
      ~since_last:900
      ~consecutive_noop_count:0
      ()
  in
  check int "0 noops = no backoff" 1800 result
;;

let () =
  run
    "keeper unified idle cooldown"
    [ ( "idle_decay"
      , [ test_case
            "idle decay: no decay within base"
            `Quick
            test_effective_cooldown_no_decay_within_base
        ; test_case "idle decay: at boundary" `Quick test_effective_cooldown_at_boundary
        ; test_case "idle decay: first decay" `Quick test_effective_cooldown_first_decay
        ; test_case "idle decay: second decay" `Quick test_effective_cooldown_second_decay
        ; test_case "idle decay: floor" `Quick test_effective_cooldown_floor
        ; test_case "idle decay: max_int" `Quick test_effective_cooldown_max_int
        ; test_case
            "noop backoff: doubles cooldown"
            `Quick
            test_noop_backoff_doubles_cooldown
        ; test_case
            "noop backoff: quadruples cooldown"
            `Quick
            test_noop_backoff_quadruples_cooldown
        ; test_case "noop backoff: caps at 4x" `Quick test_noop_backoff_caps_at_4x
        ; test_case
            "noop backoff: cap comes from runtime policy"
            `Quick
            test_noop_backoff_cap_uses_runtime_policy
        ; test_case
            "idle decay: period cap comes from runtime policy"
            `Quick
            test_idle_decay_period_cap_uses_runtime_policy
        ; test_case
            "noop backoff: zero noops unchanged"
            `Quick
            test_noop_backoff_zero_noops_unchanged
        ] )
    ]
;;
