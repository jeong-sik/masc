open Masc_tui_render_prim

let unavailable_runtime_json =
  `Assoc
    [ "generated_at_iso", `String "2026-09-20T00:00:00Z"
    ; "source", `String "/api/v1/runtime/resolved"
    ; "config_path", `String "/workspace/config/runtime.toml"
    ; "default_runtime", `Null
    ; "runtimes", `List []
    ; "lanes", `List []
    ; ( "assignments"
      , `List
          [ `Assoc
              [ "keeper", `String "affected"
              ; "assignment_source", `String "explicit"
              ; ( "resolved"
                , `Assoc
                    [ "kind", `String "unavailable"
                    ; "id", `String "fixture.missing"
                    ; ( "reason"
                      , `Assoc
                          [ "kind", `String "missing_catalog_model"
                          ; "message", `String "Capability catalog entry unavailable"
                          ; "provider_id", `String "fixture"
                          ; "provider_label", `String "Fixture"
                          ; "model_id", `String "missing"
                          ] )
                    ] )
              ]
          ] )
    ]
;;

let test_unavailable_assignment_reaches_both_keeper_surfaces () =
  match Tui_decode.decode_runtime_resolved_full unavailable_runtime_json with
  | Error detail -> Alcotest.fail detail
  | Ok (_, lanes, [ assignment ]) ->
    let label = Masc_tui_render_prim.runtime_assignment_label ~runtime_lanes:lanes assignment in
    (match label.ral_kind with
     | Runtime_assignment_unavailable reason ->
       Alcotest.(check string)
         "typed unavailable reason"
         "Capability catalog entry unavailable"
         reason
     | Runtime_assignment_lane | Runtime_assignment_model | Runtime_assignment_default ->
       Alcotest.fail "decoded unavailable assignment was reclassified");
    Alcotest.(check string)
      "operations preview"
      " \xc2\xb7 target fixture.missing (unavailable: Capability catalog entry unavailable, explicit)"
      (Masc_tui_render_prim.runtime_assignment_operations_note label);
    Alcotest.(check string)
      "Keeper Runtime Stats"
      "fixture.missing (unavailable: Capability catalog entry unavailable, explicit)"
      (Masc_tui_render_prim.runtime_assignment_stats_value label)
  | Ok (_, _, assignments) ->
    Alcotest.failf "expected one unavailable assignment, got %d" (List.length assignments)
;;

let () =
  Alcotest.run
    "TUI runtime assignment label"
    [ ( "surfaces"
      , [ Alcotest.test_case
            "decoded unavailable assignment stays unavailable"
            `Quick
            test_unavailable_assignment_reaches_both_keeper_surfaces
        ] )
    ]
;;
