(* Issue #18472 follow-up to PR #19383: widen [limit] from strict
   ["integer"] to ["integer", "string"] across the three sites that
   advertise it — [keeper_memory_search], [keeper_board_list],
   [keeper_board_search]. Fleet evidence on 2026-05-29 partial:

     fields=limit stages=coercion total:        18
       ReadFile (Anthropic-native, not ours):  13
       keeper_board_list:                       4
       keeper_memory_search:                    1
       keeper_board_search:                     0  ← no traffic yet but
                                                     same defect; bundled
                                                     per RFC-0088 §3 N-of-M.

   Runtime handlers in [Keeper_tool_memory_runtime] and the board list /
   search dispatchers read [limit] via [Safe_ops.json_int] which already
   accepts both shapes. The Anthropic-SDK schema rejection is purely a
   wire-format quirk. *)

open Alcotest

module Base = Tool_shard_types
module Board = Tool_shard_types

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

let check_widened name type_value =
  match type_value with
  | `List xs ->
    let strings =
      List.map
        (function
          | `String s -> s
          | _ -> Alcotest.failf "%s: limit type list contains non-string" name)
        xs
    in
    check (list string)
      (Printf.sprintf "%s: limit type widened to integer + string" name)
      [ "integer"; "string" ]
      strings
  | `String single ->
    Alcotest.failf
      "%s: limit type is still scalar %S; widening regressed"
      name single
  | other ->
    Alcotest.failf "%s: limit type has unexpected JSON: %s" name
      (Yojson.Safe.to_string other)

let memory_search_limit_widened () =
  let schema = find_tool_schema Base.base_tools "keeper_memory_search" in
  check_widened "keeper_memory_search" (limit_type schema)

let board_list_limit_widened () =
  let schema = find_tool_schema Board.board_tools "keeper_board_list" in
  check_widened "keeper_board_list" (limit_type schema)

let board_search_limit_widened () =
  let schema = find_tool_schema Board.board_tools "keeper_board_search" in
  check_widened "keeper_board_search" (limit_type schema)

let () =
  run "limit_schema_widen"
    [ "all three limit sites accept integer + string"
    , [ test_case "keeper_memory_search" `Quick memory_search_limit_widened
      ; test_case "keeper_board_list" `Quick board_list_limit_widened
      ; test_case "keeper_board_search" `Quick board_search_limit_widened
      ]
    ]
