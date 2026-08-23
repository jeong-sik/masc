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
         | [] | _ :: _ :: _ -> fail "JSON output descriptor lacks one model name"))
    |> List.sort String.compare
  in
  check
    (list string)
    "explicit JSON-producing tools"
    [ "Execute"
    ; "keeper_artifact_read"
    ; "keeper_tasks_list"
    ; "keeper_time_now"
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
  let task_item =
    `Assoc
      [ "id", `String "task-1"
      ; "title", `String "t"
      ; "description", `String "d"
      ; "priority", `Int 3
      ; "files", `List [ `String "lib/a.ml" ]
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
      ]
  in
  accepts
    "keeper_tasks_list"
    (`Assoc
       [ "backlog_authority", `String "primary"
       ; "degraded", `Bool false
       ; "projection", `String "full"
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
       ; "kind", `String "snapshot"
       ; "revision", `String "tasks:r1"
       ; "snapshot", `List [ compact_task_item ]
       ]);
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
             ; "paused_count", `Int 0
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
       ]);