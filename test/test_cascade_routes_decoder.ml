(** Regression test for [Cascade_routes.route_bindings_from_json] — RFC-0058
    Phase 4 follow-up.

    PR #14550 introduced the declarative sub-table form for routes
    ([routes.X] target = "Y") but the materializer passes those sub-tables
    through verbatim. The legacy consumer here used to filter every
    non-string value to [None], silently dropping every declarative route.
    These tests guard against that regression and confirm that the two
    encodings — legacy string and declarative sub-table — both decode to
    the same [(key, target)] binding list. *)

open Alcotest

let bindings = testable
    (fun fmt (k, t) -> Format.fprintf fmt "(%s, %s)" k t)
    (fun (a, b) (c, d) -> String.equal a c && String.equal b d)

let parse_routes_json src =
  let j = Yojson.Safe.from_string src in
  Masc_mcp.Cascade_routes.route_bindings_from_json j
  |> List.sort (fun (a, _) (b, _) -> String.compare a b)

let test_legacy_string_form () =
  check (list bindings) "legacy routes decode to (key, target)"
    [ "keeper_turn", "big_three"; "llm_rerank", "tool_rerank" ]
    (parse_routes_json
       {|{"routes": {"keeper_turn": "big_three", "llm_rerank": "tool_rerank"}}|})

let test_declarative_sub_table_form () =
  check (list bindings)
    "declarative sub-table routes decode by reading target"
    [ "keeper_turn", "tier-group.big_three"
    ; "llm_rerank", "tier-group.tool_rerank"
    ]
    (parse_routes_json
       {|{"routes": {
          "keeper_turn": {"target": "tier-group.big_three"},
          "llm_rerank": {"target": "tier-group.tool_rerank"}
        }}|})

let test_mixed_form_decodes_both () =
  check (list bindings) "mixed legacy+declarative entries both surface"
    [ "modern", "tier-group.modern"; "old", "big_three" ]
    (parse_routes_json
       {|{"routes": {
          "old": "big_three",
          "modern": {"target": "tier-group.modern"}
        }}|})

let test_empty_target_dropped () =
  check (list bindings) "empty target string is filtered"
    []
    (parse_routes_json
       {|{"routes": {"X": {"target": "   "}}}|})

let test_missing_target_dropped () =
  check (list bindings) "sub-table without target is filtered"
    []
    (parse_routes_json
       {|{"routes": {"X": {"other": "value"}}}|})

let () =
  Alcotest.run "cascade_routes_decoder"
    [ ( "route_bindings_from_json"
      , [ test_case "legacy string form" `Quick test_legacy_string_form
        ; test_case "declarative sub-table form" `Quick
            test_declarative_sub_table_form
        ; test_case "mixed forms decode both" `Quick test_mixed_form_decodes_both
        ; test_case "empty target is filtered" `Quick test_empty_target_dropped
        ; test_case "missing target is filtered" `Quick test_missing_target_dropped
        ] )
    ]
