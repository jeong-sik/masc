open Alcotest

module Descriptor = Masc.Keeper_tool_descriptor
module Plan = Masc.Keeper_tool_plan
module Descriptor_contract = Masc.Keeper_tool_descriptor_contract

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

let time_descriptor_contract () =
  Descriptor_contract.create
    ~accepted_tool_name:"keeper_time_now"
    (descriptor "keeper_time_now")
  |> Result.get_ok
;;

let replace_descriptor replacement =
  descriptors ()
  |> List.map (fun current ->
    if String.equal current.Descriptor.id replacement.Descriptor.id
    then replacement
    else current)
;;

let test_descriptor_contract_revalidates_unchanged_descriptor () =
  let contract = time_descriptor_contract () in
  match Descriptor_contract.revalidate ~descriptors:(descriptors ()) contract with
  | Ok current ->
    check string
      "current descriptor id"
      current.id
      (Descriptor_contract.descriptor_id contract)
  | Error _ -> fail "unchanged descriptor contract drifted"
;;

let test_descriptor_contract_rejects_removed_descriptor () =
  let contract = time_descriptor_contract () in
  let descriptors =
    descriptors ()
    |> List.filter (fun descriptor ->
      not
        (String.equal
           descriptor.Descriptor.id
           (Descriptor_contract.descriptor_id contract)))
  in
  match Descriptor_contract.revalidate ~descriptors contract with
  | Error (Descriptor_contract.Descriptor_removed _) -> ()
  | Error _ -> fail "removed descriptor returned the wrong drift"
  | Ok _ -> fail "removed descriptor revalidated"
;;

let test_descriptor_contract_rejects_name_drift () =
  let contract = time_descriptor_contract () in
  let current = descriptor "keeper_time_now" in
  let changed = { current with Descriptor.internal_name = "keeper_time_now_v2" } in
  match
    Descriptor_contract.revalidate ~descriptors:(replace_descriptor changed) contract
  with
  | Error (Descriptor_contract.Accepted_tool_name_changed _) -> ()
  | Error _ -> fail "tool name drift returned the wrong result"
  | Ok _ -> fail "tool name drift revalidated"
;;

let test_descriptor_contract_rejects_input_schema_drift () =
  let contract = time_descriptor_contract () in
  let current = descriptor "keeper_time_now" in
  let input_schema =
    `Assoc
      [ "type", `String "object"
      ; "properties", `Assoc [ "zone", `Assoc [ "type", `String "string" ] ]
      ; "required", `List []
      ; "additionalProperties", `Bool false
      ]
  in
  let changed = { current with Descriptor.input_schema } in
  match
    Descriptor_contract.revalidate ~descriptors:(replace_descriptor changed) contract
  with
  | Error (Descriptor_contract.Input_schema_changed _) -> ()
  | Error _ -> fail "input schema drift returned the wrong result"
  | Ok _ -> fail "input schema drift revalidated"
;;

let test_descriptor_contract_rejects_output_drift () =
  let contract = time_descriptor_contract () in
  let current = descriptor "keeper_time_now" in
  let changed =
    { current with Descriptor.composable_output = Descriptor.Opaque_output }
  in
  match
    Descriptor_contract.revalidate ~descriptors:(replace_descriptor changed) contract
  with
  | Error (Descriptor_contract.Composable_output_changed _) -> ()
  | Error _ -> fail "output contract drift returned the wrong result"
  | Ok _ -> fail "output contract drift revalidated"
;;

let test_descriptor_contract_rejects_execution_drift () =
  let contract = time_descriptor_contract () in
  let current = descriptor "keeper_time_now" in
  let changed =
    { current with Descriptor.execution = Descriptor.Ordinary Descriptor.Serial }
  in
  match
    Descriptor_contract.revalidate ~descriptors:(replace_descriptor changed) contract
  with
  | Error (Descriptor_contract.Execution_changed _) -> ()
  | Error _ -> fail "execution drift returned the wrong result"
  | Ok _ -> fail "execution drift revalidated"
;;

let replace_contract_field name value = function
  | `Assoc fields ->
    `Assoc
      (List.map
         (fun (field, current) ->
            if String.equal field name then field, value else field, current)
         fields)
  | _ -> fail "descriptor contract encoder returned a non-object"
;;

let check_contract_round_trip label contract =
  let encoded = Descriptor_contract.to_yojson contract in
  let decoded = Descriptor_contract.of_yojson encoded |> Result.get_ok in
  check
    (testable Yojson.Safe.pp Yojson.Safe.equal)
    label
    encoded
    (Descriptor_contract.to_yojson decoded)
;;

let test_descriptor_contract_round_trips () =
  let current = descriptor "keeper_time_now" in
  let preferred =
    { current with
      Descriptor.keeper_model_projection = Descriptor.Preferred_public_name
    ; public_name = "Clock"
    }
  in
  let internal =
    { current with
      Descriptor.keeper_model_projection = Descriptor.Internal_name
    ; internal_name = "clock_internal"
    }
  in
  Descriptor_contract.create ~accepted_tool_name:"Clock" preferred
  |> Result.get_ok
  |> check_contract_round_trip "preferred-name round-trip";
  Descriptor_contract.create ~accepted_tool_name:"clock_internal" internal
  |> Result.get_ok
  |> check_contract_round_trip "internal-name round-trip"
;;

let test_descriptor_contract_rejects_impossible_projection_and_name () =
  let encoded = Descriptor_contract.to_yojson (time_descriptor_contract ()) in
  let projection name projected_by =
    encoded
    |> replace_contract_field "model_projection" (`String name)
    |> replace_contract_field "projected_by" projected_by
  in
  List.iter
    (fun json ->
       match Descriptor_contract.of_yojson json with
       | Error
           (Descriptor_contract.Decode_invariant_violation
              (Descriptor_contract.Uncallable_model_projection _)) -> ()
       | Error _ -> fail "uncallable projection returned the wrong error"
       | Ok _ -> fail "uncallable projection decoded")
    [ projection "operator_only" `Null
    ; projection "transport_alias" (`String "keeper_time_now")
    ];
  let current = descriptor "keeper_time_now" in
  let operator_only =
    { current with Descriptor.keeper_model_projection = Descriptor.Operator_only }
  in
  (match Descriptor_contract.create ~accepted_tool_name:"keeper_time_now" operator_only with
   | Error
       (Descriptor_contract.Create_invariant_violation
          (Descriptor_contract.Uncallable_model_projection Descriptor.Operator_only)) -> ()
   | Error _ -> fail "uncallable created projection returned the wrong error"
   | Ok _ -> fail "uncallable projection created");
  let blank = replace_contract_field "accepted_tool_name" (`String " \t") encoded in
  match Descriptor_contract.of_yojson blank with
  | Error
      (Descriptor_contract.Decode_invariant_violation
         Descriptor_contract.Blank_accepted_tool_name) -> ()
  | Error _ -> fail "blank accepted name returned the wrong error"
  | Ok _ -> fail "blank accepted name decoded"
;;

let test_descriptor_contract_rejects_invalid_input_schema () =
  let current = descriptor "keeper_time_now" in
  let encoded = Descriptor_contract.to_yojson (time_descriptor_contract ()) in
  let invalid_schemas =
    [ `Null
    ; `Assoc
        [ "type", `String "object"
        ; "properties", `Null
        ; "additionalProperties", `Bool false
        ]
    ]
  in
  List.iter
    (fun input_schema ->
       let decoded = replace_contract_field "input_schema" input_schema encoded in
       (match Descriptor_contract.of_yojson decoded with
        | Error
            (Descriptor_contract.Decode_invariant_violation
               (Descriptor_contract.Invalid_model_input_schema (_ :: _))) -> ()
        | Error _ -> fail "invalid decoded input schema returned the wrong error"
        | Ok _ -> fail "invalid input schema decoded");
       let changed = { current with Descriptor.input_schema } in
       match Descriptor_contract.create ~accepted_tool_name:"keeper_time_now" changed with
       | Error
           (Descriptor_contract.Create_invariant_violation
              (Descriptor_contract.Invalid_model_input_schema (_ :: _))) -> ()
       | Error _ -> fail "invalid created input schema returned the wrong error"
       | Ok _ -> fail "invalid input schema created")
    invalid_schemas
;;

let test_descriptor_contract_rejects_noncanonical_output_schema () =
  let current = descriptor "keeper_time_now" in
  let duplicate_schema =
    `Assoc [ "type", `String "object"; "type", `String "object" ]
  in
  let changed =
    { current with
      Descriptor.composable_output =
        Descriptor.Json_output { schema = duplicate_schema }
    }
  in
  match Descriptor_contract.create ~accepted_tool_name:"keeper_time_now" changed with
  | Error
      (Descriptor_contract.Non_canonical_schema
         { location = Descriptor_contract.Composable_output_schema
         ; error = Descriptor_contract.Duplicate_object_key "type"
         }) -> ()
  | Error _ -> fail "non-canonical output schema returned the wrong error"
  | Ok _ -> fail "non-canonical output schema was captured"
;;

let test_descriptor_contract_codec_is_closed () =
  let encoded = Descriptor_contract.to_yojson (time_descriptor_contract ()) in
  let duplicate =
    match encoded with
    | `Assoc fields -> `Assoc (fields @ [ "execution", `String "serial" ])
    | _ -> fail "descriptor contract encoder returned a non-object"
  in
  (match Descriptor_contract.of_yojson duplicate with
   | Error (Descriptor_contract.Non_canonical_json (Descriptor_contract.Duplicate_object_key "execution")) -> ()
   | Error _ -> fail "duplicate contract field returned the wrong error"
   | Ok _ -> fail "duplicate contract field decoded");
  let invalid =
    match encoded with
    | `Assoc fields ->
      `Assoc
        (List.map
           (fun (name, value) ->
              if String.equal name "execution"
              then name, `String "unordered"
              else name, value)
           fields)
    | _ -> fail "descriptor contract encoder returned a non-object"
  in
  match Descriptor_contract.of_yojson invalid with
  | Error (Descriptor_contract.Invalid_execution "unordered") -> ()
  | Error _ -> fail "invalid execution returned the wrong error"
  | Ok _ -> fail "invalid execution decoded"
;;

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
  let escaped = pointer "/a~1b/~0key" in
  check string
    "canonical pointer spelling"
    "/a~1b/~0key"
    (Plan.Json_pointer.to_string escaped);
  check string
    "human fallback preserves canonical pointer identity"
    "node \"target\" has invalid output pointer /a~1b/~0key for node \"source\""
    (Plan.error_to_string
       (Plan.Invalid_output_pointer
          { node_id = node_id "target"
          ; source_node_id = node_id "source"
          ; pointer = escaped
          ; error = Plan.Json_pointer.Missing_property_schema "~key"
          }));
  (match Plan.Json_pointer.resolve escaped source with
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


(* A composition node's output is validated against the descriptor's declared
   composable schema, and an undeclared field is a hard failure -- not an
   ignored extra. #32488 added [next_cursor] to the keeper_tasks_list
   response without widening that schema, so every composition holding a
   tasks node stopped returning and answered
   [output_validation_failed / unexpected_field: next_cursor] instead. The
   live keeper_compose_work-intake evidence carries exactly that cause.

   This pins the paged shape against the schema so the producer and the
   declaration cannot drift apart again in that direction. *)
let test_tasks_list_output_schema_admits_the_page_cursor () =
  let tasks_id = node_id "tasks" in
  let tasks = node ~id:"tasks" ~tool_name:"keeper_tasks_list" literal_object in
  let plan =
    match Plan.create ~descriptors:(descriptors ()) [ tasks ] with
    | Ok plan -> plan
    | Error _ -> fail "single keeper_tasks_list node was rejected"
  in
  let run_id = Plan.Run_id.fresh () in
  let paged_response =
    `Assoc
      [ "backlog_authority", `String "store"
      ; "degraded", `Bool false
      ; "projection", `String "snapshot"
      ; "kind", `String "snapshot"
      ; "revision", `String "42"
      ; "snapshot", `List []
      ; "matching_count", `Int 120
      ; "returned_count", `Int 20
      ; "truncated", `Bool true
      ; "next_cursor", `String "opaque-keyset-cursor"
      ]
  in
  (match Plan.validate_output plan ~run_id ~node_id:tasks_id paged_response with
   | Ok _ -> ()
   | Error _ ->
     fail "a truncated keeper_tasks_list page violated its descriptor schema");
  (* The last page carries no cursor, so the field stays optional. *)
  let last_page =
    `Assoc
      [ "backlog_authority", `String "store"
      ; "degraded", `Bool false
      ; "projection", `String "snapshot"
      ; "kind", `String "snapshot"
      ; "revision", `String "42"
      ; "snapshot", `List []
      ; "matching_count", `Int 20
      ; "returned_count", `Int 20
      ; "truncated", `Bool false
      ]
  in
  match Plan.validate_output plan ~run_id ~node_id:tasks_id last_page with
  | Ok _ -> ()
  | Error _ -> fail "an unpaged keeper_tasks_list response was rejected"
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
  let enum_schema =
    `Assoc [ "type", `String "string"; "enum", `List [ `String "ok" ] ]
  in
  (match Plan.validate_composable_schema enum_schema with
   | Error
       (Plan.Unsupported_schema_keyword { keyword = "enum"; _ }) -> ()
   | Error _ | Ok _ -> fail "unsupported enum output contract was accepted");
  let schema_valued_additional_properties =
    `Assoc
      [ "type", `String "object"
      ; "properties", `Assoc []
      ; "additionalProperties", `Assoc [ "type", `String "string" ]
      ]
  in
  match Plan.validate_composable_schema schema_valued_additional_properties with
  | Error
      (Plan.Invalid_schema_keyword_value
        { keyword = "additionalProperties"; _ }) -> ()
  | Error _ | Ok _ -> fail "schema-valued additionalProperties was accepted"
;;

let test_terminal_node_is_unique_and_depends_on_every_prior_node () =
  let terminal = descriptor "keeper_surface_post" in
  let first = node ~id:"first" ~tool_name:"keeper_surface_post" literal_object in
  let second = node ~id:"second" ~tool_name:"keeper_surface_post" literal_object in
  (match Plan.create ~descriptors:[ terminal ] [ first; second ] with
   | Error (Plan.Multiple_terminal_nodes [ first_id; second_id ])
     when Plan.Node_id.equal first_id (node_id "first")
          && Plan.Node_id.equal second_id (node_id "second") -> ()
   | Error _ | Ok _ -> fail "multiple terminal nodes were accepted");
  let ordinary = descriptor "masc_board_stats" in
  let ordinary_node = node ~id:"ordinary" ~tool_name:"masc_board_stats" literal_object in
  let lone_terminal = node ~id:"terminal" ~tool_name:"keeper_surface_post" literal_object in
  (match
     Plan.create ~descriptors:[ ordinary; terminal ] [ ordinary_node; lone_terminal ]
   with
   | Error
       (Plan.Terminal_node_missing_dependency { terminal_node_id; node_id = missing })
     when Plan.Node_id.equal terminal_node_id (node_id "terminal")
          && Plan.Node_id.equal missing (node_id "ordinary") -> ()
   | Error _ | Ok _ -> fail "terminal node without explicit ancestry was accepted");
  let dependent_terminal =
    node
      ~id:"terminal"
      ~tool_name:"keeper_surface_post"
      ~after:[ node_id "ordinary" ]
      literal_object
  in
  match
    Plan.create ~descriptors:[ ordinary; terminal ] [ ordinary_node; dependent_terminal ]
  with
  | Ok _ -> ()
  | Error _ -> fail "terminal node with complete explicit ancestry was rejected"
;;

let test_plan_uses_process_owned_descriptor_authority () =
  let canonical = descriptor "keeper_time_now" in
  let supplied =
    { canonical with
      Descriptor.execution = Descriptor.Ordinary Descriptor.Serial
    ; input_schema = `Assoc [ "type", `String "string" ]
    ; composable_output = Descriptor.Opaque_output
    }
  in
  let time_node = node ~id:"time" ~tool_name:"keeper_time_now" literal_object in
  match Plan.create ~descriptors:[ supplied ] [ time_node ] with
  | Error _ -> fail "canonical descriptor id was not resolved"
  | Ok plan ->
    (match Plan.descriptor plan (node_id "time") with
     | Some descriptor when descriptor == canonical ->
       (match descriptor.Descriptor.execution, descriptor.composable_output with
        | Descriptor.Ordinary Descriptor.Concurrent, Descriptor.Json_output _ -> ()
        | _ -> fail "record-updated descriptor fields became plan authority")
     | Some _ | None -> fail "plan did not retain process-owned descriptor authority")
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
         | [] | _ :: _ :: _ ->
           failf
             "JSON output descriptor %S lacks one model name"
             descriptor.Descriptor.internal_name))
    |> List.sort String.compare
  in
  check
    (list string)
    "explicit JSON-producing tools"
    [ "Execute"
    ; "keeper_artifact_read"
    ; "keeper_tasks_list"
    ; "keeper_time_now"
      (* masc_agent_card and masc_agent_timeline left this list with #29681:
         off the model surface, so no plan can name them and a composable
         output schema had nothing to describe. *)
    ; "masc_agent_fitness"
    ; "masc_board_list"
    ; "masc_board_stats"
    ; "masc_get_metrics"
    ; "masc_goal_list"
    ; "masc_run_list"
    ]
    json_names
;;

let test_declared_output_schemas_satisfy_the_contract () =
  Descriptor.all_descriptors ()
  |> List.iter (fun descriptor ->
    match descriptor.Descriptor.composable_output with
    | Descriptor.Opaque_output -> ()
    | Descriptor.Json_output { schema } ->
      (match Plan.validate_composable_schema schema with
       | Ok () -> ()
       | Error _ ->
         failf
           "declared composable schema violates the schema contract: %s"
           descriptor.Descriptor.id))
;;

(* Producer-shaped samples mirror the single JSON construction site of each
   tool; the file:line for each lives in the schema comments in
   keeper_tool_descriptor.ml. *)
let test_new_declared_output_schemas_admit_producer_shapes () =
  let validate tool_name value =
    let single = node ~id:"n" ~tool_name literal_object in
    match Plan.create ~descriptors:(descriptors ()) [ single ] with
    | Error _ -> failf "single-node plan was rejected for %s" tool_name
    | Ok plan ->
      Plan.validate_output plan ~run_id:(Plan.Run_id.fresh ()) ~node_id:(node_id "n") value
  in
  let accepts tool_name value =
    match validate tool_name value with
    | Ok _ -> ()
    | Error _ -> failf "producer-shaped output was rejected for %s" tool_name
  in
  let rejects tool_name value =
    match validate tool_name value with
    | Error (Plan.Output_validation_failed _) -> ()
    | Error _ | Ok _ -> failf "malformed output was accepted for %s" tool_name
  in
  let metrics_value =
    Masc.Metrics_store_eio.agent_metrics_to_yojson
      { Masc.Metrics_store_eio.agent_id = "albini"
      ; period_start = 1755400000.0
      ; period_end = 1755500000.0
      ; total_tasks = 3
      ; completed_tasks = 2
      ; failed_tasks = 1
      ; avg_completion_time_s = 42.5
      ; task_completion_rate = 0.66
      ; error_rate = 0.33
      ; handoff_success_rate = 1.0
      ; unique_collaborators = [ "gemini" ]
      }
  in
  accepts
    "masc_board_list"
    (Masc.Snapshot_protocol.to_yojson
       (Masc.Snapshot_protocol.Snapshot
          { revision = "board:r1"; value = `String "posts" }));
  accepts
    "masc_board_list"
    (Masc.Snapshot_protocol.to_yojson
       (Masc.Snapshot_protocol.Unchanged { revision = "board:r1" }));
  let task_skill_reference =
    `Assoc
      [ ( "identity"
        , `Assoc
            [ "source_id", `String "project-masc"
            ; "package_id", `String "ocaml-coding"
            ; "name", `String "ocaml-coding"
            ] )
      ; "content_revision", `String (String.make 64 'a')
      ]
  in
  let task_item =
    `Assoc
      [ "id", `String "task-1"
      ; "title", `String "t"
      ; "description", `String "d"
      ; "priority", `Int 3
      ; "files", `List [ `String "lib/a.ml" ]
      ; "skills", `List [ task_skill_reference ]
      ; "created_at", `String "2026-08-18T00:00:00Z"
      ; "status", `String "claimed"
      ; "assignee", `String "albini"
      ; "claimed_at", `String "2026-08-18T00:00:01Z"
      ]
  in
  let compact_task_item =
    `Assoc
      [ "id", `String "task-2"
      ; "title", `String "t"
      ; "priority", `Int 2
      ; "created_at", `String "2026-08-18T00:00:00Z"
      ; "status", `String "todo"
      ; "skills", `List []
      ]
  in
  accepts
    "keeper_tasks_list"
    (`Assoc
       [ "backlog_authority", `String "primary"
       ; "degraded", `Bool false
       ; "projection", `String "full"
       ; "matching_count", `Int 1
       ; "returned_count", `Int 1
       ; "truncated", `Bool false
       ; "kind", `String "snapshot"
       ; "revision", `String "tasks:r1"
       ; "snapshot", `List [ task_item ]
       ]);
  accepts
    "keeper_tasks_list"
    (`Assoc
       [ "backlog_authority", `String "primary"
       ; "degraded", `Bool false
       ; "projection", `String "compact"
       ; "matching_count", `Int 1
       ; "returned_count", `Int 1
       ; "truncated", `Bool false
       ; "kind", `String "snapshot"
       ; "revision", `String "tasks:r1"
       ; "snapshot", `List [ compact_task_item ]
       ]);
  (* The unchanged variant carries no rows, so the producer omits the row
     statistics (matching_count/returned_count/truncated) entirely. *)
  accepts
    "keeper_tasks_list"
    (`Assoc
       [ "backlog_authority", `String "primary"
       ; "degraded", `Bool false
       ; "projection", `String "compact"
       ; "kind", `String "unchanged"
       ; "revision", `String "tasks:r1"
       ]);
  rejects
    "keeper_tasks_list"
    (`Assoc
       [ "backlog_authority", `String "primary"
       ; "degraded", `Bool false
       ; "kind", `String "snapshot"
       ]);
  rejects
    "keeper_tasks_list"
    (`Assoc
       [ "backlog_authority", `String "primary"
       ; "degraded", `Bool false
       ; "kind", `String "snapshot"
       ; "revision", `String "tasks:r1"
       ; "snapshot", `List [ compact_task_item ]
       ]);
  accepts
    "keeper_artifact_read"
    (`Assoc
       [ "ok", `Bool true
       ; "sha256", `String (String.make 64 'a')
       ; "offset", `Int 0
       ; "next_offset", `Int 512
       ; "total_bytes", `Int 1024
       ; "eof", `Bool false
       ; "encoding", `String "utf-8"
       ; "content", `String "chunk"
       ]);
  rejects
    "keeper_artifact_read"
    (`Assoc
       [ "ok", `Bool true
       ; "sha256", `String (String.make 64 'a')
       ; "offset", `Int 0
       ; "next_offset", `Int 512
       ; "total_bytes", `Int 1024
       ; "eof", `Bool false
       ; "encoding", `String "utf-8"
       ; "content", `String "chunk"
       ; "_unexpected", `Bool true
       ]);
  accepts
    "masc_goal_list"
    (`Assoc
       [ "status", `String "ok"
       ; "generated_at", `String "2026-08-18T00:00:00Z"
       ; "count", `Int 1
       ; ( "goals"
         , `List
             [ `Assoc
                 [ "id", `String "goal-1"
                 ; "title", `String "g"
                 ; "metric", `Null
                 ; "priority", `Int 2
                 ; "phase", `String "executing"
                 ; "owner", `Null
                 ; "created_at", `String "2026-08-01T00:00:00Z"
                 ; "updated_at", `String "2026-08-18T00:00:00Z"
                 ]
             ] )
       ; ( "rollup"
         , `Assoc
             [ "active_count", `Int 1
             ; "verifying_count", `Int 0
             ; "done_count", `Int 0
             ; "dropped_count", `Int 0
             ] )
       ]);
  accepts
    "masc_run_list"
    (`Assoc
       [ "count", `Int 1
       ; ( "runs"
         , `List
             [ Masc.Run_eio.run_record_to_json
                 { Masc.Run_eio.task_id = "task-1"
                 ; agent_name = None
                 ; plan = "plan body"
                 ; created_at = "2026-08-18T00:00:00Z"
                 ; updated_at = "2026-08-18T00:00:00Z"
                 }
             ] )
       ]);
  accepts "masc_get_metrics" metrics_value;
  accepts
    "masc_get_metrics"
    (match metrics_value with
     | `Assoc fields ->
       `Assoc
         (fields
          @ [ "requested_agent_name", `String "albini"
            ; "resolved_agent_name", `String "keeper-albini-agent"
            ])
     | other -> other);
  rejects
    "masc_get_metrics"
    (match metrics_value with
     | `Assoc fields -> `Assoc (("_unexpected", `Bool true) :: fields)
     | other -> other);
  accepts
    "masc_agent_fitness"
    (`Assoc [ "count", `Int 0; "agents", `List [] ]);
  accepts
    "masc_agent_fitness"
    (`Assoc
       [ "count", `Int 1
       ; ( "agents"
         , `List
             [ `Assoc
                 [ "agent_id", `String "albini"
                 ; ( "components"
                   , `Assoc
                       [ "completion", `Float 0.66
                       ; "reliability", `Float 0.67
                       ; "speed", `Float 1.0
                       ; "handoff", `Float 1.0
                       ] )
                 ; "metrics", metrics_value
                 ]
             ] )
       ])
;;

let test_composition_run_id_is_uuid_v7_identity () =
  let first = Plan.Composition_run_id.fresh () in
  let second = Plan.Composition_run_id.fresh () in
  check bool "fresh composition identities differ" false (Plan.Composition_run_id.equal first second);
  List.iter
    (fun value ->
       match Uuidm.of_string (Plan.Composition_run_id.to_string value) with
       | Some uuid -> check int "composition run id UUID version" 7 (Uuidm.version uuid)
       | None -> fail "composition run id is not a UUID")
    [ first; second ];
  let encoded = Plan.Composition_run_id.to_string first in
  (match Plan.Composition_run_id.of_string encoded with
   | Ok decoded ->
     check bool
       "composition run id string round-trip"
       true
       (Plan.Composition_run_id.equal first decoded)
   | Error (Plan.Composition_run_id.Invalid_uuid_v7 reason) ->
     failf "fresh UUID v7 did not decode: %s" reason);
  List.iter
    (fun invalid ->
       match Plan.Composition_run_id.of_string invalid with
       | Error (Plan.Composition_run_id.Invalid_uuid_v7 _) -> ()
       | Ok _ -> failf "non-v7 composition run id was accepted: %S" invalid)
    [ "not-a-uuid"; "550e8400-e29b-41d4-a716-446655440000" ]
;;

module Request = Masc.Keeper_tool_plan_request
module Catalog = Masc.Keeper_tool_composition_catalog
module Recipe = Masc.Keeper_async_composition_recipe

let parse_request json =
  Request.plan_of_json ~descriptors:(Descriptor.all_descriptors ()) json
;;

let request_of_string text = Yojson.Safe.from_string text

let test_request_parses_reference_chain () =
  let json =
    request_of_string
      {|{"nodes":[
          {"id":"clock","tool":"keeper_time_now"},
          {"id":"memory","tool":"keeper_memory_search","after":["clock"],
           "input":{"kind":"object","fields":[
             {"name":"query",
              "value":{"kind":"output","node":"clock","pointer":"/now_iso"}}]}}]}|}
  in
  match parse_request json with
  | Ok plan ->
    let names =
      Plan.nodes plan |> List.map (fun node -> Plan.Node_id.to_string node.Plan.id)
    in
    check (list string) "node order preserved" [ "clock"; "memory" ] names;
    (match Plan.nodes plan with
     | [ clock; _memory ] ->
       check
         (list string)
         "clock has no dependencies"
         []
         (Plan.dependencies clock |> List.map Plan.Node_id.to_string)
     | _ -> fail "expected exactly two nodes")
  | Error error -> failf "reference chain rejected: %s" (Request.error_message error)
;;

let plan_signature plan =
  Plan.nodes plan
  |> List.map (fun (node : Plan.node) ->
    String.concat
      "|"
      [ Plan.Node_id.to_string node.id
      ; node.tool_name
      ; (node.after |> List.map Plan.Node_id.to_string |> String.concat ",")
      ; ( Plan.Json_template.dependencies node.input
          |> List.map Plan.Node_id.to_string
          |> String.concat "," )
      ])
;;

let equivalent_toml_plan =
  {|[[compositions]]
name = "request-parity"
execution = "inline"

[[compositions.nodes]]
id = "clock"
tool = "keeper_time_now"
[compositions.nodes.input]
kind = "literal"
value = {}

[[compositions.nodes]]
id = "memory"
tool = "keeper_memory_search"
after = ["clock"]
[compositions.nodes.input]
kind = "object"
[[compositions.nodes.input.fields]]
name = "query"
[compositions.nodes.input.fields.value]
kind = "output"
node = "clock"
pointer = "/now_iso"
|}
;;

let test_request_and_toml_share_plan_grammar () =
  let request_plan =
    match
      parse_request
        (request_of_string
           {|{"nodes":[
               {"id":"clock","tool":"keeper_time_now"},
               {"id":"memory","tool":"keeper_memory_search","after":["clock"],
                "input":{"kind":"object","fields":[
                  {"name":"query","value":{"kind":"output","node":"clock",
                                                "pointer":"/now_iso"}}]}}]}|})
    with
    | Ok plan -> plan
    | Error error -> failf "JSON request rejected: %s" (Request.error_message error)
  in
  let catalog_plan =
    match Catalog.parse equivalent_toml_plan with
    | Error error -> failf "equivalent TOML rejected: %s" (Catalog.error_to_string error)
    | Ok catalog ->
      (match Catalog.find catalog "request-parity" with
       | Some entry -> entry.plan
       | None -> fail "equivalent TOML omitted its composition")
  in
  check
    (list string)
    "JSON request and TOML build the same descriptor-backed plan"
    (plan_signature catalog_plan)
    (plan_signature request_plan)
;;

let test_request_and_toml_reject_the_same_invalid_pointer () =
  let request_rejected =
    match
      parse_request
        (request_of_string
           {|{"nodes":[
               {"id":"clock","tool":"keeper_time_now"},
               {"id":"memory","tool":"keeper_memory_search",
                "input":{"kind":"output","node":"clock","pointer":"now_iso"}}]}|})
    with
    | Error (Request.Node_template_error { error = Request.Template_invalid_pointer _; _ }) ->
      true
    | Error _ | Ok _ -> false
  in
  let toml_rejected =
    match
      Catalog.parse
        {|[[compositions]]
name = "invalid-pointer"
execution = "inline"
[[compositions.nodes]]
id = "clock"
tool = "keeper_time_now"
[compositions.nodes.input]
kind = "literal"
value = {}
[[compositions.nodes]]
id = "memory"
tool = "keeper_memory_search"
[compositions.nodes.input]
kind = "output"
node = "clock"
pointer = "now_iso"
|}
    with
    | Error (Catalog.Invalid_json_pointer _) -> true
    | Error _ | Ok _ -> false
  in
  check bool "JSON request rejects an invalid pointer" true request_rejected;
  check bool "TOML rejects the same invalid pointer" true toml_rejected
;;

let test_validated_plan_has_a_closed_durable_request_encoding () =
  let original =
    request_of_string
      {|{"nodes":[
          {"id":"clock","tool":"keeper_time_now",
           "input":{"kind":"literal","value":{}}},
          {"id":"memory","tool":"keeper_memory_search","after":["clock"],
           "input":{"kind":"object","fields":[
             {"name":"query","value":{"kind":"output","node":"clock",
                                            "pointer":"/now_iso"}},
             {"name":"filters","value":{"kind":"array","items":[
               {"kind":"literal","value":"recent"}]}}]}}]}|}
  in
  let plan =
    match parse_request original with
    | Ok plan -> plan
    | Error error -> failf "durable fixture rejected: %s" (Request.error_message error)
  in
  let encoded =
    match Request.to_yojson plan with
    | Ok encoded -> encoded
    | Error (Request.Unsubstituted_param { name }) ->
      failf "validated request retained parameter %S" name
  in
  let decoded =
    match parse_request encoded with
    | Ok decoded -> decoded
    | Error error ->
      failf "canonical durable encoding did not revalidate: %s"
        (Request.error_message error)
  in
  check (list string) "round-trip plan identity" (plan_signature plan)
    (plan_signature decoded);
  match Request.to_yojson decoded with
  | Error _ -> fail "round-trip plan stopped being encodable"
  | Ok reencoded ->
    check
      (testable Yojson.Safe.pp Yojson.Safe.equal)
      "canonical encoding is stable"
      encoded
      reencoded
;;

let test_durable_request_encoding_rejects_unsubstituted_params () =
  let query = Plan.Json_template.param ~name:"query" in
  let input =
    match Plan.Json_template.object_ [ "query", query ] with
    | Ok input -> input
    | Error _ -> fail "unique parameter input was rejected"
  in
  let node =
    Plan.node
      ~id:(node_id "memory")
      ~tool_name:"keeper_memory_search"
      ~input
      ()
  in
  let plan =
    match Plan.create ~descriptors:(Descriptor.all_descriptors ()) [ node ] with
    | Ok plan -> plan
    | Error error -> failf "parameterized plan rejected: %s" (Plan.error_to_string error)
  in
  match Request.to_yojson plan with
  | Error (Request.Unsubstituted_param { name = "query" }) -> ()
  | Error (Request.Unsubstituted_param { name }) ->
    failf "wrong unsubstituted parameter %S" name
  | Ok _ -> fail "durable encoding admitted an unsubstituted parameter"
;;

let recipe_skill_reference () =
  let source_id = Skill_source_config.source_id_of_string "workspace" |> Result.get_ok in
  let package_id = Skill_reference.package_id_of_directory "compose" |> Result.get_ok in
  let identity =
    Skill_reference.make_identity
      ~source_id
      ~package_id
      ~name:"compose"
  in
  Skill_reference.make
    ~identity
    ~content_revision:(Skill_reference.content_revision_of_source_text "recipe fixture")
;;

let recipe_checkpoint () : Agent_core.Checkpoint.t =
  { Agent_core.Checkpoint.version = Agent_core.Checkpoint.checkpoint_version
  ; session_id = "accepted-session"
  ; agent_name = "keeper-recipe"
  ; model = "recipe-model"
  ; system_prompt = Some "accepted system prompt"
  ; messages =
      [ { Agent_core.Types.role = Agent_core.Types.User
        ; content = [ Agent_core.Types.Text "accepted history" ]
        ; name = None
        ; tool_call_id = None
        ; metadata = []
        }
      ]
  ; usage = Agent_core.Types.empty_usage
  ; turn_count = 7
  ; created_at = 1_000.0
  ; tools = []
  ; tool_choice = None
  ; disable_parallel_tool_use = false
  ; temperature = None
  ; top_p = None
  ; top_k = None
  ; min_p = None
  ; enable_thinking = None
  ; preserve_thinking = None
  ; response_format = Agent_core.Types.Off
  ; thinking_budget = None
  ; reasoning_effort = None
  ; cache_system_prompt = false
  ; context = Agent_core.Context.create_sync ()
  ; mcp_sessions = []
  ; working_context = Some (`Assoc [ "accepted", `Bool true ])
  }
;;

let recipe_invocation () =
  let schedule : Agent_core.Tool_contract.schedule =
    { planned_index = 4
    ; batch_index = 2
    ; batch_size = 3
    ; execution_mode = Agent_core.Tool_contract.Concurrent
    }
  in
  Agent_core.Tool_contract.Invocation.create
    ~tool_use_id:"tool-use-parent"
    ~turn:9
    ~schedule
    ~completion:Agent_core.Tool_contract.Continue_after_success
;;

let accepted_surface_digest_string = String.make 64 'b'

let accepted_surface_digest () =
  Recipe.Accepted_surface_digest.of_string accepted_surface_digest_string
  |> Result.get_ok
;;

let recipe_plan () =
  match
    parse_request
      (request_of_string
         {|{"nodes":[{"id":"clock","tool":"keeper_time_now",
              "input":{"kind":"literal","value":{}}}]}|})
  with
  | Ok plan -> plan
  | Error error -> failf "recipe plan rejected: %s" (Request.error_message error)
;;

let recipe_with_origin_and_checkpoint origin accepted_checkpoint =
  match
    Recipe.create
      ~composition_run_id:(Plan.Composition_run_id.fresh ())
      ~origin
      ~accepted_surface_digest:(accepted_surface_digest ())
      ~plan:(recipe_plan ())
      ~invocation:(recipe_invocation ())
      ~accepted_checkpoint
  with
  | Ok recipe -> recipe
  | Error (Recipe.Unbound_plan (Request.Unsubstituted_param { name })) ->
    failf "recipe fixture retained parameter %S" name
  | Error (Recipe.Create_negative_invocation_turn turn) ->
    failf "recipe fixture has negative turn %d" turn
  | Error (Recipe.Create_invalid_invocation_schedule detail) ->
    failf "recipe fixture has invalid schedule: %s" detail
  | Error (Recipe.Create_invalid_checkpoint error) ->
    failf "recipe fixture has invalid checkpoint: %s" (Agent_core.Error.to_string error)
  | Error (Recipe.Create_non_canonical_json _) ->
    fail "recipe fixture did not produce canonical JSON"
;;

let recipe_with_origin origin =
  recipe_with_origin_and_checkpoint origin (recipe_checkpoint ())
;;

let encode_recipe recipe =
  match Recipe.to_yojson recipe with
  | Ok json -> json
  | Error (Recipe.Encode_plan (Request.Unsubstituted_param { name })) ->
    failf "accepted recipe retained parameter %S" name
  | Error (Recipe.Encode_invalid_checkpoint error) ->
    failf "accepted recipe retained an invalid checkpoint: %s" (Agent_core.Error.to_string error)
  | Error (Recipe.Encode_non_canonical_json _) ->
    fail "accepted recipe retained non-canonical JSON"
;;

let encoded_recipe origin =
  recipe_with_origin origin |> encode_recipe
;;

let decode_recipe json =
  Recipe.of_yojson ~descriptors:(descriptors ()) json
;;

let accepted_checkpoint recipe =
  match Recipe.accepted_checkpoint recipe with
  | Ok checkpoint -> checkpoint
  | Error error -> fail ("accepted checkpoint did not decode: " ^ Agent_core.Error.to_string error)
;;

let test_async_recipe_round_trips_full_accepted_values () =
  let reference = recipe_skill_reference () in
  let original = recipe_with_origin (Recipe.Skill_composition reference) in
  let encoded = encode_recipe original in
  let decoded = decode_recipe encoded |> Result.get_ok in
  let reencoded = encode_recipe decoded in
  (match encoded with
   | `Assoc fields ->
     check
       (list string)
       "recipe stores only durable authority and accepted observations"
       [ "composition_run_id"
       ; "origin"
       ; "accepted_surface_digest"
       ; "plan"
       ; "invocation"
       ; "accepted_checkpoint"
       ]
       (List.map fst fields)
   | _ -> fail "recipe encoder did not return an object");
  check
    (testable Yojson.Safe.pp Yojson.Safe.equal)
    "canonical recipe round-trip"
    encoded
    reencoded;
  check bool
    "composition run identity"
    true
    (Plan.Composition_run_id.equal
       (Recipe.composition_run_id original)
       (Recipe.composition_run_id decoded));
  check string
    "accepted surface observation"
    accepted_surface_digest_string
    (Recipe.accepted_surface_digest decoded
     |> Recipe.Accepted_surface_digest.to_string);
  check
    (list string)
    "bound plan"
    (plan_signature (Recipe.plan original))
    (plan_signature (Recipe.plan decoded));
  (match Recipe.origin decoded with
   | Recipe.Skill_composition decoded_reference ->
     check bool "exact skill reference" true (Skill_reference.equal reference decoded_reference));
  let invocation = Recipe.invocation decoded in
  check string
    "invocation tool use id"
    "tool-use-parent"
    (Agent_core.Tool_contract.Invocation.tool_use_id invocation);
  check int "invocation turn" 9 (Agent_core.Tool_contract.Invocation.turn invocation);
  let schedule = Agent_core.Tool_contract.Invocation.schedule invocation in
  check int "planned index" 4 schedule.planned_index;
  check int "batch index" 2 schedule.batch_index;
  check int "batch size" 3 schedule.batch_size;
  (match schedule.execution_mode with
   | Agent_core.Tool_contract.Concurrent -> ()
   | Agent_core.Tool_contract.Serial -> fail "invocation execution mode changed");
  (match Agent_core.Tool_contract.Invocation.completion invocation with
   | Agent_core.Tool_contract.Continue_after_success -> ()
   | Agent_core.Tool_contract.Terminal_after_success _ ->
     fail "invocation completion changed");
  let checkpoint = accepted_checkpoint decoded in
  check string "checkpoint session" "accepted-session" checkpoint.session_id;
  check string "checkpoint agent" "keeper-recipe" checkpoint.agent_name;
  check int "checkpoint turn count" 7 checkpoint.turn_count;
  check
    (testable Yojson.Safe.pp Yojson.Safe.equal)
    "full checkpoint"
    (Agent_core.Checkpoint.to_json_result (accepted_checkpoint original) |> Result.get_ok)
    (Agent_core.Checkpoint.to_json_result checkpoint |> Result.get_ok)
;;

let poison_checkpoint_context (checkpoint : Agent_core.Checkpoint.t) =
  Agent_core.Context.set checkpoint.context "non_finite" (`Float Float.nan);
  Agent_core.Context.set
    checkpoint.context
    "duplicate"
    (`Assoc [ "same", `Int 1; "same", `Int 2 ])
;;

let test_async_recipe_checkpoint_snapshot_is_immutable () =
  let origin = Recipe.Skill_composition (recipe_skill_reference ()) in
  let source_checkpoint = recipe_checkpoint () in
  let recipe = recipe_with_origin_and_checkpoint origin source_checkpoint in
  let accepted_json = encode_recipe recipe in
  let accepted_bytes = Yojson.Safe.to_string accepted_json in
  let check_bytes label candidate =
    check string label accepted_bytes (encode_recipe candidate |> Yojson.Safe.to_string)
  in
  poison_checkpoint_context source_checkpoint;
  check_bytes "source checkpoint mutation" recipe;
  let exposed_checkpoint = accepted_checkpoint recipe in
  poison_checkpoint_context exposed_checkpoint;
  let fresh_checkpoint = accepted_checkpoint recipe in
  List.iter
    (fun key ->
       check bool
         ("fresh accessor excludes mutation " ^ key)
         true
         (Agent_core.Context.get fresh_checkpoint.context key |> Option.is_none))
    [ "non_finite"; "duplicate" ];
  check_bytes "decoded accessor mutation" recipe;
  let loaded = decode_recipe accepted_json |> Result.get_ok in
  let loaded_checkpoint = accepted_checkpoint loaded in
  poison_checkpoint_context loaded_checkpoint;
  check_bytes "loaded checkpoint mutation" loaded
;;

let test_async_recipe_rejects_an_unbound_plan () =
  let input =
    Plan.Json_template.object_ [ "query", Plan.Json_template.param ~name:"query" ]
    |> Result.get_ok
  in
  let plan =
    Plan.create
      ~descriptors:(descriptors ())
      [ Plan.node
          ~id:(node_id "memory")
          ~tool_name:"keeper_memory_search"
          ~input
          ()
      ]
    |> Result.get_ok
  in
  match
    Recipe.create
      ~composition_run_id:(Plan.Composition_run_id.fresh ())
      ~origin:(Recipe.Skill_composition (recipe_skill_reference ()))
      ~accepted_surface_digest:(accepted_surface_digest ())
      ~plan
      ~invocation:(recipe_invocation ())
      ~accepted_checkpoint:(recipe_checkpoint ())
  with
  | Error (Recipe.Unbound_plan (Request.Unsubstituted_param { name = "query" })) -> ()
  | Error (Recipe.Unbound_plan (Request.Unsubstituted_param { name })) ->
    failf "recipe rejected the wrong parameter %S" name
  | Error (Recipe.Create_negative_invocation_turn _) ->
    fail "unbound plan returned an invocation turn error"
  | Error (Recipe.Create_invalid_invocation_schedule _) ->
    fail "unbound plan returned a schedule error"
  | Error (Recipe.Create_invalid_checkpoint _) ->
    fail "unbound plan returned a checkpoint error"
  | Error (Recipe.Create_non_canonical_json _) ->
    fail "unbound plan returned a canonical JSON error"
  | Ok _ -> fail "recipe admitted an unbound plan"
;;

let add_field name value = function
  | `Assoc fields -> `Assoc (fields @ [ name, value ])
  | json -> json
;;

let update_field name update = function
  | `Assoc fields ->
    `Assoc
      (List.map
         (fun (field, value) ->
            if String.equal field name then field, update value else field, value)
         fields)
  | json -> json
;;

let test_async_recipe_decoder_closes_every_owned_object () =
  let base = encoded_recipe (Recipe.Skill_composition (recipe_skill_reference ())) in
  let cases =
    [ ( "duplicate recipe field"
      , add_field "origin" `Null base
      , Recipe.Duplicate_field { object_name = Recipe.Recipe; field = "origin" } )
    ; ( "unknown recipe field"
      , add_field "execution" (`String "async") base
      , Recipe.Unknown_field { object_name = Recipe.Recipe; field = "execution" } )
    ; ( "duplicate origin field"
      , update_field "origin" (add_field "kind" (`String "skill_composition")) base
      , Recipe.Duplicate_field { object_name = Recipe.Origin; field = "kind" } )
    ; ( "unknown origin field"
      , update_field "origin" (add_field "provenance" `Null) base
      , Recipe.Unknown_field { object_name = Recipe.Origin; field = "provenance" } )
    ; ( "duplicate invocation field"
      , update_field "invocation" (add_field "turn" (`Int 10)) base
      , Recipe.Duplicate_field { object_name = Recipe.Invocation; field = "turn" } )
    ; ( "unknown invocation field"
      , update_field "invocation" (add_field "tool_name" (`String "derived")) base
      , Recipe.Unknown_field { object_name = Recipe.Invocation; field = "tool_name" } )
    ]
  in
  List.iter
    (fun (label, json, expected) ->
       match decode_recipe json with
       | Error actual when actual = expected -> ()
       | Error _ -> failf "%s returned the wrong typed error" label
       | Ok _ -> failf "%s was accepted" label)
    cases
;;

let update_recipe_schedule update =
  update_field "invocation" (update_field "schedule" update)
;;

let replace_field name value = update_field name (fun _ -> value)

let recipe_plan_with_literal value =
  Plan.create
    ~descriptors:(descriptors ())
    [ Plan.node
        ~id:(node_id "clock")
        ~tool_name:"keeper_time_now"
        ~input:(Plan.Json_template.literal value)
        ()
    ]
  |> Result.get_ok
;;

let create_recipe_with_plan plan =
  Recipe.create
    ~composition_run_id:(Plan.Composition_run_id.fresh ())
    ~origin:(Recipe.Skill_composition (recipe_skill_reference ()))
    ~accepted_surface_digest:(accepted_surface_digest ())
    ~plan
    ~invocation:(recipe_invocation ())
    ~accepted_checkpoint:(recipe_checkpoint ())
;;

let replace_recipe_literal value =
  update_field
    "plan"
    (update_field "nodes" (function
       | `List [ node ] ->
         `List [ update_field "input" (replace_field "value" value) node ]
       | json -> json))
;;

let test_async_recipe_rejects_duplicate_literal_keys_on_create_and_load () =
  let duplicate = `Assoc [ "same", `Int 1; "same", `Int 2 ] in
  let plan = recipe_plan_with_literal duplicate in
  (match create_recipe_with_plan plan with
   | Error
       (Recipe.Create_non_canonical_json
          (Recipe.Duplicate_object_key "same")) -> ()
   | Error _ -> fail "duplicate literal key returned the wrong create error"
   | Ok _ -> fail "create accepted a duplicate literal key");
  let encoded =
    encoded_recipe (Recipe.Skill_composition (recipe_skill_reference ()))
    |> replace_recipe_literal duplicate
  in
  match decode_recipe encoded with
  | Error (Recipe.Non_canonical_json (Recipe.Duplicate_object_key "same")) -> ()
  | Error _ -> fail "duplicate literal key returned the wrong load error"
  | Ok _ -> fail "load accepted a duplicate literal key"
;;

let test_async_recipe_rejects_non_finite_literals_on_create_and_load () =
  List.iter
    (fun (label, value) ->
       let plan = recipe_plan_with_literal (`Float value) in
       (match create_recipe_with_plan plan with
        | Error
            (Recipe.Create_non_canonical_json Recipe.Non_finite_float) -> ()
        | Error _ -> failf "%s returned the wrong create error" label
        | Ok _ -> failf "create accepted %s" label);
       let encoded =
         encoded_recipe (Recipe.Skill_composition (recipe_skill_reference ()))
         |> replace_recipe_literal (`Float value)
       in
       match decode_recipe encoded with
       | Error (Recipe.Non_canonical_json Recipe.Non_finite_float) -> ()
       | Error _ -> failf "%s returned the wrong load error" label
       | Ok _ -> failf "load accepted %s" label)
    [ "NaN", Float.nan
    ; "positive infinity", Float.infinity
    ; "negative infinity", Float.neg_infinity
    ]
;;

let test_async_recipe_uses_canonical_invocation_schedule_validation () =
  let base = encoded_recipe (Recipe.Skill_composition (recipe_skill_reference ())) in
  let invalid_schedules =
    [ "negative planned index", replace_field "planned_index" (`Int (-1))
    ; "negative batch index", replace_field "batch_index" (`Int (-1))
    ; "negative batch size", replace_field "batch_size" (`Int (-1))
    ; "zero batch size", replace_field "batch_size" (`Int 0)
    ; "duplicate schedule field", add_field "batch_size" (`Int 3)
    ; "unknown schedule field", add_field "execution" (`String "derived")
    ]
  in
  List.iter
    (fun (label, update) ->
       match decode_recipe (update_recipe_schedule update base) with
       | Error (Recipe.Invalid_schedule _) -> ()
       | Error _ -> failf "%s returned the wrong typed error" label
       | Ok _ -> failf "%s was accepted" label)
    invalid_schedules;
  let negative_turn =
    update_field "invocation" (replace_field "turn" (`Int (-1))) base
  in
  (match decode_recipe negative_turn with
   | Error (Recipe.Negative_invocation_turn (-1)) -> ()
   | Error _ -> fail "negative turn returned the wrong typed error"
   | Ok _ -> fail "negative invocation turn was accepted");
  let terminal_completion =
    Agent_core.Tool_contract.completion_to_yojson
      (Agent_core.Tool_contract.Terminal_after_success
         Agent_core.Tool_contract.Proven_post_effect)
  in
  let invalid_terminal =
    update_field
      "invocation"
      (replace_field "completion" terminal_completion)
      base
  in
  match decode_recipe invalid_terminal with
  | Error (Recipe.Invalid_completion_schedule _) -> ()
  | Error _ -> fail "invalid terminal schedule returned the wrong typed error"
  | Ok _ -> fail "terminal completion with a concurrent batch was accepted"
;;

let create_recipe_with_invocation invocation =
  Recipe.create
    ~composition_run_id:(Plan.Composition_run_id.fresh ())
    ~origin:(Recipe.Skill_composition (recipe_skill_reference ()))
    ~accepted_surface_digest:(accepted_surface_digest ())
    ~plan:(recipe_plan ())
    ~invocation
    ~accepted_checkpoint:(recipe_checkpoint ())
;;

let test_async_recipe_constructor_validates_invocation () =
  let schedule = Agent_core.Tool_contract.Invocation.schedule (recipe_invocation ()) in
  let negative_turn =
    Agent_core.Tool_contract.Invocation.create
      ~tool_use_id:"negative-turn"
      ~turn:(-1)
      ~schedule
      ~completion:Agent_core.Tool_contract.Continue_after_success
  in
  (match create_recipe_with_invocation negative_turn with
   | Error (Recipe.Create_negative_invocation_turn (-1)) -> ()
   | Error _ -> fail "constructor returned the wrong negative-turn error"
   | Ok _ -> fail "constructor accepted a negative invocation turn");
  let invalid_terminal =
    Agent_core.Tool_contract.Invocation.create
      ~tool_use_id:"invalid-terminal"
      ~turn:1
      ~schedule
      ~completion:
        (Agent_core.Tool_contract.Terminal_after_success
           Agent_core.Tool_contract.Proven_pre_effect)
  in
  match create_recipe_with_invocation invalid_terminal with
  | Error (Recipe.Create_invalid_invocation_schedule _) -> ()
  | Error _ -> fail "constructor returned the wrong terminal-schedule error"
  | Ok _ -> fail "constructor accepted an invalid terminal schedule"
;;

let test_async_recipe_surface_digest_is_typed_but_observational () =
  let digest = accepted_surface_digest () in
  check string
    "typed digest round-trip"
    accepted_surface_digest_string
    (Recipe.Accepted_surface_digest.to_string digest);
  List.iter
    (fun invalid ->
       match Recipe.Accepted_surface_digest.of_string invalid with
       | Error Recipe.Accepted_surface_digest.Not_lowercase_sha256 -> ()
       | Ok _ -> failf "invalid accepted surface digest was constructed: %S" invalid)
    [ ""; String.make 63 'a'; String.make 64 'A'; String.make 64 'z' ];
  let base = encoded_recipe (Recipe.Skill_composition (recipe_skill_reference ())) in
  List.iter
    (fun invalid ->
       let json = replace_field "accepted_surface_digest" (`String invalid) base in
       match decode_recipe json with
       | Error (Recipe.Invalid_accepted_surface_digest value)
         when String.equal value invalid -> ()
       | Error _ -> failf "digest %S returned the wrong typed error" invalid
       | Ok _ -> failf "digest %S was decoded" invalid)
    [ ""; String.make 64 'A' ]
;;

let test_async_recipe_delegates_nested_strict_decoders () =
  let base = encoded_recipe (Recipe.Skill_composition (recipe_skill_reference ())) in
  let completion_unknown =
    update_field
      "invocation"
      (update_field "completion" (add_field "execution" (`String "derived")))
      base
  in
  (match decode_recipe completion_unknown with
   | Error (Recipe.Invalid_completion _) -> ()
   | Error _ -> fail "completion returned the wrong typed error"
   | Ok _ -> fail "completion accepted an unknown field");
  let checkpoint_unknown =
    update_field
      "accepted_checkpoint"
      (add_field "execution" (`String "derived"))
      base
  in
  (match decode_recipe checkpoint_unknown with
   | Error (Recipe.Invalid_checkpoint _) -> ()
   | Error _ -> fail "checkpoint returned the wrong typed error"
   | Ok _ -> fail "checkpoint accepted an unknown field");
  let plan_unknown = update_field "plan" (add_field "execution" (`String "async")) base in
  match decode_recipe plan_unknown with
  | Error (Recipe.Invalid_plan (Request.Unknown_request_field { field = "execution" })) -> ()
  | Error _ -> fail "plan returned the wrong typed error"
  | Ok _ -> fail "plan accepted an unknown field"
;;

let test_request_defaults_missing_input_to_empty_object () =
  let json = request_of_string {|{"nodes":[{"id":"clock","tool":"keeper_time_now"}]}|} in
  match parse_request json with
  | Ok plan ->
    (match Plan.nodes plan with
     | [ clock ] ->
       (match clock.Plan.input with
        | Plan.Json_template.Literal (`Assoc []) -> ()
        | _ -> fail "missing input did not default to the empty literal object")
     | _ -> fail "expected exactly one node")
  | Error error -> failf "single node rejected: %s" (Request.error_message error)
;;

let test_request_rejects_unknown_tool () =
  let json = request_of_string {|{"nodes":[{"id":"a","tool":"no_such_tool"}]}|} in
  match parse_request json with
  | Error (Request.Plan_rejected (Plan.Unknown_tool _)) -> ()
  | Error error -> failf "wrong rejection: %s" (Request.error_message error)
  | Ok _ -> fail "unknown tool was accepted"
;;

let test_request_rejects_opaque_reference () =
  let json =
    request_of_string
      {|{"nodes":[
          {"id":"status","tool":"keeper_context_status"},
          {"id":"reader","tool":"keeper_memory_search","after":["status"],
           "input":{"kind":"object","fields":[
             {"name":"query",
              "value":{"kind":"output","node":"status","pointer":"/anything"}}]}}]}|}
  in
  match parse_request json with
  | Error (Request.Plan_rejected (Plan.Opaque_output_reference _)) -> ()
  | Error error -> failf "wrong rejection: %s" (Request.error_message error)
  | Ok _ -> fail "opaque output reference was accepted"
;;

(* An off-surface name is spelled correctly and owned by a real descriptor, so
   it must not be reported as unknown: the author needs to be told the operator
   entrypoint or the projecting descriptor, not sent hunting for a typo.
   masc_tool_help is Operator_only since #29681. *)
let test_request_rejects_off_surface_tool () =
  let json = request_of_string {|{"nodes":[{"id":"help","tool":"masc_tool_help"}]}|} in
  match parse_request json with
  | Error
      ((Request.Plan_rejected
          (Plan.Tool_off_keeper_surface
            { tool_name = "masc_tool_help"; reason = Plan.Operator_only_tool; _ })) as
        error) ->
    let projection = Request.error_to_json error in
    let open Yojson.Safe.Util in
    check string
      "request error kind"
      "plan_rejected"
      (projection |> member "kind" |> to_string);
    check string
      "typed plan error kind"
      "tool_off_keeper_surface"
      (projection |> member "error" |> member "kind" |> to_string);
    check string
      "typed off-surface reason"
      "operator_only"
      (projection
       |> member "error"
       |> member "reason"
       |> member "kind"
       |> to_string)
  | Error error -> failf "wrong rejection: %s" (Request.error_message error)
  | Ok _ -> fail "off-surface tool was accepted"
;;

(* A transport alias names the descriptor that projects it, so the rejection can
   point at the tool the model actually has. *)
let test_request_names_the_projecting_tool_for_an_alias () =
  let json =
    request_of_string {|{"nodes":[{"id":"move","tool":"masc_transition"}]}|}
  in
  match parse_request json with
  | Error
      (Request.Plan_rejected
         (Plan.Tool_off_keeper_surface
            { tool_name = "masc_transition"
            ; reason = Plan.Aliased_by { projected_by = "keeper_task_claim" }
            ; _
            })) -> ()
  | Error error -> failf "wrong rejection: %s" (Request.error_message error)
  | Ok _ -> fail "transport alias was accepted"
;;

let test_request_rejects_dependency_cycle () =
  let json =
    request_of_string
      {|{"nodes":[
          {"id":"a","tool":"keeper_time_now","after":["b"]},
          {"id":"b","tool":"keeper_time_now","after":["a"]}]}|}
  in
  match parse_request json with
  | Error (Request.Plan_rejected (Plan.Dependency_cycle _)) -> ()
  | Error error -> failf "wrong rejection: %s" (Request.error_message error)
  | Ok _ -> fail "dependency cycle was accepted"
;;

let test_request_rejects_missing_dependency () =
  let json =
    request_of_string
      {|{"nodes":[{"id":"a","tool":"keeper_time_now","after":["ghost"]}]}|}
  in
  match parse_request json with
  | Error (Request.Plan_rejected (Plan.Missing_dependency _)) -> ()
  | Error error -> failf "wrong rejection: %s" (Request.error_message error)
  | Ok _ -> fail "missing dependency was accepted"
;;

let test_request_rejects_malformed_template () =
  let json =
    request_of_string
      {|{"nodes":[{"id":"a","tool":"keeper_time_now",
                   "input":{"kind":"teleport"}}]}|}
  in
  match parse_request json with
  | Error (Request.Node_template_error { error = Request.Template_unknown_kind _; _ })
    -> ()
  | Error error -> failf "wrong rejection: %s" (Request.error_message error)
  | Ok _ -> fail "unknown template kind was accepted"
;;

let test_request_rejects_unknown_request_field () =
  let json = request_of_string {|{"nodes":[],"mode":"fast"}|} in
  match parse_request json with
  | Error (Request.Unknown_request_field { field = "mode" }) -> ()
  | Error error -> failf "wrong rejection: %s" (Request.error_message error)
  | Ok _ -> fail "unknown request field was accepted"
;;

let test_request_rejects_empty_plan () =
  let json = request_of_string {|{"nodes":[]}|} in
  match parse_request json with
  | Error (Request.Plan_rejected Plan.Empty_plan) -> ()
  | Error error -> failf "wrong rejection: %s" (Request.error_message error)
  | Ok _ -> fail "empty plan was accepted"
;;

let test_request_composable_names_match_registry () =
  let names =
    Request.composable_tool_names ~descriptors:(Descriptor.all_descriptors ())
  in
  check bool "keeper_time_now is composable" true (List.mem "keeper_time_now" names);
  (* #29681 took masc_tool_help off the model surface, so it is now absent for
     a second reason and no longer tells opaque from unreachable.
     keeper_context_status is on the surface and its output is opaque. *)
  check bool "keeper_context_status stays opaque" false
    (List.mem "keeper_context_status" names)
;;

let test_plan_error_json_covers_closed_sum () =
  let json = testable Yojson.Safe.pp Yojson.Safe.equal in
  let a = node_id "a" in
  let b = node_id "b" in
  let rows =
    [ Plan.Empty_plan, "empty_plan", None
    ; Plan.Unknown_descriptor_id "descriptor", "unknown_descriptor_id", None
    ; Plan.Duplicate_node_id a, "duplicate_node_id", None
    ; Plan.Duplicate_tool_name "tool", "duplicate_tool_name", None
    ; Plan.Unknown_tool { node_id = a; tool_name = "tool" }, "unknown_tool", None
    ; ( Plan.Tool_off_keeper_surface
          { node_id = a; tool_name = "tool"; reason = Plan.Operator_only_tool }
      , "tool_off_keeper_surface"
      , Some "operator_only" )
    ; ( Plan.Tool_off_keeper_surface
          { node_id = a
          ; tool_name = "tool"
          ; reason = Plan.Aliased_by { projected_by = "public-tool" }
          }
      , "tool_off_keeper_surface"
      , Some "aliased_by" )
    ; ( Plan.Tool_off_keeper_surface
          { node_id = a; tool_name = "tool"; reason = Plan.Unresolved_schema }
      , "tool_off_keeper_surface"
      , Some "unresolved_schema" )
    ; Plan.Missing_dependency { node_id = a; dependency = b }, "missing_dependency", None
    ; ( Plan.Opaque_output_reference
          { node_id = b; source_node_id = a; source_tool_name = "source" }
      , "opaque_output_reference"
      , None )
    ; ( Plan.Invalid_output_pointer
          { node_id = b
          ; source_node_id = a
          ; pointer = pointer "/value"
          ; error = Plan.Json_pointer.Missing_properties "value"
          }
      , "invalid_output_pointer"
      , None )
    ; ( Plan.Invalid_output_schema
          { node_id = a
          ; tool_name = "tool"
          ; error = Plan.Missing_schema_type { path = [ "output" ] }
          }
      , "invalid_output_schema"
      , None )
    ; Plan.Multiple_terminal_nodes [ a; b ], "multiple_terminal_nodes", None
    ; ( Plan.Terminal_node_missing_dependency
          { terminal_node_id = b; node_id = a }
      , "terminal_node_missing_dependency"
      , None )
    ; Plan.Dependency_cycle [ a; b ], "dependency_cycle", None
    ]
  in
  check int "closed error rows" 15 (List.length rows);
  List.iter
    (fun (error, expected_kind, expected_reason) ->
       let json = Plan.error_to_json error in
       let open Yojson.Safe.Util in
       check string "error kind" expected_kind (json |> member "kind" |> to_string);
       match expected_reason with
       | None -> ()
       | Some expected ->
         check string
           "off-surface reason"
           expected
           (json |> member "reason" |> member "kind" |> to_string))
    rows;
  let pointer_errors =
    [ ( Plan.Json_pointer.Missing_properties "value"
      , `Assoc
          [ "kind", `String "missing_properties"
          ; "property", `String "value"
          ] )
    ; ( Plan.Json_pointer.Missing_property_schema "value"
      , `Assoc
          [ "kind", `String "missing_property_schema"
          ; "property", `String "value"
          ] )
    ; ( Plan.Json_pointer.Ambiguous_property_schema "value"
      , `Assoc
          [ "kind", `String "ambiguous_property_schema"
          ; "property", `String "value"
          ] )
    ; ( Plan.Json_pointer.Missing_items_schema "0"
      , `Assoc
          [ "kind", `String "missing_items_schema"; "segment", `String "0" ] )
    ; ( Plan.Json_pointer.Expected_schema_container "value"
      , `Assoc
          [ "kind", `String "expected_schema_container"
          ; "segment", `String "value"
          ] )
    ]
  in
  check int "closed pointer schema error rows" 5 (List.length pointer_errors);
  List.iter
    (fun (error, expected_error) ->
       let encoded =
         Plan.error_to_json
           (Plan.Invalid_output_pointer
              { node_id = b
              ; source_node_id = a
              ; pointer = pointer "/a~1b/~0key"
              ; error
              })
       in
       let open Yojson.Safe.Util in
       check string
         "canonical pointer wire"
         "/a~1b/~0key"
         (encoded |> member "pointer" |> to_string);
       check
         (list string)
         "decoded pointer segments"
         [ "a/b"; "~key" ]
         (encoded |> member "pointer_segments" |> to_list |> List.map to_string);
       check json
         "pointer schema error payload"
         expected_error
         (encoded |> member "error"))
    pointer_errors;
  let path = [ "properties"; "value" ] in
  let json_path = `List [ `String "properties"; `String "value" ] in
  let schema_errors =
    [ ( Plan.Expected_schema_object { path; schema = `Null }
      , `Assoc
          [ "kind", `String "expected_schema_object"
          ; "path", json_path
          ; "schema", `Null
          ] )
    ; ( Plan.Duplicate_schema_keyword { path; keyword = "type" }
      , `Assoc
          [ "kind", `String "duplicate_schema_keyword"
          ; "path", json_path
          ; "keyword", `String "type"
          ] )
    ; ( Plan.Missing_schema_type { path }
      , `Assoc [ "kind", `String "missing_schema_type"; "path", json_path ] )
    ; ( Plan.Unsupported_contract_type { path; value = `String "tuple" }
      , `Assoc
          [ "kind", `String "unsupported_contract_type"
          ; "path", json_path
          ; "value", `String "tuple"
          ] )
    ; ( Plan.Unsupported_schema_keyword { path; keyword = "oneOf" }
      , `Assoc
          [ "kind", `String "unsupported_schema_keyword"
          ; "path", json_path
          ; "keyword", `String "oneOf"
          ] )
    ; ( Plan.Invalid_schema_keyword_value
          { path; keyword = "required"; value = `Null }
      , `Assoc
          [ "kind", `String "invalid_schema_keyword_value"
          ; "path", json_path
          ; "keyword", `String "required"
          ; "value", `Null
          ] )
    ; ( Plan.Duplicate_required_field { path; field = "value" }
      , `Assoc
          [ "kind", `String "duplicate_required_field"
          ; "path", json_path
          ; "field", `String "value"
          ] )
    ; ( Plan.Unknown_required_property { path; field = "value" }
      , `Assoc
          [ "kind", `String "unknown_required_property"
          ; "path", json_path
          ; "field", `String "value"
          ] )
    ]
  in
  check int "closed schema contract error rows" 8 (List.length schema_errors);
  List.iter
    (fun (error, expected_error) ->
       let encoded =
         Plan.error_to_json
           (Plan.Invalid_output_schema
              { node_id = a; tool_name = "tool"; error })
       in
       check json
         "schema contract error payload"
         expected_error
         Yojson.Safe.Util.(encoded |> member "error"))
    schema_errors
;;

let () =
  Eio_main.run @@ fun _env ->
  run
    "keeper_tool_plan"
    [ ( "descriptor-contract"
      , [ test_case "round-trip" `Quick test_descriptor_contract_round_trips
        ; test_case
            "unchanged revalidation"
            `Quick
            test_descriptor_contract_revalidates_unchanged_descriptor
        ; test_case
            "removed descriptor drift"
            `Quick
            test_descriptor_contract_rejects_removed_descriptor
        ; test_case
            "accepted tool name drift"
            `Quick
            test_descriptor_contract_rejects_name_drift
        ; test_case
            "input schema drift"
            `Quick
            test_descriptor_contract_rejects_input_schema_drift
        ; test_case
            "composable output drift"
            `Quick
            test_descriptor_contract_rejects_output_drift
        ; test_case
            "execution drift"
            `Quick
            test_descriptor_contract_rejects_execution_drift
        ; test_case
            "impossible projection and name"
            `Quick
            test_descriptor_contract_rejects_impossible_projection_and_name
        ; test_case
            "invalid input schema"
            `Quick
            test_descriptor_contract_rejects_invalid_input_schema
        ; test_case
            "non-canonical output schema"
            `Quick
            test_descriptor_contract_rejects_noncanonical_output_schema
        ; test_case "closed codec" `Quick test_descriptor_contract_codec_is_closed
        ] )
    ; ( "request"
      , [ test_case "reference chain" `Quick test_request_parses_reference_chain
        ; test_case
            "JSON and TOML plan parity"
            `Quick
            test_request_and_toml_share_plan_grammar
        ; test_case
            "JSON and TOML invalid pointer parity"
            `Quick
            test_request_and_toml_reject_the_same_invalid_pointer
        ; test_case
            "closed durable request encoding"
            `Quick
            test_validated_plan_has_a_closed_durable_request_encoding
        ; test_case
            "durable encoding rejects parameters"
            `Quick
            test_durable_request_encoding_rejects_unsubstituted_params
        ; test_case
            "missing input defaults"
            `Quick
            test_request_defaults_missing_input_to_empty_object
        ; test_case "unknown tool" `Quick test_request_rejects_unknown_tool
        ; test_case "opaque reference" `Quick test_request_rejects_opaque_reference
        ; test_case "off-surface tool" `Quick test_request_rejects_off_surface_tool
        ; test_case
            "off-surface alias names its projector"
            `Quick
            test_request_names_the_projecting_tool_for_an_alias
        ; test_case "dependency cycle" `Quick test_request_rejects_dependency_cycle
        ; test_case "missing dependency" `Quick test_request_rejects_missing_dependency
        ; test_case "malformed template" `Quick test_request_rejects_malformed_template
        ; test_case
            "unknown request field"
            `Quick
            test_request_rejects_unknown_request_field
        ; test_case "empty plan" `Quick test_request_rejects_empty_plan
        ; test_case
            "composable names"
            `Quick
            test_request_composable_names_match_registry
        ] )
    ; ( "async-recipe"
      , [ test_case
            "full accepted values round-trip"
            `Quick
            test_async_recipe_round_trips_full_accepted_values
        ; test_case
            "accepted checkpoint snapshot is immutable"
            `Quick
            test_async_recipe_checkpoint_snapshot_is_immutable
        ; test_case
            "unbound plans are rejected"
            `Quick
            test_async_recipe_rejects_an_unbound_plan
        ; test_case
            "owned objects reject duplicate and unknown fields"
            `Quick
            test_async_recipe_decoder_closes_every_owned_object
        ; test_case
            "canonical invocation schedule validation"
            `Quick
            test_async_recipe_uses_canonical_invocation_schedule_validation
        ; test_case
            "constructor validates invocation"
            `Quick
            test_async_recipe_constructor_validates_invocation
        ; test_case
            "surface digest is typed but observational"
            `Quick
            test_async_recipe_surface_digest_is_typed_but_observational
        ; test_case
            "nested strict decoders remain authoritative"
            `Quick
            test_async_recipe_delegates_nested_strict_decoders
        ; test_case
            "duplicate literal keys fail on create and load"
            `Quick
            test_async_recipe_rejects_duplicate_literal_keys_on_create_and_load
        ; test_case
            "non-finite literals fail on create and load"
            `Quick
            test_async_recipe_rejects_non_finite_literals_on_create_and_load
        ] )
    ; ( "typed-values"
      , [ test_case "node id" `Quick test_node_id_rejects_empty
        ; test_case "composition run UUID" `Quick test_composition_run_id_is_uuid_v7_identity
        ; test_case "JSON pointer" `Quick test_json_pointer_is_exact_rfc6901_navigation
        ; test_case "JSON template" `Quick test_json_template_preserves_declared_structure
        ; test_case "plan error JSON sum" `Quick test_plan_error_json_covers_closed_sum
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
            "keeper_tasks_list output schema admits the page cursor"
            `Quick
            test_tasks_list_output_schema_admits_the_page_cursor
        ; test_case
            "invalid graphs and output edges"
            `Quick
            test_plan_rejects_invalid_graphs_and_output_edges
        ; test_case
            "closed composable output registry"
            `Quick
            test_composable_output_registry_is_closed
        ; test_case
            "declared schemas satisfy the contract"
            `Quick
            test_declared_output_schemas_satisfy_the_contract
        ; test_case
            "declared schemas admit producer shapes"
            `Quick
            test_new_declared_output_schemas_admit_producer_shapes
        ; test_case
            "unsupported output schema keywords"
            `Quick
            test_plan_rejects_unsupported_output_schema_keywords
        ; test_case
            "terminal dependency boundary"
            `Quick
            test_terminal_node_is_unique_and_depends_on_every_prior_node
        ; test_case
            "canonical descriptor authority"
            `Quick
            test_plan_uses_process_owned_descriptor_authority
        ] )
    ]
;;
