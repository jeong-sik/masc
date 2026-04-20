(** Tests for Keeper_tool_alias.

    Phase A.1 of RFC-0006. The module is data-only at this point;
    these tests pin the alias table so subsequent runtime wiring
    (Phase A.2/A.3) can rely on stable contracts. *)

module Alias = Masc_mcp.Keeper_tool_alias
module Disclosure = Masc_mcp.Keeper_tool_disclosure

let test_known_aliases_resolve () =
  Alcotest.(check (option string)) "Bash -> keeper_bash"
    (Some "keeper_bash") (Alias.to_internal "Bash");
  Alcotest.(check (option string)) "Read -> keeper_fs_read"
    (Some "keeper_fs_read") (Alias.to_internal "Read");
  Alcotest.(check (option string)) "Edit -> keeper_fs_edit"
    (Some "keeper_fs_edit") (Alias.to_internal "Edit");
  Alcotest.(check (option string)) "Write -> keeper_fs_edit"
    (Some "keeper_fs_edit") (Alias.to_internal "Write");
  Alcotest.(check (option string)) "Grep -> keeper_shell"
    (Some "keeper_shell") (Alias.to_internal "Grep")

let test_unknown_returns_none () =
  Alcotest.(check (option string)) "Skill has no cognate"
    None (Alias.to_internal "Skill");
  Alcotest.(check (option string)) "keeper_bash is internal, not public"
    None (Alias.to_internal "keeper_bash");
  Alcotest.(check (option string)) "empty string"
    None (Alias.to_internal "");
  Alcotest.(check (option string)) "case sensitive"
    None (Alias.to_internal "bash")

let test_to_public_round_trip () =
  Alcotest.(check string) "keeper_bash -> Bash"
    "Bash" (Alias.to_public "keeper_bash");
  Alcotest.(check string) "keeper_fs_read -> Read"
    "Read" (Alias.to_public "keeper_fs_read");
  Alcotest.(check string) "keeper_shell -> Grep"
    "Grep" (Alias.to_public "keeper_shell");
  (* Edit/Write collapse: first occurrence wins for stability *)
  Alcotest.(check string) "keeper_fs_edit -> Edit (first wins)"
    "Edit" (Alias.to_public "keeper_fs_edit")

let test_to_public_pass_through () =
  (* Tools without an Anthropic Code cognate should fall through verbatim. *)
  Alcotest.(check string) "keeper_board_post passes through"
    "keeper_board_post" (Alias.to_public "keeper_board_post");
  Alcotest.(check string) "unknown name passes through"
    "anything" (Alias.to_public "anything")

let test_canonicalize_observed () =
  let input = [ "Bash"; "keeper_board_post"; "Read"; "Skill"; "Write" ] in
  let expected =
    [ "keeper_bash"; "keeper_board_post"; "keeper_fs_read"; "Skill"; "keeper_fs_edit" ]
  in
  Alcotest.(check (list string)) "mixed list canonicalizes only known aliases"
    expected (Alias.canonicalize_observed input)

let test_hallucinated_builtins () =
  Alcotest.(check bool) "Skill is hallucinated"
    true (Alias.is_hallucinated_builtin "Skill");
  Alcotest.(check bool) "Agent is hallucinated"
    true (Alias.is_hallucinated_builtin "Agent");
  Alcotest.(check bool) "WebSearch is hallucinated"
    true (Alias.is_hallucinated_builtin "WebSearch");
  Alcotest.(check bool) "Bash is NOT hallucinated (has cognate)"
    false (Alias.is_hallucinated_builtin "Bash");
  Alcotest.(check bool) "keeper_bash is NOT hallucinated"
    false (Alias.is_hallucinated_builtin "keeper_bash")

let test_no_overlap_alias_and_hallucinated () =
  let aliased = List.map fst (Alias.all_aliases ()) in
  List.iter
    (fun b ->
       Alcotest.(check bool)
         (Printf.sprintf "%s must not appear in alias table" b)
         false (List.mem b aliased))
    Alias.hallucinated_builtins

let test_alias_table_is_stable () =
  let pairs = Alias.all_aliases () in
  Alcotest.(check int) "five canonical aliases" 5 (List.length pairs);
  (* Round-trip: every alias should round-trip via to_internal then to_public,
     except where collapse happens (Write -> keeper_fs_edit -> Edit). *)
  List.iter
    (fun (public, internal) ->
       Alcotest.(check (option string))
         (Printf.sprintf "%s resolves to %s" public internal)
         (Some internal) (Alias.to_internal public))
    pairs

(* ── Phase A.3 integration: canonicalize before the disclosure check ─── *)

(** Mirrors the call sequence in [keeper_agent_run.ml:1875] after
    canonicalization is applied. Pins the contract: a turn whose only
    tool calls are Anthropic Code aliases (Bash/Read/Edit/Grep/Write)
    must NOT produce any unexpected names. *)
let allowed_keeper_surface =
  [ "keeper_bash"; "keeper_fs_read"; "keeper_fs_edit"; "keeper_shell";
    "keeper_board_post"; "extend_turns" ]

let test_pure_alias_turn_no_longer_unexpected () =
  let observed = [ "Bash" ] in
  let canonical = Alias.canonicalize_observed observed in
  let unexpected =
    Disclosure.unexpected_tool_names
      ~allowed_tool_names:allowed_keeper_surface
      ~tool_names:canonical
  in
  Alcotest.(check (list string))
    "[Bash] only -> no unexpected (was the 18% nuke source)"
    [] unexpected

let test_mixed_alias_and_internal_no_unexpected () =
  let observed = [ "Read"; "keeper_board_post"; "Edit" ] in
  let canonical = Alias.canonicalize_observed observed in
  let unexpected =
    Disclosure.unexpected_tool_names
      ~allowed_tool_names:allowed_keeper_surface
      ~tool_names:canonical
  in
  Alcotest.(check (list string)) "mixed alias + internal -> no unexpected"
    [] unexpected

let test_hallucinated_builtin_still_unexpected () =
  let observed = [ "Skill"; "Bash" ] in
  let canonical = Alias.canonicalize_observed observed in
  let unexpected =
    Disclosure.unexpected_tool_names
      ~allowed_tool_names:allowed_keeper_surface
      ~tool_names:canonical
  in
  Alcotest.(check (list string))
    "Skill remains unexpected (no cognate); Bash resolved"
    [ "Skill" ] unexpected

let test_partial_tolerance_still_works () =
  let observed = [ "Skill"; "Bash" ] in
  let canonical = Alias.canonicalize_observed observed in
  let unexpected =
    Disclosure.unexpected_tool_names
      ~allowed_tool_names:allowed_keeper_surface
      ~tool_names:canonical
  in
  let has_valid =
    Disclosure.has_valid_tool_call
      ~unexpected_tool_names:unexpected
      ~tool_names:canonical
  in
  Alcotest.(check bool) "Bash counts as valid -> partial tolerance kicks in"
    true has_valid

let () =
  Alcotest.run "Keeper_tool_alias"
    [
      ( "alias-table",
        [
          Alcotest.test_case "known aliases resolve" `Quick test_known_aliases_resolve;
          Alcotest.test_case "unknown returns None" `Quick test_unknown_returns_none;
          Alcotest.test_case "to_public round-trip" `Quick test_to_public_round_trip;
          Alcotest.test_case "to_public pass-through" `Quick test_to_public_pass_through;
          Alcotest.test_case "canonicalize_observed" `Quick test_canonicalize_observed;
          Alcotest.test_case "hallucinated builtins" `Quick test_hallucinated_builtins;
          Alcotest.test_case "no overlap" `Quick test_no_overlap_alias_and_hallucinated;
          Alcotest.test_case "table is stable" `Quick test_alias_table_is_stable;
        ] );
      ( "disclosure-integration",
        [
          Alcotest.test_case "pure alias turn no longer unexpected" `Quick
            test_pure_alias_turn_no_longer_unexpected;
          Alcotest.test_case "mixed alias + internal no unexpected" `Quick
            test_mixed_alias_and_internal_no_unexpected;
          Alcotest.test_case "hallucinated builtin still unexpected" `Quick
            test_hallucinated_builtin_still_unexpected;
          Alcotest.test_case "partial tolerance still works" `Quick
            test_partial_tolerance_still_works;
        ] );
    ]
