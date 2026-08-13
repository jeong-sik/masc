open Alcotest

module Descriptor = Masc.Keeper_tool_descriptor
module Plan = Masc.Keeper_tool_plan

let node_id value =
  match Plan.Node_id.make value with
  | Ok id -> id
  | Error Plan.Node_id.Empty -> failf "unexpected empty node id: %S" value
;;

let pointer value =
  match Plan.Json_pointer.of_string value with
  | Ok pointer -> pointer
  | Error _ -> failf "unexpected invalid JSON pointer: %S" value
;;

let object_template fields =
  match Plan.Json_template.object_ fields with
  | Ok template -> template
  | Error (Plan.Json_template.Duplicate_field name) ->
    failf "unexpected duplicate template field: %S" name
;;

let descriptor name =
  Descriptor.all_descriptors ()
  |> List.find_opt (fun descriptor ->
    Descriptor.keeper_model_names descriptor |> List.exists (String.equal name))
  |> function
  | Some descriptor -> descriptor
  | None -> failf "missing model-visible descriptor: %s" name
;;

let descriptors () = Descriptor.all_descriptors ()

let node ?after ~id ~tool_name input =
  Plan.node ~id:(node_id id) ~tool_name ?after ~input ()
;;

let literal_object = Plan.Json_template.literal (`Assoc [])

let id_strings nodes =
  List.map (fun node -> Plan.Node_id.to_string node.Plan.id) nodes
;;

let test_node_id_rejects_empty () =
  match Plan.Node_id.make "" with
  | Error Plan.Node_id.Empty -> ()
  | Ok _ -> fail "empty node id was accepted"
;;

let test_json_pointer_is_exact_rfc6901_navigation () =
  let source = `Assoc [ "a/b", `Assoc [ "~key", `Int 7 ] ] in
  (match Plan.Json_pointer.resolve (pointer "/a~1b/~0key") source with
   | Ok (`Int 7) -> ()
   | Ok value -> failf "unexpected resolved value: %s" (Yojson.Safe.to_string value)
   | Error _ -> fail "escaped JSON pointer did not resolve");
  (match Plan.Json_pointer.of_string "a" with
   | Error Plan.Json_pointer.Missing_initial_slash -> ()
   | Error _ | Ok _ -> fail "pointer without initial slash was accepted");
  (match Plan.Json_pointer.of_string "/a~" with
   | Error (Plan.Json_pointer.Dangling_escape { segment = "a~" }) -> ()
   | Error _ | Ok _ -> fail "dangling JSON pointer escape was accepted");
  let array = `List [ `String "zero"; `String "one" ] in
  (match Plan.Json_pointer.resolve (pointer "/1") array with
   | Ok (`String "one") -> ()
   | Ok _ | Error _ -> fail "canonical array index did not resolve");
  List.iter
    (fun invalid ->
       match Plan.Json_pointer.resolve (pointer ("/" ^ invalid)) array with
       | Error (Plan.Json_pointer.Invalid_array_index found)
         when String.equal found invalid -> ()
       | Error _ | Ok _ -> failf "non-canonical array index was accepted: %S" invalid)
    [ ""; "01"; "+1"; "-" ]
;;

let test_json_template_preserves_declared_structure () =
  (match
     Plan.Json_template.object_
       [ "same", Plan.Json_template.literal (`Int 1)
       ; "same", Plan.Json_template.literal (`Int 2)
       ]
   with
   | Error (Plan.Json_template.Duplicate_field "same") -> ()
   | Error _ | Ok _ -> fail "duplicate object field was accepted");
  let producer = node_id "producer" in
  let template =
    object_template
      [ "value", Plan.Json_template.output ~node_id:producer ~pointer:(pointer "/value")
      ; "literal", Plan.Json_template.literal (`Bool true)
      ]
  in
  let lookup id =
    if Plan.Node_id.equal id producer then Some (`Assoc [ "value", `Int 42 ]) else None
  in
  match Plan.Json_template.resolve ~lookup template with
  | Ok (`Assoc [ ("value", `Int 42); ("literal", `Bool true) ]) -> ()
  | Ok value -> failf "template structure changed: %s" (Yojson.Safe.to_string value)
  | Error _ -> fail "valid template did not resolve"
;;

let test_fanout_fanin_layers_are_dependency_owned () =
  let seed_id = node_id "seed" in
  let seed = node ~id:"seed" ~tool_name:"keeper_time_now" literal_object in
  let left =
    node
      ~id:"left"
      ~tool_name:"masc_board_stats"
      ~after:[ seed_id ]
      literal_object
  in
  let right =
    node
      ~id:"right"
      ~tool_name:"masc_board_stats"
      ~after:[ seed_id ]
      literal_object
  in
  let sink =
    node
      ~id:"sink"
      ~tool_name:"keeper_tools_list"
      ~after:[ node_id "left"; node_id "right" ]
      literal_object
  in
  match Plan.create ~descriptors:(descriptors ()) [ seed; left; right; sink ] with
  | Error _ -> fail "valid fan-out/fan-in plan was rejected"
  | Ok plan ->
    let layers = List.map id_strings (Plan.dependency_layers plan) in
    check
      (list (list string))
      "stable dependency layers"
      [ [ "seed" ]; [ "left"; "right" ]; [ "sink" ] ]
      layers;
    check
      (list string)
      "sink dependencies are exact explicit edges"
      [ "left"; "right" ]
      (Plan.dependencies sink |> List.map Plan.Node_id.to_string);
    (match Plan.descriptor plan (node_id "sink") with
     | Some descriptor ->
       check
         string
         "descriptor lookup is plan-owned"
         "keeper_tools_list"
         descriptor.Descriptor.internal_name
     | None -> fail "plan-owned descriptor was not found")
;;

let test_output_schema_and_consumer_input_are_enforced () =
  let time_id = node_id "time" in
  let time = node ~id:"time" ~tool_name:"keeper_time_now" literal_object in
  let grep_input =
    object_template
      [ ( "pattern"
        , Plan.Json_template.output ~node_id:time_id ~pointer:(pointer "/now_iso") )
      ]
  in
  let grep = node ~id:"grep" ~tool_name:"Grep" grep_input in
  let plan =
    match Plan.create ~descriptors:(descriptors ()) [ time; grep ] with
    | Ok plan -> plan
    | Error _ -> fail "valid typed output reference was rejected"
  in
  let time_value = Masc.Keeper_tool_in_process_runtime.handle_time_now ~args:(`Assoc []) in
  let run_id = Plan.Run_id.fresh () in
  let time_output =
    match Plan.validate_output plan ~run_id ~node_id:time_id time_value with
    | Ok output -> output
    | Error _ -> fail "keeper_time_now carrier violated its descriptor schema"
  in
  let board_id = node_id "board" in
  let board_node = node ~id:"board" ~tool_name:"masc_board_stats" literal_object in
  let board_plan =
    match Plan.create ~descriptors:(descriptors ()) [ board_node ] with
    | Ok plan -> plan
    | Error _ -> fail "board stats plan was rejected"
  in
  let board_value = Masc.Board.(stats (create_store ())) in
  let board_run_id = Plan.Run_id.fresh () in
  (match Plan.validate_output board_plan ~run_id:board_run_id ~node_id:board_id board_value with
   | Ok _ -> ()
   | Error _ -> fail "masc_board_stats carrier violated its descriptor schema");
  let lookup id = if Plan.Node_id.equal id time_id then Some time_output else None in
  (match Plan.resolve_input plan ~run_id ~node_id:(node_id "grep") ~lookup with
   | Ok (`Assoc [ ("pattern", `String _) ]) -> ()
   | Ok value -> failf "resolved input changed shape: %s" (Yojson.Safe.to_string value)
   | Error _ -> fail "resolved Grep input failed its descriptor schema");
  (match
     Plan.validate_output
       plan
       ~run_id
       ~node_id:time_id
       (`Assoc [ "now_iso", `Int 1; "now_unix", `String "bad" ])
   with
   | Error (Plan.Output_validation_failed { node_id; _ })
     when Plan.Node_id.equal node_id time_id -> ()
   | Error _ | Ok _ -> fail "invalid producer output was accepted");
  (match
     Plan.validate_output
       plan
       ~run_id
       ~node_id:time_id
       (`Assoc
          [ "now_iso", `String "2026-08-14T00:00:00Z"
          ; "now_unix", `Float 0.0
          ; "_unexpected", `Bool true
          ])
   with
   | Error (Plan.Output_validation_failed { error = Plan.Unexpected_field _; _ }) -> ()
   | Error _ | Ok _ -> fail "producer output normalization hid an unexpected field");
  let malformed_consumer =
    node
      ~id:"malformed"
      ~tool_name:"Grep"
      ~after:[ time_id ]
      (Plan.Json_template.literal (`Assoc []))
  in
  let malformed_plan =
    match Plan.create ~descriptors:(descriptors ()) [ time; malformed_consumer ] with
    | Ok plan -> plan
    | Error _ -> fail "value-dependent consumer plan was rejected before resolution"
  in
  (match
     Plan.resolve_input malformed_plan ~run_id ~node_id:(node_id "malformed") ~lookup
   with
   | Error (Plan.Input_validation_failed { node_id; _ })
     when String.equal (Plan.Node_id.to_string node_id) "malformed" -> ()
   | Error _ | Ok _ -> fail "consumer input schema violation reached dispatch");
  let other_run_id = Plan.Run_id.fresh () in
  (match
     Plan.resolve_input plan ~run_id:other_run_id ~node_id:(node_id "grep") ~lookup
   with
   | Error
       (Plan.Input_template_resolution_failed
         { error = Plan.Json_template.Missing_output missing; _ })
     when Plan.Node_id.equal missing time_id -> ()
   | Error _ | Ok _ -> fail "validated output crossed an execution run boundary");
  let other_plan =
    match Plan.create ~descriptors:(descriptors ()) [ time; grep ] with
    | Ok plan -> plan
    | Error _ -> fail "equivalent second plan was rejected"
  in
  (match Plan.resolve_input other_plan ~run_id ~node_id:(node_id "grep") ~lookup with
   | Error
       (Plan.Input_template_resolution_failed
         { error = Plan.Json_template.Missing_output missing; _ })
     when Plan.Node_id.equal missing time_id -> ()
   | Error _ | Ok _ -> fail "validated output crossed a plan boundary")
;;

let test_plan_rejects_invalid_graphs_and_output_edges () =
  let missing = node_id "missing" in
  let with_missing =
    node
      ~id:"only"
      ~tool_name:"keeper_time_now"
      ~after:[ missing ]
      literal_object
  in
  (match Plan.create ~descriptors:(descriptors ()) [ with_missing ] with
   | Error (Plan.Missing_dependency { dependency; _ })
     when Plan.Node_id.equal dependency missing -> ()
   | Error _ | Ok _ -> fail "missing dependency was not rejected");
  let duplicate_a = node ~id:"same" ~tool_name:"keeper_time_now" literal_object in
  let duplicate_b = node ~id:"same" ~tool_name:"masc_board_stats" literal_object in
  (match Plan.create ~descriptors:(descriptors ()) [ duplicate_a; duplicate_b ] with
   | Error (Plan.Duplicate_node_id id)
     when String.equal (Plan.Node_id.to_string id) "same" -> ()
   | Error _ | Ok _ -> fail "duplicate node id was not rejected");
  let unknown = node ~id:"unknown" ~tool_name:"not_a_keeper_tool" literal_object in
  (match Plan.create ~descriptors:(descriptors ()) [ unknown ] with
   | Error (Plan.Unknown_tool { tool_name = "not_a_keeper_tool"; _ }) -> ()
   | Error _ | Ok _ -> fail "unknown tool was not rejected");
  let source_id = node_id "opaque" in
  let source = node ~id:"opaque" ~tool_name:"keeper_tools_list" literal_object in
  let consumer =
    node
      ~id:"consumer"
      ~tool_name:"masc_board_stats"
      (Plan.Json_template.output ~node_id:source_id ~pointer:Plan.Json_pointer.root)
  in
  (match Plan.create ~descriptors:(descriptors ()) [ source; consumer ] with
   | Error
       (Plan.Opaque_output_reference
         { source_node_id; source_tool_name = "keeper_tools_list"; _ })
     when Plan.Node_id.equal source_node_id source_id -> ()
   | Error _ | Ok _ -> fail "opaque output reference was not rejected");
  let invalid_pointer_consumer =
    node
      ~id:"bad-pointer"
      ~tool_name:"Grep"
      (object_template
         [ ( "pattern"
           , Plan.Json_template.output
               ~node_id:(node_id "typed-source")
               ~pointer:(pointer "/does-not-exist") )
         ])
  in
  let typed_source =
    node ~id:"typed-source" ~tool_name:"keeper_time_now" literal_object
  in
  (match
     Plan.create ~descriptors:(descriptors ()) [ typed_source; invalid_pointer_consumer ]
   with
   | Error (Plan.Invalid_output_pointer { source_node_id; _ })
     when String.equal (Plan.Node_id.to_string source_node_id) "typed-source" -> ()
   | Error _ | Ok _ -> fail "unreachable producer schema pointer was accepted");
  let a_id = node_id "a" in
  let b_id = node_id "b" in
  let a =
    node ~id:"a" ~tool_name:"keeper_time_now" ~after:[ b_id ] literal_object
  in
  let b =
    node ~id:"b" ~tool_name:"masc_board_stats" ~after:[ a_id ] literal_object
  in
  (match Plan.create ~descriptors:(descriptors ()) [ a; b ] with
   | Error (Plan.Dependency_cycle ids) ->
     check
       (list string)
       "closed cycle members"
       [ "a"; "b" ]
       (List.map Plan.Node_id.to_string ids)
   | Error _ | Ok _ -> fail "dependency cycle was not rejected");
  let time = descriptor "keeper_time_now" in
  (match Plan.create ~descriptors:[ time; time ] [ duplicate_a ] with
   | Error (Plan.Duplicate_tool_name "keeper_time_now") -> ()
   | Error _ | Ok _ -> fail "ambiguous descriptor name was not rejected");
  (match Plan.create ~descriptors:(descriptors ()) [] with
   | Error Plan.Empty_plan -> ()
  | Error _ | Ok _ -> fail "empty plan was accepted")
;;

let test_plan_rejects_unsupported_output_schema_keywords () =
  let time = descriptor "keeper_time_now" in
  let time_node = node ~id:"time" ~tool_name:"keeper_time_now" literal_object in
  let with_schema schema =
    { time with Descriptor.composable_output = Descriptor.Json_output { schema } }
  in
  let enum_schema =
    `Assoc [ "type", `String "string"; "enum", `List [ `String "ok" ] ]
  in
  (match Plan.create ~descriptors:[ with_schema enum_schema ] [ time_node ] with
   | Error
       (Plan.Invalid_output_schema
         { error = Plan.Unsupported_schema_keyword { keyword = "enum"; _ }; _ }) -> ()
   | Error _ | Ok _ -> fail "unsupported enum output contract was accepted");
  let schema_valued_additional_properties =
    `Assoc
      [ "type", `String "object"
      ; "properties", `Assoc []
      ; "additionalProperties", `Assoc [ "type", `String "string" ]
      ]
  in
  match
    Plan.create
      ~descriptors:[ with_schema schema_valued_additional_properties ]
      [ time_node ]
  with
  | Error
      (Plan.Invalid_output_schema
        { error = Plan.Invalid_schema_keyword_value
            { keyword = "additionalProperties"; _ }
        ; _
        }) -> ()
  | Error _ | Ok _ -> fail "schema-valued additionalProperties was accepted"
;;

let test_composable_output_registry_is_closed () =
  let json_names =
    Descriptor.all_descriptors ()
    |> List.filter_map (fun descriptor ->
      match descriptor.Descriptor.composable_output with
      | Descriptor.Opaque_output -> None
      | Descriptor.Json_output { schema } ->
        let open Yojson.Safe.Util in
        check string "JSON output schema root" "object" (schema |> member "type" |> to_string);
        (match Descriptor.keeper_model_names descriptor with
         | [ name ] -> Some name
         | [] | _ :: _ :: _ -> fail "JSON output descriptor lacks one model name"))
    |> List.sort String.compare
  in
  check
    (list string)
    "explicit JSON-producing tools"
    [ "keeper_time_now"; "masc_board_stats" ]
    json_names
;;

let () =
  Eio_main.run @@ fun _env ->
  run
    "keeper_tool_plan"
    [ ( "typed-values"
      , [ test_case "node id" `Quick test_node_id_rejects_empty
        ; test_case "JSON pointer" `Quick test_json_pointer_is_exact_rfc6901_navigation
        ; test_case "JSON template" `Quick test_json_template_preserves_declared_structure
        ] )
    ; ( "plan"
      , [ test_case
            "fan-out fan-in layers"
            `Quick
            test_fanout_fanin_layers_are_dependency_owned
        ; test_case
            "producer and consumer schemas"
            `Quick
            test_output_schema_and_consumer_input_are_enforced
        ; test_case
            "invalid graphs and output edges"
            `Quick
            test_plan_rejects_invalid_graphs_and_output_edges
        ; test_case
            "closed composable output registry"
            `Quick
            test_composable_output_registry_is_closed
        ; test_case
            "unsupported output schema keywords"
            `Quick
            test_plan_rejects_unsupported_output_schema_keywords
        ] )
    ]
;;
