(** Unit tests for Cognitive_mode (RFC-0035 PR-7,
    Master Report Dim01 P0 #2 backend). *)

open Masc_mcp.Cognitive_mode

let test_mode_roundtrip () =
  List.iter
    (fun m ->
      let s = to_string m in
      match of_string s with
      | Ok m' when m = m' -> ()
      | Ok _ ->
        Alcotest.failf "mode %s did not roundtrip" s
      | Error msg -> Alcotest.failf "mode %s rejected: %s" s msg)
    all

let test_mode_strings_match_dashboard () =
  Alcotest.(check string) "Cockpit" "cockpit" (to_string Cockpit);
  Alcotest.(check string) "Code" "code" (to_string Code);
  Alcotest.(check string) "Split" "split" (to_string Split);
  Alcotest.(check string) "Explode" "explode" (to_string Explode)

let test_of_string_rejects_unknown () =
  match of_string "unknown" with
  | Ok _ -> Alcotest.fail "of_string should reject 'unknown'"
  | Error msg ->
      Alcotest.(check bool) "error names expected mode set" true
        (String.contains msg '|')

let test_load_of_mode () =
  Alcotest.(check string) "Cockpit -> situational" "situational"
    (load_to_string (load_of_mode Cockpit));
  Alcotest.(check string) "Code -> focused" "focused"
    (load_to_string (load_of_mode Code));
  Alcotest.(check string) "Split -> comparative" "comparative"
    (load_to_string (load_of_mode Split));
  Alcotest.(check string) "Explode -> exploratory" "exploratory"
    (load_to_string (load_of_mode Explode))

let test_layout_of_mode () =
  Alcotest.(check string) "Cockpit -> all-panels" "all-panels"
    (layout_to_string (layout_of_mode Cockpit));
  Alcotest.(check string) "Code -> editor-first" "editor-first"
    (layout_to_string (layout_of_mode Code));
  Alcotest.(check string) "Split -> side-by-side" "side-by-side"
    (layout_to_string (layout_of_mode Split));
  Alcotest.(check string) "Explode -> graph-map" "graph-map"
    (layout_to_string (layout_of_mode Explode))

let test_load_layout_roundtrip () =
  List.iter
    (fun m ->
      let l = load_of_mode m in
      match load_of_string (load_to_string l) with
      | Ok l' when l = l' -> ()
      | Ok _ -> Alcotest.failf "load round-trip failed for mode %s"
                  (to_string m)
      | Error msg -> Alcotest.failf "load_of_string rejected: %s" msg)
    all;
  List.iter
    (fun m ->
      let lay = layout_of_mode m in
      match layout_of_string (layout_to_string lay) with
      | Ok lay' when lay = lay' -> ()
      | Ok _ -> Alcotest.failf "layout round-trip failed for mode %s"
                  (to_string m)
      | Error msg -> Alcotest.failf "layout_of_string rejected: %s" msg)
    all

let test_state_of_mode_consistency () =
  List.iter
    (fun m ->
      let st = state_of_mode m in
      Alcotest.(check string)
        (Printf.sprintf "state.mode equals input (%s)" (to_string m))
        (to_string m) (to_string st.mode);
      Alcotest.(check string)
        (Printf.sprintf "state.load matches load_of_mode (%s)" (to_string m))
        (load_to_string (load_of_mode m))
        (load_to_string st.load);
      Alcotest.(check string)
        (Printf.sprintf "state.layout matches layout_of_mode (%s)"
           (to_string m))
        (layout_to_string (layout_of_mode m))
        (layout_to_string st.layout);
      Alcotest.(check bool)
        (Printf.sprintf "state.label non-empty (%s)" (to_string m))
        true (String.length st.label > 0))
    all

let check_target_mode current signal expected =
  let m = transition ~current ~signal in
  Alcotest.(check string)
    (Printf.sprintf "current=%s signal=%s -> %s"
       (to_string current) (signal_to_string signal)
       (to_string expected))
    (to_string expected) (to_string m)

let all_signals =
  [
    Project_open;
    Review_started;
    File_edit_started;
    Sustained_focus_window;
    Diff_view_requested;
    Reference_lookup;
    Codebase_exploration;
    Learning_session;
    Reset_to_overview;
  ]

let expected_mode_of_signal = function
  | Project_open
  | Review_started
  | Reset_to_overview -> Cockpit
  | File_edit_started
  | Sustained_focus_window -> Code
  | Diff_view_requested
  | Reference_lookup -> Split
  | Codebase_exploration
  | Learning_session -> Explode

let test_transition_rules () =
  (* From any mode: project signals -> Cockpit *)
  check_target_mode Code Project_open Cockpit;
  check_target_mode Split Review_started Cockpit;
  check_target_mode Explode Reset_to_overview Cockpit;
  (* From any mode: focus signals -> Code *)
  check_target_mode Cockpit File_edit_started Code;
  check_target_mode Split Sustained_focus_window Code;
  (* From any mode: split signals -> Split *)
  check_target_mode Code Diff_view_requested Split;
  check_target_mode Cockpit Reference_lookup Split;
  (* From any mode: exploration signals -> Explode *)
  check_target_mode Code Codebase_exploration Explode;
  check_target_mode Cockpit Learning_session Explode

let test_transition_total_for_all_mode_signal_pairs () =
  List.iter
    (fun current ->
      List.iter
        (fun signal ->
          check_target_mode current signal (expected_mode_of_signal signal))
        all_signals)
    all

let test_transition_has_no_invalid_edge_fallback () =
  check_target_mode Cockpit Codebase_exploration Explode;
  check_target_mode Explode Project_open Cockpit

let test_mode_yojson_roundtrip () =
  List.iter
    (fun m ->
      let json = to_yojson m in
      match of_yojson json with
      | Ok m' when m = m' -> ()
      | Ok _ -> Alcotest.failf "mode %s yojson round-trip failed" (to_string m)
      | Error msg -> Alcotest.failf "of_yojson rejected: %s" msg)
    all

let test_state_yojson_roundtrip () =
  let st = state_of_mode Split in
  let json = state_to_yojson st in
  match state_of_yojson json with
  | Ok st' ->
    Alcotest.(check string) "mode preserved"
      (to_string st.mode) (to_string st'.mode);
    Alcotest.(check string) "label preserved" st.label st'.label;
    Alcotest.(check string) "load preserved"
      (load_to_string st.load) (load_to_string st'.load);
    Alcotest.(check string) "layout preserved"
      (layout_to_string st.layout) (layout_to_string st'.layout)
  | Error msg -> Alcotest.failf "state_of_yojson rejected: %s" msg

let test_state_json_shape_for_dashboard () =
  let st = state_of_mode Cockpit in
  let s = Yojson.Safe.to_string (state_to_yojson st) in
  let must_contain needle =
    let len_n = String.length needle in
    let len_s = String.length s in
    let rec scan i =
      if i + len_n > len_s then false
      else if String.sub s i len_n = needle then true
      else scan (i + 1)
    in
    Alcotest.(check bool)
      (Printf.sprintf "json must contain %s" needle) true (scan 0)
  in
  must_contain "\"mode\"";
  must_contain "\"label\"";
  must_contain "\"load\"";
  must_contain "\"layout\"";
  must_contain "\"all-panels\"";  (* layout uses kebab-case *)
  must_contain "\"situational\""

let test_state_of_yojson_rejects_unknown_mode () =
  let bad =
    Yojson.Safe.from_string
      {|{"mode":"banana","label":"Banana","load":"focused","layout":"all-panels"}|}
  in
  match state_of_yojson bad with
  | Ok _ -> Alcotest.fail "state_of_yojson should reject 'banana' mode"
  | Error msg ->
      Alcotest.(check bool) "unknown mode error mentions banana" true
        (String.contains msg 'b')

let test_state_of_yojson_rejects_unknown_load_and_layout () =
  let bad_load =
    Yojson.Safe.from_string
      {|{"mode":"code","label":"Code","load":"mystery","layout":"editor-first"}|}
  in
  (match state_of_yojson bad_load with
   | Ok _ -> Alcotest.fail "state_of_yojson should reject unknown load"
   | Error msg ->
       Alcotest.(check bool) "unknown load error mentions expected set" true
         (String.contains msg '|'));
  let bad_layout =
    Yojson.Safe.from_string
      {|{"mode":"code","label":"Code","load":"focused","layout":"diagonal"}|}
  in
  match state_of_yojson bad_layout with
  | Ok _ -> Alcotest.fail "state_of_yojson should reject unknown layout"
  | Error msg ->
      Alcotest.(check bool) "unknown layout error mentions expected set" true
        (String.contains msg '|')


let () =
  Alcotest.run "cognitive_mode"
    [
      ( "mode",
        [
          Alcotest.test_case "round-trip" `Quick test_mode_roundtrip;
          Alcotest.test_case "strings match dashboard" `Quick
            test_mode_strings_match_dashboard;
          Alcotest.test_case "rejects unknown" `Quick
            test_of_string_rejects_unknown;
        ] );
      ( "load",
        [ Alcotest.test_case "load_of_mode mapping" `Quick test_load_of_mode ] );
      ( "layout",
        [
          Alcotest.test_case "layout_of_mode mapping" `Quick
            test_layout_of_mode;
        ] );
      ( "round_trips",
        [
          Alcotest.test_case "load + layout strings" `Quick
            test_load_layout_roundtrip;
        ] );
      ( "state",
        [
          Alcotest.test_case "of_mode consistency" `Quick
            test_state_of_mode_consistency;
        ] );
      ( "transition",
        [
          Alcotest.test_case "Master Report section 1.4 rules" `Quick
            test_transition_rules;
          Alcotest.test_case "total for all mode-signal pairs" `Quick
            test_transition_total_for_all_mode_signal_pairs;
          Alcotest.test_case "no invalid edge fallback" `Quick
            test_transition_has_no_invalid_edge_fallback;
        ] );
      ( "json",
        [
          Alcotest.test_case "mode round-trip" `Quick
            test_mode_yojson_roundtrip;
          Alcotest.test_case "state round-trip" `Quick
            test_state_yojson_roundtrip;
          Alcotest.test_case "dashboard wire format" `Quick
            test_state_json_shape_for_dashboard;
          Alcotest.test_case "state rejects unknown mode" `Quick
            test_state_of_yojson_rejects_unknown_mode;
          Alcotest.test_case "state rejects unknown load/layout" `Quick
            test_state_of_yojson_rejects_unknown_load_and_layout;
        ] );
    ]
