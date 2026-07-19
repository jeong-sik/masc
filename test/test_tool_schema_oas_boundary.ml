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

    This test asserts the descriptor-derived Keeper model catalog never
    reintroduces a schema the OAS boundary cannot convert (multi-type union,
    unknown property type, malformed [type], ...). It runs the same MASC/OAS
    bridge used while constructing the Keeper tool bundle, so it fails the
    same way the runtime would — before deploy, not in production. *)

open Masc

(** Every descriptor-derived schema projected into the OAS Keeper tool bundle.
    This is the same materialized catalog consumed by
    [Keeper_tools_oas_bundle.make_tool_bundle], including descriptor-owned
    schemas that do not appear in [Tool_shard.all_keeper_tool_schemas]. *)
let keeper_schemas : Masc_domain.tool_schema list =
  Keeper_tool_policy.keeper_model_tool_schemas ()

let test_catalog_non_empty () =
  Alcotest.(check bool)
    "keeper catalog is non-empty (guards against an empty-list false pass)"
    true
    (keeper_schemas <> [])

let test_all_keeper_schemas_convert () =
  List.iter
    (fun (schema : Masc_domain.tool_schema) ->
       match Tool_bridge.params_of_json_schema schema.input_schema with
       | _ -> ()
       | exception Invalid_argument detail ->
         Alcotest.failf
           "Keeper model tool schema %S is not convertible by the MASC/OAS \
            boundary (Tool_bridge.params_of_json_schema): %s. Fix the reported \
            descriptor-owned or canonical schema before exposing it to OAS \
            (#25272)."
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
