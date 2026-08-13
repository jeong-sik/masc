open Alcotest

module Catalog = Masc.Keeper_tool_composition_catalog
module Plan = Masc.Keeper_tool_plan

let valid_catalog =
  {|[[compositions]]
name = "time-memory-query"
description = "Feed the exact clock result into memory search."

[[compositions.nodes]]
id = "time"
tool = "keeper_time_now"
[compositions.nodes.input]
kind = "literal"
value = {}

[[compositions.nodes]]
id = "search"
tool = "keeper_memory_search"
after = ["time"]
[compositions.nodes.input]
kind = "object"
[[compositions.nodes.input.fields]]
name = "query"
[compositions.nodes.input.fields.value]
kind = "output"
node = "time"
pointer = "/now_iso"
|}
;;

let node_id value =
  match Plan.Node_id.make value with
  | Ok id -> id
  | Error Plan.Node_id.Empty -> fail "unexpected empty node id"
;;

let test_catalog_builds_executable_typed_plan () =
  let catalog =
    match Catalog.parse valid_catalog with
    | Ok catalog -> catalog
    | Error _ -> fail "valid composition catalog was rejected"
  in
  check int "one catalog entry" 1 (List.length (Catalog.entries catalog));
  let entry =
    match Catalog.find catalog "time-memory-query" with
    | Some entry -> entry
    | None -> fail "composition lookup missed exact name"
  in
  check
    (option string)
    "description"
    (Some "Feed the exact clock result into memory search.")
    entry.description;
  let layers = Plan.dependency_layers entry.plan in
  check
    (list (list string))
    "typed dependency layers"
    [ [ "time" ]; [ "search" ] ]
    (List.map
       (List.map (fun node -> Plan.Node_id.to_string node.Plan.id))
       layers);
  let run_id = Plan.Run_id.fresh () in
  let time_output =
    match
      Plan.validate_output
        entry.plan
        ~run_id
        ~node_id:(node_id "time")
        (`Assoc
            [ "now_iso", `String "2026-08-14T00:00:00Z"
            ; "now_unix", `Float 0.0
            ])
    with
    | Ok output -> output
    | Error _ -> fail "valid clock output was rejected"
  in
  match
    Plan.resolve_input
      entry.plan
      ~run_id
      ~node_id:(node_id "search")
      ~lookup:(fun id ->
        if Plan.Node_id.equal id (node_id "time") then Some time_output else None)
  with
  | Ok (`Assoc [ ("query", `String "2026-08-14T00:00:00Z") ]) -> ()
  | Ok value ->
    failf "resolved catalog input changed shape: %s" (Yojson.Safe.to_string value)
  | Error _ -> fail "catalog output reference did not resolve"
;;

let test_catalog_rejects_unknown_fields () =
  let document =
    {|[[compositions]]
name = "bad"
guess = true
[[compositions.nodes]]
id = "time"
tool = "keeper_time_now"
input = { kind = "literal", value = {} }
|}
  in
  match Catalog.parse document with
  | Error
      (Catalog.Unknown_field
        { path = [ "compositions"; "0" ]; field = "guess" }) -> ()
  | Error _ | Ok _ -> fail "unknown composition field was not rejected"
;;

let test_catalog_rejects_malformed_output_pointer () =
  let document =
    {|[[compositions]]
name = "bad-pointer"
[[compositions.nodes]]
id = "time"
tool = "keeper_time_now"
[compositions.nodes.input]
kind = "literal"
value = {}
[[compositions.nodes]]
id = "search"
tool = "keeper_memory_search"
[compositions.nodes.input]
kind = "object"
[[compositions.nodes.input.fields]]
name = "query"
[compositions.nodes.input.fields.value]
kind = "output"
node = "time"
pointer = "now_iso"
|}
  in
  match Catalog.parse document with
  | Error
      (Catalog.Invalid_json_pointer
        { error = Plan.Json_pointer.Missing_initial_slash; _ }) -> ()
  | Error _ | Ok _ -> fail "non-RFC6901 output pointer was accepted"
;;

let one_node_composition name =
  Printf.sprintf
    {|[[compositions]]
name = %S
[[compositions.nodes]]
id = "time"
tool = "keeper_time_now"
input = { kind = "literal", value = {} }
|}
    name
;;

let test_catalog_rejects_duplicate_composition_names () =
  let document = one_node_composition "same" ^ one_node_composition "same" in
  match Catalog.parse document with
  | Error (Catalog.Duplicate_composition_name "same") -> ()
  | Error _ | Ok _ -> fail "duplicate composition name was accepted"
;;

let test_catalog_rejects_unknown_tool_through_plan_authority () =
  let document =
    {|[[compositions]]
name = "unknown-tool"
[[compositions.nodes]]
id = "unknown"
tool = "invented_tool"
input = { kind = "literal", value = {} }
|}
  in
  match Catalog.parse document with
  | Error
      (Catalog.Plan_rejected
        { error = Plan.Unknown_tool { tool_name = "invented_tool"; _ }; _ }) -> ()
  | Error _ | Ok _ -> fail "catalog bypassed canonical plan tool authority"
;;

let () =
  run
    "keeper_tool_composition_catalog"
    [ ( "catalog"
      , [ test_case
            "builds executable typed plan"
            `Quick
            test_catalog_builds_executable_typed_plan
        ; test_case "rejects unknown fields" `Quick test_catalog_rejects_unknown_fields
        ; test_case
            "rejects malformed pointer"
            `Quick
            test_catalog_rejects_malformed_output_pointer
        ; test_case
            "rejects duplicate names"
            `Quick
            test_catalog_rejects_duplicate_composition_names
        ; test_case
            "rejects unknown tools"
            `Quick
            test_catalog_rejects_unknown_tool_through_plan_authority
        ] )
    ]
;;
