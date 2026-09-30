let () = Candle_status.install_appraiser_check (fun () -> Ok ())

(** Whether Candle is on right now (RFC-goal-candle-ledger 3.9), and the one read
    of the ledger a server start makes. *)

open Alcotest

let temp_dir () =
  let path = Filename.temp_file "candle_status_" "" in
  Sys.remove path;
  Unix.mkdir path 0o755;
  path
;;

let rec rm_rf path =
  if Sys.file_exists path
  then
    if Sys.is_directory path
    then (
      Array.iter (fun entry -> rm_rf (Filename.concat path entry)) (Sys.readdir path);
      Unix.rmdir path)
    else Sys.remove path
;;

let with_base_path f =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_path = temp_dir () in
  Fun.protect ~finally:(fun () -> rm_rf base_path) (fun () -> f base_path)
;;

let rec mkdir_p dir =
  if not (Sys.file_exists dir)
  then (
    mkdir_p (Filename.dirname dir);
    Unix.mkdir dir 0o755)
;;

let write_file path text =
  mkdir_p (Filename.dirname path);
  Out_channel.with_open_bin path (fun oc -> Out_channel.output_string oc text)
;;

(* The tests write candle.toml, so they stop if the resolver points anywhere but
   the temporary workspace. *)
let candle_toml base_path =
  let path = Config_dir_resolver.candle_toml_path_for_base_path ~base_path in
  if not (String.starts_with ~prefix:base_path path)
  then failf "the candle.toml path %s is outside the test workspace" path;
  path
;;

let enable base_path = write_file (candle_toml base_path) {|[payout]
weight_max = 10
deduction_rate = 10
deduction_floor = 200
[payout.grades_milli]
trivial = 1000
small = 2000
medium = 3000
large = 4000
epic = 5000
|}

let row : Candle_event.t =
  let time text = Result.get_ok (Candle_time.of_rfc3339 text) in
  { at = time "2026-09-01T00:00:00Z"
  ; body =
      Candle_event.Snapshot
        { goal_id = "goal-1"
        ; request_id = "req-1"
        ; verification_run_id = "run-1"
        ; criterion_revision = "rev-1"
        ; passed_at = time "2026-08-31T00:00:00Z"
        ; goal_created_at = time "2026-08-01T00:00:00Z"
        ; due_date = None
        ; title = ""
        ; metric = None
        ; target_value = None
        ; linked_task_ids = []
        }
  }
;;

let is_enabled = function
  | Candle_config.Enabled _ -> true
  | Candle_config.Off | Candle_config.Disabled _ -> false
;;

let reason = function
  | Candle_config.Disabled { reason } -> reason
  | Candle_config.Off | Candle_config.Enabled _ -> fail "expected a disabled answer"
;;

let test_no_candle_toml_is_off_and_touches_nothing () =
  with_base_path
  @@ fun base_path ->
  check bool "off" true (Candle_status.current ~base_path = Candle_config.Off);
  Candle_status.report_at_start ~base_path;
  check bool "no ledger" false (Sys.file_exists (Candle_ledger.path ~base_path));
  check bool "no lock file either: off does not recover a ledger" false
    (Sys.file_exists (Fs_compat.private_jsonl_lock_path (Candle_ledger.path ~base_path)))
;;

(* candle.toml is read on every call, so turning Candle on, breaking the file and
   removing it each show at once, with no restart. *)
let test_the_answer_follows_candle_toml_on_every_call () =
  with_base_path
  @@ fun base_path ->
  check bool "off" true (Candle_status.current ~base_path = Candle_config.Off);
  enable base_path;
  check bool "enabled" true (is_enabled (Candle_status.current ~base_path));
  write_file (candle_toml base_path) "half_life_hours = 72\n";
  check bool "disabled" true
    (match Candle_status.current ~base_path with
     | Candle_config.Disabled _ -> true
     | Candle_config.Off | Candle_config.Enabled _ -> false);
  Sys.remove (candle_toml base_path);
  check bool "off again" true (Candle_status.current ~base_path = Candle_config.Off)
;;

let test_a_candle_toml_that_does_not_read_is_disabled_with_its_reason () =
  with_base_path
  @@ fun base_path ->
  write_file (candle_toml base_path) "half_life_hours = 72\n";
  check bool "names the key" true (String_util.contains_substring (reason (Candle_status.current ~base_path)) "half_life_hours");
  Candle_status.report_at_start ~base_path
;;

(* A server that died in the middle of an append leaves a row without its
   newline. The start-up read cuts it, so the first Goal that moves finds a
   ledger that reads. *)
let test_the_start_up_read_cuts_a_torn_tail () =
  with_base_path
  @@ fun base_path ->
  enable base_path;
  (match Candle_ledger.update ~base_path (fun _ -> Ok ([ row ], ())) with
   | Ok () -> ()
   | Error error -> failf "%s" (Candle_ledger.update_error_to_string Fun.id error));
  write_file
    (Candle_ledger.path ~base_path)
    (In_channel.with_open_bin (Candle_ledger.path ~base_path) In_channel.input_all
     ^ {|{"kind":"snapshot","at":"2026|});
  (match Candle_ledger.read ~base_path with
   | Error _ -> ()
   | Ok _ -> fail "the torn tail read as a row");
  Candle_status.report_at_start ~base_path;
  match Candle_ledger.read ~base_path with
  | Ok view -> check int "the whole row stays" 1 (List.length (Candle_ledger.events view))
  | Error error -> failf "%s" (Candle_ledger.read_error_to_string error)
;;

let test_a_ledger_that_does_not_read_disables_candle_until_it_is_repaired () =
  with_base_path
  @@ fun base_path ->
  enable base_path;
  write_file (Candle_ledger.path ~base_path) "not a row\n";
  check bool "disabled" false (is_enabled (Candle_status.current ~base_path));
  Candle_status.report_at_start ~base_path;
  check bool "still disabled: a failed read is not remembered as a good one" false
    (is_enabled (Candle_status.current ~base_path));
  check string "the ledger is left as it was" "not a row\n"
    (In_channel.with_open_bin (Candle_ledger.path ~base_path) In_channel.input_all);
  write_file (Candle_ledger.path ~base_path) "";
  check bool "enabled after the repair" true (is_enabled (Candle_status.current ~base_path))
;;

let () =
  run
    "candle_status"
    [ ( "current"
      , [ test_case "no candle.toml is off and touches nothing" `Quick
            test_no_candle_toml_is_off_and_touches_nothing
        ; test_case "the answer follows candle.toml on every call" `Quick
            test_the_answer_follows_candle_toml_on_every_call
        ; test_case "a candle.toml that does not read is disabled with its reason" `Quick
            test_a_candle_toml_that_does_not_read_is_disabled_with_its_reason
        ; test_case "the start-up read cuts a torn tail" `Quick
            test_the_start_up_read_cuts_a_torn_tail
        ; test_case "a ledger that does not read disables candle until it is repaired" `Quick
            test_a_ledger_that_does_not_read_disables_candle_until_it_is_repaired
        ] )
    ]
;;
