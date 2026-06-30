(** #9774: regression tests for judge strict JSON parse diagnostics. *)

open Alcotest
open Masc

let test_short_input_passes_through () =
  let raw = "{\"items\":[]}" in
  let out = Judge_diagnostics.truncate_with_marker raw in
  check string "short string preserved" raw out

let test_long_input_truncated_with_marker () =
  let raw = String.make 1200 'a' in
  let out = Judge_diagnostics.truncate_with_marker raw in
  check bool "result shorter than input" true (String.length out < String.length raw);
  check bool "preserves prefix" true
    (String.length out >= 500 && String.sub out 0 500 = String.make 500 'a');
  check bool "ends with chars marker" true
    (try
       let re = Re.Pcre.re {|\+\d+ chars\]$|} |> Re.compile in
       ignore (Re.exec re out); true
     with Not_found -> false)

let test_custom_max_bytes_respected () =
  let raw = String.make 100 'x' in
  let out = Judge_diagnostics.truncate_with_marker ~max_bytes:30 raw in
  check bool "first 30 chars preserved" true
    (String.length out >= 30 && String.sub out 0 30 = String.make 30 'x')

let test_format_strict_json_parse_reject_includes_label () =
  let raw = "garbage that is not json" in
  let out = Judge_diagnostics.format_strict_json_parse_reject ~judge_label:"Governance" raw in
  let contains needle =
    try
      let re = Re.Pcre.re (Re.Pcre.quote needle) |> Re.compile in
      ignore (Re.exec re out); true
    with Not_found -> false
  in
  check bool "names judge label" true (contains "Governance judge");
  check bool "names byte size" true (contains "24 chars");
  check bool "embeds raw preview" true (contains raw);
  check bool "names strict JSON parse rejection" true
    (contains "strict JSON parse rejected")

let test_format_strict_json_parse_reject_truncates_huge_raw () =
  let raw = String.make 2000 'z' in
  let out = Judge_diagnostics.format_strict_json_parse_reject ~judge_label:"Operator" raw in
  check bool "embeds size in chars" true
    (try
       let re = Re.Pcre.re {|2000 chars|} |> Re.compile in
       ignore (Re.exec re out); true
     with Not_found -> false);
  check bool "preview is bounded" true
    (String.length out < 1500)

let test_format_unparseable_response_includes_reason () =
  let raw = "{\"items\":[{\"guardrail_state\":null}]}" in
  let out =
    Judge_diagnostics.format_unparseable_response ~judge_label:"Governance"
      ~reason:"item agent_health:k1 missing guardrail_state"
      raw
  in
  let contains needle =
    try
      let re = Re.Pcre.re (Re.Pcre.quote needle) |> Re.compile in
      ignore (Re.exec re out); true
    with Not_found -> false
  in
  check bool "names structural invalid class" true
    (contains "structurally invalid response");
  check bool "includes reason" true
    (contains "missing guardrail_state");
  check bool "includes raw preview" true
    (contains raw)

let test_record_strict_json_parse_reject_increments_metrics () =
  let raw = "not-json" in
  let labels = [("judge", "governance")] in
  let unparseable_before =
    Otel_metric_store.metric_value_or_zero
      Otel_metric_store.metric_governance_judge_unparseable
      ~labels
      ()
  in
  let strict_parse_before =
    Otel_metric_store.metric_value_or_zero
      Otel_metric_store.metric_governance_strict_json_parse_reject
      ~labels
      ()
  in
  let out =
    Judge_diagnostics.record_strict_json_parse_reject
      ~judge_label:"Governance"
      raw
  in
  check bool "returns formatted diagnostic" true
    (try
       let re = Re.Pcre.re "Governance judge returned unparseable" |> Re.compile in
       ignore (Re.exec re out); true
     with Not_found -> false);
  check (float 0.0001) "unparseable counter increments"
    (unparseable_before +. 1.0)
    (Otel_metric_store.metric_value_or_zero
       Otel_metric_store.metric_governance_judge_unparseable
       ~labels
       ());
  check (float 0.0001) "strict parse rejection counter increments"
    (strict_parse_before +. 1.0)
    (Otel_metric_store.metric_value_or_zero
       Otel_metric_store.metric_governance_strict_json_parse_reject
       ~labels
       ())

let test_record_unparseable_response_increments_unparseable_only () =
  let raw = "{\"items\":[{\"guardrail_state\":null}]}" in
  let labels = [("judge", "governance")] in
  let unparseable_before =
    Otel_metric_store.metric_value_or_zero
      Otel_metric_store.metric_governance_judge_unparseable
      ~labels
      ()
  in
  let strict_parse_before =
    Otel_metric_store.metric_value_or_zero
      Otel_metric_store.metric_governance_strict_json_parse_reject
      ~labels
      ()
  in
  let out =
    Judge_diagnostics.record_unparseable_response
      ~judge_label:"Governance"
      ~reason:"item agent_health:k1 missing guardrail_state"
      raw
  in
  check bool "returns structural diagnostic" true
    (try
       let re = Re.Pcre.re "structurally invalid response" |> Re.compile in
       ignore (Re.exec re out); true
     with Not_found -> false);
  check (float 0.0001) "unparseable counter increments"
    (unparseable_before +. 1.0)
    (Otel_metric_store.metric_value_or_zero
       Otel_metric_store.metric_governance_judge_unparseable
       ~labels
       ());
  check (float 0.0001) "strict parse rejection counter unchanged"
    strict_parse_before
    (Otel_metric_store.metric_value_or_zero
       Otel_metric_store.metric_governance_strict_json_parse_reject
       ~labels
       ())

let test_strict_json_parse_metrics_json_reads_counters () =
  let raw = "still-not-json" in
  let labels = [("judge", "governance")] in
  let before_unparseable =
    int_of_float
      (Otel_metric_store.metric_value_or_zero
         Otel_metric_store.metric_governance_judge_unparseable
         ~labels
         ())
  in
  let before_strict_parse =
    int_of_float
      (Otel_metric_store.metric_value_or_zero
         Otel_metric_store.metric_governance_strict_json_parse_reject
         ~labels
         ())
  in
  ignore
    (Judge_diagnostics.record_strict_json_parse_reject
       ~judge_label:"Governance"
       raw);
  let json =
    Judge_diagnostics.strict_json_parse_metrics_json
      ~judge_label:"Governance"
  in
  let open Yojson.Safe.Util in
  check string "judge label" "governance"
    (json |> member "judge" |> to_string);
  check int "unparseable total"
    (before_unparseable + 1)
    (json |> member "governance_judge_unparseable_total" |> to_int);
  check int "strict parse rejection total"
    (before_strict_parse + 1)
    (json |> member "governance_strict_json_parse_reject_total" |> to_int)

let () =
  run "judge_diagnostics (#9774)"
    [
      ( "truncate_with_marker",
        [
          test_case "short input passes through" `Quick test_short_input_passes_through;
          test_case "long input truncated with marker" `Quick test_long_input_truncated_with_marker;
          test_case "custom max_bytes respected" `Quick test_custom_max_bytes_respected;
        ] );
      ( "format_strict_json_parse_reject",
        [
          test_case "includes judge label, size, preview, class" `Quick
            test_format_strict_json_parse_reject_includes_label;
          test_case "preview is bounded for huge raw" `Quick
            test_format_strict_json_parse_reject_truncates_huge_raw;
          test_case "structural invalid includes reason" `Quick
            test_format_unparseable_response_includes_reason;
          test_case "record increments metrics" `Quick
            test_record_strict_json_parse_reject_increments_metrics;
          test_case "structural invalid increments unparseable only" `Quick
            test_record_unparseable_response_increments_unparseable_only;
          test_case "metrics JSON reads counters" `Quick
            test_strict_json_parse_metrics_json_reads_counters;
        ] );
    ]
