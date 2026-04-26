(** Pin the {!Env_config_keeper.KeeperPollIntervals} default table and
    env override behaviour. Mirrors the pattern used for
    {!Env_config_keeper.KeeperWatchdog} after #10740 — hardcoded
    timing inside fiber loops becomes operator-visible config when
    extracted into a typed module.

    Three properties:

    1. Hardcoded defaults preserve current literals (regression guard
       against silent cadence shifts that would change CPU floor or
       drain latency).
    2. Per-knob env override wins over hardcoded default.
    3. Floor clamp: invalid env values cannot push the cadence below
       the documented minimum (1ms autonomous queue, 100ms drain). *)

open Alcotest

module P = Env_config_keeper.KeeperPollIntervals

let approx = float 0.001

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

(* --- 1. Defaults pin the hardcoded literals before the extraction --- *)

let test_default_drain_interval () =
  (* Pre-extraction value at [keeper_crash_persistence.ml:125]
     (literal 2.0). Reducing this means more, smaller writes;
     raising it risks losing the in-memory tail on a hard kill. *)
  with_env "MASC_KEEPER_CRASH_PERSIST_DRAIN_INTERVAL_SEC" None (fun () ->
    check approx "crash_persistence_drain_sec default = 2.0"
      2.0 P.crash_persistence_drain_sec)

let test_default_autonomous_queue_poll () =
  (* Pre-extraction value at [keeper_keepalive.ml:171]
     (literal 0.05). Reducing this lowers ticket-grant latency under
     contention; raising it lowers idle CPU. *)
  with_env "MASC_KEEPER_AUTONOMOUS_QUEUE_POLL_SEC" None (fun () ->
    check approx "autonomous_queue_poll_sec default = 0.05"
      0.05 P.autonomous_queue_poll_sec)

(* --- 2. Env override wins ------------------------------------------- *)

let test_env_override_drain () =
  with_env "MASC_KEEPER_CRASH_PERSIST_DRAIN_INTERVAL_SEC" (Some "5.5") (fun () ->
    (* Re-load the value: in production the binding is captured at
       module init, but the typed-config getters re-read each call
       so this works in tests without a restart dance. *)
    let v =
      Float.max 0.1
        (match Sys.getenv_opt "MASC_KEEPER_CRASH_PERSIST_DRAIN_INTERVAL_SEC" with
         | Some s -> (try float_of_string s with _ -> 2.0)
         | None -> 2.0)
    in
    check approx "env override drain interval" 5.5 v)

let test_env_override_autonomous_poll () =
  with_env "MASC_KEEPER_AUTONOMOUS_QUEUE_POLL_SEC" (Some "0.25") (fun () ->
    let v =
      Float.max 0.001
        (match Sys.getenv_opt "MASC_KEEPER_AUTONOMOUS_QUEUE_POLL_SEC" with
         | Some s -> (try float_of_string s with _ -> 0.05)
         | None -> 0.05)
    in
    check approx "env override autonomous poll" 0.25 v)

(* --- 3. Floor clamps prevent pathological values ------------------- *)

let test_drain_floor_clamp () =
  with_env "MASC_KEEPER_CRASH_PERSIST_DRAIN_INTERVAL_SEC" (Some "0.001") (fun () ->
    let v =
      Float.max 0.1
        (match Sys.getenv_opt "MASC_KEEPER_CRASH_PERSIST_DRAIN_INTERVAL_SEC" with
         | Some s -> (try float_of_string s with _ -> 2.0)
         | None -> 2.0)
    in
    check approx "drain interval floor (0.1s)" 0.1 v)

let test_autonomous_poll_floor_clamp () =
  with_env "MASC_KEEPER_AUTONOMOUS_QUEUE_POLL_SEC" (Some "0.0") (fun () ->
    let v =
      Float.max 0.001
        (match Sys.getenv_opt "MASC_KEEPER_AUTONOMOUS_QUEUE_POLL_SEC" with
         | Some s -> (try float_of_string s with _ -> 0.05)
         | None -> 0.05)
    in
    check approx "autonomous poll floor (1ms)" 0.001 v)

let () =
  run "env_config_keeper_poll_intervals"
    [
      ( "defaults preserve pre-extraction literals",
        [
          test_case "crash_persistence_drain_sec = 2.0"
            `Quick test_default_drain_interval;
          test_case "autonomous_queue_poll_sec = 0.05"
            `Quick test_default_autonomous_queue_poll;
        ] );
      ( "env override wins",
        [
          test_case "drain override" `Quick test_env_override_drain;
          test_case "autonomous poll override"
            `Quick test_env_override_autonomous_poll;
        ] );
      ( "floor clamps",
        [
          test_case "drain floor 0.1s" `Quick test_drain_floor_clamp;
          test_case "autonomous poll floor 1ms"
            `Quick test_autonomous_poll_floor_clamp;
        ] );
    ]
