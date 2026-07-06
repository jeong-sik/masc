module Types = Masc.Keeper_memory_os_types
module Memory_io = Masc.Keeper_memory_os_io
module GC = Masc.Keeper_memory_os_gc
module Report = Masc.Keeper_memory_os_gc_dry_run_report

let fact_fixture ~now ~claim =
  { Types.claim
  ; category = Types.Fact
  ; external_ref = None
  ; claim_kind = None
  ; source = { Types.trace_id = "trace-gc-dry-run"; turn = 1; tool_call_id = None }
  ; observed_by = []
  ; first_seen = now -. 60.0
  ; valid_until = None
  ; last_verified_at = Some now
  ; schema_version = Types.schema_version
  ; claim_id = None
  }
;;

let with_temp_keepers_dir f =
  let marker = Filename.temp_file "keeper-memory-os-gc-dry-run-" ".tmp" in
  Sys.remove marker;
  Memory_io.For_testing.with_keepers_dir marker (fun () -> f marker)
;;

let with_eio f = Eio_main.run @@ fun _env -> f ()

let result_for keeper_id report =
  List.find_opt
    (function
      | Report.Keeper_ok row -> String.equal row.keeper_id keeper_id
      | Report.Keeper_error row -> String.equal row.keeper_id keeper_id)
    report.Report.results
;;

let test_report_summarizes_dry_run_without_rewrite () =
  with_eio (fun () ->
    with_temp_keepers_dir (fun keepers_dir ->
      let now = 1_000.0 in
      let live = fact_fixture ~now ~claim:"keep this fact" in
      let expired =
        { live with
          Types.claim = "expired fact"
        ; Types.valid_until = Some (now -. 1.0)
        }
      in
      List.iter (Memory_io.append_fact ~keeper_id:"alpha") [ live; expired ];
      Memory_io.append_fact ~keeper_id:"beta" (fact_fixture ~now ~claim:"beta fact");
      let report = Report.run_for_keepers_dir ~keepers_dir ~now () in
      Alcotest.(check int) "keeper count" 2 (List.length report.results);
      Alcotest.(check int) "total input" 3 report.total_input;
      Alcotest.(check int) "ttl expired" 1 report.ttl_expired;
      Alcotest.(check int)
        "non-ephemeral expired is a migration candidate"
        1
        report.ttl_expired_non_ephemeral;
      Alcotest.(check int) "error count" 0 report.error_count;
      Alcotest.(check int)
        "alpha file unchanged by dry-run"
        2
        (List.length (Memory_io.read_facts_all ~keeper_id:"alpha"));
      match result_for "alpha" report with
      | Some (Report.Keeper_ok row) ->
        Alcotest.(check int) "alpha ttl expired" 1 row.ttl_expired;
        Alcotest.(check int)
          "alpha migration candidates"
          1
          row.ttl_expired_non_ephemeral;
        Alcotest.(check (list (pair string int)))
          "alpha expired by category"
          [ "fact", 1 ]
          row.ttl_expired_by_category;
        Alcotest.(check int) "alpha would write" 1 row.written
      | Some (Report.Keeper_error row) ->
        Alcotest.failf
          "unexpected alpha error: %s"
          (match row.error with
           | Report.Missing_fact_store { facts_path } ->
             Printf.sprintf "missing %s" facts_path
           | Report.Corrupt_fact_store { message }
           | Report.Fact_store_access_error { message } -> message
           | Report.Fact_store_locked { lock_path; _ } ->
             Printf.sprintf "locked %s" lock_path)
      | None -> Alcotest.fail "missing alpha result"))
;;

let test_explicit_missing_keeper_is_error () =
  with_eio (fun () ->
    with_temp_keepers_dir (fun keepers_dir ->
      let report =
        Report.run_for_keepers_dir
          ~keepers_dir
          ~keeper_ids:[ "missing"; "missing" ]
          ~now:1_000.0
          ()
      in
      Alcotest.(check int) "deduped explicit keeper" 1 (List.length report.results);
      Alcotest.(check int) "error count" 1 report.error_count;
      match result_for "missing" report with
      | Some (Report.Keeper_error row) ->
        let expected_path =
          Memory_io.facts_path_for_keepers_dir ~keepers_dir ~keeper_id:"missing"
        in
        (match row.error with
         | Report.Missing_fact_store { facts_path } ->
           Alcotest.(check string) "missing fact store path" expected_path facts_path
         | Report.Corrupt_fact_store _
         | Report.Fact_store_access_error _
         | Report.Fact_store_locked _ ->
           Alcotest.fail "expected structured missing fact store error");
        (match Report.to_json report with
         | `Assoc fields ->
           (match List.assoc_opt "keepers" fields with
            | Some (`List [ `Assoc keeper_fields ]) ->
              Alcotest.(check (option string))
                "canonical error status"
                (Some "error")
                (Option.bind
                   (List.assoc_opt "status" keeper_fields)
                   (function `String s -> Some s | _ -> None));
              Alcotest.(check (option string))
                "structured error code"
                (Some "fact_store_missing")
                (Option.bind
                   (List.assoc_opt "error_code" keeper_fields)
                   (function `String s -> Some s | _ -> None))
            | Some _ | None -> Alcotest.fail "missing keeper JSON row")
         | _ -> Alcotest.fail "report JSON must be an object")
      | Some (Report.Keeper_ok _) -> Alcotest.fail "expected missing keeper error"
      | None -> Alcotest.fail "missing explicit keeper result"))
;;

let fake_gc_report ?(total_input = 1) ?(ttl_expired = 0) ?(written = 1) () =
  { GC.total_input = total_input
  ; ttl_expired
  ; ttl_expired_ephemeral = 0
  ; ttl_expired_non_ephemeral = ttl_expired
  ; ttl_expired_by_category = (if ttl_expired > 0 then [ "fact", ttl_expired ] else [])
  ; dedup_removed = 0
  ; written
  ; dry_run = true
  }
;;

let seed_keeper ~now keeper_id =
  Memory_io.append_fact ~keeper_id (fact_fixture ~now ~claim:(keeper_id ^ " fact"))
;;

let test_lock_timeout_is_per_keeper_error () =
  with_eio (fun () ->
    with_temp_keepers_dir (fun keepers_dir ->
      let now = 1_000.0 in
      seed_keeper ~now "locked";
      let run_gc_for_keepers_dir ~keepers_dir:_ ~dry_run:_ ~keeper_id:_ ~now:_ () =
        raise
          (File_lock_eio.Flock_timeout
             { caller = "unit-test"; path = "/tmp/facts.jsonl.lock"; attempts = 3 })
      in
      let report =
        Report.For_testing.run_for_keepers_dir
          ~keepers_dir
          ~run_gc_for_keepers_dir
          ~keeper_ids:[ "locked" ]
          ~now
          ()
      in
      Alcotest.(check int) "one per-keeper error" 1 report.error_count;
      match result_for "locked" report with
      | Some (Report.Keeper_error { error = Report.Fact_store_locked row; _ }) ->
        Alcotest.(check string) "caller" "unit-test" row.caller;
        Alcotest.(check int) "attempts" 3 row.attempts
      | Some (Report.Keeper_error _) -> Alcotest.fail "expected lock timeout error"
      | Some (Report.Keeper_ok _) -> Alcotest.fail "expected locked keeper error"
      | None -> Alcotest.fail "missing locked result"))
;;

let test_corrupt_store_is_per_keeper_error () =
  with_eio (fun () ->
    with_temp_keepers_dir (fun keepers_dir ->
      let now = 1_000.0 in
      seed_keeper ~now "corrupt";
      let run_gc_for_keepers_dir ~keepers_dir:_ ~dry_run:_ ~keeper_id:_ ~now:_ () =
        raise (GC.Fact_store_corrupt "bad row")
      in
      let report =
        Report.For_testing.run_for_keepers_dir
          ~keepers_dir
          ~run_gc_for_keepers_dir
          ~keeper_ids:[ "corrupt" ]
          ~now
          ()
      in
      Alcotest.(check int) "one corrupt error" 1 report.error_count;
      match result_for "corrupt" report with
      | Some (Report.Keeper_error { error = Report.Corrupt_fact_store { message }; _ }) ->
        Alcotest.(check string) "message" "bad row" message
      | Some (Report.Keeper_error _) -> Alcotest.fail "expected corrupt store error"
      | Some (Report.Keeper_ok _) -> Alcotest.fail "expected corrupt keeper error"
      | None -> Alcotest.fail "missing corrupt result"))
;;

let test_mixed_results_keep_ok_totals_and_errors () =
  with_eio (fun () ->
    with_temp_keepers_dir (fun keepers_dir ->
      let now = 1_000.0 in
      List.iter (seed_keeper ~now) [ "alpha"; "broken" ];
      let run_gc_for_keepers_dir ~keepers_dir:_ ~dry_run:_ ~keeper_id ~now:_ () =
        if String.equal keeper_id "broken"
        then raise (GC.Fact_store_corrupt "broken")
        else fake_gc_report ~total_input:2 ~ttl_expired:1 ~written:1 ()
      in
      let report =
        Report.For_testing.run_for_keepers_dir
          ~keepers_dir
          ~run_gc_for_keepers_dir
          ~keeper_ids:[ "alpha"; "broken" ]
          ~now
          ()
      in
      Alcotest.(check int) "two results" 2 (List.length report.results);
      Alcotest.(check int) "one error" 1 report.error_count;
      Alcotest.(check int) "ok total input only" 2 report.total_input;
      Alcotest.(check int) "ok ttl only" 1 report.ttl_expired))
;;

(* The two expiry corners the External_state coverage in test_keeper_memory_os
   does not pin: the boundary equality ([ts >= now] is current, so [now > ts] is
   expired — explicit [valid_until] behavior is unchanged by the SSOT switch in
   #23426), and explicit [valid_until] taking precedence over the legacy
   [External_state] first_seen horizon in [fact_effective_valid_until]. *)
let test_ttl_expired_matches_explicit_horizon_boundary () =
  let now = 1_000_000.0 in
  let base = fact_fixture ~now ~claim:"horizon boundary fixture" in
  Alcotest.(check bool)
    "past explicit horizon expires"
    true
    (GC.ttl_expired ~now { base with Types.valid_until = Some (now -. 1.0) });
  Alcotest.(check bool)
    "boundary ts = now stays live (ts >= now is current)"
    false
    (GC.ttl_expired ~now { base with Types.valid_until = Some now });
  Alcotest.(check bool)
    "explicit valid_until overrides the legacy External_state horizon"
    false
    (GC.ttl_expired
       ~now
       { base with
         Types.claim_kind = Some Types.External_state
       ; Types.first_seen = now -. Types.external_state_ttl_seconds -. 1.0
       ; Types.valid_until = Some (now +. 60.0)
       })
;;

let test_empty_scan_is_empty_report () =
  with_eio (fun () ->
    with_temp_keepers_dir (fun keepers_dir ->
      let report = Report.run_for_keepers_dir ~keepers_dir ~now:1_000.0 () in
      Alcotest.(check int) "no keepers" 0 (List.length report.results);
      Alcotest.(check int) "no errors" 0 report.error_count;
      Alcotest.(check int) "no input" 0 report.total_input))
;;

let () =
  Alcotest.run
    "keeper_memory_os_gc_dry_run_report"
    [ ( "report"
      , [ Alcotest.test_case
            "summarizes dry-run without rewrite"
            `Quick
            test_report_summarizes_dry_run_without_rewrite
        ; Alcotest.test_case
            "explicit missing keeper is an error"
            `Quick
            test_explicit_missing_keeper_is_error
        ; Alcotest.test_case
            "lock timeout is per-keeper error"
            `Quick
            test_lock_timeout_is_per_keeper_error
        ; Alcotest.test_case
            "corrupt store is per-keeper error"
            `Quick
            test_corrupt_store_is_per_keeper_error
        ; Alcotest.test_case
            "mixed results keep ok totals and errors"
            `Quick
            test_mixed_results_keep_ok_totals_and_errors
        ; Alcotest.test_case
            "empty scan is empty report"
            `Quick
            test_empty_scan_is_empty_report
        ] )
    ; ( "ttl boundary"
      , [ Alcotest.test_case
            "expiry matches explicit horizon boundary"
            `Quick
            test_ttl_expired_matches_explicit_horizon_boundary
        ] )
    ]
;;
