open Alcotest

module TR = Masc.Keeper_tool_resolution

(* ── resolve returns correct tried_source for each admission path ── *)

let test_public_descriptor_admits_execute () =
  match TR.resolve "Execute" with
  | TR.Alias_to { canonical; via = TR.Public_descriptor } ->
      check string "canonical is tool_execute" "tool_execute" canonical
  | other ->
      fail (Printf.sprintf "expected Alias_to via Public_descriptor, got: %s"
              (match other with
               | TR.Resolved { via; _ } -> "Resolved via " ^ TR.string_of_tried_source via
               | TR.Alias_to { via; _ } -> "Alias_to via " ^ TR.string_of_tried_source via
               | TR.Unknown _ -> "Unknown"))

let test_registry_admits_keeper_board_post () =
  match TR.resolve "keeper_board_post" with
  | TR.Resolved { via = TR.Registry_core_tools; _ } -> ()
  | other ->
      fail (Printf.sprintf "expected keeper_board_post to resolve, got: %s"
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
      (* 7 base sources after Tool_name admission, the dead public MCP source, and the
         per-actor Surface sources were removed. *)
      check bool "at least 7 tried sources" true (List.length tried >= 7)
  | _ ->
      fail "__nonexistent_tool_xyz should be Unknown"

let test_descriptor_registry_admits_masc_keeper_cluster () =
  (* Boot regression guard: #19797 purged masc_keeper_* from surface lists.
     Descriptor_registry source (over internal_descriptors public names)
     (over internal_descriptors public names) restores admission without
     touching dispatch. @check does NOT exercise this path, hence this test. *)
  List.iter
    (fun name ->
      match TR.resolve name with
      | TR.Resolved { via = TR.Descriptor_registry; _ } -> ()
      | TR.Resolved { via; _ } | TR.Alias_to { via; _ } ->
          fail (Printf.sprintf
                  "%s should resolve via Descriptor_registry, got via: %s"
                  name (TR.string_of_tried_source via))
      | TR.Unknown { tried; _ } ->
          fail (Printf.sprintf
                  "%s must resolve (boot policy gate would exit 1), got Unknown (tried: %s)"
                  name (TR.string_of_tried tried)))
    [ "masc_keeper_msg"; "masc_keeper_msg_result"; "masc_keeper_msg_cancel"; "masc_keeper_msg_queue"; "masc_keeper_list"; "masc_keeper_status" ]

let test_keeper_report_state_removed () =
  check bool
    "keeper_report_state is no longer core always"
    false
    (Masc.Keeper_tool_registry.is_core_always_tool "keeper_report_state");
  match TR.resolve "keeper_report_state" with
  | TR.Unknown _ -> ()
  | TR.Resolved { via; _ } | TR.Alias_to { via; _ } ->
      fail
        (Printf.sprintf
           "keeper_report_state was removed; unexpected resolution via %s"
           (TR.string_of_tried_source via))

let test_tool_execute_resolves () =
  (* Was "resolves via surface"; the per-actor Surface source was removed in
     the surface-cut refactor. tool_execute now resolves via an earlier source
     (Dispatch_table / Public_descriptor). *)
  match TR.resolve "tool_execute" with
  | TR.Resolved _ | TR.Alias_to _ -> ()
  | TR.Unknown { tried; _ } ->
      fail (Printf.sprintf "tool_execute should resolve, got Unknown (tried: %s)"
              (TR.string_of_tried tried))

let test_masc_board_post_resolves () =
  match TR.resolve "masc_board_post" with
  | TR.Resolved _ | TR.Alias_to _ -> ()
  | TR.Unknown { tried; _ } ->
      fail (Printf.sprintf "masc_board_post should resolve, got Unknown (tried: %s)"
              (TR.string_of_tried tried))

let test_hidden_descriptor_precedes_system_internal_fallback () =
  (* masc_gc is a system-internal tool (tool_misc dispatch, hidden from keeper
     surfaces). It also has a dispatch-only descriptor, which is earlier in the
     resolution chain. Keep the current provenance explicit while asserting that
     the System_internal fallback still independently recognizes the real tool. *)
  match TR.resolve "masc_gc" with
  | TR.Resolved { via = TR.Descriptor_registry; canonical } ->
      check string "canonical preserved" "masc_gc" canonical;
      check bool
        "system-internal fallback also admits masc_gc"
        true
        (List.mem TR.System_internal (TR.all_admitting_sources "masc_gc"))
  | TR.Resolved { via; _ } | TR.Alias_to { via; _ } ->
      fail (Printf.sprintf "masc_gc resolved via %s; expected Descriptor_registry"
              (TR.string_of_tried_source via))
  | TR.Unknown { tried; _ } ->
      fail (Printf.sprintf
              "masc_gc must resolve (system-internal tool), got Unknown (tried: %s)"
              (TR.string_of_tried tried))

(* ── Policy validation surface ── *)

let resolves name =
  match TR.resolve name with
  | TR.Resolved _ | TR.Alias_to _ -> true
  | TR.Unknown _ -> false

let policy_validation_tool_names =
  [ "keeper_board_post"
  ; "tool_search_files"
  ; "tool_execute"
  ; "Execute"
  ; "Read"
  ; "Search"
  ; "keeper_task_done"
  ; "keeper_time_now"
  ; "masc_status"
  ; "mcp__masc__masc_status"
  ; "masc_transition"
  ]

let test_policy_validation_known_tools_resolve () =
  List.iter
    (fun name -> check bool (name ^ " resolves") true (resolves name))
    policy_validation_tool_names

let test_policy_validation_unknown_tool_misses () =
  check bool "__missing_tool misses" false (resolves "__missing_tool")

let test_public_descriptor_names_resolve () =
  List.iter
    (fun name -> check bool (name ^ " resolves") true (resolves name))
    [
      "Execute";
      "Grep";
      "Search";
      "Read";
      "Edit";
      "Write";
      "WebSearch";
      "WebFetch";
    ]

let test_retired_public_names_miss () =
  List.iter
    (fun name -> check bool (name ^ " misses") false (resolves name))
    [
      "Bash";
      "SearchFiles";
      "ReadFile";
      "EditFile";
      "WriteFile";
      "keeper_task_submit_for_verification";
    ]

(* ── Core tool names that must resolve ── *)

let policy_tool_names =
  List.sort_uniq String.compare
    [
      "keeper_board_comment";
      "keeper_board_curation_read";
      "keeper_board_curation_submit";
      "keeper_board_post_get";
      "keeper_board_list";
      "keeper_board_post";
      "keeper_board_search";
      "keeper_board_stats";
      "keeper_board_vote";
      "keeper_broadcast";
      "keeper_context_status";
      "keeper_library_read";
      "keeper_surface_read";
      "keeper_surface_post";
      "keeper_person_note_set";
      "keeper_library_search";
      "keeper_memory_search";
      "keeper_memory_write";
      "keeper_task_claim";
      "keeper_task_create";
      "keeper_task_done";
      "keeper_tasks_audit";
      "keeper_tasks_list";
      "keeper_time_now";
      "keeper_tool_search";
      "keeper_tools_list";
      "keeper_voice_agent";
      "keeper_voice_listen";
      "keeper_voice_session_end";
      "keeper_voice_session_start";
      "keeper_voice_sessions";
      "keeper_voice_speak";
      "masc_add_task";
      "masc_agent_card";
      "masc_batch_add_tasks";
      "masc_broadcast";

      "masc_dashboard";
      "masc_goal_list";
      "masc_goal_transition";
      "masc_goal_upsert";
      "masc_goal_verify";
      "masc_heartbeat";
      "masc_keeper_list";
      "masc_keeper_msg";
      "masc_keeper_msg_result";
      "masc_keeper_msg_cancel";
      "masc_keeper_msg_queue";
      "masc_keeper_status";
      "masc_messages";
      "masc_plan_get";
      "masc_plan_get_task";
      "masc_status";
      "masc_task_history";
      "masc_tasks";
      "masc_tool_help";
      "masc_transition";
      "masc_web_fetch";
      "masc_web_search";
      "tool_edit_file";
      "tool_execute";
      "tool_read_file";
      "tool_search_files";
      "tool_write_file";
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
  if unresolved <> [] then
    fail (Printf.sprintf "unresolved: %s" (String.concat ", " unresolved));
  check int "all active policy tools should resolve" 0 (List.length unresolved)

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
        test_case "Execute resolves via public descriptor" `Quick test_public_descriptor_admits_execute;
        test_case "keeper_board_post resolves via registry" `Quick test_registry_admits_keeper_board_post;
        test_case "mcp prefix stripped and resolved" `Quick test_mcp_prefix_stripped;
        test_case "unknown returns tried list" `Quick test_unknown_returns_tried_list;
        test_case "keeper_report_state is removed" `Quick test_keeper_report_state_removed;
        test_case "tool_execute resolves" `Quick test_tool_execute_resolves;
        test_case "masc_keeper_* cluster resolves via descriptor registry (boot guard)" `Quick test_descriptor_registry_admits_masc_keeper_cluster;
        test_case "masc_board_post resolves" `Quick test_masc_board_post_resolves;
        test_case "masc_gc descriptor precedes the system-internal fallback" `Quick test_hidden_descriptor_precedes_system_internal_fallback;
      ]
    ; "policy_validation", [
        test_case "known tools resolve" `Quick test_policy_validation_known_tools_resolve;
        test_case "unknown tools miss" `Quick test_policy_validation_unknown_tool_misses;
        test_case "public descriptor names resolve" `Quick test_public_descriptor_names_resolve;
        test_case "retired public names miss" `Quick test_retired_public_names_miss;
      ]
    ; "matrix", [
        test_case "all policy tools resolve" `Quick test_all_policy_tools_resolve;
        test_case "matrix report: 0 dead entries" `Quick test_matrix_report;
        test_case "full-probe overlap analysis" `Quick test_full_probe_overlap;
      ]
    ]
