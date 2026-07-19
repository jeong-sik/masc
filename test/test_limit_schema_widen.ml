(* Reversal of Issue #18472's [limit] wire-format widening.

   #18472 widened [limit] from strict ["integer"] to the union
   ["integer", "string"] across five sites so the correction_pipeline
   would not fire when an LLM emitted a numeric string. OAS #2343 then
   made mcp_schema fail-closed: a [type] array with more than one
   non-null member raises Invalid_argument
   ("property \"limit\" type array must contain exactly one non-null
   type") during tool-schema conversion, which propagated to the keeper
   cycle and crashed every keeper on 2026-07-19.

   The runtime handlers already read [limit] via [Safe_ops.json_int],
   which coerces string->int, so a single strict ["integer"] loses no
   behaviour. This test guards AGAINST re-widening: every advertised
   [limit] must be a single scalar JSON Schema type, never a multi-type
   array. Covers all five sites #18472 touched, not the three the
   original widening test pinned. *)

open Alcotest

let find_tool_schema schemas name =
  List.find_opt (fun (s : Masc_domain.tool_schema) -> String.equal s.name name) schemas
  |> function
  | Some s -> s
  | None -> Alcotest.failf "tool schema %S not found" name

let limit_type schema =
  match schema.Masc_domain.input_schema with
  | `Assoc fields ->
    (match List.assoc_opt "properties" fields with
     | Some (`Assoc props) ->
       (match List.assoc_opt "limit" props with
        | Some (`Assoc limit_fields) ->
          (match List.assoc_opt "type" limit_fields with
           | Some v -> v
           | None -> Alcotest.failf "%s: limit field missing 'type'" schema.name)
        | _ -> Alcotest.failf "%s: limit field missing in properties" schema.name)
     | _ -> Alcotest.failf "%s: properties not an Assoc" schema.name)
  | _ -> Alcotest.failf "%s: input_schema not an Assoc" schema.name

(* A [type] array with more than one non-null member is exactly what OAS
   #2343 fail-closed rejects. Assert every [limit] is a single scalar. *)
let check_single_type name type_value =
  match type_value with
  | `String single ->
    check string
      (Printf.sprintf "%s: limit type is a single scalar" name)
      "integer"
      single
  | `List _ ->
    Alcotest.failf
      "%s: limit type is a multi-type array; OAS #2343 fail-closed rejects it \
       and crashes the keeper cycle (see #18472 revert)"
      name
  | other ->
    Alcotest.failf
      "%s: limit type has unexpected JSON: %s"
      name
      (Yojson.Safe.to_string other)

let case tools name () = check_single_type name (limit_type (find_tool_schema tools name))

let () =
  run
    "limit_schema_strict"
    [ ( "every advertised limit is a single strict type"
      , [ test_case
            "keeper_tasks_list"
            `Quick
            (case Tool_shard_types.taskboard_tools "keeper_tasks_list")
        ; test_case
            "keeper_tasks_audit"
            `Quick
            (case Tool_shard_types.taskboard_tools "keeper_tasks_audit")
        ; test_case
            "keeper_memory_search"
            `Quick
            (case Tool_shard_types.base_tools "keeper_memory_search")
        ; test_case
            "keeper_board_list"
            `Quick
            (case Tool_shard_types.board_tools "keeper_board_list")
        ; test_case
            "keeper_board_search"
            `Quick
            (case Tool_shard_types.board_tools "keeper_board_search")
        ] )
    ]
