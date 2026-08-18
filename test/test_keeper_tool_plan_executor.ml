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
  let producer = canonical_descriptor "keeper_time_now" in
  let parallel = canonical_descriptor "masc_board_stats" in
  let final = canonical_descriptor "keeper_tools_list" in
  let producer_node =
    Plan.node
      ~id:(node_id "producer")
      ~tool_name:"keeper_time_now"
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
  Tool_result.make_ok ~tool_name ~start_time:0.0 ~data ()
;;

let node_name node = Plan.Node_id.to_string node.Plan.id

let valid_data_for_node node =
  match node_name node with
  | "producer" -> `Assoc [ "now_iso", `String "2026-08-14T00:00:00Z"; "now_unix", `Float 0.0 ]
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
           ~start_time:0.0
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

let test_deferred_cause_does_not_mask_unknown_sibling () =
  Eio_main.run @@ fun _env ->
  let plan = fixture () in
  let dispatch ~tool_use_id:_ ~node ~descriptor:_ ~schedule:_ ~input:_ =
    match node_name node with
    | "left" ->
      Executor.dispatch_result
        ~deferred_kind:Masc.Keeper_tool_execution.Generic_deferred
        (Tool_result.make_deferred ~tool_name:"left" ~start_time:0.0 ())
    | "right" ->
      Executor.dispatch_result
        ~failure_effect_disposition:Tool_result.Effect_outcome_unknown
        (Tool_result.make_err
           ~tool_name:"right"
           ~class_:Tool_result.Runtime_failure
           ~start_time:0.0
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
      (completed ~tool_name:node.tool_name ~data:(`Assoc [ "now_iso", `Int 7 ]))
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
            "observation failure settles siblings and stops downstream"
            `Quick
            test_observation_failure_settles_siblings_and_stops_downstream
        ; test_case
            "dispatch exception preserves pre-minted identity"
            `Quick
            test_dispatch_exception_preserves_pre_minted_tool_identity
        ; test_case
            "deferred cause does not mask unknown sibling"
            `Quick
            test_deferred_cause_does_not_mask_unknown_sibling
        ; test_case
            "malformed producer stops consumers"
            `Quick
            test_malformed_declared_output_stops_before_consumer
        ; test_case
            "outer completion owns terminal boundary"
            `Quick
            test_outer_completion_owns_terminal_boundary
        ] )
    ]
;;
