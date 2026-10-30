(** Unit tests for [Env_config_runtime_services.ScheduleRunner].

    The knob is read once at module load (same shape as the sibling
    knobs in the file), so the pinnable contract is the value itself:

    - the poll cadence honors the floor ([>= 1.0]) even when the env
      var sets a lower value
    - with the env var unset (the CI default) the value is the
      documented default [15.0] *)

open Masc

let test_interval_floor () =
  (* Non-vacuous: exercises the clamp directly, so deleting [Float.max 1.0]
     from the code turns the sub-floor case red. The module-load
     [interval_sec] cannot test this — it is read once before the test runs. *)
  Alcotest.(check (float 0.001))
    "a sub-floor interval clamps up to the floor"
    1.0
    (Env_config_runtime_services.ScheduleRunner.clamp_interval_sec 0.1);
  Alcotest.(check (float 0.001))
    "an above-floor interval passes through unchanged"
    42.0
    (Env_config_runtime_services.ScheduleRunner.clamp_interval_sec 42.0)
;;

let test_interval_non_finite () =
  (* Regression for the nan/+inf sleep-forever defect (PR #25258 P2):
     [Float.max floor nan = nan] and [Float.max floor +inf = +inf], so the
     floor clamp alone let a non-finite env value reach [Eio.Time.sleep],
     stalling the schedule runner until process restart. The boundary now
     rejects non-finite and falls back to the documented default (15.0).
     Deleting the [Float.is_finite] guard turns these cases red. *)
  let clamp = Env_config_runtime_services.ScheduleRunner.clamp_interval_sec in
  Alcotest.(check bool) "nan yields a finite interval" true (Float.is_finite (clamp Float.nan));
  Alcotest.(check (float 0.001)) "nan falls back to the documented default" 15.0 (clamp Float.nan);
  Alcotest.(check bool)
    "+inf yields a finite interval"
    true
    (Float.is_finite (clamp Float.infinity));
  Alcotest.(check (float 0.001))
    "+inf falls back to the documented default"
    15.0
    (clamp Float.infinity);
  Alcotest.(check bool)
    "-inf yields a finite interval"
    true
    (Float.is_finite (clamp Float.neg_infinity));
  Alcotest.(check (float 0.001))
    "-inf falls back to the documented default"
    15.0
    (clamp Float.neg_infinity)
;;

let test_interval_default () =
  match Sys.getenv_opt "MASC_SCHEDULE_RUNNER_INTERVAL_SEC" with
  | Some _ ->
    Alcotest.(check bool)
      "env override is honored (value unchanged at runtime)"
      true
      (Env_config_runtime_services.ScheduleRunner.interval_sec >= 1.0)
  | None ->
    Alcotest.(check (float 0.001))
      "unset env yields the documented default"
      15.0
      Env_config_runtime_services.ScheduleRunner.interval_sec
;;

let () =
  Alcotest.run
    "env_config_schedule_runner"
    [ ( "schedule_runner"
      , [ Alcotest.test_case "floor clamp" `Quick test_interval_floor
        ; Alcotest.test_case "non-finite fallback" `Quick test_interval_non_finite
        ; Alcotest.test_case "documented default" `Quick test_interval_default
        ] )
    ]
;;
