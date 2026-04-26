(* test/test_cdal_ledger_health_10115.ml

   #10115: the cdal_verdict writer pipeline went 12 days dormant in
   production while the reader gate kept firing "no verdict found"
   advisories whose WARN message misdirected the operator toward
   [MASC_CDAL_VERDICT_LOOKUP_LIMIT].  The lookup limit was never
   the cause — the writer never ran.  This test pins the new
   diagnosis surface:

     1. [ledger_health_report] returns [latest_mtime=None] and
        [total_files=0] for an empty / nonexistent base_dir.
     2. After writing one file, [latest_mtime] reflects that
        file's mtime and [age_seconds] is non-negative.
     3. [log_ledger_health_warn_if_stale] returns the same shape
        as [ledger_health_report] (caller can keep it for metrics).
     4. The empty-ledger path yields a report a caller can detect
        without parsing log lines. *)

let () =
  let dir =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "masc-test-cdal-ledger-10115-%06x" (Random.bits ()))
  in
  Unix.putenv "MASC_BASE_PATH" dir
;;

module G = Masc_mcp.Cdal_verdict_gate

let with_temp_base_dir f =
  let dir =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "cdal-ledger-test-%06x" (Random.bits ()))
  in
  Unix.mkdir dir 0o755;
  let cleanup () =
    let rec rm_rf path =
      if Sys.is_directory path
      then (
        Array.iter (fun name -> rm_rf (Filename.concat path name)) (Sys.readdir path);
        Unix.rmdir path)
      else Sys.remove path
    in
    try rm_rf dir with
    | _ -> ()
  in
  Fun.protect ~finally:cleanup (fun () -> f dir)
;;

let touch_jsonl ~base_dir ~month ~day =
  let month_dir = Filename.concat base_dir month in
  (try Unix.mkdir month_dir 0o755 with
   | Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  let path = Filename.concat month_dir (day ^ ".jsonl") in
  let oc = open_out path in
  output_string oc "{}\n";
  close_out oc;
  path
;;

(* Empty / nonexistent base_dir: report total_files=0 + no mtime. *)
let test_empty_base_dir_no_files () =
  let dir = "/tmp/cdal-test-nonexistent-" ^ string_of_int (Random.bits ()) in
  (* Don't mkdir — we want the nonexistent-dir branch. *)
  let report = G.ledger_health_report ~base_dir:dir () in
  Alcotest.(check int) "no files reported for nonexistent dir" 0 report.total_files;
  Alcotest.(check bool) "latest_mtime is None" true (report.latest_mtime = None);
  Alcotest.(check bool) "age_seconds is None" true (report.age_seconds = None);
  Alcotest.(check string) "base_dir round-trips" dir report.base_dir
;;

(* Empty existing dir: no jsonl files = same shape as nonexistent. *)
let test_existing_dir_with_no_jsonl () =
  with_temp_base_dir
  @@ fun dir ->
  let report = G.ledger_health_report ~base_dir:dir () in
  Alcotest.(check int) "total_files=0" 0 report.total_files;
  Alcotest.(check bool) "no latest_mtime" true (report.latest_mtime = None)
;;

(* One jsonl file present: report sees it.  age_seconds is small. *)
let test_one_jsonl_file_visible () =
  with_temp_base_dir
  @@ fun dir ->
  let _path = touch_jsonl ~base_dir:dir ~month:"2026-04" ~day:"08" in
  let report = G.ledger_health_report ~base_dir:dir () in
  Alcotest.(check int) "total_files=1" 1 report.total_files;
  (match report.latest_mtime with
   | None -> Alcotest.fail "latest_mtime should be Some after touching a file"
   | Some _ -> ());
  match report.age_seconds with
  | None -> Alcotest.fail "age_seconds should be Some after touching a file"
  | Some age ->
    (* The file was just touched; age should be small.  Allow up
       to 60s to absorb test-runner clock skew. *)
    Alcotest.(check bool)
      "age_seconds non-negative and bounded"
      true
      (age >= 0.0 && age < 60.0)
;;

(* Multiple files across months: latest_mtime is the newest.
   This pins that we walk all month directories, not just one. *)
let test_multiple_months_pick_newest () =
  with_temp_base_dir
  @@ fun dir ->
  let _ = touch_jsonl ~base_dir:dir ~month:"2026-03" ~day:"01" in
  let _ = touch_jsonl ~base_dir:dir ~month:"2026-04" ~day:"01" in
  let _ = touch_jsonl ~base_dir:dir ~month:"2026-04" ~day:"08" in
  let report = G.ledger_health_report ~base_dir:dir () in
  Alcotest.(check int) "total_files=3" 3 report.total_files;
  match report.latest_mtime with
  | None -> Alcotest.fail "expected a latest_mtime"
  | Some t ->
    let age =
      match report.age_seconds with
      | Some a -> a
      | None -> Alcotest.fail "age_seconds should accompany latest_mtime"
    in
    Alcotest.(check bool)
      "age_seconds matches now - latest_mtime"
      true
      (Float.abs (Time_compat.now () -. t -. age) < 1.0)
;;

(* log_ledger_health_warn_if_stale returns the same shape as
   ledger_health_report.  Pin the wrapper contract independently
   of the WARN side effect (which we don't capture here). *)
let test_warn_wrapper_returns_report () =
  with_temp_base_dir
  @@ fun dir ->
  let _ = touch_jsonl ~base_dir:dir ~month:"2026-04" ~day:"08" in
  let report = G.log_ledger_health_warn_if_stale ~base_dir:dir () in
  Alcotest.(check int)
    "wrapper returns same total_files as bare report"
    1
    report.total_files;
  Alcotest.(check string) "base_dir round-trips through wrapper" dir report.base_dir
;;

(* Default staleness threshold is exposed as a constant so
   operators (and dashboards) can reference the same value the
   gate uses internally. *)
let test_default_threshold_is_seven_days () =
  Alcotest.(check (float 0.001))
    "stale_age_seconds_default = 7 days in seconds"
    (7. *. 86400.)
    G.stale_age_seconds_default
;;

let () =
  Alcotest.run
    "cdal_ledger_health_10115"
    [ ( "empty_ledger"
      , [ Alcotest.test_case "nonexistent base_dir" `Quick test_empty_base_dir_no_files
        ; Alcotest.test_case
            "existing dir, no jsonl"
            `Quick
            test_existing_dir_with_no_jsonl
        ] )
    ; ( "populated_ledger"
      , [ Alcotest.test_case
            "single jsonl file visible"
            `Quick
            test_one_jsonl_file_visible
        ; Alcotest.test_case
            "multiple months, latest picked"
            `Quick
            test_multiple_months_pick_newest
        ] )
    ; ( "wrapper_contract"
      , [ Alcotest.test_case
            "warn wrapper returns report"
            `Quick
            test_warn_wrapper_returns_report
        ; Alcotest.test_case
            "default threshold is 7 days"
            `Quick
            test_default_threshold_is_seven_days
        ] )
    ]
;;
