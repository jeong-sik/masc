open Alcotest

module Descriptor = Masc.Keeper_tool_descriptor
module Plan = Masc.Keeper_tool_plan
module Executor = Masc.Keeper_tool_plan_executor
module Tool_bridge = Masc.Tool_bridge

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

let fixture ?(branch_failure_policy=Plan.default_branch_failure_policy) () =
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
      ~branch_failure_policy
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
  let dispatch ?launch_replay:_ ~tool_use_id ~node ~descriptor:_ ~schedule:_ ~input () =
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
  let dispatch ?launch_replay:_ ~tool_use_id:_ ~node ~descriptor:_ ~schedule:_ ~input:_ () =
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
     | Executor.Run_journal_rejected error ->
       Alcotest.fail (Masc.Keeper_tool_execution_journal.error_to_string error)
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
  let dispatch ?launch_replay:_ ~tool_use_id:_ ~node ~descriptor:_ ~schedule:_ ~input:_ () =
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
  let dispatch ?launch_replay:_ ~tool_use_id:_ ~node ~descriptor:_ ~schedule:_ ~input:_ () =
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
     | Executor.Run_journal_rejected error ->
       Alcotest.fail (Masc.Keeper_tool_execution_journal.error_to_string error)
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
  let dispatch ?launch_replay:_ ~tool_use_id ~node:_ ~descriptor:_ ~schedule:_ ~input:_ () =
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
     | Executor.Run_journal_rejected error ->
       Alcotest.fail (Masc.Keeper_tool_execution_journal.error_to_string error)
     | Executor.Plan_execution_failed _
     | Executor.Node_observation_failed _
     | Executor.Outer_completion_mismatch _ ->
       fail "dispatch exception lost its settled tool result")
;;

let test_deferred_effect_evidence_is_not_invented () =
  Eio_main.run @@ fun _env ->
  List.iter (fun (evidence, expected) ->
    let plan = fixture () in
    let dispatch ?launch_replay:_ ~tool_use_id:_ ~node ~descriptor:_ ~schedule:_ ~input:_ () =
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

let test_deferred_cause_does_not_mask_unknown_sibling ?(observation_failure=false) () =
  Eio_main.run @@ fun _env ->
  let plan = fixture ~branch_failure_policy:Plan.Continue_independent () in
  let dispatch ?launch_replay:_ ~tool_use_id:_ ~node ~descriptor:_ ~schedule:_ ~input:_ () =
    match node_name node with
    | "left" ->
      Executor.dispatch_result
        ~deferred_kind:Masc.Keeper_tool_execution.Generic_deferred
        (Tool_result.make_deferred ~tool_name:"left" ~start_time:(Tool_timing.start ()) ())
    | "right" when not observation_failure ->
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
  let observe_node_result node =
    if observation_failure && Plan.Node_id.to_string node.Executor.node_id = "right"
    then Error "actual higher sibling observation unavailable" else Ok () in
  match Executor.execute ~plan ~run_id:(Plan.Run_id.fresh ()) ~dispatch ~observe_node_result () with
  | Ok _ -> fail "deferred and failed siblings did not stop the plan"
  | Error failure ->
    (match failure.cause with
     | Executor.Tool_did_not_complete result ->
       check string "lowest planned cause" "left" (Plan.Node_id.to_string result.node_id);
       (match result.result with
        | Tool_result.Deferred _ -> ()
        | Tool_result.Completed _ | Tool_result.Failed _ ->
          fail "lower-index deferred cause changed")
     | Executor.Run_journal_rejected error ->
       Alcotest.fail (Masc.Keeper_tool_execution_journal.error_to_string error)
     | Executor.Plan_execution_failed _
     | Executor.Node_observation_failed _
     | Executor.Outer_completion_mismatch _ ->
       fail "deferred cause became a plan error");
    (match Executor.failure_causes failure with
     | [Executor.Tool_did_not_complete left;Executor.Tool_did_not_complete right]
         when not observation_failure ->
       check (list string) "all actual sibling causes retain planned order" ["left";"right"]
         [Plan.Node_id.to_string left.node_id;Plan.Node_id.to_string right.node_id]
     | [Executor.Tool_did_not_complete left;Executor.Node_observation_failed {node=right;detail}]
         when observation_failure ->
       check (list string) "higher observation failure survives the earlier wait" ["left";"right"]
         [Plan.Node_id.to_string left.node_id;Plan.Node_id.to_string right.node_id];
       check string "actual observation failure detail is retained"
         "actual higher sibling observation unavailable" detail;
       check bool "higher sibling tool actually completed before observation failed" true
         (Tool_result.is_success right.result)
     | _ -> fail "non-primary actual sibling cause was lost");
    check string
      "unknown sibling dominates deferred cause"
      "effect_outcome_unknown"
      (Tool_result.failure_effect_disposition_to_string failure.effect_disposition)
;;

let test_malformed_declared_output_stops_before_consumer () =
  Eio_main.run @@ fun _env ->
  let plan = fixture () in
  let called = ref [] in
  let dispatch ?launch_replay:_ ~tool_use_id:_ ~node ~descriptor:_ ~schedule:_ ~input:_ () =
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
     | Executor.Run_journal_rejected error ->
       Alcotest.fail (Masc.Keeper_tool_execution_journal.error_to_string error)
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
  let dispatch ?launch_replay:_ ~tool_use_id:_ ~node ~descriptor:_ ~schedule:_ ~input () =
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

let never_dispatched ?launch_replay:_ ~tool_use_id:_ ~node ~descriptor:_ ~schedule:_ ~input:_ () =
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
  | Executor.Run_journal_rejected error ->
    Alcotest.fail (Masc.Keeper_tool_execution_journal.error_to_string error)
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
          ; canonical_descriptor "keeper_wiki_search"
          ; canonical_descriptor "masc_board_search"
          ]
        [ search ~id:"memory" ~tool:"keeper_memory_search" "EACCES"
        ; search ~after ~id:"wiki" ~tool:"keeper_wiki_search" "EACCES"
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
       [ "board"; "wiki" ]
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
  let dispatch ?launch_replay:_ ~tool_use_id:_ ~node ~descriptor:_ ~schedule:_ ~input:_ () =
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
     | Executor.Run_journal_rejected error ->
       Alcotest.fail (Masc.Keeper_tool_execution_journal.error_to_string error)
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
  let dispatch ?launch_replay:_ ~tool_use_id:_ ~node ~descriptor:_ ~schedule:_ ~input:_ () =
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
  let dispatch ?launch_replay:_ ~tool_use_id:_ ~node ~descriptor:_ ~schedule:_ ~input:_ () =
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
     | Executor.Run_journal_rejected error ->
       Alcotest.fail (Masc.Keeper_tool_execution_journal.error_to_string error)
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
  let dispatch ?launch_replay:_ ~tool_use_id:_ ~node ~descriptor:_ ~schedule:_ ~input:_ () =
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
     | Executor.Run_journal_rejected error ->
       Alcotest.fail (Masc.Keeper_tool_execution_journal.error_to_string error)
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
  let dispatch ?launch_replay:_ ~tool_use_id:_ ~node ~descriptor:_ ~schedule:_ ~input:_ () =
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
     | Executor.Run_journal_rejected error ->
       Alcotest.fail (Masc.Keeper_tool_execution_journal.error_to_string error)
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
  let dispatch ?launch_replay:_ ~tool_use_id:_ ~node ~descriptor:_ ~schedule:_ ~input:_ () =
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

(* Declaration order deliberately differs from dependency and lexical order.
   Exercise the public plan and executor, including repeated explicit/output
   edges, serial failure propagation and independent typed dataflow. *)
let test_unordered_graph_preserves_execution ~fail_serial () =
  Eio_main.run @@ fun _ ->
  let json = testable Yojson.Safe.pretty_print Yojson.Safe.equal in
  let pointer value = match Plan.Json_pointer.of_string value with
    | Ok pointer -> pointer
    | Error _ -> fail "fixture output pointer" in
  let source_path = "/keeper/probe/a.ml" in
  let source = make_node ~tool_name:"keeper_lane_status" ~after:[] ~input:empty_input "z-source" in
  let independent = make_node ~tool_name:"keeper_lane_status" ~after:[] ~input:empty_input "independent" in
  let session_input = Plan.Json_template.literal (`Assoc ["action",`String "status"]) in
  let serial_before = make_node ~tool_name:"BrowserSession" ~after:["z-source"]
      ~input:session_input "z-serial" in
  let serial_after = make_node ~tool_name:"BrowserSession" ~after:["z-source"]
      ~input:session_input "a-serial" in
  let join = make_node ~tool_name:"Read" ~after:["z-source";"z-source"]
      ~input:(object_template ["file_path", Plan.Json_template.output
        ~node_id:source.id ~pointer:(pointer "/profile")]) "a-join" in
  let sink = make_node ~tool_name:"Grep" ~after:["a-join";"a-join"]
      ~input:(object_template ["pattern",Plan.Json_template.literal (`String "probe");
        "path",Plan.Json_template.output ~node_id:join.id ~pointer:(pointer "/path")]) "a-final" in
  let nodes = [sink;serial_before;join;serial_after;source;independent] in
  let plan = match Plan.create ~descriptors:(Descriptor.all_descriptors ())
      ~branch_failure_policy:Plan.Continue_independent nodes with
    | Ok plan -> plan
    | Error error -> fail (Plan.error_to_string error) in
  check (list (list string)) "stable semantic dependency layers"
    [["z-source";"independent"];["z-serial";"a-join";"a-serial"];["a-final"]]
    (Plan.dependency_layers plan |> List.map (List.map node_name));
  check int "explicit and output references form one semantic edge" 1
    (List.length (Plan.dependencies join));
  let roots_entered = ref 0 and active = ref 0 and calls = ref [] in
  let both, release = Eio.Promise.create () in
  let dispatch ?launch_replay:_ ~tool_use_id ~node ~descriptor:_ ~schedule ~input () =
    let name = node_name node in
    let ordinal = List.find_index (fun original -> original == node) nodes in
    check (option int) "dispatch retains original plan operand and ordinal"
      (Some schedule.Agent_core.Tool_contract.planned_index) ordinal;
    let batch_index,batch_size,execution_mode = match name with
      | "z-source" | "independent" -> 0,2,Agent_core.Tool_contract.Concurrent
      | "z-serial" -> 1,1,Agent_core.Tool_contract.Serial
      | "a-join" -> 2,1,Agent_core.Tool_contract.Concurrent
      | "a-serial" -> 3,1,Agent_core.Tool_contract.Serial
      | "a-final" -> 4,1,Agent_core.Tool_contract.Concurrent
      | other -> failf "unexpected fixture node %s" other in
    check int "original batch index" batch_index schedule.batch_index;
    check int "original batch size" batch_size schedule.batch_size;
    check bool "descriptor execution mode retained" true (execution_mode = schedule.execution_mode);
    if execution_mode = Agent_core.Tool_contract.Serial then
      check int "serial entry owns the executor exclusively" 0 !active;
    incr active;
    Fun.protect ~finally:(fun () -> decr active) (fun () ->
      calls := (name,tool_use_id) :: !calls;
      if name = "z-source" || name = "independent" then (
        incr roots_entered;
        if !roots_entered = 2 then Eio.Promise.resolve release ();
        Eio.Promise.await both);
      Eio.Fiber.yield ();
      if name = "z-serial" && fail_serial then
        Executor.dispatch_result ~failure_effect_disposition:Tool_result.Proven_pre_effect
          (Tool_result.make_err ~tool_name:node.Plan.tool_name ~class_:Tool_result.Workflow_rejection
            ~effect_disposition:Tool_result.Proven_pre_effect ~start_time:(Tool_timing.start ())
            "original serial predecessor refused")
      else (
        let data = match name with
          | "z-source" -> `Assoc ["profile",`String source_path;"lane",`Null;"endpoint",`Null;
              "probe",`Null;"last_dispatch",`Null;"operator_action",`Null]
          | "independent" -> lane_status_data
          | "z-serial" -> `Assoc []
          | "a-serial" ->
            check bool "failed original serial predecessor prevents its successor" false fail_serial;
            `Assoc []
          | "a-join" ->
            check json "upstream output binds the Read input" (`Assoc ["file_path",`String source_path]) input;
            `Assoc ["ok",`Bool true;"path",`String source_path;"bytes",`Int 5;"truncated",`Bool false;
              "offset",`Int 1;"returned_lines",`Int 1;"content",`String "probe"]
          | "a-final" ->
            check json "Read output reaches the original consumer"
              (`Assoc ["pattern",`String "probe";"path",`String source_path]) input;
            `Assoc ["ok",`Bool true;"op",`String "rg";"path",`String source_path;"pattern",`String "probe";
              "via",`String "host";"status",`Assoc ["kind",`String "exit";"code",`Int 0];"matches",`List []]
          | other -> failf "unexpected fixture result %s" other in
        Executor.dispatch_result (completed ~tool_name:node.Plan.tool_name ~data))) in
  let results = match Executor.execute ~plan ~run_id:(Plan.Run_id.fresh ()) ~dispatch () with
    | Ok results when not fail_serial -> results
    | Error failure when fail_serial ->
      (match failure.cause with
       | Executor.Tool_did_not_complete result ->
         check string "original serial node owns the failure" "z-serial"
           (Plan.Node_id.to_string result.node_id)
       | Executor.Run_journal_rejected _ | Executor.Plan_execution_failed _
       | Executor.Node_observation_failed _ | Executor.Outer_completion_mismatch _ ->
         fail "serial refusal lost its execution cause");
      failure.settled
    | Ok _ -> fail "serial refusal became success"
    | Error _ -> fail "valid unordered dataflow failed" in
  let expected = if fail_serial then [sink;serial_before;join;source;independent] else nodes in
  check (list string) "settlements retain canonical plan order including independent work"
    (List.map node_name expected) (List.map (fun (r : Executor.node_result) -> Plan.Node_id.to_string r.node_id) results);
  let uses = List.map snd !calls in
  check int "every admitted dispatch keeps a distinct original tool use" (List.length expected)
    (List.length (List.sort_uniq String.compare uses));
  check int "both unrelated roots were actually admitted" 2 !roots_entered;
  check int "all original executor entries settled" 0 !active
;;

let test_reused_plan_keeps_each_execution_owner_after_interruption_and_failure () =
  Eio_main.run @@ fun _ ->
  let plan = fixture ~branch_failure_policy:Plan.Continue_independent () in
  let entered, resolve_entered = Eio.Promise.create () in
  let never, _resolve_never = Eio.Promise.create () in
  let interrupted_calls = ref [] and interrupted_observations = ref [] in
  let blocked_dispatch ?launch_replay:_ ~tool_use_id ~node ~descriptor:_ ~schedule:_ ~input:_ () =
    check string "only the original producer enters before interruption" "producer" (node_name node);
    interrupted_calls := tool_use_id :: !interrupted_calls;
    Eio.Promise.resolve resolve_entered ();
    Eio.Promise.await never in
  let observe_interrupted (result : Executor.node_result) =
    interrupted_observations := result :: !interrupted_observations; Ok () in
  (match Eio.Switch.run (fun sw ->
     Eio.Fiber.fork ~sw (fun () ->
       ignore (Executor.execute ~plan ~run_id:(Plan.Run_id.fresh ()) ~dispatch:blocked_dispatch
         ~observe_node_result:observe_interrupted ());
       fail "interrupted producer unexpectedly settled");
     Eio.Promise.await entered;
     Eio.Switch.fail sw Exit) with
   | () -> fail "caller interruption did not leave the original execution"
   | exception Exit -> ());
  check int "interrupted owner has no fabricated settlement" 0 (List.length !interrupted_observations);
  let run ~marker ~reject_left =
    let called = ref [] and observed = ref [] in
    let dispatch ?launch_replay:_ ~tool_use_id ~node ~descriptor:_ ~schedule ~input:_ () =
      let name = node_name node in
      called := (name,tool_use_id) :: !called;
      check (option int) "fresh execution retains the original ordinal"
        (Some schedule.Agent_core.Tool_contract.planned_index)
        (List.find_index (fun original -> original == node) (Plan.nodes plan));
      if reject_left && name = "left" then
        Executor.dispatch_result ~failure_effect_disposition:Tool_result.Proven_pre_effect
          (Tool_result.make_err ~tool_name:node.Plan.tool_name ~class_:Tool_result.Workflow_rejection
            ~effect_disposition:Tool_result.Proven_pre_effect ~start_time:(Tool_timing.start ()) "left refused")
      else (
        Eio.Fiber.yield ();
        let data = match valid_data_for_node node with
          | `Assoc fields when name = "left" || name = "right" ->
            `Assoc (("post_count",`Int marker) :: List.remove_assoc "post_count" fields)
          | data -> data in
        Executor.dispatch_result (completed ~tool_name:node.Plan.tool_name ~data)) in
    let observe_node_result (result : Executor.node_result) =
      observed := result :: !observed; Ok () in
    let execution = Executor.execute ~plan ~run_id:(Plan.Run_id.fresh ()) ~dispatch ~observe_node_result () in
    let settled = match execution with
      | Ok settled when not reject_left -> settled
      | Error failure when reject_left ->
        (match failure.cause with
         | Executor.Tool_did_not_complete result ->
           check string "current refusal owns the current cause" "left"
             (Plan.Node_id.to_string result.node_id)
         | Executor.Run_journal_rejected _ | Executor.Plan_execution_failed _
         | Executor.Node_observation_failed _ | Executor.Outer_completion_mismatch _ ->
           fail "refusal changed execution cause");
        failure.settled
      | Ok _ -> fail "current refusal became success"
      | Error _ -> fail "later execution reused an interrupted or failed owner" in
    let expected = if reject_left then ["producer";"left";"right"]
      else ["producer";"left";"right";"final"] in
    check (list string) "fresh owners settle in original plan order" expected
      (List.map (fun (r : Executor.node_result) -> Plan.Node_id.to_string r.node_id) settled);
    check (list string) "each execution dispatches its own complete admitted branch"
      (List.sort String.compare expected) (List.map fst !called |> List.sort String.compare);
    check (list string) "observer sees only this execution's actual dispatches"
      (List.map snd !called |> List.sort String.compare)
      (List.map (fun (r : Executor.node_result) -> r.tool_use_id) !observed |> List.sort String.compare);
    let right = List.find (fun (r : Executor.node_result) ->
        Plan.Node_id.equal r.node_id (node_id "right")) settled in
    check int "independent result belongs to the current execution" marker
      Yojson.Safe.Util.(Tool_result.data right.result |> member "post_count" |> to_int);
    List.map snd !called in
  let after_interruption = run ~marker:2 ~reject_left:true in
  let after_failure = run ~marker:3 ~reject_left:false in
  let uses = !interrupted_calls @ after_interruption @ after_failure in
  check int "one interrupted producer and both later runs keep distinct original tool uses"
    (1 + List.length after_interruption + List.length after_failure)
    (List.length (List.sort_uniq String.compare uses));
  check int "later results do not settle the interrupted observer" 0 (List.length !interrupted_observations)
;;

let export_pointer value =
  match Plan.Json_pointer.of_string value with
  | Ok value -> value
  | Error _ -> fail "invalid export fixture pointer"
;;

let export_measurement = ref None
let provider_trial_corpus = ref []

let with_export_base f =
  let base = Filename.temp_file "masc-composition-exports-" "" in
  Sys.remove base;
  Unix.mkdir base 0o700;
  let rec remove path =
    if Sys.is_directory path then (
      Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path);
      Unix.rmdir path)
    else Sys.remove path
  in
  Fun.protect ~finally:(fun () -> remove base) (fun () -> f base)
;;

let exported_read_fixture ?(branch_failure_policy = Plan.Fail_fast) ?(pointer = "/path") () =
  let nodes =
    [ make_node ~tool_name:"Read" ~after:[]
        ~input:(object_template [ "file_path", Plan.Json_template.literal (`String "probe.txt") ]) "read" ]
  in
  let exports = [ Plan.export ~name:"path" ~node_id:(node_id "read") ~pointer:(export_pointer pointer) ] in
  match Plan.create ~descriptors:[ canonical_descriptor "Read" ] ~branch_failure_policy ~exports nodes with
  | Ok plan -> plan
  | Error error -> failf "export fixture rejected: %s" (Plan.error_to_string error)
;;

let read_export_data =
  let content = String.make 16384 'x' in
  `Assoc [ "ok", `Bool true; "path", `String "probe.txt"
         ; "bytes", `Int (String.length content); "truncated", `Bool false
         ; "offset", `Int 0; "returned_lines", `Int 1; "content", `String content ]
;;

let project_export ~base_path ~plan ~execution original =
  match Masc.Keeper_tool_composition_surface.For_testing.project_execution_result
          ~base_path ~plan ~execution original with
  | Ok result -> result
  | Error error -> fail error.Tool_bridge.message
;;

let provider_content ~base_path ?model_projection result =
  let module T = Agent_core.Types in
  let content, outcome =
    match Tool_bridge.to_agent_core_typed_result ~base_path ?model_projection result with
    | Ok output -> output.content, T.Tool_succeeded
    | Error error -> error.message, T.Tool_failed
        { T.failure_kind = T.Non_retryable_tool_error; error_class = error.error_class }
  in
  let message : Llm_provider.Types.message =
    { origin = Llm_provider.Types.Conversation;  role = T.Tool
    ; content = [ Llm_provider.Types.ToolResult { tool_use_id = "export-fixture"; content; outcome
                                ; json = None; content_blocks = None } ]
    ; name = None; tool_call_id = Some "export-fixture"; metadata = [] }
  in
  match Llm_provider.Backend_openai_serialize.openai_messages_of_message message with
  | [ wire ] ->
    let wire_content = Yojson.Safe.Util.(wire |> member "content" |> to_string) in
    check string "provider receives exact projected content" content wire_content;
    wire_content
  | _ -> fail "provider did not serialize one tool result"
;;

(* Keep the real provider projection and real bounded artifact-reader pages.
   A later external model trial replays these immutable observations; it does
   not synthesize a smaller result or reexecute the producer. *)
let previous_provider_content ~base_path ?model_projection result =
  match Tool_bridge.attach_artifact_manifest ~projection:Tool_output.Inline_with_reference ~base_path result with
  | Ok result -> provider_content ~base_path ?model_projection result
  | Error error -> fail error.Tool_bridge.message
;;

let record_provider_trial ~base_path ?(model_projection = Tool_output.default_model_projection)
    ~scenario ~task ~expected original projected =
  let baseline = provider_content ~base_path ~model_projection original in
  let selected = provider_content ~base_path ~model_projection projected in
  let previous = previous_provider_content ~base_path ~model_projection projected in
  let references_in_json json =
    match Tool_output.normalized_artifact_refs_in_json_strict json with
    | Ok references -> references
    | Error detail -> fail detail
  in
  let references =
    List.concat_map (fun content ->
      match Tool_output.decode_from_agent_core content with
      | Tool_output.Decoded reference -> [ reference ]
      | Tool_output.Not_marker ->
        (match Yojson.Safe.from_string content with
         | json -> references_in_json json
         | exception Yojson.Json_error _ -> [])
      | Tool_output.Invalid_marker { detail } -> fail detail) [ baseline; selected; previous ]
    @ Tool_result.retained_artifacts projected
    @ references_in_json (Tool_result.data projected)
    |> List.sort_uniq (fun left right -> String.compare left.Tool_output.sha256 right.Tool_output.sha256)
  in
  let pages = List.concat_map (fun (reference : Tool_output.artifact_ref) ->
    let rec read offset =
      let args = `Assoc [ "sha256", `String reference.sha256; "offset", `Int offset ] in
      let execution, observation = Masc.Keeper_artifact_read.handle_with_page ~base_path ~args in
      match observation, execution.Masc.Keeper_tool_execution.data with
      | Some page, Some data ->
        let content = provider_content ~base_path
            (completed ~tool_name:"keeper_artifact_read" ~data) in
        check bool "captured artifact page is immediately readable" false (Tool_output.is_marker content);
        let entry = `Assoc [ "args", args; "content", `String content ] in
        if page.eof then [ entry ]
        else (
          check bool "artifact paging advances" true (page.next_offset > offset);
          entry :: read page.next_offset)
      | None, _ | Some _, None -> fail "real artifact reader could not capture a stored result"
    in
    read 0) references in
  let reader = canonical_descriptor "keeper_artifact_read" in
  let schema = `Assoc [ "name", `String reader.public_name; "description", `String reader.description
                      ; "input_schema", reader.input_schema ] in
  let reader_tool = Llm_provider.Backend_openai_serialize.build_openai_tool_json schema in
  provider_trial_corpus :=
    `Assoc [ "scenario", `String scenario; "task", `String task; "expected", expected
           ; "tool_name", `String (Tool_result.tool_name original)
           ; "baseline_content", `String baseline; "selected_content", `String selected
           ; "previous_selected_content", `String previous
           ; "provider_projection_ceiling_bytes", `Int (Tool_output.inline_ceiling_bytes model_projection)
           ; "reader_tool", reader_tool
           ; "reader_default_max_bytes", `Int Masc.Keeper_artifact_read.default_max_bytes
           ; "pages", `List pages ] :: !provider_trial_corpus
;;

let execution_document ~base_path reference =
  match Tool_blob_store.fetch (Tool_blob_store.create ~base_path) ~sha256:reference.Tool_output.sha256 with
  | Ok (Some raw) ->
    (match Tool_output.artifact_manifest_of_json (Yojson.Safe.from_string raw) with
     | Tool_output.Decoded_artifact_manifest { structured_content; _ } -> structured_content
     | Tool_output.Not_artifact_manifest -> fail "execution artifact is not a typed manifest"
     | Tool_output.Invalid_artifact_manifest { detail } -> fail detail)
  | Ok None -> fail "advertised execution artifact is missing"
  | Error error -> fail (Tool_blob_store.fetch_error_to_string error)
;;

let test_export_success_preserves_durable_original () =
  Eio_main.run @@ fun _env ->
  with_export_base @@ fun base_path ->
  let plan = exported_read_fixture () in
  let calls = ref 0 in
  let dispatch ?launch_replay:_ ~tool_use_id:_ ~node ~descriptor:_ ~schedule:_ ~input:_ () =
    incr calls;
    Executor.dispatch_result (completed ~tool_name:node.Plan.tool_name ~data:read_export_data)
  in
  let execution = Executor.execute ~plan ~run_id:(Plan.Run_id.fresh ()) ~dispatch () in
  let original = Masc.Keeper_tool_composition_surface.For_testing.result_of_execution
      ~tool_name:"keeper_compose_export-fixture" ~tool_kind:Descriptor.Composition_tool
      ~start_time:(Tool_timing.start ()) execution in
  let projected = project_export ~base_path ~plan ~execution original in
  check bool "success remains authoritative" true (Tool_result.is_success projected);
  let data = Tool_result.data projected in
  let open Yojson.Safe.Util in
  check string "selected path" "probe.txt" (data |> member "exports" |> member "path" |> member "value" |> to_string);
  check bool "all action data moved to the artifact" true (data |> member "actions" = `Null);
  let reference = data |> member "execution_artifact" in
  let reference = match Tool_output.normalized_artifact_ref_of_json reference with
    | Tool_output.Decoded_normalized_artifact_ref reference -> reference
    | Tool_output.Not_normalized_artifact_ref | Tool_output.Invalid_normalized_artifact_ref _ ->
      fail "execution artifact is not a canonical reference" in
  check string "execution uses canonical retention edge" Tool_output.artifact_manifest_mime reference.mime;
  let raw = execution_document ~base_path reference in
  check string "raw producer retained byte-for-byte"
    (Yojson.Safe.to_string (Tool_result.to_json original))
    (raw |> member "result" |> Yojson.Safe.to_string);
  check int "one dispatch, no replay" 1 !calls;
  check bool "artifact retained for observers" true (Tool_result.retained_artifacts projected <> []);
  let wire_content = provider_content ~base_path projected in
  check bool "small exports remain immediately readable" false (Tool_output.is_marker wire_content);
  let wire = Yojson.Safe.from_string wire_content in
  check string "selected path survives actual provider serialization" "probe.txt"
    (wire |> member "structured_content" |> member "exports" |> member "path" |> member "value" |> to_string);
  check bool "provider content roots the complete manifest" true
    (wire |> member "artifact_manifest" <> `Null);
  let baseline_wire = provider_content ~base_path original in
  record_provider_trial ~base_path ~scenario:"selected_path"
    ~task:"Return JSON containing only the exact path field returned by the completed read: {\"path\":\"...\"}. Use the composition result or its artifact; do not guess the path. If you read artifacts, use default full pages and omit max_bytes."
    ~expected:(`Assoc [ "path", `String "probe.txt" ]) original projected;
  export_measurement := Some
    (`Assoc [ "scope", `String "controlled Read composition through attach_artifact_manifest, AGENT_CORE, OpenAI serializer"
            ; "raw_result_bytes", `Int (String.length (Tool_result.message original))
            ; "export_result_bytes", `Int (String.length (Tool_result.message projected))
            ; "provider_tool_content_bytes", `Int (String.length wire_content)
            ; "baseline_provider_tool_content_bytes", `Int (String.length baseline_wire)
            ; "baseline_externalized", `Bool (Tool_output.is_marker baseline_wire)
            ; "export_externalized", `Bool (Tool_output.is_marker wire_content)
            ; "node_dispatches", `Int !calls
            ; "full_artifact_retrieved", `Bool true ])
;;

let test_export_failure_preserves_independent_branch () =
  Eio_main.run @@ fun _env ->
  with_export_base @@ fun base_path ->
  let source = independent_branch_fixture () in
  let exports =
    [ Plan.export ~name:"independent" ~node_id:(node_id "a") ~pointer:(export_pointer "/post_count")
    ; Plan.export ~name:"failed" ~node_id:(node_id "b") ~pointer:(export_pointer "/post_count")
    ; Plan.export ~name:"blocked" ~node_id:(node_id "d") ~pointer:(export_pointer "/profile") ] in
  let nodes = List.map (fun (node : Plan.node) ->
    if String.equal (node_name node) "d" then
      Plan.node ~id:node.id ~tool_name:"keeper_lane_status"
        ~after:node.after ~input:node.input ()
    else node) (Plan.nodes source) in
  let plan =
    match Plan.create ~descriptors:(Descriptor.all_descriptors ())
            ~branch_failure_policy:Plan.Continue_independent ~exports nodes with
    | Ok plan -> plan
    | Error error -> fail (Plan.error_to_string error)
  in
  let dispatches = ref 0 in
  let dispatch ?launch_replay:_ ~tool_use_id:_ ~node ~descriptor:_ ~schedule:_ ~input:_ () =
    incr dispatches;
    if String.equal (node_name node) "b" then
      Executor.dispatch_result ~failure_effect_disposition:Tool_result.Effect_outcome_unknown
        (Tool_result.make_err ~tool_name:node.Plan.tool_name ~class_:Tool_result.Runtime_failure
           ~effect_disposition:Tool_result.Effect_outcome_unknown ~start_time:(Tool_timing.start ())
           "fixture effect outcome unknown")
    else
      let data = match node_name node with
        | "producer" -> lane_status_data | "c" -> tools_list_data | _ -> board_stats_data in
      Executor.dispatch_result (completed ~tool_name:node.Plan.tool_name ~data)
  in
  let execution = Executor.execute ~plan ~run_id:(Plan.Run_id.fresh ()) ~dispatch () in
  let dispatched_before_presentations = !dispatches in
  let original = Masc.Keeper_tool_composition_surface.For_testing.result_of_execution
      ~tool_name:"keeper_compose_partial-fixture" ~tool_kind:Descriptor.Composition_tool
      ~start_time:(Tool_timing.start ()) execution in
  match Masc.Keeper_tool_composition_surface.For_testing.project_execution_result ~base_path ~plan ~execution original with
  | Error error -> fail error.Tool_bridge.message
  | Ok projected ->
    (match projected with
     | Tool_result.Failed { effect_disposition = Tool_result.Effect_outcome_unknown; _ } -> ()
     | Tool_result.Failed _ | Tool_result.Completed _ | Tool_result.Deferred _ -> fail "unknown failure became a success or weaker disposition");
    let open Yojson.Safe.Util in
    let data = Tool_result.data projected in
    check bool "independent result retained" true (data |> member "exports" |> member "independent" |> member "available" |> to_bool);
    List.iter (fun name -> check bool (name ^ " is unavailable") false
      (data |> member "exports" |> member name |> member "available" |> to_bool)) [ "failed"; "blocked" ];
    check bool "failure cause remains visible" true (data |> member "cause" <> `Null);
    check bool "full failure artifact is addressable" true (data |> member "execution_artifact" <> `Null);
    let wire = provider_content ~base_path projected |> Yojson.Safe.from_string in
    let wire_data = wire |> member "structured_content" in
    check bool "independent result reaches provider on failure" true
      (wire_data |> member "exports" |> member "independent" |> member "available" |> to_bool);
    check string "unknown effect reaches provider" "effect_outcome_unknown"
      (wire_data |> member "effect_disposition" |> to_string);
    check bool "provider keeps failed node and cause" true (wire_data |> member "cause" <> `Null);
    let diagnostic = wire |> member "content" |> to_string |> Yojson.Safe.from_string in
    check string "canonical failure class remains model-visible"
      (Tool_result.tool_failure_class_to_string Tool_result.Runtime_failure)
      (diagnostic |> member "failure_class" |> to_string);
    check string "canonical failed disposition remains model-visible" "failed"
      (diagnostic |> member "masc.tool_disposition" |> to_string);
    let selected_wire = provider_content ~base_path projected in
    let previous_wire = previous_provider_content ~base_path projected in
    check bool "structured failure avoids repeated selected payload" true
      (String.length selected_wire < String.length previous_wire);
    let full_reference = data |> member "execution_artifact" in
    let full_reference = match Tool_output.normalized_artifact_ref_of_json full_reference with
      | Tool_output.Decoded_normalized_artifact_ref reference -> reference
      | Tool_output.Not_normalized_artifact_ref | Tool_output.Invalid_normalized_artifact_ref _ ->
        fail "full failure artifact reference is malformed" in
    check string "full original failure evidence is unchanged"
      (Tool_result.to_json original |> Yojson.Safe.to_string)
      (execution_document ~base_path full_reference |> member "result" |> Yojson.Safe.to_string);
    let task = "Return JSON with the independent branch's post_count as independent, availability of the failed branch as failed_available, aggregate disposition as disposition, and effect disposition as effect_disposition. Preserve the failure and never replay the producer. If you read artifacts, use default full pages and omit max_bytes." in
    let expected = `Assoc [ "independent", `Int 0; "failed_available", `Bool false
                         ; "disposition", `String "failed"; "effect_disposition", `String "effect_outcome_unknown" ] in
    record_provider_trial ~base_path ~scenario:"partial_unknown_effect" ~task ~expected original projected;
    (* Use this already observed selected wire's exact size as the fixture
       descriptor boundary; both presentations share it and the producer is
       not rerun. The default descriptor trial above remains unchanged. *)
    let model_projection = Tool_output.Store_above { threshold_bytes = String.length selected_wire } in
    record_provider_trial ~base_path ~model_projection ~scenario:"partial_unknown_effect_marker_boundary"
      ~task ~expected original projected;
    let boundary = match !provider_trial_corpus with
      | trial :: _ -> trial | [] -> fail "boundary trial was not captured" in
    let previous_root = match boundary |> member "previous_selected_content" |> to_string
        |> Tool_output.decode_from_agent_core with
      | Tool_output.Decoded reference -> reference
      | Tool_output.Not_marker -> fail "previous presentation did not cross the same descriptor ceiling"
      | Tool_output.Invalid_marker { detail } -> fail detail in
    check bool "same ceiling leaves the selected result immediately readable" false
      (boundary |> member "selected_content" |> to_string |> Tool_output.is_marker);
    let root_page = boundary |> member "pages" |> to_list |> List.find_opt (fun page ->
        let args = member "args" page in
        (args |> member "sha256" |> to_string) = previous_root.sha256
        && (args |> member "offset" |> to_int) = 0) in
    (match root_page with
     | Some captured ->
       let execution, observation = Masc.Keeper_artifact_read.handle_with_page
           ~base_path ~args:(member "args" captured) in
       (match observation, execution.Masc.Keeper_tool_execution.data with
        | Some page, Some data ->
          check string "reader replay resolves the exact previous root" previous_root.sha256 page.sha256;
          let replay = provider_content ~base_path (completed ~tool_name:"keeper_artifact_read" ~data) in
          check string "captured root page replays the real reader response"
            (member "content" captured |> to_string) replay
        | None, _ | Some _, None -> fail "real reader replay could not retrieve the previous root")
     | None -> fail "previous marker root cannot be replayed through the captured artifact reader");
    check int "presentation and root-page capture never replay the producer"
      dispatched_before_presentations !dispatches;
    Printf.printf "composition_provider_trial_root_capture previous_marker=true selected_inline=true root_page_captured=true producer_dispatches=%d projection_ceiling_bytes=%d\n%!"
      !dispatches (Tool_output.inline_ceiling_bytes model_projection)
;;

let run_exported_read ~base_path ?(pointer = "/path") ?(retained = []) () =
  let plan = exported_read_fixture ~pointer () in
  let dispatch ?launch_replay:_ ~tool_use_id:_ ~node ~descriptor:_ ~schedule:_ ~input:_ () =
    completed ~tool_name:node.Plan.tool_name ~data:read_export_data
    |> Tool_result.with_retained_artifacts retained
    |> Executor.dispatch_result
  in
  let execution = Executor.execute ~plan ~run_id:(Plan.Run_id.fresh ()) ~dispatch () in
  let original = Masc.Keeper_tool_composition_surface.For_testing.result_of_execution
      ~tool_name:"keeper_compose_export-fixture" ~tool_kind:Descriptor.Composition_tool
      ~start_time:(Tool_timing.start ()) execution in
  let projected = project_export ~base_path ~plan ~execution original in
  execution, original, projected
;;

let execution_reference result =
  let json = Yojson.Safe.Util.(Tool_result.data result |> member "execution_artifact") in
  match Tool_output.normalized_artifact_ref_of_json json with
  | Tool_output.Decoded_normalized_artifact_ref reference -> reference
  | Tool_output.Not_normalized_artifact_ref | Tool_output.Invalid_normalized_artifact_ref _ ->
    fail "missing execution artifact"
;;

let test_large_export_keeps_existing_externalization () =
  Eio_main.run @@ fun _env ->
  with_export_base @@ fun base_path ->
  let _, _, projected = run_exported_read ~base_path ~pointer:"/content" () in
  let wire = provider_content ~base_path projected in
  match Tool_output.decode_from_agent_core wire with
  | Tool_output.Decoded reference ->
    check string "large export uses existing manifest transport"
      Tool_output.artifact_manifest_mime reference.mime;
    let stored = execution_document ~base_path reference in
    check int "large selected value remains exact in durable result" 16384
      Yojson.Safe.Util.(stored |> member "exports" |> member "path" |> member "value" |> to_string |> String.length)
  | Tool_output.Not_marker -> fail "large export bypassed its typed projection ceiling"
  | Tool_output.Invalid_marker { detail } -> fail detail
;;

let save_export_evidence config ~execution result =
  let source_id = Skill_source_config.source_id_of_string "workspace" |> Result.get_ok in
  let package_id = Skill_catalog_snapshot.package_id_of_directory "export-fixture" |> Result.get_ok in
  let reference = Skill_reference.make
      ~identity:(Skill_reference.make_identity ~source_id ~package_id ~name:"export-fixture")
      ~content_revision:(Skill_reference.content_revision_of_string (String.make 64 'a') |> Result.get_ok) in
  let parent_invocation = Agent_core.Tool_contract.Invocation.create
      ~tool_use_id:"export-fixture" ~turn:1
      ~schedule:{ planned_index = 0; batch_index = 0; batch_size = 1
                ; execution_mode = Agent_core.Tool_contract.Serial }
      ~completion:Agent_core.Tool_contract.Continue_after_success in
  let settlements = match execution with
    | Ok nodes -> nodes
    | Error (failure : Executor.failure) -> failure.settled in
  let module Evidence = Masc.Keeper_skill_composition_evidence in
  match Evidence.make ~reference ~composition_run_id:(Plan.Composition_run_id.fresh ())
          ~parent_invocation ~request_id:None ~keeper_name:"alpha"
          ~composition_tool:"keeper_compose_export-fixture"
          ~composition_execution:Masc.Keeper_tool_composition_catalog.Inline
          ~result ~executor_settlements:(List.map Masc.Keeper_tool_composition_surface.For_testing.node_result_to_json settlements) with
  | Error error -> fail (Evidence.error_to_string error)
  | Ok evidence ->
    (match Evidence.save_latest config evidence with
     | Ok Evidence.Saved -> ()
     | Ok (Evidence.Saved_with_lock_release_error _) -> fail "evidence lock release failed"
     | Error error -> fail (Evidence.error_to_string error))
;;

let save_async_export ~base_path result =
  let module Async = Masc.Keeper_msg_async in
  let request_id = "composition-export-request" in
  let entry : Async.entry =
    { request_id; keeper_name = "alpha"; base_path; submitted_by = "alpha"
    ; request_context = None; submitted_at = 1.; completed_at = Some 2.
    ; status = Async.Done { ok = true; body = Tool_result.message result
                           ; data = Some (Tool_result.data result) } } in
  (match Async.For_testing.persist_terminal_record entry with
   | Ok () -> ()
   | Error error -> fail error);
  request_id
;;

let check_export_retention ~base_path ~child result =
  let store = Tool_blob_store.create ~base_path in
  let dead = Tool_blob_store.put_durable store ~bytes:"unowned export artifact" ~mime:"text/plain" in
  let maintain mode =
    match Tool_blob_maintenance.run ~base_path
            ~board_posts_file:Masc_board_handlers.Board_paths.posts_file ~mode with
    | Ok report -> report
    | Error error -> fail (Tool_blob_maintenance.error_to_string error) in
  ignore (maintain Tool_blob_maintenance.Observe_only);
  ignore (maintain Tool_blob_maintenance.Delete_previous_candidates);
  let reference = execution_reference result in
  ignore (execution_document ~base_path reference);
  check (option string) "intermediate retained child survives two offline passes"
    (Some "intermediate child") (Tool_blob_store.fetch store ~sha256:child.Tool_output.sha256 |> Result.get_ok);
  check (option string) "unowned artifact is actually collected" None
    (Tool_blob_store.fetch store ~sha256:dead.sha256 |> Result.get_ok)
;;

let test_export_evidence_is_independent_retention_owner () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  with_export_base @@ fun base_path ->
  let config = Masc.Workspace.default_config base_path in
  let child = Tool_blob_store.put_durable (Tool_blob_store.create ~base_path)
      ~bytes:"intermediate child" ~mime:"text/plain" in
  let execution, _, projected = run_exported_read ~base_path ~retained:[ child ] () in
  save_export_evidence config ~execution projected;
  (* There is no Keeper checkpoint or tool-call row: Skill evidence owns this run. *)
  check_export_retention ~base_path ~child projected
;;

let test_async_export_status_and_retention () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  with_export_base @@ fun base_path ->
  let config = Masc.Workspace.default_config base_path in
  let child = Tool_blob_store.put_durable (Tool_blob_store.create ~base_path)
      ~bytes:"intermediate child" ~mime:"text/plain" in
  let _, _, projected = run_exported_read ~base_path ~retained:[ child ] () in
  let request_id = save_async_export ~base_path projected in
  (* The terminal request is the sole durable owner before status retrieval. *)
  check_export_retention ~base_path ~child projected;
  let meta = Masc_test_deps.meta_of_json_fixture
      (`Assoc [ "name", `String "alpha"; "activation_mode", `String "manual" ]) |> Result.get_ok in
  let status = Masc.Keeper_tool_composition_surface.For_testing.status_result ~config ~meta ~request_id in
  let wire = provider_content ~base_path status |> Yojson.Safe.from_string in
  let open Yojson.Safe.Util in
  let data = wire |> member "structured_content" in
  check string "async status is immediately readable" "done" (data |> member "status" |> to_string);
  check string "async export survives status and provider boundaries" "probe.txt"
    (data |> member "result" |> member "exports" |> member "path" |> member "value" |> to_string);
  check bool "status wire preserves its durable root" true (wire |> member "artifact_manifest" <> `Null)
;;

let test_export_storage_failure_does_not_advertise_result () =
  Eio_main.run @@ fun _env ->
  let base_path = Filename.temp_file "masc-composition-invalid-base-" "" in
  Fun.protect ~finally:(fun () -> Sys.remove base_path) @@ fun () ->
  let plan = exported_read_fixture () in
  let calls = ref 0 in
  let dispatch ?launch_replay:_ ~tool_use_id:_ ~node ~descriptor:_ ~schedule:_ ~input:_ () =
    incr calls;
    Executor.dispatch_result (completed ~tool_name:node.Plan.tool_name ~data:read_export_data)
  in
  let execution = Executor.execute ~plan ~run_id:(Plan.Run_id.fresh ()) ~dispatch () in
  let original = Masc.Keeper_tool_composition_surface.For_testing.result_of_execution
      ~tool_name:"keeper_compose_storage-fixture" ~tool_kind:Descriptor.Composition_tool
      ~start_time:(Tool_timing.start ()) execution in
  (match Masc.Keeper_composition_result.project ~base_path ~plan ~execution original with
   | Error { Tool_bridge.kind = Tool_bridge.Artifact_storage_failure; _ } -> ()
   | Error _ | Ok _ -> fail "failed storage advertised a successful export");
  check int "storage failure does not replay tool effects" 1 !calls
;;


(* These native compiler operands are not Skill admission fixtures. Public
   async-child syntax stays refused until the real producer/owner bridge lands. *)
let compiled_node ~id ~tool_name input =
  Plan.node ~id:(node_id id) ~tool_name ~input ()

let compiled_child_fixture () =
  let require label = function Ok x -> x | Error _ -> fail label in
  let reference name revision = Skill_reference.of_yojson (`Assoc
    ["identity",`Assoc ["source_id",`String "fixture";"package_id",`String name;"name",`String name];
     "content_revision",`String (String.make 64 revision)]) |> require "exact child identity" in
  let bound tool field =
    let producer = compiled_node ~id:"producer" ~tool_name:tool (Plan.Json_template.literal (`Assoc [])) in
    Plan.create ~descriptors:(Descriptor.all_descriptors ())
      ~exports:[Plan.export ~name:"answer" ~node_id:producer.id ~pointer:(export_pointer field)] [producer]
    |> require "validated bound child export" in
  let schema = `Assoc ["type",`String "object";"properties",`Assoc
      ["_blob",`Assoc ["type",`String "string"]];"additionalProperties",`Bool false] in
  let make alias revision tool field =
    let child = Plan.fixed_async_child ~alias:(node_id alias) ~reference:(reference alias revision)
        ~tool_name:("keeper_composition_" ^ alias) ~args:(`Assoc []) ~input_schema:schema
        ~bound_plan:(bound tool field) in
    Plan.child_nodes ~child ~submission_id:(node_id (alias ^ "-submit"))
      ~result_id:(node_id (alias ^ "-result")) () in
  let text = make "text" 'a' "keeper_lane_status" "/profile" in
  let integer = make "integer" 'b' "masc_board_stats" "/post_count" in
  let children = [text;integer] in
  let nodes = List.concat_map (fun (child : Plan.child_nodes) -> [child.submission;child.result]) children in
  let plan = Plan.create_compiled ~descriptors:(Descriptor.all_descriptors ()) ~children nodes
      |> require "native compiled parent" in
  plan,children,nodes

let test_compiled_child_node_contracts () =
  let plan,children,_ = compiled_child_fixture () in
  let text,integer = match children with [a;b] -> a,b | _ -> fail "two children" in
  check string "both result nodes use the canonical result name" text.result.tool_name integer.result.tool_name;
  let run_id = Plan.Run_id.fresh () in
  let valid id value = match Plan.validate_output plan ~run_id ~node_id:id value with
    | Ok _ -> () | Error _ -> fail "declared selected export was rejected" in
  let invalid id value = match Plan.validate_output plan ~run_id ~node_id:id value with
    | Error (Plan.Output_validation_failed _) -> () | Error _ | Ok _ -> fail "another child's export schema was borrowed" in
  valid text.result.id (`Assoc ["answer",`String "text"]);
  valid integer.result.id (`Assoc ["answer",`Int 7]);
  invalid text.result.id (`Assoc ["answer",`Int 7]);
  invalid integer.result.id (`Assoc ["answer",`String "text"]);
  List.iter (fun (child : Plan.child_nodes) ->
    check bool "compiled result has no fabricated descriptor" true (Plan.descriptor plan child.result.id = None);
    check bool "effectful submission is not readonly" true
      (Plan.readonly_for_input plan ~node_id:child.submission.id ~input:(`Assoc []) = Some false);
    check bool "canonical result observation is readonly" true
      (Plan.readonly_for_input plan ~node_id:child.result.id ~input:(`Assoc []) = Some true)) children;
  List.iter (function
    | Executor.Serial_batch scheduled ->
      (match scheduled.contract.target with Plan.Child_submission _ -> ()
       | Plan.Child_arguments _ | Plan.Child_result _ | Plan.Descriptor_target _ -> fail "result barrier acquired Serial lifetime")
    | Executor.Concurrent_batch scheduled -> List.iter (fun (scheduled : Executor.scheduled_node) ->
        match scheduled.contract.target with Plan.Child_result _ -> ()
        | Plan.Child_arguments _ | Plan.Child_submission _ | Plan.Descriptor_target _ -> fail "submission was scheduled concurrently") scheduled)
    (Executor.schedule plan)

let test_compiled_child_operand_identity () =
  let _,children,nodes = compiled_child_fixture () in
  let original = List.hd children in
  let changed = Plan.node ~id:original.submission.id ~tool_name:original.submission.tool_name
      ~input:(Plan.Json_template.literal (`Assoc ["changed",`Bool true])) () in
  let altered = List.map (fun (n : Plan.node) -> if Plan.Node_id.equal n.id changed.id then changed else n) nodes in
  (match Plan.create_compiled ~descriptors:(Descriptor.all_descriptors ()) ~children altered with
   | Error (Plan.Compiled_child_conflict id) -> check string "changed fixed node refused" (Plan.Node_id.to_string changed.id) (Plan.Node_id.to_string id)
   | Error _ | Ok _ -> fail "altered child acquired original compiler authority");
  let duplicate = Plan.child_nodes ~child:original.child ~submission_id:(node_id "duplicate-submit")
      ~result_id:(node_id "duplicate-result") () in
  (match Plan.create_compiled ~descriptors:(Descriptor.all_descriptors ()) ~children:(duplicate::children)
      (duplicate.submission::duplicate.result::nodes) with
   | Error (Plan.Compiled_child_conflict _) -> () | Error _ | Ok _ -> fail "duplicate logical child alias admitted");
  (match Plan.create ~descriptors:(Descriptor.all_descriptors ()) nodes with
   | Error (Plan.Unknown_tool _) -> () | Error _ | Ok _ -> fail "plain node copied a native child route by name")

let test_compiled_child_owned_encoding () =
  let module Request = Masc.Keeper_tool_plan_request in
  let plan,_,_ = compiled_child_fixture () in
  let encoded = Request.to_yojson plan |> function Ok json -> json | Error _ -> fail "compiled evidence encoding" in
  (match Request.plan_of_json ~descriptors:(Descriptor.all_descriptors ()) encoded with
   | Error _ -> () | Ok _ -> fail "model JSON reconstructed native compiler authority");
  let encoded_nodes = Yojson.Safe.Util.(encoded |> member "nodes" |> to_list) in
  let operands = List.map (fun n -> Yojson.Safe.Util.member "compiled_child" n) encoded_nodes in
  check bool "compiled route evidence contains fixed child plans" true
    (List.for_all (fun operand -> Yojson.Safe.Util.member "declared_plan" operand <> `Null) operands);
  let contracts = Request.contracts_to_yojson plan |> function Ok json -> json | Error _ -> fail "child contract freeze" in
  check bool "schema definitions do not create artifact references" true
    (match Tool_output.normalized_artifact_refs_in_json_strict (`List [encoded;contracts]) with
     | Ok [] -> true | Ok (_::_) | Error _ -> false)

let test_compiled_child_requires_parent_occurrence () =
  Eio_main.run @@ fun _ ->
  let _,children,nodes = compiled_child_fixture () in
  let sibling = compiled_node ~id:"independent" ~tool_name:"keeper_lane_status" (Plan.Json_template.literal (`Assoc [])) in
  let plan = match Plan.create_compiled ~descriptors:(Descriptor.all_descriptors ()) ~children
      ~branch_failure_policy:Plan.Continue_independent (nodes @ [sibling]) with
    | Ok p -> p | Error _ -> fail "independent compiled sibling" in
  let ordinary = ref [] and compiled = ref 0 in
  let dispatch ?launch_replay:_ ~tool_use_id:_ ~(node : Plan.node) ~descriptor:_ ~schedule:_ ~input:_ () =
    ordinary := Plan.Node_id.to_string node.id :: !ordinary;
    Executor.dispatch_result (completed ~tool_name:node.tool_name ~data:(`Assoc
      ["profile",`String "fixture";"lane",`Null;"endpoint",`Null;"probe",`Null;"last_dispatch",`Null;"operator_action",`Null])) in
  let dispatch_compiled ~attempt:_ ~target:_ ~tool_use_id:_ ~node:_ ~schedule:_ ~input:_ =
    incr compiled; fail "unowned child producer entered" in
  let result = Executor.execute ~plan ~run_id:(Plan.Run_id.fresh ()) ~dispatch ~dispatch_compiled () in
  (match result with
   | Error failure -> check bool "missing occurrence is pre-effect" true
       (failure.effect_disposition = Tool_result.Proven_pre_effect)
   | Ok _ -> fail "compiled child executed without canonical parent occurrence");
  check int "compiled producer is never entered without parent authority" 0 !compiled;
  check (list string) "independent ordinary work still progresses" ["independent"] !ordinary

let () =
  run ~and_exit:false
    "keeper_tool_plan_executor"
    [ ( "execution"
      , [ test_case "exports persist complete execution" `Quick test_export_success_preserves_durable_original
        ; test_case "partial exports preserve unknown failures" `Quick test_export_failure_preserves_independent_branch
        ; test_case "large selected exports keep manifest transport" `Quick test_large_export_keeps_existing_externalization
        ; test_case "Skill evidence retains execution and child artifacts" `Quick test_export_evidence_is_independent_retention_owner
        ; test_case "async status carries exports and roots execution artifacts" `Quick test_async_export_status_and_retention
        ; test_case "export storage failure never replays" `Quick test_export_storage_failure_does_not_advertise_result
        ; test_case "reused plan keeps execution owners after interruption and refusal" `Quick
            test_reused_plan_keeps_each_execution_owner_after_interruption_and_failure
        ; test_case "unordered graph retains typed dataflow and Serial order" `Quick
            (test_unordered_graph_preserves_execution ~fail_serial:false)
        ; test_case "unordered graph keeps independent typed work after Serial refusal" `Quick
            (test_unordered_graph_preserves_execution ~fail_serial:true)
        ; test_case "parallel dataflow schedule" `Quick test_schedule_and_parallel_dataflow
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
            (test_deferred_cause_does_not_mask_unknown_sibling ~observation_failure:false)
        ; Alcotest.test_case
            "deferred cause retains a higher completed sibling observation failure"
            `Quick
            (test_deferred_cause_does_not_mask_unknown_sibling ~observation_failure:true)
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
    ; ( "compiled child contracts"
      , [ test_case "child export schemas and short scheduling modes" `Quick test_compiled_child_node_contracts
        ; test_case "fixed operand cannot be altered or copied by name" `Quick test_compiled_child_operand_identity
        ; test_case "owned encoding does not grant model compiler authority" `Quick test_compiled_child_owned_encoding
        ; test_case "parent occurrence required before compiled producer" `Quick test_compiled_child_requires_parent_occurrence ] )
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
 ;
  Option.iter (fun measurement -> Printf.printf "composition_export_measurement=%s\n%!" (Yojson.Safe.to_string measurement)) !export_measurement;
  Printf.printf "composition_provider_trial_corpus=%s\n%!"
    (Yojson.Safe.to_string (`Assoc [ "schema_version", `Int 1
      ; "scope", `String "fixture producer, production executor/projection/reader and OpenAI tool-result serialization; no live Keeper or model execution"
      ; "scenarios", `List (List.rev !provider_trial_corpus) ]))
;;
