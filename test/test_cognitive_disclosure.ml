(** Unit tests for Cognitive_disclosure (RFC-0035 PR-8,
    Master Report Dim01 P0 #1). *)

open Masc_mcp.Cognitive_disclosure

let make_item ?(level = Perceive) ?(title = "T") ?(summary = "S")
    ?(detail = None) ?(metric = None) ?(default_open = false) () =
  { level; title; summary; detail; metric; default_open }

let test_level_roundtrip () =
  List.iter
    (fun l ->
      let s = level_to_string l in
      match level_of_string s with
      | Ok l' when l = l' -> ()
      | Ok _ -> Alcotest.failf "level %s did not roundtrip" s
      | Error msg -> Alcotest.failf "level %s rejected: %s" s msg)
    all

let test_level_strings_match_dashboard () =
  Alcotest.(check string) "Perceive" "perceive" (level_to_string Perceive);
  Alcotest.(check string) "Comprehend" "comprehend"
    (level_to_string Comprehend);
  Alcotest.(check string) "Project" "project" (level_to_string Project)

let test_of_string_rejects_unknown () =
  match level_of_string "unknown" with
  | Ok _ -> Alcotest.fail "level_of_string should reject 'unknown'"
  | Error _ -> ()

let test_level_index_and_labels () =
  Alcotest.(check int) "Perceive index" 1 (level_index Perceive);
  Alcotest.(check int) "Comprehend index" 2 (level_index Comprehend);
  Alcotest.(check int) "Project index" 3 (level_index Project);
  Alcotest.(check string) "Perceive label" "Perceive"
    (level_label Perceive);
  Alcotest.(check string) "Project label" "Project"
    (level_label Project);
  Alcotest.(check string) "Perceive caption" "Direct signal"
    (level_caption Perceive);
  Alcotest.(check string) "Comprehend caption" "Grouped meaning"
    (level_caption Comprehend);
  Alcotest.(check string) "Project caption" "Forward state"
    (level_caption Project)

let test_summarize_empty () =
  let s = summarize [] in
  Alcotest.(check int) "empty total" 0 s.total;
  Alcotest.(check int) "empty perceive_count" 0 s.perceive_count;
  Alcotest.(check int) "empty comprehend_count" 0 s.comprehend_count;
  Alcotest.(check int) "empty project_count" 0 s.project_count;
  Alcotest.(check bool) "empty open_default_level None" true
    (s.open_default_level = None);
  Alcotest.(check bool) "empty incomplete" false s.complete

let test_summarize_single_level_incomplete () =
  let items =
    [
      make_item ~level:Perceive ~title:"a" ();
      make_item ~level:Perceive ~title:"b" ();
    ]
  in
  let s = summarize items in
  Alcotest.(check int) "total" 2 s.total;
  Alcotest.(check int) "perceive_count" 2 s.perceive_count;
  Alcotest.(check int) "comprehend_count" 0 s.comprehend_count;
  Alcotest.(check int) "project_count" 0 s.project_count;
  Alcotest.(check bool) "incomplete (missing comprehend/project)" false
    s.complete

let test_summarize_all_levels_complete () =
  let items =
    [
      make_item ~level:Perceive ();
      make_item ~level:Comprehend ();
      make_item ~level:Project ();
    ]
  in
  let s = summarize items in
  Alcotest.(check int) "total 3" 3 s.total;
  Alcotest.(check bool) "complete" true s.complete

let test_summarize_first_default_open_captured () =
  let items =
    [
      make_item ~level:Perceive ();
      make_item ~level:Comprehend ~default_open:true ();
      make_item ~level:Project ~default_open:true ();
    ]
  in
  let s = summarize items in
  match s.open_default_level with
  | Some Comprehend -> ()
  | Some other ->
    Alcotest.failf "expected open_default Comprehend, got %s"
      (level_to_string other)
  | None -> Alcotest.fail "expected open_default Comprehend, got None"

let test_items_at_level_filter () =
  let items =
    [
      make_item ~level:Perceive ~title:"p1" ();
      make_item ~level:Comprehend ~title:"c1" ();
      make_item ~level:Perceive ~title:"p2" ();
    ]
  in
  let perceive_items = items_at_level Perceive items in
  Alcotest.(check int) "perceive count" 2 (List.length perceive_items);
  Alcotest.(check string) "first perceive" "p1"
    (List.nth perceive_items 0).title;
  Alcotest.(check string) "second perceive (input order)" "p2"
    (List.nth perceive_items 1).title

let test_item_json_roundtrip () =
  let item =
    make_item ~level:Comprehend ~title:"build status"
      ~summary:"5 of 7 modules green" ~detail:(Some "remaining: dashboard, oas")
      ~metric:(Some "5/7") ~default_open:true ()
  in
  let json = item_to_yojson item in
  match item_of_yojson json with
  | Ok item' ->
    Alcotest.(check string) "level preserved"
      (level_to_string item.level) (level_to_string item'.level);
    Alcotest.(check string) "title preserved" item.title item'.title;
    Alcotest.(check string) "summary preserved" item.summary item'.summary;
    Alcotest.(check (option string)) "detail preserved" item.detail
      item'.detail;
    Alcotest.(check (option string)) "metric preserved" item.metric
      item'.metric;
    Alcotest.(check bool) "default_open preserved" item.default_open
      item'.default_open
  | Error msg -> Alcotest.failf "item_of_yojson rejected: %s" msg

let test_item_optional_fields_absent_when_none () =
  let item = make_item ~level:Perceive ~title:"t" ~summary:"s" () in
  let json = item_to_yojson item in
  match json with
  | `Assoc fields ->
    Alcotest.(check bool) "detail absent when None" true
      (not (List.mem_assoc "detail" fields));
    Alcotest.(check bool) "metric absent when None" true
      (not (List.mem_assoc "metric" fields));
    Alcotest.(check bool) "defaultOpen absent when false" true
      (not (List.mem_assoc "defaultOpen" fields))
  | _ -> Alcotest.fail "to_yojson must emit a JSON object"

let test_item_of_yojson_rejects_missing_required () =
  let bad =
    Yojson.Safe.from_string {|{"level":"perceive","title":"t"}|}
  in
  match item_of_yojson bad with
  | Ok _ -> Alcotest.fail "should reject missing summary"
  | Error _ -> ()

let test_item_of_yojson_rejects_unknown_level () =
  let bad =
    Yojson.Safe.from_string
      {|{"level":"unknown","title":"t","summary":"s"}|}
  in
  match item_of_yojson bad with
  | Ok _ -> Alcotest.fail "should reject unknown level"
  | Error _ -> ()

let test_summary_json_shape_for_dashboard () =
  let items =
    [
      make_item ~level:Perceive ();
      make_item ~level:Comprehend ~default_open:true ();
    ]
  in
  let s = summarize items in
  let json_str = Yojson.Safe.to_string (summary_to_yojson s) in
  let must_contain needle =
    let len_n = String.length needle in
    let len_s = String.length json_str in
    let rec scan i =
      if i + len_n > len_s then false
      else if String.sub json_str i len_n = needle then true
      else scan (i + 1)
    in
    Alcotest.(check bool)
      (Printf.sprintf "summary json must contain %s" needle) true (scan 0)
  in
  must_contain "\"total\"";
  must_contain "\"byLevel\"";
  must_contain "\"openDefaultLevel\"";
  must_contain "\"complete\"";
  must_contain "\"perceive\"";
  must_contain "\"comprehend\""

let test_well_formed_accepts_valid () =
  let item = make_item ~title:"t" ~summary:"s" () in
  match is_well_formed item with
  | Ok () -> ()
  | Error msg -> Alcotest.failf "well-formed rejected: %s" msg

let test_well_formed_rejects_blanks () =
  let blank_title = make_item ~title:"" ~summary:"s" () in
  Alcotest.(check bool) "blank title rejected" true
    (Result.is_error (is_well_formed blank_title));
  let blank_summary = make_item ~title:"t" ~summary:"" () in
  Alcotest.(check bool) "blank summary rejected" true
    (Result.is_error (is_well_formed blank_summary))

let () =
  Alcotest.run "cognitive_disclosure"
    [
      ( "level",
        [
          Alcotest.test_case "round-trip" `Quick test_level_roundtrip;
          Alcotest.test_case "strings match dashboard" `Quick
            test_level_strings_match_dashboard;
          Alcotest.test_case "rejects unknown" `Quick
            test_of_string_rejects_unknown;
          Alcotest.test_case "index + label + caption" `Quick
            test_level_index_and_labels;
        ] );
      ( "summarize",
        [
          Alcotest.test_case "empty input" `Quick test_summarize_empty;
          Alcotest.test_case "single level incomplete" `Quick
            test_summarize_single_level_incomplete;
          Alcotest.test_case "all levels complete" `Quick
            test_summarize_all_levels_complete;
          Alcotest.test_case "first defaultOpen captured" `Quick
            test_summarize_first_default_open_captured;
        ] );
      ( "filter",
        [
          Alcotest.test_case "items_at_level preserves order" `Quick
            test_items_at_level_filter;
        ] );
      ( "json",
        [
          Alcotest.test_case "item round-trip with all fields" `Quick
            test_item_json_roundtrip;
          Alcotest.test_case "optional fields absent when None" `Quick
            test_item_optional_fields_absent_when_none;
          Alcotest.test_case "rejects missing required" `Quick
            test_item_of_yojson_rejects_missing_required;
          Alcotest.test_case "rejects unknown level" `Quick
            test_item_of_yojson_rejects_unknown_level;
          Alcotest.test_case "summary dashboard wire shape" `Quick
            test_summary_json_shape_for_dashboard;
        ] );
      ( "well_formed",
        [
          Alcotest.test_case "accepts valid" `Quick
            test_well_formed_accepts_valid;
          Alcotest.test_case "rejects blank title or summary" `Quick
            test_well_formed_rejects_blanks;
        ] );
    ]
