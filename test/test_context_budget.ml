(** Tests for Context_budget_manager — session-level context budget tracking. *)

module Cbm = Masc_mcp.Context_budget_manager

let () =
  let open Alcotest in
  run "Context_budget_manager"
    [
      ( "create",
        [
          test_case "default max budget" `Quick (fun () ->
              (* env var MASC_CONTEXT_BUDGET_MAX is unset in test env *)
              let t = Cbm.create () in
              check int "default 100000" 100_000 (Cbm.max_budget t);
              check int "total starts at 0" 0 (Cbm.total_tokens t));
          test_case "custom max budget" `Quick (fun () ->
              let t = Cbm.create ~max_budget:50_000 () in
              check int "custom" 50_000 (Cbm.max_budget t));
          test_case "zero max_budget falls back to env/default" `Quick (fun () ->
              let t = Cbm.create ~max_budget:0 () in
              check int "fallback" 100_000 (Cbm.max_budget t));
        ] );
      ( "record_turn",
        [
          test_case "single turn accumulates" `Quick (fun () ->
              let t = Cbm.create ~max_budget:10_000 () in
              Cbm.record_turn t ~estimated_tokens:500;
              check int "500" 500 (Cbm.total_tokens t));
          test_case "multiple turns accumulate" `Quick (fun () ->
              let t = Cbm.create ~max_budget:10_000 () in
              Cbm.record_turn t ~estimated_tokens:300;
              Cbm.record_turn t ~estimated_tokens:200;
              Cbm.record_turn t ~estimated_tokens:100;
              check int "600" 600 (Cbm.total_tokens t));
        ] );
      ( "record_tool_schemas",
        [
          test_case "tool schemas accumulate" `Quick (fun () ->
              let t = Cbm.create ~max_budget:10_000 () in
              Cbm.record_tool_schemas t ~count:5 ~estimated_tokens:1000;
              check int "1000" 1000 (Cbm.total_tokens t));
          test_case "tool schemas + turns combine" `Quick (fun () ->
              let t = Cbm.create ~max_budget:10_000 () in
              Cbm.record_tool_schemas t ~count:3 ~estimated_tokens:800;
              Cbm.record_turn t ~estimated_tokens:200;
              check int "1000 combined" 1000 (Cbm.total_tokens t));
        ] );
      ( "usage_ratio",
        [
          test_case "zero usage" `Quick (fun () ->
              let t = Cbm.create ~max_budget:10_000 () in
              let r = Cbm.usage_ratio t in
              check bool "0.0" true (Float.equal r 0.0));
          test_case "half usage" `Quick (fun () ->
              let t = Cbm.create ~max_budget:10_000 () in
              Cbm.record_turn t ~estimated_tokens:5_000;
              let r = Cbm.usage_ratio t in
              check bool "0.5" true (Float.equal r 0.5));
          test_case "full usage" `Quick (fun () ->
              let t = Cbm.create ~max_budget:10_000 () in
              Cbm.record_turn t ~estimated_tokens:10_000;
              let r = Cbm.usage_ratio t in
              check bool "1.0" true (Float.equal r 1.0));
          test_case "over budget" `Quick (fun () ->
              let t = Cbm.create ~max_budget:10_000 () in
              Cbm.record_turn t ~estimated_tokens:15_000;
              let r = Cbm.usage_ratio t in
              check bool ">1.0" true (r > 1.0));
        ] );
      ( "phase_transitions",
        [
          test_case "0% -> None_phase" `Quick (fun () ->
              let t = Cbm.create ~max_budget:10_000 () in
              check string "none" "none"
                (Cbm.show_compression_phase (Cbm.current_phase t)));
          test_case "49% -> None_phase" `Quick (fun () ->
              let t = Cbm.create ~max_budget:10_000 () in
              Cbm.record_turn t ~estimated_tokens:4_999;
              check string "none at 49%" "none"
                (Cbm.show_compression_phase (Cbm.current_phase t)));
          test_case "50% exact -> Compact_tools" `Quick (fun () ->
              let t = Cbm.create ~max_budget:10_000 () in
              Cbm.record_turn t ~estimated_tokens:5_000;
              check string "compact at 50%" "compact_tools"
                (Cbm.show_compression_phase (Cbm.current_phase t)));
          test_case "69% -> Compact_tools" `Quick (fun () ->
              let t = Cbm.create ~max_budget:10_000 () in
              Cbm.record_turn t ~estimated_tokens:6_999;
              check string "compact at 69%" "compact_tools"
                (Cbm.show_compression_phase (Cbm.current_phase t)));
          test_case "70% exact -> Drop_low" `Quick (fun () ->
              let t = Cbm.create ~max_budget:10_000 () in
              Cbm.record_turn t ~estimated_tokens:7_000;
              check string "drop_low at 70%" "drop_low"
                (Cbm.show_compression_phase (Cbm.current_phase t)));
          test_case "84% -> Drop_low" `Quick (fun () ->
              let t = Cbm.create ~max_budget:10_000 () in
              Cbm.record_turn t ~estimated_tokens:8_499;
              check string "drop_low at 84%" "drop_low"
                (Cbm.show_compression_phase (Cbm.current_phase t)));
          test_case "85% exact -> Summarize" `Quick (fun () ->
              let t = Cbm.create ~max_budget:10_000 () in
              Cbm.record_turn t ~estimated_tokens:8_500;
              check string "summarize at 85%" "summarize"
                (Cbm.show_compression_phase (Cbm.current_phase t)));
          test_case "100% -> Summarize" `Quick (fun () ->
              let t = Cbm.create ~max_budget:10_000 () in
              Cbm.record_turn t ~estimated_tokens:10_000;
              check string "summarize at 100%" "summarize"
                (Cbm.show_compression_phase (Cbm.current_phase t)));
          test_case "progressive accumulation crosses phases" `Quick (fun () ->
              let t = Cbm.create ~max_budget:10_000 () in
              check string "start: none" "none"
                (Cbm.show_compression_phase (Cbm.current_phase t));
              Cbm.record_turn t ~estimated_tokens:5_000;
              check string "50%: compact" "compact_tools"
                (Cbm.show_compression_phase (Cbm.current_phase t));
              Cbm.record_turn t ~estimated_tokens:2_000;
              check string "70%: drop_low" "drop_low"
                (Cbm.show_compression_phase (Cbm.current_phase t));
              Cbm.record_turn t ~estimated_tokens:1_500;
              check string "85%: summarize" "summarize"
                (Cbm.show_compression_phase (Cbm.current_phase t)));
        ] );
      ( "tool_budget_for_phase",
        [
          test_case "None_phase returns None" `Quick (fun () ->
              let t = Cbm.create ~max_budget:100_000 () in
              check bool "no limit" true
                (Cbm.tool_budget_for_phase t = None));
          test_case "Compact_tools returns max/10" `Quick (fun () ->
              let t = Cbm.create ~max_budget:100_000 () in
              Cbm.record_turn t ~estimated_tokens:50_000;
              check (option int) "10000" (Some 10_000)
                (Cbm.tool_budget_for_phase t));
          test_case "Drop_low returns max/20" `Quick (fun () ->
              let t = Cbm.create ~max_budget:100_000 () in
              Cbm.record_turn t ~estimated_tokens:70_000;
              check (option int) "5000" (Some 5_000)
                (Cbm.tool_budget_for_phase t));
          test_case "Summarize returns max/40" `Quick (fun () ->
              let t = Cbm.create ~max_budget:100_000 () in
              Cbm.record_turn t ~estimated_tokens:85_000;
              check (option int) "2500" (Some 2_500)
                (Cbm.tool_budget_for_phase t));
        ] );
      ( "summary",
        [
          test_case "format at zero" `Quick (fun () ->
              let t = Cbm.create ~max_budget:10_000 () in
              let s = Cbm.summary t in
              check bool "contains tokens" true
                (String.length s > 0);
              check bool "contains 0/10000" true
                (let needle = "0/10000" in
                 let nl = String.length needle in
                 let sl = String.length s in
                 nl <= sl &&
                 let rec check_at i =
                   if i > sl - nl then false
                   else if String.sub s i nl = needle then true
                   else check_at (i + 1)
                 in
                 check_at 0));
          test_case "format at 50%" `Quick (fun () ->
              let t = Cbm.create ~max_budget:10_000 () in
              Cbm.record_turn t ~estimated_tokens:5_000;
              let s = Cbm.summary t in
              check bool "contains phase" true
                (let needle = "compact_tools" in
                 let nl = String.length needle in
                 let sl = String.length s in
                 nl <= sl &&
                 let rec check_at i =
                   if i > sl - nl then false
                   else if String.sub s i nl = needle then true
                   else check_at (i + 1)
                 in
                 check_at 0));
        ] );
    ]
