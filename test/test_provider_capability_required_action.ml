open Alcotest

module Capability = Masc_mcp.Provider_capability
module Skip_reason = Masc_mcp.Cascade_candidate_skip_reason

let bool_option =
  testable
    (Fmt.of_to_string (function
       | None -> "None"
       | Some true -> "Some true"
       | Some false -> "Some false"))
    ( = )

let provider_names providers =
  List.map (fun (p : Capability.t) -> p.provider_name) providers

let filtered_names filtered =
  List.map (fun ((p : Capability.t), _missing) -> p.provider_name) filtered

let test_unknown_snapshot_is_non_filtering () =
  let candidate = Capability.unknown ~provider_name:"glm" in
  check
    bool_option
    "unknown capability passes through"
    None
    (Capability.can_satisfy_required_action
       candidate
       ~required_tools:[ "keeper_bash" ])

let test_known_snapshot_satisfies_required_tools () =
  let candidate =
    Capability.known
      ~provider_name:"claude"
      ~satisfying_tools:[ "mcp__masc__keeper_bash"; "keeper_task_claim" ]
      ~tool_choice_support:true
  in
  check
    bool_option
    "known matching snapshot satisfies"
    (Some true)
    (Capability.can_satisfy_required_action
       candidate
       ~required_tools:[ "keeper_bash" ])

let test_known_snapshot_reports_missing_tools () =
  let candidate =
    Capability.known
      ~provider_name:"ollama"
      ~satisfying_tools:[ "keeper_task_claim" ]
      ~tool_choice_support:true
  in
  check
    (option (list string))
    "missing tools are canonicalized"
    (Some [ "keeper_bash" ])
    (Capability.missing_required_tools
       candidate
       ~required_tools:[ "mcp__masc__keeper_bash" ]);
  check
    bool_option
    "missing tool rejects"
    (Some false)
    (Capability.can_satisfy_required_action
       candidate
       ~required_tools:[ "keeper_bash" ])

let test_strict_tool_choice_support_is_separate_from_tool_presence () =
  let candidate =
    Capability.known
      ~provider_name:"local-inline"
      ~satisfying_tools:[ "keeper_bash" ]
      ~tool_choice_support:false
  in
  check
    bool_option
    "strict mode rejects provider without tool_choice"
    (Some false)
    (Capability.can_satisfy_required_action
       candidate
       ~required_tools:[ "keeper_bash" ]);
  check
    bool_option
    "advisory mode accepts tool-capable provider"
    (Some true)
    (Capability.can_satisfy_required_action
       ~require_tool_choice:false
       candidate
       ~required_tools:[ "keeper_bash" ])

let test_filter_candidates_preserves_order_and_missing_evidence () =
  let unknown = Capability.unknown ~provider_name:"unknown" in
  let good =
    Capability.known
      ~provider_name:"good"
      ~satisfying_tools:[ "keeper_bash" ]
      ~tool_choice_support:true
  in
  let missing =
    Capability.known
      ~provider_name:"missing"
      ~satisfying_tools:[ "keeper_task_claim" ]
      ~tool_choice_support:true
  in
  let passed, filtered =
    Capability.filter_candidates_for_required_tools
      [ unknown; missing; good ]
      ~required_tools:[ "keeper_bash" ]
  in
  check (list string) "passed order" [ "unknown"; "good" ] (provider_names passed);
  check (list string) "filtered order" [ "missing" ] (filtered_names filtered);
  check
    (list string)
    "filtered missing evidence"
    [ "keeper_bash" ]
    (match filtered with
     | [ (_candidate, missing_tools) ] -> missing_tools
     | _ -> fail "expected one filtered candidate")

let test_skip_reason_manifest_shape () =
  let json =
    Skip_reason.to_yojson
      ~candidate:"glm"
      (Skip_reason.Required_tool_unsupported { missing = [ "keeper_bash" ] })
  in
  check
    string
    "tag"
    "required_tool_unsupported"
    (Yojson.Safe.Util.(json |> member "kind" |> to_string));
  check
    string
    "candidate"
    "glm"
    (Yojson.Safe.Util.(json |> member "candidate" |> to_string));
  check
    (list string)
    "missing"
    [ "keeper_bash" ]
    (Yojson.Safe.Util.(json |> member "missing" |> to_list |> List.map to_string))

let () =
  run
    "provider_capability_required_action"
    [
      ( "decision",
        [
          test_case
            "unknown snapshot is non-filtering"
            `Quick
            test_unknown_snapshot_is_non_filtering;
          test_case
            "known snapshot satisfies required tools"
            `Quick
            test_known_snapshot_satisfies_required_tools;
          test_case
            "known snapshot reports missing tools"
            `Quick
            test_known_snapshot_reports_missing_tools;
          test_case
            "strict tool_choice support is separate"
            `Quick
            test_strict_tool_choice_support_is_separate_from_tool_presence;
          test_case
            "filter preserves order and missing evidence"
            `Quick
            test_filter_candidates_preserves_order_and_missing_evidence;
          test_case "skip reason manifest shape" `Quick test_skip_reason_manifest_shape;
        ] );
    ]
