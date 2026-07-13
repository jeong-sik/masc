open Alcotest

(** RFC-0084 PR-4 — [Tool_capability] typed sum + Set tests.

    Verifies:
    - Every [kind] variant round-trips through [to_string] / [of_string]
    - [all_kinds] enumerates exactly 3 variants
    - [Set.diff] semantics for [check]
    - [has] reads [Tool_catalog] metadata
    - [granted] of an unknown tool returns the empty set
    - [check ~required:empty ~granted:empty] returns [Ok ()]
    - [check] with disjoint required + granted returns [Error required] *)

let test_round_trip_all_kinds () =
  List.iter
    (fun kind ->
      let s = Tool_capability.to_string kind in
      match Tool_capability.of_string s with
      | Some kind' when kind = kind' -> ()
      | Some _ -> failf "round-trip kind mismatch for %s" s
      | None -> failf "of_string %S returned None" s)
    Tool_capability.all_kinds
;;

let test_all_kinds_cardinality () =
  (check int)
    "Tool_capability.all_kinds enumerates 3 variants"
    3
    (List.length Tool_capability.all_kinds)
;;

let test_of_string_unknown_returns_none () =
  (check (option string))
    "of_string on unknown returns None"
    None
    (Option.map
       Tool_capability.to_string
       (Tool_capability.of_string "unknown_capability"))
;;

let test_has_unknown_tool_returns_false () =
  (check bool)
    "has Read_only on an unregistered tool name returns false"
    false
    (Tool_capability.has Read_only "__nonexistent_tool__")
;;

let test_has_catalog_metadata () =
  let name = "__cap_catalog_tool" in
  Tool_catalog.register_metadata name
    { Tool_catalog.default_metadata with
      readonly = Some true;
      mcp_context_required = Some true;
      idempotent = Some true;
    };
  List.iter
    (fun kind ->
      (check bool)
        ("catalog metadata grants " ^ Tool_capability.to_string kind)
        true
        (Tool_capability.has kind name))
    Tool_capability.all_kinds
;;

let test_has_catalog_capabilities () =
  (check bool)
    "explicit read-only metadata grants Read_only"
    true
    (Tool_capability.has Read_only "tool_read_file");
  (check bool)
    "tool_search_files grants Read_only"
    true
    (Tool_capability.has Read_only "tool_search_files");
  (check bool)
    "explicit inline metadata grants Mcp_context_required"
    true
    (Tool_capability.has Mcp_context_required "masc_messages")
;;

let test_granted_unknown_tool_is_empty () =
  let s = Tool_capability.granted "__nonexistent_tool__" in
  (check bool)
    "granted on an unregistered tool returns the empty set"
    true
    (Tool_capability.Set.is_empty s)
;;

let test_check_empty_required_is_ok () =
  let result =
    Tool_capability.check
      ~required:Tool_capability.Set.empty
      ~granted:Tool_capability.Set.empty
  in
  match result with
  | Ok () -> ()
  | Error _ ->
    failf "check with empty required should return Ok"
;;

let test_check_missing_capability_returns_error () =
  let required =
    Tool_capability.Set.singleton Tool_capability.Read_only
  in
  let granted = Tool_capability.Set.empty in
  match Tool_capability.check ~required ~granted with
  | Ok () -> failf "check with missing capability should return Error"
  | Error missing ->
    (check int)
      "Error.missing.cardinality"
      1
      (Tool_capability.Set.cardinal missing)
;;

let test_check_granted_superset_is_ok () =
  let required =
    Tool_capability.Set.singleton Tool_capability.Read_only
  in
  let granted =
    Tool_capability.Set.add
      Tool_capability.Idempotent
      required
  in
  match Tool_capability.check ~required ~granted with
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
        ; test_case "has-catalog-metadata" `Quick test_has_catalog_metadata
        ; test_case "has-catalog-capabilities" `Quick test_has_catalog_capabilities
        ; test_case "granted-unknown-tool-is-empty" `Quick test_granted_unknown_tool_is_empty
        ; test_case "check-empty-required-is-ok" `Quick test_check_empty_required_is_ok
        ; test_case "check-missing-capability-returns-error" `Quick test_check_missing_capability_returns_error
        ; test_case "check-granted-superset-is-ok" `Quick test_check_granted_superset_is_ok
        ] )
    ]
;;
