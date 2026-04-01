(** Tests for Tool_access_policy — shared allow/deny selector ADT.

    Covers: selector variants, normalize_names edge cases, deny-wins
    semantics, with_deny_* composition, resolve with/without candidates,
    and integration with Tool_catalog surfaces. *)

open Alcotest
open Masc_mcp

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

let test_keeper_denied_surface_blocks_admin_tools () =
  let admin_tools = Tool_catalog.tools_for_surface Tool_catalog.Keeper_denied in
  let policy = {
    Tool_access_policy.allow = All;
    deny = Surface Tool_catalog.Keeper_denied;
  } in
  check bool "keeper_denied surface has tools" true
    (List.length admin_tools > 0);
  List.iter (fun tool_name ->
    check bool
      (Printf.sprintf "%s denied by Keeper_denied surface" tool_name)
      false
      (Tool_access_policy.allows_name policy tool_name)
  ) (List.filteri (fun i _ -> i < 5) admin_tools)

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
(* Runner                                                            *)
(* ================================================================ *)

let () =
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
            test_keeper_denied_surface_blocks_admin_tools;
        ] );
      ( "of_allowlist",
        [
          test_case "no deny" `Quick test_of_allowlist_no_deny;
          test_case "empty allowlist" `Quick test_of_allowlist_empty;
        ] );
    ]
