(** test_telemetry_unified_source — round-trip tests for Telemetry_unified_source. *)

open Masc
open Telemetry_unified_source

let roundtrip_all_variants () =
  List.iter (fun (expected, label) ->
    let s = Telemetry_unified_source.source_to_string expected in
    match Telemetry_unified_source.source_of_string s with
    | Some actual ->
      Alcotest.(check bool)
        (Printf.sprintf "%s round-trip: %s → %s" label s
           (Telemetry_unified_source.source_to_string actual))
        true (actual = expected)
    | None ->
      Alcotest.fail (Printf.sprintf "%s: source_of_string returned None for '%s'" label s)
  ) [
    Keeper_metric,            "Keeper_metric";
    Agent_event,              "Agent_event";
    Tool_call_io,             "Tool_call_io";
    Trajectory_tool_call,     "Trajectory_tool_call";
    Tool_usage,               "Tool_usage";
    Oas_event,                "Oas_event";
    Execution_receipt,        "Execution_receipt";
    Tool_metric,              "Tool_metric";
  ]

let source_of_string_edge_cases () =
  let eq a b =
    match a, b with
    | None, None -> true
    | Some a, Some b -> a = b
    | _ -> false
  in
  let check input expected =
    let actual = Telemetry_unified_source.source_of_string input in
    let ok = eq actual expected in
    let label = Printf.sprintf "source_of_string %S" input in
    Alcotest.(check bool) label true ok
  in
  check "" None;
  check "gibberish" None;
  check "keeper_metric" (Some Keeper_metric);
  check "KEEPER_METRIC" None;   (* case-sensitive *)
  check " " None;
  check "tool_call_io " None    (* trailing space *)

let all_sources_match_strings () =
  let count = List.length Telemetry_unified_source.all_sources in
  Alcotest.(check int) "all_sources has 8 variants" 8 count;
  List.iter (fun src ->
    let s = Telemetry_unified_source.source_to_string src in
    match Telemetry_unified_source.source_of_string s with
    | Some actual ->
      Alcotest.(check bool) (Printf.sprintf "all_sources: %s round-trips" s) true (actual = src)
    | None ->
      Alcotest.fail (Printf.sprintf "all_sources: %s does not round-trip" s)
  ) Telemetry_unified_source.all_sources

(* ── Cases ──────────────────────────────────────── *)

let cases = [
  "all variants round-trip via source_to_string/source_of_string",
    `Quick, roundtrip_all_variants;
  "source_of_string edge cases (empty, invalid, case, spacing)",
    `Quick, source_of_string_edge_cases;
  "all_sources list is complete and each entry round-trips",
    `Quick, all_sources_match_strings;
]

let () =
  Alcotest.run "telemetry_unified_source" [
    "source_roundtrip", cases;
  ]
