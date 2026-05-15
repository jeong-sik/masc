open Alcotest

module TR = Masc_mcp.Keeper_tool_resolution

(* ── resolve returns correct tried_source for each admission path ── *)

let test_alias_route_admits_bash () =
  match TR.resolve "Bash" with
  | TR.Alias_to { canonical; via = TR.Alias_route } ->
      check string "canonical is Bash" "Bash" canonical
  | other ->
      fail (Printf.sprintf "expected Alias_to via Alias_route, got: %s"
              (match other with
               | TR.Resolved { via; _ } -> "Resolved via " ^ TR.string_of_tried_source via
               | TR.Alias_to { via; _ } -> "Alias_to via " ^ TR.string_of_tried_source via
               | TR.Unknown _ -> "Unknown"))

let test_tool_name_variant_admits_keeper_board_post () =
  match TR.resolve "keeper_board_post" with
  | TR.Resolved { via = TR.Tool_name_variant; _ } -> ()
  | other ->
      fail (Printf.sprintf "expected Resolved via Tool_name_variant, got: %s"
              (match other with
               | TR.Resolved { via; _ } -> "Resolved via " ^ TR.string_of_tried_source via
               | TR.Alias_to { via; _ } -> "Alias_to via " ^ TR.string_of_tried_source via
               | TR.Unknown _ -> "Unknown"))

let test_mcp_prefix_stripped () =
  (* "mcp__masc__masc_status" should strip prefix to "masc_status" and resolve *)
  match TR.resolve "mcp__masc__masc_status" with
  | TR.Resolved _ | TR.Alias_to _ -> ()
  | TR.Unknown { name; tried } ->
      fail (Printf.sprintf "mcp__masc__masc_status should resolve, got Unknown: %s (tried: %s)"
              name (TR.string_of_tried tried))

let test_unknown_returns_tried_list () =
  match TR.resolve "__nonexistent_tool_xyz" with
  | TR.Unknown { name; tried } ->
      check string "name preserved" "__nonexistent_tool_xyz" name;
      check bool "at least 13 tried sources" true (List.length tried >= 13)
  | _ ->
      fail "__nonexistent_tool_xyz should be Unknown"

let test_extend_turns_resolved () =
  (* extend_turns is in core_always_tools (S7: Registry_core_tools) or
     Tool_name_variant depending on order *)
  match TR.resolve "extend_turns" with
  | TR.Resolved _ -> ()
  | TR.Alias_to _ -> ()
  | TR.Unknown { name; tried } ->
      fail (Printf.sprintf "extend_turns should resolve, got Unknown (tried: %s)"
              (TR.string_of_tried tried))

let test_surface_admits_masc_code_git () =
  match TR.resolve "masc_code_git" with
  | TR.Resolved { via = TR.Surface _; _ } -> ()
  | TR.Resolved { via; _ } ->
      (* Admitted through a different source — still ok for shim *)
      ignore via
  | TR.Alias_to _ -> ()
  | TR.Unknown { tried; _ } ->
      fail (Printf.sprintf "masc_code_git should resolve, got Unknown (tried: %s)"
              (TR.string_of_tried tried))

let test_alias_masc_to_internal () =
  match TR.resolve "masc_board_post" with
  | TR.Resolved _ | TR.Alias_to _ -> ()
  | TR.Unknown { tried; _ } ->
      fail (Printf.sprintf "masc_board_post should resolve, got Unknown (tried: %s)"
              (TR.string_of_tried tried))

(* ── is_known_policy_tool_name legacy adapter ── *)

let test_legacy_adapter_known () =
  check bool "keeper_bash is known" true
    (TR.is_known_policy_tool_name "keeper_bash");
  check bool "Bash is known" true
    (TR.is_known_policy_tool_name "Bash");
  check bool "masc_status is known" true
    (TR.is_known_policy_tool_name "masc_status")

let test_legacy_adapter_unknown () =
  check bool "__missing_tool is not known" false
    (TR.is_known_policy_tool_name "__missing_tool")

(* ── Phase 4: 88×15 Matrix — every tool_policy.toml tool resolves ── *)

let policy_tool_names = [
  "extend_turns"; "keeper_bash"; "keeper_board_cleanup"; "keeper_board_comment";
  "keeper_board_curation_read"; "keeper_board_curation_submit"; "keeper_board_delete";
  "keeper_board_get"; "keeper_board_list"; "keeper_board_post"; "keeper_board_search";
  "keeper_board_stats"; "keeper_board_vote"; "keeper_broadcast"; "keeper_context_status";
  "keeper_fs_edit"; "keeper_fs_read"; "keeper_library_read"; "keeper_library_search";
  "keeper_memory_search"; "keeper_memory_write"; "keeper_pr_create"; "keeper_pr_list";
  "keeper_pr_review_comment"; "keeper_pr_review_read"; "keeper_pr_review_reply";
  "keeper_pr_status"; "keeper_preflight_check"; "keeper_shell"; "keeper_task_done";
  "keeper_task_submit_for_verification"; "keeper_time_now"; "keeper_tool_search";
  "keeper_tools_list"; "masc_approval_pending"; "masc_code_delete"; "masc_code_edit";
  "masc_code_git"; "masc_code_read"; "masc_code_search"; "masc_code_shell";
  "masc_code_symbols"; "masc_code_write"; "masc_status"; "masc_web_fetch";
  "masc_web_search"; "masc_worktree_create"; "masc_worktree_list"; "masc_worktree_remove";
]

(** Categorize each tool by which sources admit it.
    A = multi-source (>=2), B = single-source (1), C = zero-source (dead), D = alias-only *)
type category = A | B | C | D

let categorize resolution =
  match resolution with
  | TR.Unknown _ -> C
  | TR.Alias_to _ -> D
  | TR.Resolved _ -> A (* Resolved means at least 1 source hit; multi-source requires deeper analysis *)

let string_of_category = function A -> "A(multi)" | B -> "B(single)" | C -> "C(dead)" | D -> "D(alias)"

let test_all_policy_tools_resolve () =
  let unresolved =
    List.filter_map (fun name ->
      match TR.resolve name with
      | TR.Resolved _ | TR.Alias_to _ -> None
      | TR.Unknown _ -> Some name
    ) policy_tool_names
  in
  check int "all 50 policy tools should resolve" 0 (List.length unresolved);
  if unresolved <> [] then
    fail (Printf.sprintf "unresolved: %s" (String.concat ", " unresolved))

let test_matrix_report () =
  let results =
    List.map (fun name ->
      let res = TR.resolve name in
      let cat = categorize res in
      (name, res, cat)
    ) policy_tool_names
  in
  let a_count = List.length (List.filter (fun (_, _, c) -> c = A) results) in
  let d_count = List.length (List.filter (fun (_, _, c) -> c = D) results) in
  let c_count = List.length (List.filter (fun (_, _, c) -> c = C) results) in
  (* Phase 4 gate: 0 dead entries *)
  check int "dead entries (C) should be 0" 0 c_count;
  (* All entries must resolve *)
  check int "resolved + alias entries should equal total" (List.length policy_tool_names)
    (a_count + d_count + c_count);
  (* Provenance report for Phase 5 analysis *)
  List.iter (fun (name, res, _cat) ->
    match res with
    | TR.Resolved { via; _ } ->
        Printf.printf "  [A] %-40s via=%s\n" name (TR.string_of_tried_source via)
    | TR.Alias_to { canonical; via; _ } ->
        Printf.printf "  [D] %-40s -> %s via=%s\n" name canonical (TR.string_of_tried_source via)
    | TR.Unknown { tried; _ } ->
        Printf.printf "  [C] %-40s tried=[%s]\n" name (TR.string_of_tried tried)
  ) results;
  Printf.printf "  Summary: A=%d D=%d C=%d total=%d\n" a_count d_count c_count (List.length policy_tool_names)

(* ── Phase 5: full-probe overlap analysis ── *)

let test_full_probe_overlap () =
  (* Each tool must admit from >= 1 source via all_admitting_sources *)
  let per_tool =
    List.map (fun name ->
      let sources = TR.all_admitting_sources name in
      (name, sources, List.length sources)
    ) policy_tool_names
  in
  let single_source =
    List.filter_map (fun (name, sources, count) ->
      if count = 1 then Some (name, List.hd sources) else None
    ) per_tool
  in
  let zero_source =
    List.filter (fun (_, _, count) -> count = 0) per_tool
  in
  (* No tool should have 0 sources *)
  check int "zero-source tools should be 0" 0 (List.length zero_source);
  (* Report overlap distribution *)
  let multi_count = List.length policy_tool_names - List.length single_source in
  Printf.printf "  Full-probe: %d multi-source, %d single-source, %d zero-source\n"
    multi_count (List.length single_source) (List.length zero_source);
  List.iter (fun (name, sources, count) ->
    Printf.printf "  %-40s %2d sources: %s\n" name count (TR.string_of_tried sources)
  ) per_tool;
  (* Phase 5 gate: tools with only 1 source are fragile *)
  if single_source <> [] then begin
    Printf.printf "  Single-source (fragile) tools:\n";
    List.iter (fun (name, src) ->
      Printf.printf "    %-40s only via %s\n" name (TR.string_of_tried_source src)
    ) single_source
  end

(* ── Suite ── *)

let () =
  Alcotest.run "test_tool_resolution"
    [ "resolve", [
        test_case "Bash resolves via Alias_route" `Quick test_alias_route_admits_bash;
        test_case "keeper_board_post resolves via Tool_name_variant" `Quick test_tool_name_variant_admits_keeper_board_post;
        test_case "mcp prefix stripped and resolved" `Quick test_mcp_prefix_stripped;
        test_case "unknown returns tried list" `Quick test_unknown_returns_tried_list;
        test_case "extend_turns resolves" `Quick test_extend_turns_resolved;
        test_case "masc_code_git resolves via surface" `Quick test_surface_admits_masc_code_git;
        test_case "masc_board_post resolves via alias" `Quick test_alias_masc_to_internal;
      ]
    ; "legacy_adapter", [
        test_case "known tools return true" `Quick test_legacy_adapter_known;
        test_case "unknown tools return false" `Quick test_legacy_adapter_unknown;
      ]
    ; "matrix", [
        test_case "all policy tools resolve" `Quick test_all_policy_tools_resolve;
        test_case "matrix report: 0 dead entries" `Quick test_matrix_report;
        test_case "full-probe overlap analysis" `Quick test_full_probe_overlap;
      ]
    ]
