(** Regression test for [Cascade_routes.route_bindings_from_json].

    Routes are declared as RFC-0058 sub-tables:
    [[routes.X] target = "Y"]. The TOML materializer passes those
    sub-tables through verbatim, so the runtime decoder must read the
    [target] field from the materialized object. *)

open Alcotest

let bindings = testable
    (fun fmt (k, t) -> Format.fprintf fmt "(%s, %s)" k t)
    (fun (a, b) (c, d) -> String.equal a c && String.equal b d)

let parse_routes_json src =
  let j = Yojson.Safe.from_string src in
  Masc_mcp.Cascade_routes.route_bindings_from_json j
  |> List.sort (fun (a, _) (b, _) -> String.compare a b)

let test_declarative_sub_table_form () =
  check (list bindings)
    "declarative sub-table routes decode by reading target"
    [ "keeper_turn", "tier-group.primary"
    ; "llm_rerank", "tier-group.scoring"
    ]
    (parse_routes_json
       {|{"routes": {
          "keeper_turn": {"target": "tier-group.primary"},
          "llm_rerank": {"target": "tier-group.scoring"}
        }}|})

let test_string_form_is_dropped () =
  check (list bindings) "string route entries are ignored"
    [ "modern", "tier-group.modern" ]
    (parse_routes_json
       {|{"routes": {
          "old": "primary",
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
      , [ test_case "declarative sub-table form" `Quick
            test_declarative_sub_table_form
        ; test_case "string form is ignored" `Quick test_string_form_is_dropped
        ; test_case "empty target is filtered" `Quick test_empty_target_dropped
        ; test_case "missing target is filtered" `Quick test_missing_target_dropped
        ] )
    ]
