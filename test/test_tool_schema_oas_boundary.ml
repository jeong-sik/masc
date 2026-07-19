(** Regression guard for #25272 — keeper tool schemas must convert cleanly
    through the OAS boundary.

    On 2026-07-19T01:41Z every keeper cycle began crashing with

      Invalid_argument("property \"limit\" type array must contain exactly
                        one non-null type")

    A [limit] property had been widened to ["type": ["integer","string"]] to
    accept numeric-string arguments (Issue #18472). But
    [Tool_bridge.params_of_json_schema] delegates to
    [Agent_sdk.Mcp.json_schema_to_params] (OAS #2343, fail-closed on schema
    types it cannot map to a single param type), which raises Invalid_argument
    on a multi-non-null-type union. The uncaught exception took down the whole
    keeper turn — every tool, not just the offending one.

    This test asserts the canonical keeper catalog never reintroduces a schema
    the OAS boundary cannot convert (multi-type union, unknown property type,
    malformed [type], ...). It runs the real boundary function used at
    dispatch, so it fails the same way the runtime would — before deploy,
    not in production. *)

open Masc

(** Every schema the keeper projects to its model, from the canonical
    catalog. New shards added to [Tool_shard.all_keeper_tool_schemas] are
    covered automatically. *)
let keeper_schemas : Masc_domain.tool_schema list = Tool_shard.all_keeper_tool_schemas

let test_catalog_non_empty () =
  Alcotest.(check bool)
    "keeper catalog is non-empty (guards against an empty-list false pass)"
    true
    (keeper_schemas <> [])

let test_all_keeper_schemas_convert () =
  List.iter
    (fun (schema : Masc_domain.tool_schema) ->
       match Agent_sdk.Mcp.json_schema_to_params_result schema.input_schema with
       | Ok _ -> ()
       | Error detail ->
         Alcotest.failf
           "tool schema %S is not convertible by the OAS boundary \
            (Agent_sdk.Mcp.json_schema_to_params): %s. A multi-non-null-type \
            union or an unknown property type here raises Invalid_argument and \
            crashes the keeper turn (#25272). Use a single [type] per property."
           schema.name
           detail)
    keeper_schemas

let () =
  Alcotest.run
    "tool_schema_oas_boundary"
    [ ( "boundary"
      , [ Alcotest.test_case "keeper catalog non-empty" `Quick test_catalog_non_empty
        ; Alcotest.test_case
            "all keeper tool schemas convert through the OAS boundary"
            `Quick
            test_all_keeper_schemas_convert
        ] )
    ]
;;
