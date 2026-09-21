open Masc_tui_render_prim

let unavailable_runtime_json =
  `Assoc
    [ "generated_at_iso", `String "2026-09-20T00:00:00Z"
    ; "source", `String "/api/v1/runtime/resolved"
    ; "config_path", `String "/workspace/config/runtime.toml"
    ; "default_runtime", `Null
    ; "runtimes", `List []
    ; "lanes", `List []
    ; "media_failover", `List []
    ; "media_failover_declared", `List []
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

let test_unavailable_assignment_keeps_its_typed_label () =
  match Masc.Tui_decode.decode_runtime_resolved_full unavailable_runtime_json with
  | Error detail -> Alcotest.fail detail
  | Ok (_, _, [ assignment ]) ->
    (match assignment.ra_resolution with
     | Runtime_assignment_unavailable
         { runtime_id; reason = Missing_catalog_model { provider_label; model_id } } ->
       Alcotest.(check string) "typed unavailable runtime" "fixture.missing" runtime_id;
       Alcotest.(check string)
         "typed unavailable provider label"
         "Fixture"
         provider_label;
       Alcotest.(check string) "typed unavailable model" "missing" model_id
     | Runtime_assignment_lane _ | Runtime_assignment_missing ->
       Alcotest.fail "decoded unavailable assignment was reclassified");
    Alcotest.(check string)
      "shared Keeper assignment label"
      "fixture.missing (not in catalog: Fixture / missing, explicit)"
      (Masc_tui_render_prim.runtime_assignment_label assignment)
  | Ok (_, _, assignments) ->
    Alcotest.failf "expected one unavailable assignment, got %d" (List.length assignments)
;;

let test_missing_assignment_does_not_target_any_runtime () =
  let assignment : Masc.Tui_decode.runtime_assignment =
    { ra_keeper = "defaulted"
    ; ra_source = Default_runtime
    ; ra_resolution = Runtime_assignment_missing
    }
  in
  Alcotest.(check bool)
    "not grouped under the configured default"
    false
    (Masc_tui_render_prim.runtime_assignment_targets assignment "default.lane");
  Alcotest.(check bool)
    "not grouped under another runtime"
    false
    (Masc_tui_render_prim.runtime_assignment_targets assignment "other.runtime")
;;

let () =
  Alcotest.run
    "TUI runtime assignment label"
    [ ( "surfaces"
      , [ Alcotest.test_case
            "decoded unavailable assignment stays unavailable"
            `Quick
            test_unavailable_assignment_keeps_its_typed_label
        ; Alcotest.test_case
            "missing assignment targets no runtime"
            `Quick
            test_missing_assignment_does_not_target_any_runtime
        ] )
    ]
;;
