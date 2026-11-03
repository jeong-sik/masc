(** Pin the {!Env_config_keeper.KeeperAdmissionBounds} default table and env
    override behaviour. The admission path used to admit every ready selection
    in one durable queue snapshot, so a steady arrival rate became an unbounded
    backlog even while every Keeper stayed alive (#29365). These tests pin the
    bound and its clamp.

    Three properties:

    1. The default preserves the documented value (32 events).
    2. Per-knob env override wins over the default.
    3. The clamp keeps invalid env values inside [1, 256]. *)

open Alcotest

module B = Env_config_keeper.KeeperAdmissionBounds

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

(* --- 1. Default preserves the documented literal ------------------- *)

let test_default_max_events () =
  with_env "MASC_KEEPER_ADMISSION_MAX_EVENTS" None (fun () ->
    check int "max_events default = 32" 32 (B.max_events ()))
;;

(* --- 2. Env override wins ------------------------------------------ *)

let test_env_override_max_events () =
  with_env "MASC_KEEPER_ADMISSION_MAX_EVENTS" (Some "7") (fun () ->
    check int "env override max_events" 7 (B.max_events ()))
;;

(* --- 3. Clamps keep pathological values inside the range ----------- *)

let test_max_events_floor_clamp () =
  with_env "MASC_KEEPER_ADMISSION_MAX_EVENTS" (Some "0") (fun () ->
    check int "max_events floor (1)" 1 (B.max_events ()))
;;

let test_max_events_ceiling_clamp () =
  with_env "MASC_KEEPER_ADMISSION_MAX_EVENTS" (Some "100000") (fun () ->
    check int "max_events ceiling (256)" 256 (B.max_events ()))
;;

let () =
  run
    "env_config_keeper_admission_bounds"
    [
      ( "defaults preserve documented literals",
        [ test_case "max_events = 32" `Quick test_default_max_events ] );
      ( "env override wins",
        [ test_case "max_events override" `Quick test_env_override_max_events ]
      );
      ( "clamps",
        [
          test_case "max_events floor 1" `Quick test_max_events_floor_clamp;
          test_case "max_events ceiling 256" `Quick test_max_events_ceiling_clamp;
        ] );
    ]
;;
