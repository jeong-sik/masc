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

let replace_descriptor replacement =
  descriptors ()
  |> List.map (fun current ->
    if String.equal current.Descriptor.id replacement.Descriptor.id
    then replacement
    else current)
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
  let seed = node ~id:"seed" ~tool_name:"keeper_lane_status" literal_object in
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
      ; "new_tasks", `List []
      ; "new_tasks_count", `Int 0
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
  let lane_id = node_id "lane" in
  let lane = node ~id:"lane" ~tool_name:"keeper_lane_status" literal_object in
  let grep_input =
    object_template
      [ ( "pattern"
        , Plan.Json_template.output ~node_id:lane_id ~pointer:(pointer "/profile") )
      ]
  in
  let grep = node ~id:"grep" ~tool_name:"Grep" grep_input in
  let plan =
    match Plan.create ~descriptors:(descriptors ()) [ lane; grep ] with
    | Ok plan -> plan
    | Error _ -> fail "valid typed output reference was rejected"
  in
  (* The docker keeper's answer from Keeper_tool_lane_status.handle. The
     dispatch runtime's composable output probe runs that producer itself. *)
  let lane_value =
    `Assoc
      [ "profile", `String "docker"
      ; "lane", `Null
      ; "endpoint", `Null
      ; "probe", `Null
      ; "last_dispatch", `Null
      ; "operator_action", `Null
      ; "note", `String "no remote lane"
      ]
  in
  let run_id = Plan.Run_id.fresh () in
  let lane_output =
    match Plan.validate_output plan ~run_id ~node_id:lane_id lane_value with
    | Ok output -> output
    | Error _ -> fail "keeper_lane_status carrier violated its descriptor schema"
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
  let lookup id = if Plan.Node_id.equal id lane_id then Some lane_output else None in
  (match Plan.resolve_input plan ~run_id ~node_id:(node_id "grep") ~lookup with
   | Ok (`Assoc [ ("pattern", `String _) ]) -> ()
   | Ok value -> failf "resolved input changed shape: %s" (Yojson.Safe.to_string value)
   | Error _ -> fail "resolved Grep input failed its descriptor schema");
  (match
     Plan.validate_output
       plan
       ~run_id
       ~node_id:lane_id
       (`Assoc
          [ "profile", `Int 1
          ; "lane", `Int 2
          ; "endpoint", `Null
          ; "operator_action", `Null
          ])
   with
   | Error (Plan.Output_validation_failed { node_id; _ })
     when Plan.Node_id.equal node_id lane_id -> ()
   | Error _ | Ok _ -> fail "invalid producer output was accepted");
  (match
     Plan.validate_output
       plan
       ~run_id
       ~node_id:lane_id
       (`Assoc
          [ "profile", `String "docker"
          ; "lane", `Null
          ; "endpoint", `Null
          ; "operator_action", `Null
          ; "_unexpected", `Bool true
          ])
   with
   | Error (Plan.Output_validation_failed { error = Plan.Unexpected_field _; _ }) -> ()
   | Error _ | Ok _ -> fail "producer output normalization hid an unexpected field");
  let malformed_consumer =
    node
      ~id:"malformed"
      ~tool_name:"Grep"
      ~after:[ lane_id ]
      (Plan.Json_template.literal (`Assoc []))
  in
  let malformed_plan =
    match Plan.create ~descriptors:(descriptors ()) [ lane; malformed_consumer ] with
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
     when Plan.Node_id.equal missing lane_id -> ()
   | Error _ | Ok _ -> fail "validated output crossed an execution run boundary");
  let other_plan =
    match Plan.create ~descriptors:(descriptors ()) [ lane; grep ] with
    | Ok plan -> plan
    | Error _ -> fail "equivalent second plan was rejected"
  in
  (match Plan.resolve_input other_plan ~run_id ~node_id:(node_id "grep") ~lookup with
   | Error
       (Plan.Input_template_resolution_failed
         { error = Plan.Json_template.Missing_output missing; _ })
     when Plan.Node_id.equal missing lane_id -> ()
   | Error _ | Ok _ -> fail "validated output crossed a plan boundary")
;;

let test_read_output_feeds_grep_path_input () =
  let read_id = node_id "read" in
  let read_node =
    node ~id:"read" ~tool_name:"Read"
      (object_template [ "file_path", Plan.Json_template.literal (`String "a.ml") ])
  in
  let grep_node =
    node ~id:"grep" ~tool_name:"Grep"
      (object_template
         [ "pattern", Plan.Json_template.literal (`String "probe")
         ; "path", Plan.Json_template.output ~node_id:read_id ~pointer:(pointer "/path")
         ])
  in
  let plan =
    match Plan.create ~descriptors:(descriptors ()) [ read_node; grep_node ] with
    | Ok plan -> plan
    | Error _ -> fail "Read -> Grep typed chain was rejected"
  in
  let run_id = Plan.Run_id.fresh () in
  let read_output =
    match Plan.validate_output plan ~run_id ~node_id:read_id
            (`Assoc
               [ "ok", `Bool true; "path", `String "/keeper/probe/a.ml"
               ; "bytes", `Int 4; "truncated", `Bool false; "offset", `Int 0
               ; "returned_lines", `Int 1; "content", `String "probe" ])
    with
    | Ok output -> output
    | Error _ -> fail "producer-shaped Read output violated its declared schema"
  in
  let lookup id = if Plan.Node_id.equal id read_id then Some read_output else None in
  (match Plan.resolve_input plan ~run_id ~node_id:(node_id "grep") ~lookup with
   | Ok (`Assoc fields) ->
     check string "Grep path came from Read output" "/keeper/probe/a.ml"
       Yojson.Safe.Util.(List.assoc "path" fields |> to_string)
   | Ok _ | Error _ -> fail "resolved Grep input lost the referenced path");
  let bad_pointer_node =
    node ~id:"grep-bad" ~tool_name:"Grep"
      (object_template
         [ "pattern", Plan.Json_template.literal (`String "probe")
         ; ( "path"
           , Plan.Json_template.output ~node_id:read_id
               ~pointer:(pointer "/nonexistent") )
         ])
  in
  match Plan.create ~descriptors:(descriptors ()) [ read_node; bad_pointer_node ] with
  | Error (Plan.Invalid_output_pointer _) -> ()
  | Error _ | Ok _ -> fail "unreachable Read schema pointer was accepted"
;;

let test_plan_rejects_invalid_graphs_and_output_edges () =
  let missing = node_id "missing" in
  let with_missing =
    node
      ~id:"only"
      ~tool_name:"keeper_lane_status"
      ~after:[ missing ]
      literal_object
  in
  (match Plan.create ~descriptors:(descriptors ()) [ with_missing ] with
   | Error (Plan.Missing_dependency { dependency; _ })
     when Plan.Node_id.equal dependency missing -> ()
   | Error _ | Ok _ -> fail "missing dependency was not rejected");
  let duplicate_a = node ~id:"same" ~tool_name:"keeper_lane_status" literal_object in
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
    node ~id:"typed-source" ~tool_name:"keeper_lane_status" literal_object
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
    node ~id:"a" ~tool_name:"keeper_lane_status" ~after:[ b_id ] literal_object
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
  let lane = descriptor "keeper_lane_status" in
  (match Plan.create ~descriptors:[ lane; lane ] [ duplicate_a ] with
   | Error (Plan.Duplicate_tool_name "keeper_lane_status") -> ()
   | Error _ | Ok _ -> fail "ambiguous descriptor name was not rejected");
  (match Plan.create ~descriptors:(descriptors ()) [] with
   | Error Plan.Empty_plan -> ()
  | Error _ | Ok _ -> fail "empty plan was accepted")
;;

let test_write_edit_output_schemas_are_split_by_tool () =
  (* PR #34928 review: Write and Edit shared one output schema, so a Write
     node referencing [/occurrences] passed plan-create and its consumer
     failed only after the file was already written — Write is content-only
     and never emits the patch fields. Edit owns them (and emits them on
     both lanes); the insert fields belong to no tool's reachable input and
     are advertised by none. *)
  let consumer_for ~id ~source pointer_path =
    node
      ~id
      ~tool_name:"Grep"
      (object_template
         [ "pattern", Plan.Json_template.literal (`String "probe")
         ; ( "path"
           , Plan.Json_template.output
               ~node_id:(node_id source)
               ~pointer:(pointer pointer_path) )
         ])
  in
  let write_source = node ~id:"write-src" ~tool_name:"Write" literal_object in
  (match
     Plan.create
       ~descriptors:(descriptors ())
       [ write_source; consumer_for ~id:"w-occ" ~source:"write-src" "/occurrences" ]
   with
   | Error (Plan.Invalid_output_pointer { pointer = bad; _ })
     when String.equal (Plan.Json_pointer.to_string bad) "/occurrences" -> ()
   | Error _ | Ok _ ->
     fail "Write node referencing /occurrences must not pass plan-create");
  (match
     Plan.create
       ~descriptors:(descriptors ())
       [ write_source; consumer_for ~id:"w-ins" ~source:"write-src" "/inserted" ]
   with
   | Error (Plan.Invalid_output_pointer _) -> ()
   | Error _ | Ok _ ->
     fail "Write node referencing /inserted must not pass plan-create");
  let edit_source = node ~id:"edit-src" ~tool_name:"Edit" literal_object in
  (match
     Plan.create
       ~descriptors:(descriptors ())
       [ edit_source; consumer_for ~id:"e-occ" ~source:"edit-src" "/occurrences" ]
   with
   | Ok _ -> ()
   | Error _ -> fail "Edit node referencing /occurrences must pass plan-create");
  (match
     Plan.create
       ~descriptors:(descriptors ())
       [ edit_source; consumer_for ~id:"e-rall" ~source:"edit-src" "/replace_all" ]
   with
   | Ok _ -> ()
   | Error _ -> fail "Edit node referencing /replace_all must pass plan-create");
  match
    Plan.create
      ~descriptors:(descriptors ())
      [ edit_source; consumer_for ~id:"e-ins" ~source:"edit-src" "/inserted" ]
  with
  | Error (Plan.Invalid_output_pointer _) -> ()
  | Error _ | Ok _ ->
    fail "Edit node referencing /inserted must not pass plan-create — no \
          reachable input emits it"
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

let test_nullable_lane_output_keeps_type_and_field_validation () =
  let single = node ~id:"lane" ~tool_name:"keeper_lane_status" literal_object in
  let plan =
    match Plan.create ~descriptors:(descriptors ()) [ single ] with
    | Ok plan -> plan
    | Error _ -> fail "nullable lane status schema was rejected"
  in
  let fields =
    [ "profile", `String "docker"
    ; "lane", `Null
    ; "endpoint", `Null
    ; "operator_action", `Null
    ; "probe", `Null
    ; "last_dispatch", `Null
    ]
  in
  let validate fields =
    Plan.validate_output plan ~run_id:(Plan.Run_id.fresh ())
      ~node_id:(node_id "lane") (`Assoc fields)
  in
  let accepts fields =
    match validate fields with
    | Ok _ -> ()
    | Error _ -> fail "valid nullable lane observation was rejected"
  in
  accepts fields;
  accepts
    [ "profile", `String "remote-ssh"
    ; "lane", `String "ssh"
    ; "endpoint", `String "declared"
    ; "operator_action", `String "inspect the endpoint"
    ; "probe", `Assoc [ "state", `String "not_asked" ]
    ; "last_dispatch", `Assoc [ "outcome", `String "payload_finished" ]
    ];
  List.iter
    (fun invalid ->
       match validate invalid with
       | Error (Plan.Output_validation_failed _) -> ()
       | Error _ | Ok _ -> fail "nullable schema accepted an invalid observation")
    [ ("lane", `Int 7) :: List.remove_assoc "lane" fields
    ; ("probe", `String "not-an-object") :: List.remove_assoc "probe" fields
    ; List.remove_assoc "lane" fields
    ; ("undeclared", `Null) :: fields
    ; ("lane", `Null) :: fields
    ]
;;

let test_nullable_container_references_and_contracts () =
  let leaf = `Assoc [ "type", `String "string" ] in
  let schema =
    `Assoc
      [ "type", `List [ `String "null"; `String "object" ]
      ; "properties", `Assoc
          [ "rows", `Assoc
              [ "type", `List [ `String "array"; `String "null" ]
              ; "items", `Assoc
                  [ "type", `String "object"
                  ; "properties", `Assoc [ "value", leaf ]
                  ]
              ]
          ]
      ]
  in
  (match Plan.validate_composable_schema schema with
   | Ok () -> ()
   | Error _ -> fail "nullable container contract was rejected");
  let source = node ~id:"source" ~tool_name:"keeper_lane_status" literal_object in
  let consumer path =
    node ~id:"consumer" ~tool_name:"Grep"
      (object_template
         [ "pattern", Plan.Json_template.output
             ~node_id:(node_id "source") ~pointer:(pointer path) ])
  in
  (match Plan.create ~descriptors:(descriptors ()) [ source; consumer "/probe" ] with
   | Ok _ -> ()
   | Error _ -> fail "the declared nullable observation cannot feed a consumer");
  (match Plan.create ~descriptors:(descriptors ()) [ source; consumer "/probe/state" ] with
   | Error (Plan.Invalid_output_pointer
       { error = Plan.Json_pointer.Missing_properties "state"; _ }) -> ()
   | Error _ | Ok _ -> fail "nullable traversal invented an undeclared property");
  let path = pointer "/rows/0/value" in
  (match Plan.Json_pointer.resolve path (`Assoc [ "rows", `Null ]) with
   | Error (Plan.Json_pointer.Expected_container "0") -> ()
   | Error _ | Ok _ -> fail "a null container invented a downstream value");
  List.iter
    (fun kind ->
       match Plan.validate_composable_schema (`Assoc [ "type", kind ]) with
       | Error (Plan.Unsupported_contract_type _) -> ()
       | Error _ | Ok _ -> fail "unsupported nullable type contract was accepted")
    [ `List []
    ; `List [ `String "null"; `String "null" ]
    ; `List [ `String "null"; `String "unknown" ]
    ; `List [ `String "string"; `String "number" ]
    ; `List [ `String "null"; `String "string"; `String "number" ]
    ];
  match Plan.validate_composable_schema
          (`Assoc
             [ "type", `List [ `String "object"; `String "null" ]
             ; "properties", `Assoc [ "bad", `Assoc [ "type", `String "unknown" ] ]
             ]) with
  | Error (Plan.Unsupported_contract_type _) -> ()
  | Error _ | Ok _ -> fail "nullable object hid an invalid nested schema"
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
  let canonical = descriptor "keeper_lane_status" in
  let supplied =
    { canonical with
      Descriptor.execution = Descriptor.Ordinary Descriptor.Serial
    ; input_schema = `Assoc [ "type", `String "string" ]
    ; composable_output = Descriptor.Opaque_output
    }
  in
  let lane_node = node ~id:"lane" ~tool_name:"keeper_lane_status" literal_object in
  match Plan.create ~descriptors:[ supplied ] [ lane_node ] with
  | Error _ -> fail "canonical descriptor id was not resolved"
  | Ok plan ->
    (match Plan.descriptor plan (node_id "lane") with
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
    [ "BrowserGoto"
    ; "BrowserInteract"
    ; "BrowserRead"
    ; "Edit"
    ; "Execute"
    ; "Grep"
    ; "Read"
    ; "Write"
    ; "keeper_artifact_read"
    ; "keeper_lane_status"
      (* keeper_spawn answers a start with the handle every later spawn call
         names; declared so run-and-read can hand it from start to wait. *)
    ; "keeper_spawn"
    ; "keeper_tasks_list"
      (* masc_agent_card and masc_agent_timeline left this list with #29681:
         off the model surface, so no plan can name them and a composable
         output schema had nothing to describe. *)
    ; "masc_agent_fitness"
    ; "masc_board_list"
    ; "masc_board_stats"
    ; "masc_get_metrics"
    ; "masc_goal_list"
    ; "masc_msx_screen"
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
         (* One counter per Goal_phase constructor, and the declared schema
            closes the object and requires all of them. A phase added to
            Goal_phase without its counter here reads as the producer
            emitting a shape its own schema rejects (#34976 added
            awaiting_confirmation, #34985 declared its counter). *)
       ; ( "rollup"
         , `Assoc
             [ "active_count", `Int 1
             ; "verifying_count", `Int 0
             ; "awaiting_confirmation_count", `Int 0
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
  (* PR #33019 removed requested_agent_name/resolved_agent_name aliases from
     the schema, so outputs carrying those ghost fields must be rejected. *)
  rejects
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
       ]);
  (* Host lane: [file_bytes] present, [via] absent; [next_offset] and
     [last_line_partial] co-occur on a window cut mid-line. *)
  accepts
    "Read"
    (`Assoc
       [ "ok", `Bool true
       ; "path", `String "/keeper/probe/a.ml"
       ; "bytes", `Int 12
       ; "truncated", `Bool true
       ; "offset", `Int 0
       ; "returned_lines", `Int 3
       ; "content", `String "let a = 1\n"
       ; "file_bytes", `Int 4096
       ; "next_offset", `Int 4
       ; "last_line_partial", `Bool true
       ]);
  (* Backend-routed lane: [via] present, [file_bytes] absent. *)
  accepts
    "Read"
    (`Assoc
       [ "ok", `Bool true
       ; "path", `String "/keeper/probe/a.ml"
       ; "bytes", `Int 12
       ; "truncated", `Bool true
       ; "offset", `Int 0
       ; "returned_lines", `Int 3
       ; "content", `String "let a = 1\n"
       ; "next_offset", `Int 4
       ; "via", `String "backend"
       ]);
  rejects "Read" (`Assoc [ "ok", `Bool true; "path", `String "/x" ]);
  accepts
    "Grep"
    (`Assoc
       [ "ok", `Bool true
       ; "op", `String "rg"
       ; "path", `String "/keeper/probe"
       ; "pattern", `String "probe"
       ; "via", `String "host"
       ; "status", `Assoc [ "kind", `String "exit"; "code", `Int 0 ]
       ; "matches", `List [ `String "a.ml:1:probe" ]
       ]);
  rejects
    "Grep"
    (`Assoc
       [ "ok", `Bool true; "op", `String "rg"; "path", `String "/p"
       ; "pattern", `String "p"; "via", `String "host"
       ; "status", `Assoc [ "kind", `String "exit"; "code", `Int 0 ]
       ; "matches", `List [ `Int 1 ] ]);
  accepts
    "Write"
    (`Assoc
       [ "ok", `Bool true; "path", `String "/keeper/probe/out.txt"
       ; "mode", `String "overwrite"; "bytes_written", `Int 5 ]);
  accepts
    "Edit"
    (`Assoc
       [ "ok", `Bool true; "path", `String "/keeper/probe/out.txt"
       ; "mode", `String "patch"; "replace_all", `Bool false
       ; "occurrences", `Int 1; "bytes_written", `Int 9
       ; "via", `String "remote-ssh" ]);
  rejects
    "Edit"
    (`Assoc [ "ok", `Bool true; "path", `String "/x"; "mode", `String "patch" ])
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
let parse_request json =
  Request.plan_of_json ~descriptors:(Descriptor.all_descriptors ()) json
;;

let request_of_string text = Yojson.Safe.from_string text

let test_request_parses_reference_chain () =
  let json =
    request_of_string
      {|{"nodes":[
          {"id":"lane","tool":"keeper_lane_status"},
          {"id":"memory","tool":"keeper_memory_search","after":["lane"],
           "input":{"kind":"object","fields":[
             {"name":"query",
              "value":{"kind":"output","node":"lane","pointer":"/profile"}}]}}]}|}
  in
  match parse_request json with
  | Ok plan ->
    let names =
      Plan.nodes plan |> List.map (fun node -> Plan.Node_id.to_string node.Plan.id)
    in
    check (list string) "node order preserved" [ "lane"; "memory" ] names;
    (match Plan.nodes plan with
     | [ lane; _memory ] ->
       check
         (list string)
         "lane has no dependencies"
         []
         (Plan.dependencies lane |> List.map Plan.Node_id.to_string)
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
id = "lane"
tool = "keeper_lane_status"
[compositions.nodes.input]
kind = "literal"
value = {}

[[compositions.nodes]]
id = "memory"
tool = "keeper_memory_search"
after = ["lane"]
[compositions.nodes.input]
kind = "object"
[[compositions.nodes.input.fields]]
name = "query"
[compositions.nodes.input.fields.value]
kind = "output"
node = "lane"
pointer = "/profile"
|}
;;

let test_request_and_toml_share_plan_grammar () =
  let request_plan =
    match
      parse_request
        (request_of_string
           {|{"nodes":[
               {"id":"lane","tool":"keeper_lane_status"},
               {"id":"memory","tool":"keeper_memory_search","after":["lane"],
                "input":{"kind":"object","fields":[
                  {"name":"query","value":{"kind":"output","node":"lane",
                                                "pointer":"/profile"}}]}}]}|})
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
               {"id":"lane","tool":"keeper_lane_status"},
               {"id":"memory","tool":"keeper_memory_search",
                "input":{"kind":"output","node":"lane","pointer":"profile"}}]}|})
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
id = "lane"
tool = "keeper_lane_status"
[compositions.nodes.input]
kind = "literal"
value = {}
[[compositions.nodes]]
id = "memory"
tool = "keeper_memory_search"
[compositions.nodes.input]
kind = "output"
node = "lane"
pointer = "profile"
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
          {"id":"lane","tool":"keeper_lane_status",
           "input":{"kind":"literal","value":{}}},
          {"id":"memory","tool":"keeper_memory_search","after":["lane"],
           "input":{"kind":"object","fields":[
             {"name":"query","value":{"kind":"output","node":"lane",
                                            "pointer":"/profile"}},
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

let recipe_plan () =
  match
    parse_request
      (request_of_string
         {|{"nodes":[{"id":"lane","tool":"keeper_lane_status",
              "input":{"kind":"literal","value":{}}}]}|})
  with
  | Ok plan -> plan
  | Error error -> failf "recipe plan rejected: %s" (Request.error_message error)
;;

let poison_checkpoint_context (checkpoint : Agent_core.Checkpoint.t) =
  Agent_core.Context.set checkpoint.context "non_finite" (`Float Float.nan);
  Agent_core.Context.set
    checkpoint.context
    "duplicate"
    (`Assoc [ "same", `Int 1; "same", `Int 2 ])
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

let update_recipe_schedule update =
  update_field "invocation" (update_field "schedule" update)
;;

let replace_field name value = update_field name (fun _ -> value)

let recipe_plan_with_literal value =
  Plan.create
    ~descriptors:(descriptors ())
    [ Plan.node
        ~id:(node_id "lane")
        ~tool_name:"keeper_lane_status"
        ~input:(Plan.Json_template.literal value)
        ()
    ]
  |> Result.get_ok
;;

let replace_recipe_literal value =
  update_field
    "plan"
    (update_field "nodes" (function
       | `List [ node ] ->
         `List [ update_field "input" (replace_field "value" value) node ]
       | json -> json))
;;

let test_request_defaults_missing_input_to_empty_object () =
  let json = request_of_string {|{"nodes":[{"id":"lane","tool":"keeper_lane_status"}]}|} in
  match parse_request json with
  | Ok plan ->
    (match Plan.nodes plan with
     | [ lane ] ->
       (match lane.Plan.input with
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
          {"id":"a","tool":"keeper_lane_status","after":["b"]},
          {"id":"b","tool":"keeper_lane_status","after":["a"]}]}|}
  in
  match parse_request json with
  | Error (Request.Plan_rejected (Plan.Dependency_cycle _)) -> ()
  | Error error -> failf "wrong rejection: %s" (Request.error_message error)
  | Ok _ -> fail "dependency cycle was accepted"
;;

let test_request_rejects_missing_dependency () =
  let json =
    request_of_string
      {|{"nodes":[{"id":"a","tool":"keeper_lane_status","after":["ghost"]}]}|}
  in
  match parse_request json with
  | Error (Request.Plan_rejected (Plan.Missing_dependency _)) -> ()
  | Error error -> failf "wrong rejection: %s" (Request.error_message error)
  | Ok _ -> fail "missing dependency was accepted"
;;

let test_request_rejects_malformed_template () =
  let json =
    request_of_string
      {|{"nodes":[{"id":"a","tool":"keeper_lane_status",
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
  check bool "keeper_lane_status is composable" true (List.mem "keeper_lane_status" names);
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
    [ ( "request"
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
        ; test_case "node id" `Quick test_node_id_rejects_empty
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
            "Read output feeds Grep path input"
            `Quick
            test_read_output_feeds_grep_path_input
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
            "Write and Edit output schemas are split by tool"
            `Quick
            test_write_edit_output_schemas_are_split_by_tool
        ; test_case "nullable lane output stays strict" `Quick
            test_nullable_lane_output_keeps_type_and_field_validation
        ; test_case "nullable container references and contracts" `Quick
            test_nullable_container_references_and_contracts
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
