let allocate ?runtime_visible inner_width =
  Masc_tui_render_schedule.allocate_keeper_columns
    ?runtime_visible ~prioritize_runtime:false ~inner_width ~widest_runtime:49 ()

let test_runtime_visibility_yields_space_to_detail () =
  let visible = allocate 151 in
  let grouped = allocate ~runtime_visible:false 151 in
  Alcotest.(check bool) "the existing runtime path stays visible" true visible.kcol_show_runtime;
  Alcotest.(check bool) "grouped hides the runtime column" false grouped.kcol_show_runtime;
  Alcotest.(check int) "a hidden runtime has no allocation" 0 grouped.kcol_runtime;
  Alcotest.(check bool) "the Keeper name keeps its minimum" true
    (grouped.kcol_name >= 16);
  Alcotest.(check bool) "the detail receives the released space" true
    (grouped.kcol_task > visible.kcol_task)

let rich_summary : Masc_tui_keeper_list_model.waiting_summary =
  { tool = 12; model = 3; external_wait = 2; delegate = 1; verification = 1; background = 12 }

let test_waiting_group_preserves_all_reasons_at_ninety_cells () =
  let narrow =
    Masc_tui_render_schedule.waiting_group_layout
      ~available_cells:86 ~group_count:19 rich_summary
  in
  Alcotest.(check bool) "the dense label decision activates" true narrow.compact;
  Alcotest.(check int) "all five reasons and async remain represented" 6 narrow.segment_count;
  Alcotest.(check bool) "all summary counts fit the 90-cell frame" true
    (narrow.cells <= 86);
  let wide =
    Masc_tui_render_schedule.waiting_group_layout
      ~available_cells:146 ~group_count:19 rich_summary
  in
  Alcotest.(check bool) "wide frames keep full labels" false wide.compact

let test_hidden_runtime_preserves_failure_context_in_detail () =
  let context = Some "streaming · last failed · provider · 3m ago" in
  Alcotest.(check (option string)) "Grouped carries the existing failure reading"
    context
    (Masc_tui_render_schedule.keeper_failure_context_for_detail
       ~show_runtime:false context);
  Alcotest.(check (option string)) "Compact and Detailed do not duplicate it" None
    (Masc_tui_render_schedule.keeper_failure_context_for_detail
       ~show_runtime:true context)

let () =
  Alcotest.run "tui_keeper_columns"
    [ ( "column allocation"
      , [ Alcotest.test_case "runtime visibility yields space to detail" `Quick
            test_runtime_visibility_yields_space_to_detail
        ; Alcotest.test_case "90-cell waiting group preserves every count" `Quick
            test_waiting_group_preserves_all_reasons_at_ninety_cells
        ; Alcotest.test_case "hidden runtime preserves failure context" `Quick
            test_hidden_runtime_preserves_failure_context_in_detail
        ] )
    ]
