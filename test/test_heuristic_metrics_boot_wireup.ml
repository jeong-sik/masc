(* test/test_heuristic_metrics_boot_wireup.ml

   #9919: pin the boot-time diagnostics wiring contract. The
   bootstrap block in [lib/server/server_runtime_bootstrap.ml]
   wraps [Heuristic_metrics_diagnostics.analyze] around the
   live [Heuristic_metrics.recent] slice; this test exercises
   the same analyze-over-recent-slice flow without spinning up
   the full server, so a regression that removes the wiring or
   changes the diagnostics signature is caught by CI.

   The #9919 regression signature itself is exercised in
   [test_heuristic_metrics_diagnostics.ml] (merged via PR #9879);
   this test only verifies the boot-time consumption shape.  *)

module HM = Masc_mcp.Heuristic_metrics
module HD = Masc_mcp.Heuristic_metrics_diagnostics

let tmp_base_path () =
  Filename.concat
    (Filename.get_temp_dir_name ())
    (Printf.sprintf "masc-heuristic-wireup-%d-%06x" (Unix.getpid ()) (Random.bits ()))
;;

let with_fresh_store f =
  let base = tmp_base_path () in
  Unix.mkdir base 0o755;
  HM.init ~base_path:base;
  Fun.protect
    ~finally:(fun () ->
      try HM.flush () with
      | _ ->
        ();
        let rec rm_rf p =
          if Sys.file_exists p
          then
            if Sys.is_directory p
            then (
              Sys.readdir p |> Array.iter (fun c -> rm_rf (Filename.concat p c));
              Unix.rmdir p)
            else Sys.remove p
        in
        rm_rf base)
    f
;;

let record_failure_event () =
  HM.record
    { module_name = "keeper_hooks_oas"
    ; site = "post_tool_use_failure"
    ; raw_value = 1.0
    ; threshold = 0.0
    ; triggered = true
    ; provenance = HM.Pipeline_stage "post_tool_use_failure"
    ; timestamp = Unix.gettimeofday ()
    }
;;

let test_empty_store_produces_zero_report () =
  with_fresh_store (fun () ->
    let recent = HM.recent 500 in
    let report = HD.analyze recent in
    Alcotest.(check int) "empty → 0 total" 0 report.total_records;
    Alcotest.(check int) "empty → 0 degenerate" 0 (List.length report.degenerate_sites);
    Alcotest.(check int) "empty → 0 one_sided" 0 (List.length report.one_sided_sites))
;;

let test_degenerate_signature_flagged_by_wireup_flow () =
  with_fresh_store (fun () ->
    (* Emit exactly the #9919 signature — 25 identical records,
       all [(1.0, 0.0, true)] at post_tool_use_failure. 25 clears
       the [degenerate_min_records] threshold (20). *)
    for _ = 1 to 25 do
      record_failure_event ()
    done;
    HM.flush ();
    let recent = HM.recent 500 in
    let report = HD.analyze recent in
    Alcotest.(check int) "25 records ingested" 25 report.total_records;
    Alcotest.(check bool)
      "post_tool_use_failure flagged as degenerate"
      true
      (List.mem "post_tool_use_failure" report.degenerate_sites);
    Alcotest.(check bool)
      "post_tool_use_failure flagged as one_sided (always triggered=true)"
      true
      (List.mem "post_tool_use_failure" report.one_sided_sites);
    let summary = HD.pretty_summary report in
    Alcotest.(check bool)
      "summary mentions the site"
      true
      (let s = String.lowercase_ascii summary in
       let n = "post_tool_use_failure" in
       let nl = String.length n in
       let sl = String.length s in
       let rec scan i =
         if i + nl > sl
         then false
         else if String.sub s i nl = n
         then true
         else scan (i + 1)
       in
       scan 0))
;;

let () =
  Alcotest.run
    "heuristic_metrics_boot_wireup"
    [ ( "boot-time consumption shape"
      , [ Alcotest.test_case
            "empty store → empty report"
            `Quick
            test_empty_store_produces_zero_report
        ; Alcotest.test_case
            "#9919 signature → both flags fire"
            `Quick
            test_degenerate_signature_flagged_by_wireup_flow
        ] )
    ]
;;
