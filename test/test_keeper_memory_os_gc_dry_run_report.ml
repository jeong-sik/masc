module Types = Masc.Keeper_memory_os_types
module Memory_io = Masc.Keeper_memory_os_io
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
           | Report.Fact_store_access_error { message } -> message)
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
         | Report.Corrupt_fact_store _ | Report.Fact_store_access_error _ ->
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
        ] )
    ]
;;
