(** #9774: regression tests for the judge fallback diagnostic formatter. *)

open Alcotest
open Masc_mcp

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

let test_format_lenient_fallback_includes_label () =
  let raw = "garbage that is not json" in
  let out = Judge_diagnostics.format_lenient_fallback ~judge_label:"Governance" raw in
  let contains needle =
    try
      let re = Re.Pcre.re (Re.Pcre.quote needle) |> Re.compile in
      ignore (Re.exec re out); true
    with Not_found -> false
  in
  check bool "names judge label" true (contains "Governance judge");
  check bool "names byte size" true (contains "24 chars");
  check bool "embeds raw preview" true (contains raw);
  check bool "names fallback class" true (contains "Lenient_json fallback hit")

let test_format_lenient_fallback_truncates_huge_raw () =
  let raw = String.make 2000 'z' in
  let out = Judge_diagnostics.format_lenient_fallback ~judge_label:"Operator" raw in
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

let test_record_lenient_fallback_increments_metrics () =
  let raw = "not-json" in
  let labels = [("judge", "governance")] in
  let unparseable_before =
    Prometheus.metric_value_or_zero
      Prometheus.metric_governance_judge_unparseable
      ~labels
      ()
  in
  let fallback_before =
    Prometheus.metric_value_or_zero
      Prometheus.metric_governance_lenient_json_fallback_hit
      ~labels
      ()
  in
  let out =
    Judge_diagnostics.record_lenient_fallback
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
    (Prometheus.metric_value_or_zero
       Prometheus.metric_governance_judge_unparseable
       ~labels
       ());
  check (float 0.0001) "fallback counter increments"
    (fallback_before +. 1.0)
    (Prometheus.metric_value_or_zero
       Prometheus.metric_governance_lenient_json_fallback_hit
       ~labels
       ())

let test_record_unparseable_response_increments_unparseable_only () =
  let raw = "{\"items\":[{\"guardrail_state\":null}]}" in
  let labels = [("judge", "governance")] in
  let unparseable_before =
    Prometheus.metric_value_or_zero
      Prometheus.metric_governance_judge_unparseable
      ~labels
      ()
  in
  let fallback_before =
    Prometheus.metric_value_or_zero
      Prometheus.metric_governance_lenient_json_fallback_hit
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
    (Prometheus.metric_value_or_zero
       Prometheus.metric_governance_judge_unparseable
       ~labels
       ());
  check (float 0.0001) "lenient fallback counter unchanged"
    fallback_before
    (Prometheus.metric_value_or_zero
       Prometheus.metric_governance_lenient_json_fallback_hit
       ~labels
       ())

let test_lenient_fallback_metrics_json_reads_counters () =
  let raw = "still-not-json" in
  let labels = [("judge", "governance")] in
  let before_unparseable =
    int_of_float
      (Prometheus.metric_value_or_zero
         Prometheus.metric_governance_judge_unparseable
         ~labels
         ())
  in
  let before_fallback =
    int_of_float
      (Prometheus.metric_value_or_zero
         Prometheus.metric_governance_lenient_json_fallback_hit
         ~labels
         ())
  in
  ignore
    (Judge_diagnostics.record_lenient_fallback
       ~judge_label:"Governance"
       raw);
  let json =
    Judge_diagnostics.lenient_fallback_metrics_json
      ~judge_label:"Governance"
  in
  let open Yojson.Safe.Util in
  check string "judge label" "governance"
    (json |> member "judge" |> to_string);
  check int "unparseable total"
    (before_unparseable + 1)
    (json |> member "governance_judge_unparseable_total" |> to_int);
  check int "fallback total"
    (before_fallback + 1)
    (json |> member "governance_lenient_json_fallback_hit_total" |> to_int)

let () =
  run "judge_diagnostics (#9774)"
    [
      ( "truncate_with_marker",
        [
          test_case "short input passes through" `Quick test_short_input_passes_through;
          test_case "long input truncated with marker" `Quick test_long_input_truncated_with_marker;
          test_case "custom max_bytes respected" `Quick test_custom_max_bytes_respected;
        ] );
      ( "format_lenient_fallback",
        [
          test_case "includes judge label, size, preview, class" `Quick
            test_format_lenient_fallback_includes_label;
          test_case "preview is bounded for huge raw" `Quick
            test_format_lenient_fallback_truncates_huge_raw;
          test_case "structural invalid includes reason" `Quick
            test_format_unparseable_response_includes_reason;
          test_case "record increments metrics" `Quick
            test_record_lenient_fallback_increments_metrics;
          test_case "structural invalid increments unparseable only" `Quick
            test_record_unparseable_response_increments_unparseable_only;
          test_case "metrics JSON reads counters" `Quick
            test_lenient_fallback_metrics_json_reads_counters;
        ] );
    ]
