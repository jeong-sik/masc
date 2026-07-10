module Boundary = Boundary_redaction

let runtime_lane = Boundary.runtime_lane_label
let runtime_lane_string = Boundary.to_string runtime_lane

let test_runtime_lane_derives_from_model_label () =
  Alcotest.(check string)
    "runtime lane serializes like runtime model label"
    (Boundary.to_string Boundary.runtime_model_label)
    runtime_lane_string

let test_unknown_model_label_is_distinct_from_runtime_redaction () =
  let unknown_model = Boundary.to_string Boundary.unknown_model_label in
  Alcotest.(check string) "unknown model label" "unknown_model" unknown_model;
  Alcotest.(check bool)
    "unknown model is not the redacted runtime lane"
    false
    (String.equal runtime_lane_string unknown_model)

let test_runtime_lane_public_surfaces_use_boundary_ssot () =
  Alcotest.(check string)
    "keeper hooks use boundary lane SSOT"
    runtime_lane_string
    Masc.Keeper_hooks_oas.runtime_lane_label;
  Alcotest.(check string)
    "keeper hooks OAS types use boundary lane SSOT"
    runtime_lane_string
    Keeper_hooks_oas_types.runtime_lane_label;
  Alcotest.(check string)
    "keeper agent result uses boundary lane SSOT"
    runtime_lane_string
    Masc.Keeper_agent_result.runtime_lane_label

let () =
  Alcotest.run
    "boundary_redaction_runtime_lane"
    [ ( "runtime-lane"
      , [ Alcotest.test_case
            "runtime lane derives from typed model label"
            `Quick
            test_runtime_lane_derives_from_model_label
        ; Alcotest.test_case
            "unknown model label is a typed boundary label"
            `Quick
            test_unknown_model_label_is_distinct_from_runtime_redaction
        ; Alcotest.test_case
            "public surfaces serialize boundary lane"
            `Quick
            test_runtime_lane_public_surfaces_use_boundary_ssot
        ] )
    ]
