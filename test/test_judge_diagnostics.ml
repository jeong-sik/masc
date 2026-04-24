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
        ] );
    ]
