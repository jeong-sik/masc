(** Web_dashboard Module Coverage Tests

    Tests for MASC Web Dashboard:
    - html: dashboard HTML generation
*)

open Alcotest

module Web_dashboard = Masc_mcp.Web_dashboard

let contains_re re s =
  try
    let _ = Str.search_forward (Str.regexp re) s 0 in
    true
  with Not_found -> false

let contains_re_ci re s =
  try
    let _ = Str.search_forward (Str.regexp_case_fold re) s 0 in
    true
  with Not_found -> false

(* ============================================================
   html Tests
   ============================================================ *)

let test_html_nonempty () =
  let html = Web_dashboard.html () in
  check bool "nonempty" true (String.length html > 0)

let test_html_starts_with_doctype () =
  let html = Web_dashboard.html () in
  check bool "doctype" true
    (String.length html >= 15 && String.sub html 0 15 = "<!DOCTYPE html>")

let test_html_contains_head () =
  let html = Web_dashboard.html () in
  check bool "has head" true (String.length html > 0)

let test_html_contains_body () =
  let html = Web_dashboard.html () in
  check bool "has body" true (String.length html > 0)

let test_html_contains_title () =
  let html = Web_dashboard.html () in
  check bool "has MASC title" true
    (String.length html > 0 && contains_re "MASC" html)

let test_html_contains_style () =
  let html = Web_dashboard.html () in
  check bool "has style" true
    (String.length html > 0 && contains_re "<style>" html)

let test_html_contains_script () =
  let html = Web_dashboard.html () in
  check bool "has script" true
    (String.length html > 0 && contains_re "<script>" html)

let test_html_valid_length () =
  let html = Web_dashboard.html () in
  (* Dashboard HTML should be substantial *)
  check bool "reasonable length" true (String.length html > 1000)

let test_html_ends_with_html_tag () =
  let html = Web_dashboard.html () in
  let trimmed = String.trim html in
  let len = String.length trimmed in
  check bool "ends with </html>" true
    (len >= 7 && String.sub trimmed (len - 7) 7 = "</html>")

let test_html_contains_sse () =
  let html = Web_dashboard.html () in
  (* Dashboard should reference SSE for real-time updates *)
  check bool "references SSE" true
    (String.length html > 0 && contains_re_ci "sse\\|eventsource" html)

let test_html_contains_keeper_state_query_params () =
  let html = Web_dashboard.html () in
  check bool "keeper query params" true
    (String.length html > 0
    && contains_re "keeper_field_query" html
    && contains_re "keeper_kpi" html)

let test_html_contains_keeper_kpi_interaction () =
  let html = Web_dashboard.html () in
  check bool "keeper kpi interaction" true
    (String.length html > 0
    && contains_re "setKeeperSelectedKpi" html
    && contains_re "keeper-kpi\\.selected" html)

let test_html_contains_meta_localizer () =
  let html = Web_dashboard.html () in
  check bool "keeper meta localizer" true
    (String.length html > 0
    && contains_re "localizeKeeperMetaLabels" html
    && contains_re "keeperMetaLabelKo" html)

(* ============================================================
   Test Runners
   ============================================================ *)

let () =
  run "Web_dashboard Coverage" [
    "html", [
      test_case "nonempty" `Quick test_html_nonempty;
      test_case "doctype" `Quick test_html_starts_with_doctype;
      test_case "head" `Quick test_html_contains_head;
      test_case "body" `Quick test_html_contains_body;
      test_case "title" `Quick test_html_contains_title;
      test_case "style" `Quick test_html_contains_style;
      test_case "script" `Quick test_html_contains_script;
      test_case "valid length" `Quick test_html_valid_length;
      test_case "ends with html" `Quick test_html_ends_with_html_tag;
      test_case "contains sse" `Quick test_html_contains_sse;
      test_case "keeper query params" `Quick test_html_contains_keeper_state_query_params;
      test_case "keeper kpi interaction" `Quick test_html_contains_keeper_kpi_interaction;
      test_case "keeper meta localizer" `Quick test_html_contains_meta_localizer;
    ];
  ]
