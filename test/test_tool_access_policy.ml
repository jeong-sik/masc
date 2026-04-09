(** Tests for Tool_access_policy — shared allow/deny selector ADT.

    Covers: selector variants, normalize_names edge cases, deny-wins
    semantics, with_deny_* composition, resolve with/without candidates,
    and integration with Tool_catalog surfaces. *)

open Alcotest
open Masc_mcp

let init_keeper_tool_registry () =
  Masc_test_deps.init_keeper_tool_registry ()

(* ================================================================ *)
(* Selector basics                                                   *)
(* ================================================================ *)

let test_empty_selector_matches_nothing () =
  check bool "Empty never matches" false
    (Tool_access_policy.selector_matches_name Empty "anything");
  check bool "Empty vs empty string" false
    (Tool_access_policy.selector_matches_name Empty "")

let test_all_selector_matches_everything () =
  check bool "All matches known tool" true
    (Tool_access_policy.selector_matches_name All "masc_status");
  check bool "All matches arbitrary string" true
    (Tool_access_policy.selector_matches_name All "nonexistent_tool_xyz")

let test_names_selector_exact_match () =
  let sel = Tool_access_policy.Names [ "masc_status"; "masc_join" ] in
  check bool "matches listed name" true
    (Tool_access_policy.selector_matches_name sel "masc_status");
  check bool "rejects unlisted name" false
    (Tool_access_policy.selector_matches_name sel "masc_leave")

let test_names_selector_trims_and_dedupes () =
  let sel = Tool_access_policy.Names [ " masc_status "; "masc_status"; ""; "  " ] in
  check bool "matches after trim" true
    (Tool_access_policy.selector_matches_name sel "masc_status");
  check bool "empty strings filtered" false
    (Tool_access_policy.selector_matches_name sel "")

(* ================================================================ *)
(* Union selector                                                    *)
(* ================================================================ *)

let test_union_empty_list_is_empty () =
  let sel = Tool_access_policy.union [] in
  check bool "union of [] is Empty" false
    (Tool_access_policy.selector_matches_name sel "anything")

let test_union_single_element_unwraps () =
  let inner = Tool_access_policy.Names [ "masc_status" ] in
  let sel = Tool_access_policy.union [ inner ] in
  (* Single-element union should be the element itself, not Union [inner] *)
  check bool "matches through single union" true
    (Tool_access_policy.selector_matches_name sel "masc_status");
  check bool "rejects non-member" false
    (Tool_access_policy.selector_matches_name sel "masc_leave")

let test_union_matches_any_member () =
  let selector =
    Tool_access_policy.union
      [ Names [ "masc_status" ]; Surface Tool_catalog.Admin ]
  in
  check bool "status in union" true
    (Tool_access_policy.selector_matches_name selector "masc_status");
  check bool "admin surface tool in union" true
    (Tool_access_policy.selector_matches_name selector "masc_tool_admin_update")

let test_union_of_empties_matches_nothing () =
  let sel = Tool_access_policy.union [ Empty; Empty; Empty ] in
  check bool "union of empties" false
    (Tool_access_policy.selector_matches_name sel "anything")

(* ================================================================ *)
(* Policy presets                                                     *)
(* ================================================================ *)

let test_empty_policy_denies_everything () =
  let policy = Tool_access_policy.empty in
  check bool "empty allows nothing" false
    (Tool_access_policy.allows_name policy "masc_status");
  check bool "empty resolve is []" true
    (Tool_access_policy.resolve policy = [])

let test_allow_all_policy () =
  let policy = Tool_access_policy.allow_all in
  check bool "allow_all permits known tool" true
    (Tool_access_policy.allows_name policy "masc_status");
  check bool "allow_all permits arbitrary name" true
    (Tool_access_policy.allows_name policy "totally_unknown_tool")

(* ================================================================ *)
(* Deny-wins semantics                                               *)
(* ================================================================ *)

let test_deny_overrides_allow () =
  let policy =
    Tool_access_policy.of_allowlist
      ~deny:[ "masc_board_post" ]
      [ "masc_status"; "masc_board_post" ]
  in
  check bool "status allowed" true
    (Tool_access_policy.allows_name policy "masc_status");
  check bool "board_post denied even though in allow" false
    (Tool_access_policy.allows_name policy "masc_board_post")

let test_deny_all_blocks_everything () =
  let policy = { Tool_access_policy.allow = All; deny = All } in
  check bool "allow=All + deny=All -> denied" false
    (Tool_access_policy.allows_name policy "masc_status")

let test_allow_names_deny_same_names () =
  let names = [ "a"; "b"; "c" ] in
  let policy = Tool_access_policy.of_allowlist ~deny:names names in
  check bool "all denied" true
    (List.for_all
      (fun n -> not (Tool_access_policy.allows_name policy n))
      names);
  check bool "resolve is empty" true
    (Tool_access_policy.resolve policy = [])

(* ================================================================ *)
(* with_deny_* composition                                           *)
(* ================================================================ *)

let test_with_deny_names_adds_to_existing () =
  let base = Tool_access_policy.of_allowlist [ "a"; "b"; "c" ] in
  let extended = Tool_access_policy.with_deny_names base [ "b" ] in
  check bool "a still allowed" true
    (Tool_access_policy.allows_name extended "a");
  check bool "b now denied" false
    (Tool_access_policy.allows_name extended "b");
  check bool "c still allowed" true
    (Tool_access_policy.allows_name extended "c")

let test_with_deny_selector_empty_is_noop () =
  let base = Tool_access_policy.of_allowlist [ "a"; "b" ] in
  let same = Tool_access_policy.with_deny_selector base Empty in
  check bool "a still allowed" true
    (Tool_access_policy.allows_name same "a");
  check bool "b still allowed" true
    (Tool_access_policy.allows_name same "b")

let test_with_deny_selector_accumulates () =
  let base = Tool_access_policy.of_allowlist [ "a"; "b"; "c" ] in
  let step1 = Tool_access_policy.with_deny_names base [ "a" ] in
  let step2 = Tool_access_policy.with_deny_names step1 [ "b" ] in
  check bool "a denied after step1" false
    (Tool_access_policy.allows_name step2 "a");
  check bool "b denied after step2" false
    (Tool_access_policy.allows_name step2 "b");
  check bool "c survives both" true
    (Tool_access_policy.allows_name step2 "c")

(* ================================================================ *)
(* resolve / resolve_selector                                        *)
(* ================================================================ *)

let test_resolve_empty_returns_empty () =
  let resolved = Tool_access_policy.resolve_selector Empty in
  check (list string) "Empty resolves to []" [] resolved

let test_resolve_all_with_candidates () =
  let candidates = [ "x"; "y"; "z" ] in
  let resolved =
    Tool_access_policy.resolve_selector ~candidates All
  in
  check (list string) "All with candidates returns candidates"
    [ "x"; "y"; "z" ] resolved

let test_resolve_names_deduplicates () =
  let resolved =
    Tool_access_policy.resolve_selector
      (Names [ "a"; "b"; "a"; " b "; "c" ])
  in
  check (list string) "deduped and trimmed" [ "a"; "b"; "c" ] resolved

let test_resolve_policy_deny_removes_from_allow () =
  let policy = {
    Tool_access_policy.allow = Names [ "a"; "b"; "c"; "d" ];
    deny = Names [ "b"; "d" ];
  } in
  let resolved = Tool_access_policy.resolve policy in
  check (list string) "only non-denied remain" [ "a"; "c" ] resolved

let test_resolve_union_flattens_and_dedupes () =
  let sel = Tool_access_policy.Union [
    Names [ "a"; "b" ];
    Names [ "b"; "c" ];
  ] in
  let resolved = Tool_access_policy.resolve_selector sel in
  check (list string) "union flattened, deduped" [ "a"; "b"; "c" ] resolved

(* ================================================================ *)
(* Surface integration                                               *)
(* ================================================================ *)

let test_surface_resolution_respects_candidates () =
  let candidates =
    [ "masc_status"; "masc_add_task"; "masc_board_post"; "totally_unknown" ]
  in
  let policy =
    {
      Tool_access_policy.allow = Surface Tool_catalog.Local_worker;
      deny = Names [ "masc_add_task" ];
    }
  in
  let resolved = Tool_access_policy.resolve ~candidates policy in
  check bool "keeps status" true (List.mem "masc_status" resolved);
  check bool "drops denied tool" false (List.mem "masc_add_task" resolved);
  check bool "drops candidate outside surface" false
    (List.mem "totally_unknown" resolved)

let test_keeper_denied_surface_blocks_tools () =
  let denied_tools = Tool_catalog.tools_for_surface Tool_catalog.Keeper_denied in
  let policy = {
    Tool_access_policy.allow = All;
    deny = Surface Tool_catalog.Keeper_denied;
  } in
  check bool "keeper_denied surface has tools" true
    (List.length denied_tools > 0);
  List.iter (fun tool_name ->
    check bool
      (Printf.sprintf "%s denied by Keeper_denied surface" tool_name)
      false
      (Tool_access_policy.allows_name policy tool_name)
  ) denied_tools

(* ================================================================ *)
(* of_allowlist convenience constructor                              *)
(* ================================================================ *)

let test_of_allowlist_no_deny () =
  let policy = Tool_access_policy.of_allowlist [ "a"; "b" ] in
  check bool "a allowed" true (Tool_access_policy.allows_name policy "a");
  check bool "b allowed" true (Tool_access_policy.allows_name policy "b");
  check bool "c not allowed" false (Tool_access_policy.allows_name policy "c")

let test_of_allowlist_empty () =
  let policy = Tool_access_policy.of_allowlist [] in
  check bool "nothing allowed" false
    (Tool_access_policy.allows_name policy "anything");
  check bool "resolve is empty" true
    (Tool_access_policy.resolve policy = [])

(* ================================================================ *)
(* Inter selector                                                    *)
(* ================================================================ *)

let test_inter_matches_common_only () =
  let sel =
    Tool_access_policy.Inter
      [ Names [ "a"; "b"; "c" ]; Names [ "b"; "c"; "d" ] ]
  in
  check bool "a only in first" false
    (Tool_access_policy.selector_matches_name sel "a");
  check bool "b in both" true
    (Tool_access_policy.selector_matches_name sel "b");
  check bool "c in both" true
    (Tool_access_policy.selector_matches_name sel "c");
  check bool "d only in second" false
    (Tool_access_policy.selector_matches_name sel "d")

let test_inter_empty_list_is_all () =
  let sel = Tool_access_policy.inter [] in
  check bool "inter [] matches anything" true
    (Tool_access_policy.selector_matches_name sel "anything")

let test_inter_single_unwraps () =
  let inner = Tool_access_policy.Names [ "a"; "b" ] in
  let sel = Tool_access_policy.inter [ inner ] in
  check bool "matches a" true
    (Tool_access_policy.selector_matches_name sel "a");
  check bool "rejects c" false
    (Tool_access_policy.selector_matches_name sel "c")

let test_inter_with_empty_yields_nothing () =
  let sel =
    Tool_access_policy.Inter [ Names [ "a"; "b" ]; Empty ]
  in
  check bool "Empty kills intersection" false
    (Tool_access_policy.selector_matches_name sel "a")

let test_inter_is_commutative () =
  let s1 = Tool_access_policy.Names [ "a"; "b"; "c" ] in
  let s2 = Tool_access_policy.Names [ "b"; "c"; "d" ] in
  let forward = Tool_access_policy.Inter [ s1; s2 ] in
  let reverse = Tool_access_policy.Inter [ s2; s1 ] in
  List.iter
    (fun name ->
      check bool
        (Printf.sprintf "%s: forward = reverse" name)
        (Tool_access_policy.selector_matches_name forward name)
        (Tool_access_policy.selector_matches_name reverse name))
    [ "a"; "b"; "c"; "d"; "e" ]

let test_resolve_inter_computes_intersection () =
  let sel =
    Tool_access_policy.Inter
      [ Names [ "a"; "b"; "c" ]; Names [ "b"; "c"; "d" ] ]
  in
  let resolved = Tool_access_policy.resolve_selector sel in
  check (list string) "intersection of two sets" [ "b"; "c" ] resolved

let test_resolve_inter_three_way () =
  let sel =
    Tool_access_policy.Inter
      [
        Names [ "a"; "b"; "c"; "d" ];
        Names [ "b"; "c"; "d"; "e" ];
        Names [ "c"; "d"; "e"; "f" ];
      ]
  in
  let resolved = Tool_access_policy.resolve_selector sel in
  check (list string) "three-way intersection" [ "c"; "d" ] resolved

(* ================================================================ *)
(* Diff selector                                                     *)
(* ================================================================ *)

let test_diff_subtracts_exclude () =
  let sel =
    Tool_access_policy.Diff
      { base = Names [ "a"; "b"; "c" ]; exclude = Names [ "b" ] }
  in
  check bool "a kept" true
    (Tool_access_policy.selector_matches_name sel "a");
  check bool "b excluded" false
    (Tool_access_policy.selector_matches_name sel "b");
  check bool "c kept" true
    (Tool_access_policy.selector_matches_name sel "c")

let test_diff_empty_exclude_is_identity () =
  let base = Tool_access_policy.Names [ "a"; "b" ] in
  let sel = Tool_access_policy.diff ~base ~exclude:Empty in
  check bool "a kept" true
    (Tool_access_policy.selector_matches_name sel "a");
  check bool "b kept" true
    (Tool_access_policy.selector_matches_name sel "b")

let test_diff_empty_base_is_empty () =
  let sel =
    Tool_access_policy.diff ~base:Empty ~exclude:(Names [ "a" ])
  in
  check bool "empty base -> nothing" false
    (Tool_access_policy.selector_matches_name sel "a")

let test_diff_with_surface () =
  let sel =
    Tool_access_policy.Diff
      {
        base = Surface Tool_catalog.Public_mcp;
        exclude = Names [ "masc_board_delete" ];
      }
  in
  check bool "status still in public" true
    (Tool_access_policy.selector_matches_name sel "masc_status");
  check bool "board_delete excluded" false
    (Tool_access_policy.selector_matches_name sel "masc_board_delete")

let test_resolve_diff () =
  let sel =
    Tool_access_policy.Diff
      { base = Names [ "a"; "b"; "c"; "d" ]; exclude = Names [ "b"; "d" ] }
  in
  let resolved = Tool_access_policy.resolve_selector sel in
  check (list string) "base minus exclude" [ "a"; "c" ] resolved

let test_resolve_diff_disjoint_is_base () =
  let sel =
    Tool_access_policy.Diff
      { base = Names [ "a"; "b" ]; exclude = Names [ "x"; "y" ] }
  in
  let resolved = Tool_access_policy.resolve_selector sel in
  check (list string) "disjoint exclude = base unchanged" [ "a"; "b" ] resolved

(* ================================================================ *)
(* Inter + Diff composition                                          *)
(* ================================================================ *)

let test_inter_with_all_narrows_to_other () =
  let sel =
    Tool_access_policy.Inter [ All; Names [ "a"; "b" ] ]
  in
  check bool "a in both" true
    (Tool_access_policy.selector_matches_name sel "a");
  check bool "c not in Names" false
    (Tool_access_policy.selector_matches_name sel "c")

let test_resolve_inter_with_all () =
  let sel =
    Tool_access_policy.Inter
      [ All; Names [ "x"; "y" ] ]
  in
  let resolved =
    Tool_access_policy.resolve_selector ~candidates:[ "x"; "y"; "z" ] sel
  in
  check (list string) "All ∩ Names = Names" [ "x"; "y" ] resolved

let test_deny_with_inter () =
  let policy =
    {
      Tool_access_policy.allow = Names [ "a"; "b"; "c"; "d" ];
      deny = Inter [ Names [ "b"; "c"; "d" ]; Names [ "c"; "d"; "e" ] ];
    }
  in
  check bool "a allowed (not in deny inter)" true
    (Tool_access_policy.allows_name policy "a");
  check bool "b allowed (only in one deny arm)" true
    (Tool_access_policy.allows_name policy "b");
  check bool "c denied (in both deny arms)" false
    (Tool_access_policy.allows_name policy "c");
  check bool "d denied (in both deny arms)" false
    (Tool_access_policy.allows_name policy "d")

let test_deny_with_diff () =
  let policy =
    {
      Tool_access_policy.allow = Names [ "a"; "b"; "c" ];
      deny =
        Diff
          { base = Names [ "a"; "b"; "c" ]; exclude = Names [ "a" ] };
    }
  in
  check bool "a survives (excluded from deny)" true
    (Tool_access_policy.allows_name policy "a");
  check bool "b denied" false
    (Tool_access_policy.allows_name policy "b");
  check bool "c denied" false
    (Tool_access_policy.allows_name policy "c")

let test_diff_constructor_bypass_empty_exclude () =
  let sel =
    Tool_access_policy.Diff { base = Names [ "a"; "b" ]; exclude = Empty }
  in
  check bool "a matches through raw Diff" true
    (Tool_access_policy.selector_matches_name sel "a");
  check bool "c rejected" false
    (Tool_access_policy.selector_matches_name sel "c")

let test_inter_then_diff () =
  let sel =
    Tool_access_policy.Diff
      {
        base = Inter [ Names [ "a"; "b"; "c" ]; Names [ "b"; "c"; "d" ] ];
        exclude = Names [ "c" ];
      }
  in
  let resolved = Tool_access_policy.resolve_selector sel in
  check (list string) "inter then diff" [ "b" ] resolved

let test_diff_in_policy_deny () =
  let policy =
    {
      Tool_access_policy.allow =
        Diff
          {
            base = Names [ "a"; "b"; "c"; "d" ];
            exclude = Names [ "c"; "d" ];
          };
      deny = Names [ "b" ];
    }
  in
  let resolved = Tool_access_policy.resolve policy in
  check (list string) "diff allow + deny" [ "a" ] resolved

(* ================================================================ *)
(* 3-Layer Tool Gate tests                                           *)
(* ================================================================ *)

let make_gate_test_meta ?(name = "test-gate") () : Keeper_types.keeper_meta =
  match Keeper_types.meta_of_json
    (`Assoc [("name", `String name); ("agent_name", `String name);
             ("trace_id", `String "test-trace-gate")]) with
  | Ok meta -> meta
  | Error e -> failwith (Printf.sprintf "make_gate_test_meta failed: %s" e)

let test_core_tools_are_core () =
  init_keeper_tool_registry ();
  let core = Keeper_exec_tools.core_always_tools in
  check bool "masc_status is core" true
    (List.mem "masc_status" core);
  check bool "masc_broadcast is not core" false
    (List.mem "masc_broadcast" core);
  check bool "masc_heartbeat removed from core" false
    (List.mem "masc_heartbeat" core);
  check bool "masc_tool_help moved to BM25" false
    (List.mem "masc_tool_help" core);
  check bool "extend_turns is core" true
    (List.mem "extend_turns" core);
  check bool "is_core_always_tool masc_status" true
    (Keeper_exec_tools.is_core_always_tool "masc_status");
  check bool "non-core tool" false
    (Keeper_exec_tools.is_core_always_tool "keeper_bash")

let test_universe_superset_of_policy () =
  init_keeper_tool_registry ();
  let base = make_gate_test_meta () in
  let meta = { base with
    tool_access = Preset { preset = Minimal; also_allow = [] };
    tool_denylist = [];
  } in
  let policy = Keeper_exec_tools.keeper_allowed_tool_names meta in
  let universe = Keeper_exec_tools.keeper_universe_tool_names meta in
  let missing =
    List.filter (fun name -> not (List.mem name universe)) policy
  in
  check (list string) "all policy tools in universe" [] missing;
  check bool "universe >= policy" true
    (List.length universe >= List.length policy)

let test_minimal_preset_includes_core_masc () =
  init_keeper_tool_registry ();
  let base = make_gate_test_meta ~name:"test-minimal" () in
  let meta = { base with
    tool_access = Preset { preset = Minimal; also_allow = [] };
    tool_denylist = [];
  } in
  let universe = Keeper_exec_tools.keeper_universe_tool_names meta in
  check bool "masc_status in universe" true
    (List.mem "masc_status" universe);
  check bool "masc_heartbeat in universe" true
    (List.mem "masc_heartbeat" universe);
  check bool "masc_tool_help in universe" true
    (List.mem "masc_tool_help" universe);
  check bool "masc_broadcast excluded from universe" false
    (List.mem "masc_broadcast" universe)

(* ================================================================ *)
(* Preset-scoped universe (#4637)                                    *)
(* ================================================================ *)

let test_preset_universe_subset_of_global () =
  init_keeper_tool_registry ();
  let base = make_gate_test_meta () in
  let meta = { base with
    tool_access = Preset { preset = Coding; also_allow = [] };
    tool_denylist = [];
  } in
  let scoped = Keeper_exec_tools.keeper_preset_universe_tool_names meta in
  let global = Keeper_exec_tools.keeper_universe_tool_names meta in
  let outside =
    List.filter (fun name -> not (List.mem name global)) scoped
  in
  check (list string) "scoped is subset of global" [] outside;
  check bool "scoped < global for non-Full preset" true
    (List.length scoped < List.length global)

let test_preset_universe_includes_core () =
  init_keeper_tool_registry ();
  let base = make_gate_test_meta ~name:"test-scoped" () in
  let meta = { base with
    tool_access = Preset { preset = Minimal; also_allow = [] };
    tool_denylist = [];
  } in
  let scoped = Keeper_exec_tools.keeper_preset_universe_tool_names meta in
  check bool "masc_status in scoped" true
    (List.mem "masc_status" scoped);
  check bool "masc_heartbeat removed from scoped" false
    (List.mem "masc_heartbeat" scoped);
  check bool "masc_tool_help in scoped" true
    (List.mem "masc_tool_help" scoped);
  check bool "masc_broadcast excluded from scoped" false
    (List.mem "masc_broadcast" scoped)

let test_preset_universe_sizes () =
  init_keeper_tool_registry ();
  let make preset =
    let base = make_gate_test_meta () in
    { base with
      tool_access = Preset { preset; also_allow = [] };
      tool_denylist = [];
    }
  in
  let minimal_size = List.length (Keeper_exec_tools.keeper_preset_universe_tool_names (make Minimal)) in
  let messaging_size = List.length (Keeper_exec_tools.keeper_preset_universe_tool_names (make Messaging)) in
  let coding_size = List.length (Keeper_exec_tools.keeper_preset_universe_tool_names (make Coding)) in
  let full_size = List.length (Keeper_exec_tools.keeper_preset_universe_tool_names (make Full)) in
  check bool
    (Printf.sprintf "Minimal(%d) < Messaging(%d)" minimal_size messaging_size)
    true (minimal_size < messaging_size);
  check bool
    (Printf.sprintf "Messaging(%d) < Coding(%d)" messaging_size coding_size)
    true (messaging_size < coding_size);
  check bool
    (Printf.sprintf "Coding(%d) <= Full(%d)" coding_size full_size)
    true (coding_size <= full_size)

let test_preset_universe_superset_of_policy () =
  init_keeper_tool_registry ();
  let base = make_gate_test_meta () in
  let meta = { base with
    tool_access = Preset { preset = Coding; also_allow = [] };
    tool_denylist = [];
  } in
  let policy = Keeper_exec_tools.keeper_allowed_tool_names meta in
  let scoped = Keeper_exec_tools.keeper_preset_universe_tool_names meta in
  let missing =
    List.filter (fun name -> not (List.mem name scoped)) policy
  in
  check (list string) "all policy tools in preset universe" [] missing

let test_registered_inline_board_tool_survives_filter () =
  init_keeper_tool_registry ();
  Keeper_exec_tools.inject_masc_schemas Config.raw_all_tool_schemas;
  let base = make_gate_test_meta ~name:"test-board-inline" () in
  let meta = { base with
    tool_access = Custom [ "keeper_board_post"; "masc_who" ];
    tool_denylist = [];
  } in
  let allowed = Keeper_exec_tools.keeper_allowed_tool_names meta in
  check bool "keeper board wrapper tool survives" true
    (List.mem "keeper_board_post" allowed);
  check bool "raw masc_board_post filtered out" false
    (List.mem "masc_board_post" allowed);
  check bool "unsupported inline tool removed" false
    (List.mem "masc_who" allowed)

(* ================================================================ *)
(* Runner                                                            *)
(* ================================================================ *)

let () =
  let base_path = Masc_test_deps.find_project_root () in
  ignore (Result.get_ok (Keeper_exec_tools.init_policy_config ~base_path));
  run "Tool_access_policy"
    [
      ( "selector_basics",
        [
          test_case "Empty matches nothing" `Quick
            test_empty_selector_matches_nothing;
          test_case "All matches everything" `Quick
            test_all_selector_matches_everything;
          test_case "Names exact match" `Quick
            test_names_selector_exact_match;
          test_case "Names trims and dedupes" `Quick
            test_names_selector_trims_and_dedupes;
        ] );
      ( "union",
        [
          test_case "empty list is Empty" `Quick
            test_union_empty_list_is_empty;
          test_case "single element unwraps" `Quick
            test_union_single_element_unwraps;
          test_case "matches any member" `Quick
            test_union_matches_any_member;
          test_case "union of empties" `Quick
            test_union_of_empties_matches_nothing;
        ] );
      ( "policy_presets",
        [
          test_case "empty denies everything" `Quick
            test_empty_policy_denies_everything;
          test_case "allow_all permits everything" `Quick
            test_allow_all_policy;
        ] );
      ( "deny_wins",
        [
          test_case "deny overrides allow" `Quick
            test_deny_overrides_allow;
          test_case "deny All blocks everything" `Quick
            test_deny_all_blocks_everything;
          test_case "allow=deny same names -> empty" `Quick
            test_allow_names_deny_same_names;
        ] );
      ( "with_deny_composition",
        [
          test_case "with_deny_names adds" `Quick
            test_with_deny_names_adds_to_existing;
          test_case "with_deny_selector Empty is noop" `Quick
            test_with_deny_selector_empty_is_noop;
          test_case "with_deny accumulates" `Quick
            test_with_deny_selector_accumulates;
        ] );
      ( "resolve",
        [
          test_case "Empty returns []" `Quick
            test_resolve_empty_returns_empty;
          test_case "All with candidates" `Quick
            test_resolve_all_with_candidates;
          test_case "Names deduplicates" `Quick
            test_resolve_names_deduplicates;
          test_case "deny removes from allow" `Quick
            test_resolve_policy_deny_removes_from_allow;
          test_case "Union flattens and dedupes" `Quick
            test_resolve_union_flattens_and_dedupes;
        ] );
      ( "surface_integration",
        [
          test_case "surface respects candidates" `Quick
            test_surface_resolution_respects_candidates;
          test_case "Keeper_denied surface blocks" `Quick
            test_keeper_denied_surface_blocks_tools;
        ] );
      ( "of_allowlist",
        [
          test_case "no deny" `Quick test_of_allowlist_no_deny;
          test_case "empty allowlist" `Quick test_of_allowlist_empty;
        ] );
      ( "inter",
        [
          test_case "matches common only" `Quick
            test_inter_matches_common_only;
          test_case "empty list is All" `Quick
            test_inter_empty_list_is_all;
          test_case "single element unwraps" `Quick
            test_inter_single_unwraps;
          test_case "with Empty yields nothing" `Quick
            test_inter_with_empty_yields_nothing;
          test_case "is commutative" `Quick
            test_inter_is_commutative;
          test_case "resolve computes intersection" `Quick
            test_resolve_inter_computes_intersection;
          test_case "resolve three-way" `Quick
            test_resolve_inter_three_way;
        ] );
      ( "diff",
        [
          test_case "subtracts exclude" `Quick
            test_diff_subtracts_exclude;
          test_case "empty exclude is identity" `Quick
            test_diff_empty_exclude_is_identity;
          test_case "empty base is empty" `Quick
            test_diff_empty_base_is_empty;
          test_case "with surface" `Quick
            test_diff_with_surface;
          test_case "resolve diff" `Quick
            test_resolve_diff;
          test_case "resolve disjoint is base" `Quick
            test_resolve_diff_disjoint_is_base;
        ] );
      ( "inter_diff_composition",
        [
          test_case "Inter with All narrows" `Quick
            test_inter_with_all_narrows_to_other;
          test_case "resolve Inter with All" `Quick
            test_resolve_inter_with_all;
          test_case "deny with Inter" `Quick
            test_deny_with_inter;
          test_case "deny with Diff" `Quick
            test_deny_with_diff;
          test_case "Diff bypass empty exclude" `Quick
            test_diff_constructor_bypass_empty_exclude;
          test_case "inter then diff" `Quick
            test_inter_then_diff;
          test_case "diff in policy deny" `Quick
            test_diff_in_policy_deny;
        ] );
      (* ======================================================== *)
      (* 3-Layer Tool Gate: core / universe / policy               *)
      (* ======================================================== *)
      ( "tool_gate_3layer",
        [
          test_case "core tools are core" `Quick
            test_core_tools_are_core;
          test_case "universe superset of policy" `Quick
            test_universe_superset_of_policy;
          test_case "minimal preset includes core masc" `Quick
            test_minimal_preset_includes_core_masc;
          test_case "registered inline board tool survives filter" `Quick
            test_registered_inline_board_tool_survives_filter;
        ] );
      (* ======================================================== *)
      (* Preset-scoped universe (#4637)                            *)
      (* ======================================================== *)
      ( "preset_scoped_universe",
        [
          test_case "scoped subset of global" `Quick
            test_preset_universe_subset_of_global;
          test_case "scoped includes core" `Quick
            test_preset_universe_includes_core;
          test_case "preset size ordering" `Quick
            test_preset_universe_sizes;
          test_case "scoped superset of policy" `Quick
            test_preset_universe_superset_of_policy;
        ] );
    ]
