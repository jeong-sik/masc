(** Pin the {!Env_config_keeper.KeeperAdmissionBounds} default, its runtime
    file value and its clamp. The admission path used to admit every ready
    selection in one durable queue snapshot, so a steady arrival rate became an
    unbounded backlog even while every Keeper stayed alive (#29365).

    The bound is a runtime-file setting, [turn.admission_max_events]: the
    loader declares its name file-owned and puts the file's value in the boot
    store, and the process environment does not reach the reader (#50889).

    Four properties of the reader:

    1. Without a file value the documented default applies (32 events).
    2. The file value wins over the default.
    3. A value in the process environment does not reach the reader.
    4. The reader stays inside [1, 256] whatever the store holds.

    The loader's side of the same setting, the [turn.admission_max_events] key
    and the load that refuses a value outside the range, is in
    [test_file_owned_settings_ignore_env]. *)

open Alcotest

module B = Env_config_keeper.KeeperAdmissionBounds

let name = B.max_events_env_key

(* The name declared file-owned, as the loader declares it, and [value], when
   there is one, in the boot store. *)
let with_file_value value f =
  Config_boot_overrides.reset_for_tests ();
  Config_boot_overrides.declare_file_owned [ name ];
  Option.iter (Config_boot_overrides.set name) value;
  Fun.protect ~finally:Config_boot_overrides.reset_for_tests f
;;

let with_process_env value f =
  let inherited = Sys.getenv_opt name in
  Unix.putenv name value;
  Fun.protect
    ~finally:(fun () -> Unix.putenv name (Option.value inherited ~default:""))
    f
;;

(* --- 1. Default preserves the documented literal ------------------- *)

let test_default_max_events () =
  with_file_value None (fun () ->
    check int "max_events default = 32" 32 (B.max_events ());
    check int "the exposed default is the one the reader uses" 32 B.max_events_default)
;;

(* --- 2. The runtime file's value wins ------------------------------ *)

let test_file_value_max_events () =
  with_file_value (Some "7") (fun () ->
    check int "file value max_events" 7 (B.max_events ()))
;;

(* --- 3. The process environment is not an input -------------------- *)

let test_process_env_does_not_reach_max_events () =
  with_process_env "9" (fun () ->
    with_file_value None (fun () ->
      check int "the default, not the environment's 9" 32 (B.max_events ()));
    with_file_value (Some "7") (fun () ->
      check int "the file value, not the environment's 9" 7 (B.max_events ())))
;;

(* --- 4. The reader stays inside the range --------------------------- *)

(* The loader refuses 0 and 100000 before they reach the store, so a server
   never holds them. These cases put them there directly: the reader's own
   result stays inside the range whatever the store holds. *)

let test_max_events_floor_clamp () =
  with_file_value (Some "0") (fun () ->
    check int "max_events floor (1)" 1 (B.max_events ());
    check int "the exposed floor is the one the reader clamps to" 1 B.max_events_floor)
;;

let test_max_events_ceiling_clamp () =
  with_file_value (Some "100000") (fun () ->
    check int "max_events ceiling (256)" 256 (B.max_events ());
    check int "the exposed ceiling is the one the reader clamps to" 256 B.max_events_ceiling)
;;

let () =
  run
    "env_config_keeper_admission_bounds"
    [
      ( "defaults preserve documented literals",
        [ test_case "max_events = 32" `Quick test_default_max_events ] );
      ( "the runtime file is the input",
        [
          test_case "file value wins" `Quick test_file_value_max_events;
          test_case "process env does not reach the reader" `Quick
            test_process_env_does_not_reach_max_events;
        ] );
      ( "clamps",
        [
          test_case "max_events floor 1" `Quick test_max_events_floor_clamp;
          test_case "max_events ceiling 256" `Quick test_max_events_ceiling_clamp;
        ] );
    ]
;;
