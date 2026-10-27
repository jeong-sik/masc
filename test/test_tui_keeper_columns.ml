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

let () =
  Alcotest.run "tui_keeper_columns"
    [ ( "column allocation"
      , [ Alcotest.test_case "runtime visibility yields space to detail" `Quick
            test_runtime_visibility_yields_space_to_detail
        ] )
    ]
