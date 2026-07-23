(** Observation-only tests for [Keeper_disk_pressure]. *)

open Alcotest

module Disk = Keeper_disk_pressure

let member_int name fields =
  match List.assoc_opt name fields with
  | Some (`Int value) -> value
  | Some json -> failf "%s expected int, got %s" name (Yojson.Safe.to_string json)
  | None -> failf "%s missing" name
;;

let test_typed_enospc_is_observed () =
  Disk.reset_for_tests ();
  Disk.note_exception
    ~site:"test.disk"
    (Unix.Unix_error (Unix.ENOSPC, "write", "fixture"));
  let fields = Disk.observation_fields () in
  check int "ENOSPC count" 1
    (member_int "storage_space_exhaustion_observations_total" fields);
  check string "mode" "observation_only"
    (match List.assoc "mode" fields with
     | `String value -> value
     | json -> failf "mode expected string, got %s" (Yojson.Safe.to_string json))
;;

let test_error_text_does_not_become_storage_fact () =
  Disk.reset_for_tests ();
  Disk.note_exception ~site:"test.text" (Failure "no space left on device");
  check int "untyped text ignored" 0
    (member_int "storage_space_exhaustion_observations_total" (Disk.observation_fields ()))
;;

let test_snapshot_contains_raw_facts_without_admission () =
  Disk.reset_for_tests ();
  Eio_main.run
  @@ fun _env ->
  Eio_guard.enable ();
  Fun.protect
    ~finally:Eio_guard.disable
    (fun () ->
      let root = Filename.get_temp_dir_name () in
      let json = Disk.snapshot_json ~masc_root:root () in
      let open Yojson.Safe.Util in
      check string "mode" "observation_only" (json |> member "mode" |> to_string);
      check string "root" root (json |> member "masc_root" |> to_string);
      check bool "filesystem projection present" true (json |> member "filesystem" <> `Null);
      check bool "no admission" true (json |> member "admission" = `Null);
      check bool "no active breaker" true (json |> member "active" = `Null);
      check bool "no free-space floor" true (json |> member "min_free_bytes" = `Null))
;;

let () =
  run
    "keeper_disk_pressure_observation"
    [ ( "typed errors"
      , [ test_case "ENOSPC" `Quick test_typed_enospc_is_observed
        ; test_case "untyped text ignored" `Quick test_error_text_does_not_become_storage_fact
        ] )
    ; "snapshot", [ test_case "raw facts only" `Quick test_snapshot_contains_raw_facts_without_admission ]
    ]
;;
