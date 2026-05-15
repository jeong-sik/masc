open Alcotest

(** RFC-0084 PR-4 — [Tool_capability] typed sum + Set tests.

    Verifies:
    - All 5 [kind] variants round-trip through [to_string] / [of_string]
    - [all_kinds] enumerates exactly 5 variants
    - [Set.diff] semantics for [check]
    - Bridge to legacy [Tool_dispatch] sets via [has] returns [false] for
      an unknown tool name (the legacy sets are empty at test boot — no
      [init_*_set] is called from [masc_test_deps] env setup)
    - [granted] of an unknown tool returns the empty set
    - [check ~required:empty ~granted:empty] returns [Ok ()]
    - [check] with disjoint required + granted returns [Error required] *)

let test_round_trip_all_kinds () =
  List.iter
    (fun kind ->
      let s = Masc_mcp.Tool_capability.to_string kind in
      match Masc_mcp.Tool_capability.of_string s with
      | Some kind' when kind = kind' -> ()
      | Some _ -> failf "round-trip kind mismatch for %s" s
      | None -> failf "of_string %S returned None" s)
    Masc_mcp.Tool_capability.all_kinds
;;

let test_all_kinds_cardinality () =
  (check int)
    "Tool_capability.all_kinds enumerates 5 variants"
    5
    (List.length Masc_mcp.Tool_capability.all_kinds)
;;

let test_of_string_unknown_returns_none () =
  (check (option string))
    "of_string on unknown returns None"
    None
    (Option.map
       Masc_mcp.Tool_capability.to_string
       (Masc_mcp.Tool_capability.of_string "unknown_capability"))
;;

let test_has_unknown_tool_returns_false () =
  (* The legacy Tool_dispatch sets are empty at test boot. *)
  (check bool)
    "has Read_only on an unregistered tool name returns false"
    false
    (Masc_mcp.Tool_capability.has Read_only "__nonexistent_tool__")
;;

let test_granted_unknown_tool_is_empty () =
  let s = Masc_mcp.Tool_capability.granted "__nonexistent_tool__" in
  (check bool)
    "granted on an unregistered tool returns the empty set"
    true
    (Masc_mcp.Tool_capability.Set.is_empty s)
;;

let test_check_empty_required_is_ok () =
  let result =
    Masc_mcp.Tool_capability.check
      ~required:Masc_mcp.Tool_capability.Set.empty
      ~granted:Masc_mcp.Tool_capability.Set.empty
  in
  match result with
  | Ok () -> ()
  | Error _ ->
    failf "check with empty required should return Ok"
;;

let test_check_missing_capability_returns_error () =
  let required =
    Masc_mcp.Tool_capability.Set.singleton Masc_mcp.Tool_capability.Read_only
  in
  let granted = Masc_mcp.Tool_capability.Set.empty in
  match Masc_mcp.Tool_capability.check ~required ~granted with
  | Ok () -> failf "check with missing capability should return Error"
  | Error missing ->
    (check int)
      "Error.missing.cardinality"
      1
      (Masc_mcp.Tool_capability.Set.cardinal missing)
;;

let test_check_granted_superset_is_ok () =
  let required =
    Masc_mcp.Tool_capability.Set.singleton Masc_mcp.Tool_capability.Read_only
  in
  let granted =
    Masc_mcp.Tool_capability.Set.add
      Masc_mcp.Tool_capability.Idempotent
      required
  in
  match Masc_mcp.Tool_capability.check ~required ~granted with
  | Ok () -> ()
  | Error _ ->
    failf "check with granted ⊇ required should return Ok"
;;

let () =
  Alcotest.run
    "RFC-0084 PR-4 Tool_capability typed"
    [ ( "tool-capability"
      , [ test_case "round-trip-all-kinds" `Quick test_round_trip_all_kinds
        ; test_case "all-kinds-cardinality" `Quick test_all_kinds_cardinality
        ; test_case "of-string-unknown-returns-none" `Quick test_of_string_unknown_returns_none
        ; test_case "has-unknown-tool-returns-false" `Quick test_has_unknown_tool_returns_false
        ; test_case "granted-unknown-tool-is-empty" `Quick test_granted_unknown_tool_is_empty
        ; test_case "check-empty-required-is-ok" `Quick test_check_empty_required_is_ok
        ; test_case "check-missing-capability-returns-error" `Quick test_check_missing_capability_returns_error
        ; test_case "check-granted-superset-is-ok" `Quick test_check_granted_superset_is_ok
        ] )
    ]
;;
