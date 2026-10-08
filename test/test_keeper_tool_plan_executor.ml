open Alcotest

module Descriptor = Masc.Keeper_tool_descriptor
module Plan = Masc.Keeper_tool_plan
module Executor = Masc.Keeper_tool_plan_executor

let node_id value =
  match Plan.Node_id.make value with
  | Ok id -> id
  | Error Plan.Node_id.Empty -> failf "unexpected empty node id: %S" value
;;

let canonical_descriptor name =
  Descriptor.all_descriptors ()
  |> List.find_opt (fun descriptor ->
    Descriptor.keeper_model_names descriptor |> List.exists (String.equal name))
  |> function
  | Some descriptor -> descriptor
  | None -> failf "canonical descriptor is missing: %s" name
;;

let fixture () =
  let producer = canonical_descriptor "keeper_lane_status" in
  let parallel = canonical_descriptor "masc_board_stats" in
  let final = canonical_descriptor "keeper_tools_list" in
  let producer_node =
    Plan.node
      ~id:(node_id "producer")
      ~tool_name:"keeper_lane_status"
      ~input:(Plan.Json_template.literal (`Assoc []))
      ()
  in
  let left_node =
    Plan.node
      ~id:(node_id "left")
      ~tool_name:"masc_board_stats"
      ~after:[ node_id "producer" ]
      ~input:(Plan.Json_template.literal (`Assoc []))
      ()
  in
  let right_node =
    Plan.node
      ~id:(node_id "right")
      ~tool_name:"masc_board_stats"
      ~after:[ node_id "producer" ]
      ~input:(Plan.Json_template.literal (`Assoc []))
      ()
  in
  let final_node =
    Plan.node
      ~id:(node_id "final")
      ~tool_name:"keeper_tools_list"
      ~after:[ node_id "left"; node_id "right" ]
      ~input:(Plan.Json_template.literal (`Assoc []))
      ()
  in
  match
    Plan.create
      ~descriptors:[ producer; parallel; final ]
      [ producer_node; left_node; right_node; final_node ]
  with
  | Ok plan -> plan
  | Error _ -> fail "valid executor fixture plan was rejected"
;;

let completed ~tool_name ~data =
  Tool_result.make_ok ~tool_name ~start_time:(Tool_timing.start ()) ~data ()
;;

let node_name node = Plan.Node_id.to_string node.Plan.id

let valid_data_for_node node =
  match node_name node with
  | "producer" ->
    `Assoc
      [ "profile", `String "docker"
      ; "lane", `Null
      ; "endpoint", `Null
      ; "probe", `Null
      ; "last_dispatch", `Null
      ; "operator_action", `Null
      ]
  | "left" | "right" ->
    `Assoc
      [ "post_count", `Int 0
      ; "comment_count", `Int 0
      ; "expired_pending", `Int 0
      ; "last_sweep", `Float 0.0
      ; "backend", `String "test"
      ]
  | "final" -> `Assoc [ "tools", `List [] ]
  | name -> failf "unexpected fixture node: %s" name
;;

let test_schedule_and_parallel_dataflow () =
  Eio_main.run @@ fun _env ->
  let plan = fixture () in
  let batches = Executor.schedule plan in
  (match batches with
   | [ Executor.Concurrent_batch [ producer ]
     ; Executor.Concurrent_batch [ left; right ]
     ; Executor.Concurrent_batch [ final ]
     ] ->
     check int "producer batch index" 0 producer.schedule.batch_index;
     check int "parallel batch index" 1 left.schedule.batch_index;
     check int "left batch size" 2 left.schedule.batch_size;
     check int "right batch size" 2 right.schedule.batch_size;
     check int "final batch index" 2 final.schedule.batch_index;
     check bool
       "parallel execution mode"
       true
       (left.schedule.execution_mode = Agent_core.Tool_contract.Concurrent);
     check bool
       "final execution mode"
       true
       (final.schedule.execution_mode = Agent_core.Tool_contract.Concurrent)
   | _ -> fail "descriptor-aware schedule shape changed");
  let sibling_count = Atomic.make 0 in
  let observed = ref [] in
  let dispatched = ref [] in
  let execution_ids = ref [] in
  let both_started, release = Eio.Promise.create () in
  let dispatch ~tool_use_id ~node ~descriptor:_ ~schedule:_ ~input =
    let name = node_name node in
    dispatched := (name, tool_use_id) :: !dispatched;
    if String.equal name "left" || String.equal name "right"
    then (
      check string "parallel input" "{}" (Yojson.Safe.to_string input);
      if Atomic.fetch_and_add sibling_count 1 = 1 then Eio.Promise.resolve release ();
      Eio.Promise.await both_started);
    Executor.dispatch_result
      (completed ~tool_name:node.Plan.tool_name ~data:(valid_data_for_node node))
  in
  let observe_node_result result =
    execution_ids := Ids.Execution_id.to_string result.Executor.execution_id :: !execution_ids;
    observed
      := ( Plan.Node_id.to_string result.Executor.node_id
         , result.Executor.tool_use_id
         , result.Executor.schedule.planned_index )
         :: !observed;
    Ok ()
  in
  match
    Executor.execute
      ~plan
      ~run_id:(Plan.Run_id.fresh ())
      ~dispatch
      ~observe_node_result
      ()
  with
  | Error _ -> fail "valid parallel plan stopped"
  | Ok results ->
    check
      (list string)
      "settled execution order"
      [ "producer"; "left"; "right"; "final" ]
      (List.map (fun result -> Plan.Node_id.to_string result.Executor.node_id) results);
    check int "both siblings entered before either returned" 2 (Atomic.get sibling_count);
    check int "one execution id per settled node" 4 (List.length !execution_ids);
    check int
      "execution ids are unique"
      4
      (List.sort_uniq String.compare !execution_ids |> List.length);
    check
      (list (pair string string))
      "observer receives the exact pre-dispatch tool identity"
      (List.sort compare !dispatched)
      (List.map (fun (name, tool_use_id, _) -> name, tool_use_id) !observed
       |> List.sort compare);
    check int
      "tool identities are unique"
      4
      (List.map snd !dispatched |> List.sort_uniq String.compare |> List.length);
    List.iter
      (fun (_, tool_use_id) ->
         check bool
           "tool identity is non-empty"
           true
           (String.length (String.trim tool_use_id) > 0))
      !dispatched
;;

let test_failed_sibling_stops_downstream_after_batch_settlement () =
  Eio_main.run @@ fun _env ->
  let plan = fixture () in
  let called = ref [] in
  let dispatch ~tool_use_id:_ ~node ~descriptor:_ ~schedule:_ ~input:_ =
    let name = node_name node in
    called := !called @ [ name ];
    if String.equal name "left"
    then
      Executor.dispatch_result
        ~failure_effect_disposition:Tool_result.Proven_pre_effect
        (Tool_result.make_err
           ~tool_name:name
           ~class_:Tool_result.Workflow_rejection
           ~start_time:(Tool_timing.start ())
           "left rejected")
    else
      Executor.dispatch_result
        (completed ~tool_name:node.Plan.tool_name ~data:(valid_data_for_node node))
  in
  match Executor.execute ~plan ~run_id:(Plan.Run_id.fresh ()) ~dispatch () with
  | Ok _ -> fail "failed sibling did not stop the plan"
  | Error failure ->
    check
      (list string)
      "downstream was not dispatched"
      [ "left"; "producer"; "right" ]
      (List.sort String.compare !called);
    check
      (list string)
      "successful sibling remains settled"
      [ "producer"; "left"; "right" ]
      (List.map (fun result -> Plan.Node_id.to_string result.Executor.node_id) failure.settled);
    (match failure.cause with
     | Executor.Tool_did_not_complete result ->
       check string "lowest planned cause" "left" (Plan.Node_id.to_string result.node_id);
       (match result.result with
       | Tool_result.Failed { class_ = Tool_result.Workflow_rejection; _ } -> ()
        | Tool_result.Completed _ | Tool_result.Deferred _ | Tool_result.Failed _ ->
          fail "canonical failed disposition changed")
     | Executor.Plan_execution_failed _
     | Executor.Node_observation_failed _
     | Executor.Outer_completion_mismatch _ ->
       fail "tool failure became a plan error")
;;

let test_output_validation_precedes_node_observation () =
  Eio_main.run @@ fun _env ->
  let plan = fixture () in
  let called = ref [] in
  let observed = ref None in
  let dispatch ~tool_use_id:_ ~node ~descriptor:_ ~schedule:_ ~input:_ =
    called := node_name node :: !called;
    Executor.dispatch_result (completed ~tool_name:node.Plan.tool_name ~data:`Null)
  in
  let observe_node_result result = observed := Some result; Ok () in
  match Executor.execute ~plan ~run_id:(Plan.Run_id.fresh ())
          ~dispatch ~observe_node_result () with
  | Ok _ -> fail "invalid output must not complete the plan"
  | Error failure ->
    check (list string) "invalid producer stops dependent nodes" [ "producer" ] !called;
    (match !observed with
     | None -> fail "invalid-output node was not observed"
     | Some node ->
       check bool "observer sees output validation failure" true
         (Option.is_some node.Executor.output_validation_error);
       check bool "original producer completion is retained" true
         (Tool_result.is_success node.result);
       check bool "original invalid bytes are retained" true
         (Yojson.Safe.equal `Null (Tool_result.data node.result)));
    match failure.cause with
    | Executor.Plan_execution_failed { error = Plan.Output_validation_failed _; _ } -> ()
    | _ -> fail "output validation lost its typed plan failure"
;;

let test_observation_failure_settles_siblings_and_stops_downstream () =
  Eio_main.run @@ fun _env ->
  let plan = fixture () in
  let observed = ref [] in
  let dispatch ~tool_use_id:_ ~node ~descriptor:_ ~schedule:_ ~input:_ =
    Executor.dispatch_result
      (completed ~tool_name:node.Plan.tool_name ~data:(valid_data_for_node node))
  in
  let observe_node_result result =
    let name = Plan.Node_id.to_string result.Executor.node_id in
    observed := name :: !observed;
    if String.equal name "left" then Error "durable append failed" else Ok ()
  in
  match
    Executor.execute
      ~plan
      ~run_id:(Plan.Run_id.fresh ())
      ~dispatch
      ~observe_node_result
      ()
  with
  | Ok _ -> fail "observation failure did not stop the plan"
  | Error failure ->
    check
      (list string)
      "all current siblings observed before stop"
      [ "left"; "producer"; "right" ]
      (List.sort String.compare !observed);
    (match failure.cause with
     | Executor.Node_observation_failed { node; detail } ->
       check string "failed observation node" "left" (Plan.Node_id.to_string node.node_id);
       check string "exact observation error" "durable append failed" detail
     | Executor.Plan_execution_failed _
     | Executor.Tool_did_not_complete _
     | Executor.Outer_completion_mismatch _ ->
       fail "observation failure lost its typed cause")
;;

let test_dispatch_exception_preserves_pre_minted_tool_identity () =
  Eio_main.run @@ fun _env ->
  let plan = fixture () in
  let dispatched_id = ref None in
  let observed_id = ref None in
  let dispatch ~tool_use_id ~node:_ ~descriptor:_ ~schedule:_ ~input:_ =
    dispatched_id := Some tool_use_id;
    failwith "dispatch exploded before returning evidence"
  in
  let observe_node_result result =
    observed_id := Some result.Executor.tool_use_id;
    Ok ()
  in
  match
    Executor.execute
      ~plan
      ~run_id:(Plan.Run_id.fresh ())
      ~dispatch
      ~observe_node_result
      ()
  with
  | Ok _ -> fail "dispatch exception did not stop the plan"
  | Error failure ->
    check (option string) "observer keeps dispatch identity" !dispatched_id !observed_id;
    (match !observed_id with
     | Some tool_use_id ->
       check bool
         "exception identity is non-empty"
         true
         (String.length (String.trim tool_use_id) > 0)
     | None -> fail "exception settlement was not observed");
    (match failure.cause with
     | Executor.Tool_did_not_complete result ->
       check string
         "failure carries the same identity"
         (Option.get !dispatched_id)
         result.tool_use_id
     | Executor.Plan_execution_failed _
     | Executor.Node_observation_failed _
     | Executor.Outer_completion_mismatch _ ->
       fail "dispatch exception lost its settled tool result")
;;

let test_deferred_effect_evidence_is_not_invented () =
  Eio_main.run @@ fun _env ->
  List.iter (fun (evidence, expected) ->
    let plan = fixture () in
    let dispatch ~tool_use_id:_ ~node ~descriptor:_ ~schedule:_ ~input:_ =
      if String.equal (node_name node) "left" then
        let result = Tool_result.make_deferred ~tool_name:"left" ~start_time:(Tool_timing.start ()) () in
        let execution = Masc.Keeper_tool_execution.of_tool_result
            ?failure_effect_disposition:evidence result in
        Executor.dispatch_result
          ~failure_effect_disposition:execution.failure_effect_disposition
          ~deferred_kind:Masc.Keeper_tool_execution.Generic_deferred result
      else
        Executor.dispatch_result
          (completed ~tool_name:node.Plan.tool_name ~data:(valid_data_for_node node))
    in
    match Executor.execute ~plan ~run_id:(Plan.Run_id.fresh ()) ~dispatch () with
    | Ok _ -> fail "deferred node must not complete the dependent plan"
    | Error failure ->
      check string "aggregate preserves supplied effect evidence" expected
        (Tool_result.failure_effect_disposition_to_string failure.effect_disposition))
    [ None, "effect_outcome_unknown"
    ; Some Tool_result.Proven_pre_effect, "proven_pre_effect"
    ; Some Tool_result.Proven_post_effect, "proven_post_effect" ]
;;

let test_deferred_cause_does_not_mask_unknown_sibling () =
  Eio_main.run @@ fun _env ->
  let plan = fixture () in
  let dispatch ~tool_use_id:_ ~node ~descriptor:_ ~schedule:_ ~input:_ =
    match node_name node with
    | "left" ->
      Executor.dispatch_result
        ~deferred_kind:Masc.Keeper_tool_execution.Generic_deferred
        (Tool_result.make_deferred ~tool_name:"left" ~start_time:(Tool_timing.start ()) ())
    | "right" ->
      Executor.dispatch_result
        ~failure_effect_disposition:Tool_result.Effect_outcome_unknown
        (Tool_result.make_err
           ~tool_name:"right"
           ~class_:Tool_result.Runtime_failure
           ~start_time:(Tool_timing.start ())
           "right outcome unknown")
    | _ ->
      Executor.dispatch_result
        (completed ~tool_name:node.Plan.tool_name ~data:(valid_data_for_node node))
  in
  match Executor.execute ~plan ~run_id:(Plan.Run_id.fresh ()) ~dispatch () with
  | Ok _ -> fail "deferred and failed siblings did not stop the plan"
  | Error failure ->
    (match failure.cause with
     | Executor.Tool_did_not_complete result ->
       check string "lowest planned cause" "left" (Plan.Node_id.to_string result.node_id);
       (match result.result with
        | Tool_result.Deferred _ -> ()
        | Tool_result.Completed _ | Tool_result.Failed _ ->
          fail "lower-index deferred cause changed")
     | Executor.Plan_execution_failed _
     | Executor.Node_observation_failed _
     | Executor.Outer_completion_mismatch _ ->
       fail "deferred cause became a plan error");
    check string
      "unknown sibling dominates deferred cause"
      "effect_outcome_unknown"
      (Tool_result.failure_effect_disposition_to_string failure.effect_disposition)
;;

let test_malformed_declared_output_stops_before_consumer () =
  Eio_main.run @@ fun _env ->
  let plan = fixture () in
  let called = ref [] in
  let dispatch ~tool_use_id:_ ~node ~descriptor:_ ~schedule:_ ~input:_ =
    called := node_name node :: !called;
    Executor.dispatch_result
      (completed
         ~tool_name:node.tool_name
         ~data:
           (`Assoc
              [ "profile", `Int 7
              ; "lane", `Null
              ; "endpoint", `Null
              ; "operator_action", `Null
              ]))
  in
  match Executor.execute ~plan ~run_id:(Plan.Run_id.fresh ()) ~dispatch () with
  | Ok _ -> fail "malformed producer output was accepted"
  | Error failure ->
    check (list string) "only producer dispatched" [ "producer" ] (List.rev !called);
    (match failure.cause with
     | Executor.Plan_execution_failed
         { error = Plan.Output_validation_failed { node_id = failed; _ }; _ }
       when Plan.Node_id.equal failed (node_id "producer") -> ()
     | Executor.Plan_execution_failed _
     | Executor.Tool_did_not_complete _
     | Executor.Node_observation_failed _
     | Executor.Outer_completion_mismatch _ ->
       fail "malformed producer did not retain its typed validation cause")
;;

let test_typed_output_flows_to_consumer_dispatch_input () =
  Eio_main.run @@ fun _env ->
  let read_id = node_id "read" in
  let pointer value =
    match Plan.Json_pointer.of_string value with
    | Ok pointer -> pointer
    | Error _ -> failf "unexpected invalid JSON pointer: %S" value
  in
  let template fields =
    match Plan.Json_template.object_ fields with
    | Ok template -> template
    | Error (Plan.Json_template.Duplicate_field name) ->
      failf "unexpected duplicate template field: %S" name
  in
  let read_node =
    Plan.node
      ~id:read_id
      ~tool_name:"Read"
      ~input:(template [ "file_path", Plan.Json_template.literal (`String "a.ml") ])
      ()
  in
  let grep_node =
    Plan.node
      ~id:(node_id "grep")
      ~tool_name:"Grep"
      ~input:
        (template
           [ "pattern", Plan.Json_template.literal (`String "probe")
           ; ( "path"
             , Plan.Json_template.output ~node_id:read_id ~pointer:(pointer "/path") )
           ])
      ()
  in
  let plan =
    match
      Plan.create
        ~descriptors:[ canonical_descriptor "Read"; canonical_descriptor "Grep" ]
        [ read_node; grep_node ]
    with
    | Ok plan -> plan
    | Error error ->
      fail ("Read -> Grep executor plan was rejected: " ^ Plan.error_to_string error)
  in
  let captured_grep_input = ref None in
  let dispatch ~tool_use_id:_ ~node ~descriptor:_ ~schedule:_ ~input =
    match node_name node with
    | "read" ->
      Executor.dispatch_result
        (completed
           ~tool_name:"Read"
           ~data:
             (`Assoc
                [ "ok", `Bool true
                ; "path", `String "/keeper/probe/a.ml"
                ; "bytes", `Int 5
                ; "truncated", `Bool false
                ; "offset", `Int 1
                ; "returned_lines", `Int 1
                ; "content", `String "probe"
                ]))
    | "grep" ->
      captured_grep_input := Some input;
      Executor.dispatch_result
        (completed
           ~tool_name:"Grep"
           ~data:
             (`Assoc
                [ "ok", `Bool true
                ; "op", `String "rg"
                ; "path", `String "/keeper/probe/a.ml"
                ; "pattern", `String "probe"
                ; "via", `String "host"
                ; "status", `Assoc [ "kind", `String "exit"; "code", `Int 0 ]
                ; "matches", `List [ `String "a.ml:1:probe" ]
                ]))
    | name -> failf "unexpected dispatched node: %s" name
  in
  match Executor.execute ~plan ~run_id:(Plan.Run_id.fresh ()) ~dispatch () with
  | Error _ -> fail "typed Read -> Grep chain did not complete"
  | Ok _ ->
    (match !captured_grep_input with
     | Some (`Assoc fields) ->
       check
         string
         "Grep dispatch input carries Read's path"
         "/keeper/probe/a.ml"
         Yojson.Safe.Util.(List.assoc "path" fields |> to_string)
     | Some _ -> fail "Grep dispatch input lost its object shape"
     | None -> fail "Grep node was never dispatched")
;;

let test_outer_completion_owns_terminal_boundary () =
  let terminal_descriptor = canonical_descriptor "keeper_surface_post" in
  let terminal_node =
    Plan.node
      ~id:(node_id "terminal")
      ~tool_name:"keeper_surface_post"
      ~input:(Plan.Json_template.literal (`Assoc []))
      ()
  in
  let terminal_plan =
    match Plan.create ~descriptors:[ terminal_descriptor ] [ terminal_node ] with
    | Ok plan -> plan
    | Error _ -> fail "single terminal composition was rejected"
  in
  (match Executor.outer_completion terminal_plan with
   | Agent_core.Tool_contract.Terminal_after_success
       Agent_core.Tool_contract.Effect_outcome_unknown -> ()
   | Agent_core.Tool_contract.Continue_after_success
   | Agent_core.Tool_contract.Terminal_after_success _ ->
     fail "terminal boundary was not projected to the outer composition");
  match Executor.outer_completion (fixture ()) with
  | Agent_core.Tool_contract.Continue_after_success -> ()
  | Agent_core.Tool_contract.Terminal_after_success _ ->
    fail "ordinary composition became terminal"
;;

module Validation = Masc.Tool_input_validation

let object_template fields =
  match Plan.Json_template.object_ fields with
  | Ok template -> template
  | Error (Plan.Json_template.Duplicate_field name) ->
    failf "unexpected duplicate template field: %S" name
;;

let json_pointer value =
  match Plan.Json_pointer.of_string value with
  | Ok pointer -> pointer
  | Error _ -> failf "unexpected invalid JSON pointer: %S" value
;;

let never_dispatched ~tool_use_id:_ ~node ~descriptor:_ ~schedule:_ ~input:_ =
  failf "node %s ran although a later node input was invalid" (node_name node)
;;

let expect_rejected_before_any_node ~label ~node failure =
  check int (label ^ ": no node settled") 0 (List.length failure.Executor.settled);
  check string
    (label ^ ": nothing ran, so nothing took effect")
    "proven_pre_effect"
    (Tool_result.failure_effect_disposition_to_string failure.effect_disposition);
  match failure.cause with
  | Executor.Plan_execution_failed
      { node_id = failed
      ; error = Plan.Input_validation_failed { node_id = rejected; rejection; _ }
      ; _
      }
    when Plan.Node_id.equal failed (node_id node)
         && Plan.Node_id.equal rejected (node_id node) -> rejection.Validation.violation
  | Executor.Plan_execution_failed _
  | Executor.Tool_did_not_complete _
  | Executor.Node_observation_failed _
  | Executor.Outer_completion_mismatch _ ->
    failf "%s: the invalid node input lost its typed plan cause" label
;;

(* One search runs alone, then two more share the batch after it. Only the
   last node's input breaks a declared bound, and it breaks it with a literal,
   so nothing about it depends on the search before it. The plan used to run
   the first search, then fail the batch and throw its result away. *)
let test_static_input_rejection_runs_no_node () =
  Eio_main.run @@ fun _env ->
  let search ?after ~id ~tool query =
    Plan.node
      ~id:(node_id id)
      ~tool_name:tool
      ?after
      ~input:(object_template [ "query", Plan.Json_template.literal (`String query) ])
      ()
  in
  let after = [ node_id "memory" ] in
  let over_the_board_bound = String.make 201 'q' in
  let plan =
    match
      Plan.create
        ~descriptors:
          [ canonical_descriptor "keeper_memory_search"
          ; canonical_descriptor "keeper_library_search"
          ; canonical_descriptor "masc_board_search"
          ]
        [ search ~id:"memory" ~tool:"keeper_memory_search" "EACCES"
        ; search ~after ~id:"library" ~tool:"keeper_library_search" "EACCES"
        ; search ~after ~id:"board" ~tool:"masc_board_search" over_the_board_bound
        ]
    with
    | Ok plan -> plan
    | Error error -> fail ("the three-search plan was rejected: " ^ Plan.error_to_string error)
  in
  (match Executor.schedule plan with
   | [ Executor.Concurrent_batch [ memory ]; Executor.Concurrent_batch concurrent ] ->
     check string "the first search runs alone" "memory" (node_name memory.node);
     check
       (list string)
       "the searches after it share the next batch"
       [ "board"; "library" ]
       (List.map (fun (scheduled : Executor.scheduled_node) -> node_name scheduled.node)
          concurrent
        |> List.sort String.compare)
   | _ -> fail "the plan no longer schedules one search ahead of the other two");
  match
    Executor.execute ~plan ~run_id:(Plan.Run_id.fresh ()) ~dispatch:never_dispatched ()
  with
  | Ok _ -> fail "an over-long board query completed the plan"
  | Error failure ->
    (match expect_rejected_before_any_node ~label:"board bound" ~node:"board" failure with
     | Validation.Argument_out_of_range
         { path = "query"; keyword = Validation.Count_bound Validation.Max_length } -> ()
     | _ -> fail "the board query was not refused by its maxLength")
;;

(* A composition node and a top-level call go through one validator, so a
   literal outside the node tool's enum is refused like a direct call is, and
   before the node ahead of it runs. *)
let test_enum_literal_is_refused_before_any_node () =
  Eio_main.run @@ fun _env ->
  let plan =
    match
      Plan.create
        ~descriptors:
          [ canonical_descriptor "keeper_lane_status"
          ; canonical_descriptor "keeper_memory_search"
          ]
        [ Plan.node
            ~id:(node_id "lane")
            ~tool_name:"keeper_lane_status"
            ~input:(Plan.Json_template.literal (`Assoc []))
            ()
        ; Plan.node
            ~id:(node_id "search")
            ~tool_name:"keeper_memory_search"
            ~after:[ node_id "lane" ]
            ~input:
              (object_template
                 [ "query", Plan.Json_template.literal (`String "EACCES")
                 ; "source", Plan.Json_template.literal (`String "durable")
                 ])
            ()
        ]
    with
    | Ok plan -> plan
    | Error error -> fail ("enum literal plan was rejected: " ^ Plan.error_to_string error)
  in
  match
    Executor.execute ~plan ~run_id:(Plan.Run_id.fresh ()) ~dispatch:never_dispatched ()
  with
  | Ok _ -> fail "a source outside the enum completed the plan"
  | Error failure ->
    (match expect_rejected_before_any_node ~label:"enum literal" ~node:"search" failure with
     | Validation.Field_errors
         [ { Agent_core.Tool_input_validation.path = "/source"
           ; expected = Agent_core.Tool_input_validation.Expected_enum { allowed; _ }
           ; _
           }
         ] ->
       check
         (list string)
         "the refusal names the declared members"
         [ "current"; "absorbed"; "dropped"; "history"; "all" ]
         (List.map Yojson.Safe.Util.to_string allowed)
     | _ -> fail "the source literal was not refused by its enum")
;;

(* An input that reads a producer output cannot be checked before the producer
   runs. It is checked when its own node runs, with the same enum rule, after
   the producer has settled. *)
let test_output_value_outside_enum_is_refused_when_its_node_runs () =
  Eio_main.run @@ fun _env ->
  let read_id = node_id "read" in
  let plan =
    match
      Plan.create
        ~descriptors:[ canonical_descriptor "Read"; canonical_descriptor "keeper_memory_search" ]
        [ Plan.node
            ~id:read_id
            ~tool_name:"Read"
            ~input:
              (object_template [ "file_path", Plan.Json_template.literal (`String "a.ml") ])
            ()
        ; Plan.node
            ~id:(node_id "search")
            ~tool_name:"keeper_memory_search"
            ~input:
              (object_template
                 [ "query", Plan.Json_template.literal (`String "probe")
                 ; ( "source"
                   , Plan.Json_template.output ~node_id:read_id ~pointer:(json_pointer "/path") )
                 ])
            ()
        ]
    with
    | Ok plan -> plan
    | Error error -> fail ("Read -> search plan was rejected: " ^ Plan.error_to_string error)
  in
  let dispatched = ref [] in
  let dispatch ~tool_use_id:_ ~node ~descriptor:_ ~schedule:_ ~input:_ =
    dispatched := node_name node :: !dispatched;
    match node_name node with
    | "read" ->
      Executor.dispatch_result
        (completed
           ~tool_name:"Read"
           ~data:
             (`Assoc
                [ "ok", `Bool true
                ; "path", `String "/keeper/probe/a.ml"
                ; "bytes", `Int 5
                ; "truncated", `Bool false
                ; "offset", `Int 1
                ; "returned_lines", `Int 1
                ; "content", `String "probe"
                ]))
    | name -> failf "node %s ran with a source outside the enum" name
  in
  match Executor.execute ~plan ~run_id:(Plan.Run_id.fresh ()) ~dispatch () with
  | Ok _ -> fail "a path read back as a source completed the plan"
  | Error failure ->
    check (list string) "the producer ran first" [ "read" ] !dispatched;
    check
      (list string)
      "the producer stays settled"
      [ "read" ]
      (List.map (fun result -> Plan.Node_id.to_string result.Executor.node_id) failure.settled);
    (match failure.cause with
     | Executor.Plan_execution_failed
         { error =
             Plan.Input_validation_failed
               { node_id = rejected
               ; rejection =
                   { Validation.violation =
                       Validation.Field_errors
                         [ { Agent_core.Tool_input_validation.path = "/source"
                           ; expected = Agent_core.Tool_input_validation.Expected_enum _
                           ; _
                           }
                         ]
                   ; _
                   }
               ; _
               }
         ; _
         }
       when Plan.Node_id.equal rejected (node_id "search") -> ()
     | Executor.Plan_execution_failed _
     | Executor.Tool_did_not_complete _
     | Executor.Node_observation_failed _
     | Executor.Outer_completion_mismatch _ ->
       fail "the output-bound source was not refused by its enum at run time")
;;

let lane_status_data =
  `Assoc
    [ "profile", `String "docker"
    ; "lane", `Null
    ; "endpoint", `Null
    ; "probe", `Null
    ; "last_dispatch", `Null
    ; "operator_action", `Null
    ]
;;

let board_stats_data =
  `Assoc
    [ "post_count", `Int 0
    ; "comment_count", `Int 0
    ; "expired_pending", `Int 0
    ; "last_sweep", `Float 0.0
    ; "backend", `String "test"
    ]
;;

let tools_list_data = `Assoc [ "tools", `List [] ]

let make_node ~tool_name ~after ~input name =
  Plan.node ~id:(node_id name) ~tool_name ~after:(List.map node_id after) ~input ()
;;

let empty_input = Plan.Json_template.literal (`Assoc [])

(* H4-S1: c depends only on a; b is an unrelated branch held on a promise.
   The wave must start c once a settles, before b is released. *)
let ready_wave_fixture () =
  let producer = canonical_descriptor "keeper_lane_status" in
  let parallel = canonical_descriptor "masc_board_stats" in
  let final = canonical_descriptor "keeper_tools_list" in
  let nodes =
    [ make_node ~tool_name:"keeper_lane_status" ~after:[] ~input:empty_input "producer"
    ; make_node ~tool_name:"masc_board_stats" ~after:[ "producer" ] ~input:empty_input "a"
    ; make_node ~tool_name:"masc_board_stats" ~after:[ "producer" ] ~input:empty_input "b"
    ; make_node ~tool_name:"keeper_tools_list" ~after:[ "a" ] ~input:empty_input "c"
    ]
  in
  match Plan.create ~descriptors:[ producer; parallel; final ] nodes with
  | Ok plan -> plan
  | Error _ -> fail "valid ready-wave fixture plan was rejected"
;;

let test_ready_wave_starts_dependent_before_unrelated_release () =
  Eio_main.run @@ fun _env ->
  let plan = ready_wave_fixture () in
  let events = ref [] in
  let log event = events := !events @ [ event ] in
  let release_b, resolve_release_b = Eio.Promise.create () in
  let dispatch ~tool_use_id:_ ~node ~descriptor:_ ~schedule:_ ~input:_ =
    match node_name node with
    | "b" ->
      Eio.Promise.await release_b;
      log "b-done";
      Executor.dispatch_result
        (completed ~tool_name:node.Plan.tool_name ~data:board_stats_data)
    | "c" ->
      log "c-started";
      Eio.Promise.resolve resolve_release_b ();
      Executor.dispatch_result
        (completed ~tool_name:node.Plan.tool_name ~data:tools_list_data)
    | "producer" ->
      Executor.dispatch_result
        (completed ~tool_name:node.Plan.tool_name ~data:lane_status_data)
    | "a" ->
      Executor.dispatch_result
        (completed ~tool_name:node.Plan.tool_name ~data:board_stats_data)
    | name -> failf "unexpected dispatched node: %s" name
  in
  match Executor.execute ~plan ~run_id:(Plan.Run_id.fresh ()) ~dispatch () with
  | Error _ -> fail "ready-wave plan did not complete"
  | Ok results ->
    check
      (list string)
      "settled plan order"
      [ "producer"; "a"; "b"; "c" ]
      (List.map (fun result -> Plan.Node_id.to_string result.Executor.node_id) results);
    check
      (list string)
      "dependent starts before the unrelated branch is released"
      [ "c-started"; "b-done" ]
      !events
;;

(* H4-S2: under Continue_independent, a failure in b blocks only b's
   descendant d while the independent a -> c branch settles. *)
let independent_branch_fixture () =
  let producer = canonical_descriptor "keeper_lane_status" in
  let parallel = canonical_descriptor "masc_board_stats" in
  let final = canonical_descriptor "keeper_tools_list" in
  let nodes =
    [ make_node ~tool_name:"keeper_lane_status" ~after:[] ~input:empty_input "producer"
    ; make_node ~tool_name:"masc_board_stats" ~after:[ "producer" ] ~input:empty_input "a"
    ; make_node ~tool_name:"masc_board_stats" ~after:[ "producer" ] ~input:empty_input "b"
    ; make_node ~tool_name:"keeper_tools_list" ~after:[ "a" ] ~input:empty_input "c"
    ; make_node ~tool_name:"keeper_tools_list" ~after:[ "b" ] ~input:empty_input "d"
    ]
  in
  match
    Plan.create
      ~descriptors:[ producer; parallel; final ]
      ~branch_failure_policy:Plan.Continue_independent
      nodes
  with
  | Ok plan -> plan
  | Error _ -> fail "valid independent-branch fixture plan was rejected"
;;

let test_continue_independent_preserves_unrelated_branch () =
  Eio_main.run @@ fun _env ->
  let plan = independent_branch_fixture () in
  let called = ref [] in
  let dispatch ~tool_use_id:_ ~node ~descriptor:_ ~schedule:_ ~input:_ =
    let name = node_name node in
    called := !called @ [ name ];
    if String.equal name "b"
    then
      Executor.dispatch_result
        ~failure_effect_disposition:Tool_result.Proven_pre_effect
        (Tool_result.make_err
           ~tool_name:name
           ~class_:Tool_result.Workflow_rejection
           ~start_time:(Tool_timing.start ())
           "b rejected")
    else (
      let data =
        match name with
        | "producer" -> lane_status_data
        | "c" -> tools_list_data
        | _ -> board_stats_data
      in
      Executor.dispatch_result (completed ~tool_name:node.Plan.tool_name ~data))
  in
  match Executor.execute ~plan ~run_id:(Plan.Run_id.fresh ()) ~dispatch () with
  | Ok _ -> fail "failed branch did not fail the plan"
  | Error failure ->
    check
      (list string)
      "failed branch descendant was not dispatched"
      [ "a"; "b"; "c"; "producer" ]
      (List.sort String.compare !called);
    check
      (list string)
      "independent branch remains settled"
      [ "producer"; "a"; "b"; "c" ]
      (List.map (fun result -> Plan.Node_id.to_string result.Executor.node_id) failure.settled);
    (match failure.cause with
     | Executor.Tool_did_not_complete result ->
       check string "lowest planned cause" "b" (Plan.Node_id.to_string result.node_id)
     | Executor.Plan_execution_failed _
     | Executor.Node_observation_failed _
     | Executor.Outer_completion_mismatch _ ->
       fail "branch failure became a plan error")
;;

(* H4-S3: serial nodes run alone in static schedule order even when an
   unrelated concurrent node is still running. *)
let serial_order_fixture () =
  let producer = canonical_descriptor "keeper_lane_status" in
  let parallel = canonical_descriptor "masc_board_stats" in
  let serial = canonical_descriptor "BrowserSession" in
  let session_input =
    Plan.Json_template.literal (`Assoc [ "action", `String "status" ])
  in
  let nodes =
    [ make_node ~tool_name:"keeper_lane_status" ~after:[] ~input:empty_input "producer"
    ; make_node ~tool_name:"masc_board_stats" ~after:[ "producer" ] ~input:empty_input "w"
    ; make_node ~tool_name:"BrowserSession" ~after:[ "producer" ] ~input:session_input "s1"
    ; make_node ~tool_name:"BrowserSession" ~after:[ "producer" ] ~input:session_input "s2"
    ]
  in
  match Plan.create ~descriptors:[ producer; parallel; serial ] nodes with
  | Ok plan -> plan
  | Error _ -> fail "valid serial-order fixture plan was rejected"
;;

(* H4-S2 follow-up (code-reviewer P2): a serial chain stands down as a chain.
   s2 follows s1 in the static serial order without declaring a dependency, so
   the wave must consult the serial predecessor's settlement: when s1 failed
   (or deferred or was skipped), s2 dispatches no tool under either branch
   failure policy, while s1 itself still carries the plan cause. *)
let serial_chain_failure_fixture ~branch_failure_policy =
  let producer = canonical_descriptor "keeper_lane_status" in
  let serial = canonical_descriptor "BrowserSession" in
  let session_input =
    Plan.Json_template.literal (`Assoc [ "action", `String "status" ])
  in
  let nodes =
    [ make_node ~tool_name:"keeper_lane_status" ~after:[] ~input:empty_input "producer"
    ; make_node ~tool_name:"BrowserSession" ~after:[ "producer" ] ~input:session_input "s1"
    ; make_node ~tool_name:"BrowserSession" ~after:[ "producer" ] ~input:session_input "s2"
    ]
  in
  match
    Plan.create ~descriptors:[ producer; serial ] ~branch_failure_policy nodes
  with
  | Ok plan -> plan
  | Error _ -> fail "valid serial-chain failure fixture plan was rejected"
;;

let test_serial_failure_stops_successor_fail_fast () =
  Eio_main.run @@ fun _env ->
  let plan = serial_chain_failure_fixture ~branch_failure_policy:Plan.Fail_fast in
  let called = ref [] in
  let dispatch ~tool_use_id:_ ~node ~descriptor:_ ~schedule:_ ~input:_ =
    let name = node_name node in
    called := !called @ [ name ];
    match name with
    | "producer" ->
      Executor.dispatch_result (completed ~tool_name:name ~data:lane_status_data)
    | "s1" ->
      Executor.dispatch_result
        ~failure_effect_disposition:Tool_result.Proven_pre_effect
        (Tool_result.make_err
           ~tool_name:name
           ~class_:Tool_result.Workflow_rejection
           ~start_time:(Tool_timing.start ())
           "s1 rejected")
    | "s2" -> failf "s2 dispatched after serial predecessor failure under Fail_fast"
    | other -> failf "unexpected dispatched node: %s" other
  in
  match Executor.execute ~plan ~run_id:(Plan.Run_id.fresh ()) ~dispatch () with
  | Ok _ -> fail "failed serial node did not fail the plan"
  | Error failure ->
    check
      (list string)
      "serial successor was not dispatched and chain order kept"
      [ "producer"; "s1" ]
      !called;
    check
      (list string)
      "settled results keep canonical plan order"
      [ "producer"; "s1" ]
      (List.map (fun result -> Plan.Node_id.to_string result.Executor.node_id) failure.settled);
    (match failure.cause with
     | Executor.Tool_did_not_complete result ->
       check string "failed serial node carries the cause" "s1" (Plan.Node_id.to_string result.node_id)
     | Executor.Plan_execution_failed _
     | Executor.Node_observation_failed _
     | Executor.Outer_completion_mismatch _ ->
       fail "serial failure became a plan error")
;;

let test_serial_failure_stops_successor_continue_independent () =
  Eio_main.run @@ fun _env ->
  let plan =
    serial_chain_failure_fixture ~branch_failure_policy:Plan.Continue_independent
  in
  let called = ref [] in
  let dispatch ~tool_use_id:_ ~node ~descriptor:_ ~schedule:_ ~input:_ =
    let name = node_name node in
    called := !called @ [ name ];
    match name with
    | "producer" ->
      Executor.dispatch_result (completed ~tool_name:name ~data:lane_status_data)
    | "s1" ->
      Executor.dispatch_result
        ~failure_effect_disposition:Tool_result.Proven_pre_effect
        (Tool_result.make_err
           ~tool_name:name
           ~class_:Tool_result.Workflow_rejection
           ~start_time:(Tool_timing.start ())
           "s1 rejected")
    | "s2" ->
      failf "s2 dispatched after serial predecessor failure under Continue_independent"
    | other -> failf "unexpected dispatched node: %s" other
  in
  match Executor.execute ~plan ~run_id:(Plan.Run_id.fresh ()) ~dispatch () with
  | Ok _ -> fail "failed serial node did not fail the plan"
  | Error failure ->
    check
      (list string)
      "serial successor was not dispatched even under Continue_independent"
      [ "producer"; "s1" ]
      !called;
    check
      (list string)
      "settled results keep canonical plan order"
      [ "producer"; "s1" ]
      (List.map (fun result -> Plan.Node_id.to_string result.Executor.node_id) failure.settled);
    (match failure.cause with
     | Executor.Tool_did_not_complete result ->
       check string "failed serial node carries the cause" "s1" (Plan.Node_id.to_string result.node_id)
     | Executor.Plan_execution_failed _
     | Executor.Node_observation_failed _
     | Executor.Outer_completion_mismatch _ ->
       fail "serial failure became a plan error")
;;

let test_serial_nodes_run_alone_in_schedule_order () =
  Eio_main.run @@ fun _env ->
  let plan = serial_order_fixture () in
  let active = Atomic.make 0 in
  let max_active = Atomic.make 0 in
  let entered = ref [] in
  let dispatch ~tool_use_id:_ ~node ~descriptor:_ ~schedule:_ ~input:_ =
    let name = node_name node in
    entered := !entered @ [ name ];
    let current = Atomic.fetch_and_add active 1 + 1 in
    let rec raise_max () =
      let observed = Atomic.get max_active in
      if current > observed
      then (
        if Atomic.compare_and_set max_active observed current
        then ()
        else raise_max ())
      else ()
    in
    raise_max ();
    for _ = 1 to 20 do
      Eio.Fiber.yield ()
    done;
    ignore (Atomic.fetch_and_add active (-1));
    let data =
      match name with
      | "producer" -> lane_status_data
      | "s1" | "s2" -> `Assoc []
      | _ -> board_stats_data
    in
    Executor.dispatch_result (completed ~tool_name:node.Plan.tool_name ~data)
  in
  match Executor.execute ~plan ~run_id:(Plan.Run_id.fresh ()) ~dispatch () with
  | Error _ -> fail "serial-order plan did not complete"
  | Ok _ ->
    let rec index_of position name = function
      | [] -> failf "node %s was never dispatched" name
      | entry :: _ when String.equal entry name -> position
      | _ :: rest -> index_of (position + 1) name rest
    in
    let index = index_of 0 in
    check bool "producer dispatches first" true (index "producer" !entered = 0);
    check bool "serial nodes keep schedule order" true (index "s1" !entered < index "s2" !entered);
    check int "no two nodes ever overlapped" 1 (Atomic.get max_active)
;;

let () =
  run
    "keeper_tool_plan_executor"
    [ ( "execution"
      , [ test_case "parallel dataflow schedule" `Quick test_schedule_and_parallel_dataflow
        ; test_case
            "failed sibling stops downstream"
            `Quick
            test_failed_sibling_stops_downstream_after_batch_settlement
        ; test_case
            "output validation precedes node observation"
            `Quick
            test_output_validation_precedes_node_observation
        ; Alcotest.test_case
            "observation failure settles siblings and stops downstream"
            `Quick
            test_observation_failure_settles_siblings_and_stops_downstream
        ; test_case
            "dispatch exception preserves pre-minted identity"
            `Quick
            test_dispatch_exception_preserves_pre_minted_tool_identity
        ; test_case
            "deferred effect evidence is not invented"
            `Quick
            test_deferred_effect_evidence_is_not_invented
        ; Alcotest.test_case
            "deferred cause does not mask unknown sibling"
            `Quick
            test_deferred_cause_does_not_mask_unknown_sibling
        ; test_case
            "malformed producer stops consumers"
            `Quick
            test_malformed_declared_output_stops_before_consumer
        ; test_case
            "typed output flows to consumer dispatch input"
            `Quick
            test_typed_output_flows_to_consumer_dispatch_input
        ; test_case
            "outer completion owns terminal boundary"
            `Quick
            test_outer_completion_owns_terminal_boundary
        ; test_case
            "ready wave starts dependent before unrelated release"
            `Quick
            test_ready_wave_starts_dependent_before_unrelated_release
        ; test_case
            "continue independent preserves unrelated branch"
            `Quick
            test_continue_independent_preserves_unrelated_branch
        ; test_case
            "serial nodes run alone in schedule order"
            `Quick
            test_serial_nodes_run_alone_in_schedule_order
        ; test_case
            "serial failure stops successor under Fail_fast"
            `Quick
            test_serial_failure_stops_successor_fail_fast
        ; test_case
            "serial failure stops successor under Continue_independent"
            `Quick
            test_serial_failure_stops_successor_continue_independent
        ] )
    ; ( "node input validation"
      , [ test_case
            "a literal input violation runs no node"
            `Quick
            test_static_input_rejection_runs_no_node
        ; test_case
            "an enum literal is refused before any node"
            `Quick
            test_enum_literal_is_refused_before_any_node
        ; test_case
            "an output value outside the enum is refused when its node runs"
            `Quick
            test_output_value_outside_enum_is_refused_when_its_node_runs
        ] )
    ]
;;
