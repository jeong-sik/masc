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

let test_other_errnos_do_not_become_storage_facts () =
  Disk.reset_for_tests ();
  List.iter
    (fun code -> Disk.note_exception ~site:"test.other" (Unix.Unix_error (code, "write", "fixture")))
    [ Unix.EMFILE; Unix.ENFILE; Unix.EACCES; Unix.EAGAIN; Unix.EUNKNOWNERR 4242 ];
  check int "other errnos ignored" 0
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

let make_snapshot ~available_bytes ~available_percent =
  Disk.Snapshot
    { path = "/tmp"
    ; filesystem = "statvfs"
    ; total_bytes = 100 * 1024 * 1024 * 1024
    ; used_bytes = (100 * 1024 * 1024 * 1024) - available_bytes
    ; available_bytes
    ; capacity_percent = 100.0 -. available_percent
    ; available_percent
    ; mounted_on = "/tmp"
    }
;;

let test_classify_health_thresholds_and_enospc_recency () =
  let gib = 1024 * 1024 * 1024 in
  let healthy_snap = make_snapshot ~available_bytes:(50 * gib) ~available_percent:50.0 in
  let low_snap = make_snapshot ~available_bytes:(10 * gib) ~available_percent:10.0 in
  let crit_snap = make_snapshot ~available_bytes:(1 * gib) ~available_percent:4.0 in
  let check_health label expected actual =
    check string label
      (Disk.health_status_to_string expected)
      (Disk.health_status_to_string actual)
  in
  check_health "healthy snapshot" Disk.Healthy
    (Disk.classify_health ~now:10_000.0 ~enospc_observations:0 ~last_enospc_ts:None healthy_snap);
  check_health "low space snapshot" Disk.Low_space
    (Disk.classify_health ~now:10_000.0 ~enospc_observations:0 ~last_enospc_ts:None low_snap);
  check_health "critical space snapshot" Disk.Critical_space
    (Disk.classify_health ~now:10_000.0 ~enospc_observations:0 ~last_enospc_ts:None crit_snap);
  check_health "probe error" Disk.Probe_unavailable
    (Disk.classify_health ~now:10_000.0 ~enospc_observations:0 ~last_enospc_ts:None (Disk.Probe_error "enoent"));
  check_health "recent ENOSPC is exhausted" Disk.Exhausted_enospc
    (Disk.classify_health ~now:10_000.0 ~enospc_observations:1 ~last_enospc_ts:(Some 9_900.0) healthy_snap);
  check_health "stale ENOSPC recovers when disk is healthy" Disk.Healthy
    (Disk.classify_health
       ~now:10_000.0
       ~enospc_observations:2
       ~last_enospc_ts:(Some (10_000.0 -. Disk.enospc_recent_window_sec -. 1.0))
       healthy_snap);
  check_health "undated ENOSPC does not permanently pin healthy disk" Disk.Healthy
    (Disk.classify_health ~now:10_000.0 ~enospc_observations:2 ~last_enospc_ts:None healthy_snap)
;;

let test_snapshot_json_recovers_after_enospc_window () =
  Disk.reset_for_tests ();
  Eio_main.run
  @@ fun _env ->
  Eio_guard.enable ();
  Fun.protect
    ~finally:Eio_guard.disable
    (fun () ->
      let root = Filename.get_temp_dir_name () in
      Disk.note_exception
        ~site:"test.recency"
        (Unix.Unix_error (Unix.ENOSPC, "write", "fixture"));
      let open Yojson.Safe.Util in
      let now = Time_compat.now () in
      let during_window = Disk.snapshot_json ~now:(now +. 5.0) ~masc_root:root () in
      check string "recent ENOSPC rollup status is error" "error"
        (during_window |> member "status" |> to_string);
      check string "recent ENOSPC health_status" "exhausted_enospc"
        (during_window |> member "health_status" |> to_string);
      check bool "recent ENOSPC requires operator action" true
        (during_window |> member "operator_action_required" |> to_bool);
      let after_window =
        Disk.snapshot_json
          ~now:(now +. Disk.enospc_recent_window_sec +. 60.0)
          ~masc_root:root
          ()
      in
      check bool "stale ENOSPC clears exhausted_enospc without restart" true
        (not (String.equal (after_window |> member "health_status" |> to_string) "exhausted_enospc")))
;;

let () =
  run
    "keeper_disk_pressure_observation"
    [ ( "typed errors"
      , [ test_case "ENOSPC" `Quick test_typed_enospc_is_observed
        ; test_case "untyped text ignored" `Quick test_error_text_does_not_become_storage_fact
        ; test_case "other errnos ignored" `Quick test_other_errnos_do_not_become_storage_facts
        ] )
    ; ( "snapshot"
      , [ test_case "raw facts only" `Quick test_snapshot_contains_raw_facts_without_admission
        ; test_case "health thresholds and ENOSPC recency" `Quick
            test_classify_health_thresholds_and_enospc_recency
        ; test_case "snapshot recovers after ENOSPC recency window" `Quick
            test_snapshot_json_recovers_after_enospc_window
        ] )
    ]
;;
