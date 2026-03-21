(** Mode Tool Count Tests — End-to-end validation that Config.enabled_tool_schemas
    returns correct tool counts for each mode preset.

    These tests verify the full pipeline:
    Config.all_tool_schemas → Tool_catalog visibility filter → Mode category filter *)

open Alcotest

module Mode = Masc_mcp.Mode
module Config = Masc_mcp.Config

(* ============================================================
   Helpers
   ============================================================ *)

let count_for_mode mode =
  let cats = Mode.categories_for_mode mode in
  let schemas = Config.enabled_tool_schemas cats in
  List.length schemas

let tools_for_mode mode =
  let cats = Mode.categories_for_mode mode in
  Config.enabled_tool_schemas cats

let tool_names_for_mode mode =
  List.map (fun (s : Types.tool_schema) -> s.name) (tools_for_mode mode)

(* ============================================================
   Core invariant: monotonic ordering
   Solo <= Minimal <= Coding < Standard < Parallel < Full
   ============================================================ *)

let test_monotonic_ordering () =
  let solo     = count_for_mode Solo in
  let minimal  = count_for_mode Minimal in
  let coding   = count_for_mode Coding in
  let standard = count_for_mode Standard in
  let parallel = count_for_mode Parallel in
  let full     = count_for_mode Full in
  (* Print actual counts for diagnostics *)
  let msg = Printf.sprintf
    "Solo=%d Minimal=%d Coding=%d Standard=%d Parallel=%d Full=%d"
    solo minimal coding standard parallel full
  in
  check bool (msg ^ " | Solo <= Minimal") true (solo <= minimal);
  check bool (msg ^ " | Minimal <= Coding") true (minimal <= coding);
  check bool (msg ^ " | Coding < Standard") true (coding < standard);
  check bool (msg ^ " | Standard < Parallel") true (standard < parallel);
  check bool (msg ^ " | Parallel <= Full") true (parallel <= full)

(* ============================================================
   Per-mode range assertions
   ============================================================ *)

let assert_in_range mode ~low ~high =
  let n = count_for_mode mode in
  let label = Printf.sprintf "%s: %d tools (expected %d..%d)"
    (Mode.mode_to_string mode) n low high
  in
  check bool label true (n >= low && n <= high)

let test_minimal_range () =
  (* Minimal = [Core_Room; Core_Task; Health] — baseline ~75 after Core split *)
  assert_in_range Minimal ~low:50 ~high:110

let test_standard_range () =
  (* Standard = [Core; Comm; Worktree; Health; Plan; Board; Consensus] — baseline ~221 *)
  assert_in_range Standard ~low:175 ~high:275

let test_parallel_range () =
  (* Parallel = 11 categories — baseline ~251 *)
  assert_in_range Parallel ~low:200 ~high:305

let test_coding_range () =
  (* Coding = core_all @ [Worktree; Code; Health; Plan; Consensus] *)
  assert_in_range Coding ~low:135 ~high:250

let test_full_range () =
  (* Full = all 19 categories = all visible tools — baseline ~362 *)
  assert_in_range Full ~low:290 ~high:440

let test_solo_range () =
  (* Solo = [Core_Room; Core_Task; Worktree] — baseline ~25 after Core split *)
  assert_in_range Solo ~low:15 ~high:40

(* ============================================================
   Full mode = all visible tools (no filtering loss)
   ============================================================ *)

let test_full_equals_visible () =
  let visible = Config.visible_tool_schemas () in
  let full = tools_for_mode Full in
  let visible_count = List.length visible in
  let full_count = List.length full in
  (* Full mode uses all_categories (all 19 non-Unknown categories).
     Every visible tool should be in a known category, so Full = visible. *)
  let msg = Printf.sprintf "visible=%d full=%d" visible_count full_count in
  check bool (msg ^ " | Full == visible") true (full_count = visible_count)

(* ============================================================
   Mode management tools always present in every mode
   ============================================================ *)

let test_mode_mgmt_tools_always_present () =
  let modes = [Mode.Minimal; Standard; Parallel; Coding; Full; Solo; Agent] in
  List.iter (fun mode ->
    let names = tool_names_for_mode mode in
    let has name = List.mem name names in
    let mode_str = Mode.mode_to_string mode in
    check bool (mode_str ^ " has masc_switch_mode") true (has "masc_switch_mode");
    check bool (mode_str ^ " has masc_get_config") true (has "masc_get_config")
  ) modes

(* ============================================================
   No Unknown-category tools leak through
   ============================================================ *)

let test_no_unknown_tools () =
  let modes = [Mode.Minimal; Standard; Parallel; Coding; Full; Solo; Agent] in
  List.iter (fun mode ->
    let names = tool_names_for_mode mode in
    List.iter (fun name ->
      let cat = Mode.tool_category name in
      let mode_str = Mode.mode_to_string mode in
      check bool
        (Printf.sprintf "%s: %s should not be Unknown" mode_str name)
        true (cat <> Mode.Unknown)
    ) names
  ) modes

(* ============================================================
   Category-specific spot checks
   ============================================================ *)

let test_minimal_has_core_tools () =
  let names = tool_names_for_mode Minimal in
  check bool "minimal has masc_join" true (List.mem "masc_join" names);
  check bool "minimal has masc_status" true (List.mem "masc_status" names);
  check bool "minimal has masc_heartbeat" true (List.mem "masc_heartbeat" names)

let test_minimal_lacks_board_tools () =
  let names = tool_names_for_mode Minimal in
  check bool "minimal lacks masc_board_post" true
    (not (List.mem "masc_board_post" names));
  check bool "minimal lacks masc_board_list" true
    (not (List.mem "masc_board_list" names))

let test_standard_has_board_tools () =
  let names = tool_names_for_mode Standard in
  check bool "standard has masc_board_post" true (List.mem "masc_board_post" names);
  check bool "standard has masc_board_list" true (List.mem "masc_board_list" names)

let test_coding_has_code_tools () =
  let names = tool_names_for_mode Coding in
  check bool "coding has masc_code_search" true (List.mem "masc_code_search" names);
  check bool "coding has masc_code_symbols" true (List.mem "masc_code_symbols" names)

let test_solo_lacks_comm_tools () =
  let names = tool_names_for_mode Solo in
  check bool "solo lacks masc_broadcast" true
    (not (List.mem "masc_broadcast" names));
  check bool "solo lacks masc_messages" true
    (not (List.mem "masc_messages" names))

let test_parallel_has_governance () =
  let names = tool_names_for_mode Parallel in
  check bool "parallel has masc_case_status" true
    (List.mem "masc_case_status" names);
  check bool "parallel has masc_cases" true
    (List.mem "masc_cases" names)

(* ============================================================
   Custom mode with empty categories
   ============================================================ *)

let test_custom_empty () =
  let cats = Mode.categories_for_mode Custom in
  check int "custom has 0 categories" 0 (List.length cats);
  let schemas = Config.enabled_tool_schemas cats in
  (* Custom with no categories still gets mode management tools
     plus any Hidden tools that bypass filtering *)
  let names = List.map (fun (s : Types.tool_schema) -> s.name) schemas in
  check bool "custom has masc_switch_mode" true (List.mem "masc_switch_mode" names);
  check bool "custom has masc_get_config" true (List.mem "masc_get_config" names)

(* ============================================================
   Print actual counts (diagnostic, always passes)
   ============================================================ *)

let test_print_counts () =
  let modes = [
    ("Solo", Mode.Solo); ("Minimal", Mode.Minimal);
    ("Coding", Mode.Coding); ("Standard", Mode.Standard);
    ("Parallel", Mode.Parallel); ("Full", Mode.Full);
  ] in
  let all_count = List.length Config.all_tool_schemas in
  let visible_count = List.length (Config.visible_tool_schemas ()) in
  Printf.printf "\n=== Tool Count Report ===\n";
  Printf.printf "all_tool_schemas: %d\n" all_count;
  Printf.printf "visible_tool_schemas: %d\n" visible_count;
  List.iter (fun (name, mode) ->
    Printf.printf "%s: %d\n" name (count_for_mode mode)
  ) modes;
  Printf.printf "=========================\n%!";
  check bool "all_tool_schemas > 0" true (all_count > 0);
  check bool "visible_tool_schemas > 0" true (visible_count > 0)

(* ============================================================
   Test runner
   ============================================================ *)

let () =
  run "mode_tool_count" [
    "invariants", [
      test_case "monotonic ordering" `Quick test_monotonic_ordering;
      test_case "mode mgmt always present" `Quick test_mode_mgmt_tools_always_present;
      test_case "no unknown tools" `Quick test_no_unknown_tools;
      test_case "full equals visible" `Quick test_full_equals_visible;
    ];
    "ranges", [
      test_case "minimal range" `Quick test_minimal_range;
      test_case "standard range" `Quick test_standard_range;
      test_case "parallel range" `Quick test_parallel_range;
      test_case "coding range" `Quick test_coding_range;
      test_case "full range" `Quick test_full_range;
      test_case "solo range" `Quick test_solo_range;
    ];
    "spot_checks", [
      test_case "minimal has core tools" `Quick test_minimal_has_core_tools;
      test_case "minimal lacks board" `Quick test_minimal_lacks_board_tools;
      test_case "standard has board" `Quick test_standard_has_board_tools;
      test_case "coding has code tools" `Quick test_coding_has_code_tools;
      test_case "solo lacks comm" `Quick test_solo_lacks_comm_tools;
      test_case "parallel has governance" `Quick test_parallel_has_governance;
      test_case "custom empty" `Quick test_custom_empty;
    ];
    "diagnostics", [
      test_case "print counts" `Quick test_print_counts;
    ];
  ]
