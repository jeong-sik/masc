open Alcotest

module CB = Masc_mcp.Keeper_failure_circuit_breaker

let contains haystack needle =
  let nl = String.length needle and hl = String.length haystack in
  if nl > hl then false
  else
    let rec scan i =
      if i + nl > hl then false
      else if String.sub haystack i nl = needle then true
      else scan (i + 1)
    in scan 0

let test_classify_path_not_found () =
  check bool "path_not_found from prefix" true
    (CB.classify_error "path_not_found_under_allowed_roots: /foo" = CB.Path_not_found);
  check bool "path_not_found from NSFD" true
    (CB.classify_error "No such file or directory" = CB.Path_not_found)

let test_classify_path_not_allowed () =
  check bool "path_not_allowed" true
    (CB.classify_error "path_not_in_allowed_paths: /x" = CB.Path_not_allowed)

let test_classify_other () =
  check bool "other" true
    (CB.classify_error "random error" = CB.Other)

let test_no_hint_under_threshold () =
  CB.record_success ~keeper_name:"t1";
  let r1 = CB.maybe_enrich_error ~keeper_name:"t1" ~error_msg:"path_not_found: /a" in
  check bool "1st: no hint" true (not (contains r1 "CIRCUIT BREAKER"));
  let r2 = CB.maybe_enrich_error ~keeper_name:"t1" ~error_msg:"path_not_found: /b" in
  check bool "2nd: no hint" true (not (contains r2 "CIRCUIT BREAKER"))

let test_hint_at_threshold () =
  CB.record_success ~keeper_name:"t2";
  ignore (CB.maybe_enrich_error ~keeper_name:"t2" ~error_msg:"path_not_found: /a");
  ignore (CB.maybe_enrich_error ~keeper_name:"t2" ~error_msg:"path_not_found: /b");
  let r3 = CB.maybe_enrich_error ~keeper_name:"t2" ~error_msg:"path_not_found: /c" in
  check bool "3rd: HAS hint" true (contains r3 "CIRCUIT BREAKER");
  check bool "mentions playground" true (contains r3 "playground");
  check bool "mentions ls" true (contains r3 "keeper_shell op=ls")

let test_reset_on_success () =
  CB.record_success ~keeper_name:"t3";
  ignore (CB.maybe_enrich_error ~keeper_name:"t3" ~error_msg:"path_not_found: /a");
  ignore (CB.maybe_enrich_error ~keeper_name:"t3" ~error_msg:"path_not_found: /b");
  CB.record_success ~keeper_name:"t3";
  let r = CB.maybe_enrich_error ~keeper_name:"t3" ~error_msg:"path_not_found: /c" in
  check bool "after reset: no hint" true (not (contains r "CIRCUIT BREAKER"))

let test_class_change_resets () =
  ignore (CB.maybe_enrich_error ~keeper_name:"t4" ~error_msg:"path_not_found: /a");
  ignore (CB.maybe_enrich_error ~keeper_name:"t4" ~error_msg:"path_not_found: /b");
  ignore (CB.maybe_enrich_error ~keeper_name:"t4" ~error_msg:"path_not_in_allowed_paths: /x");
  let r = CB.maybe_enrich_error ~keeper_name:"t4" ~error_msg:"path_not_in_allowed_paths: /y" in
  check bool "class switch: no hint at 2nd" true (not (contains r "CIRCUIT BREAKER"))

let test_snapshot () =
  ignore (CB.maybe_enrich_error ~keeper_name:"t5" ~error_msg:"path_not_found: /a");
  match CB.snapshot_json () with
  | `List entries -> check bool "has entries" true (List.length entries > 0)
  | _ -> Alcotest.fail "expected list"

let () =
  run "Circuit_breaker" [
    "classify", [
      test_case "path_not_found" `Quick test_classify_path_not_found;
      test_case "path_not_allowed" `Quick test_classify_path_not_allowed;
      test_case "other" `Quick test_classify_other;
    ];
    "threshold", [
      test_case "no hint under threshold" `Quick test_no_hint_under_threshold;
      test_case "hint at threshold" `Quick test_hint_at_threshold;
      test_case "reset on success" `Quick test_reset_on_success;
      test_case "class change resets" `Quick test_class_change_resets;
    ];
    "diagnostics", [
      test_case "snapshot" `Quick test_snapshot;
    ];
  ]
