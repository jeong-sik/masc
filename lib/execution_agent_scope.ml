module Event = Execution_event
module Journal = Execution_journal
module Settlement = Execution_tool_settlement
module Writer = Execution_lane_writer
module Tx = Journal.Transaction
module Json = Execution_json

type t =
  { writer : Writer.t
  ; run : Journal.run
  }

type turn =
  { scope : t
  ; node : Event.Node_id.t
  ; ordinal : int
  }

type provider_attempt =
  { turn : turn
  ; node : Event.Node_id.t
  }

type scope_locator = { run_id : Event.Run_id.t }

type invocation_locator =
  { run_id : Event.Run_id.t
  ; node : Event.Node_id.t
  }

type invocation =
  { durable : Settlement.durable_invocation
  ; locator : invocation_locator
  ; scope : t
  }

type invocation_authority =
  { invocation : Tool_contract.Invocation.t
  ; tool_name : string
  ; input : Yojson.Safe.t
  }

type settled_invocation =
  { authority : invocation_authority
  ; result : Llm_provider.Types.content_block
  }

type tool_result =
  { invocation : Tool_contract.Invocation.t
  ; tool_name : string
  ; input : Yojson.Safe.t
  ; content : string
  ; outcome : Llm_provider.Types.tool_result_outcome
  }

type execution =
  | Executed of tool_result * Journal.cursor * int
  | Replayed of tool_result

type invocation_progress =
  | Invocation_unattempted
  | Invocation_attempted_or_settled

type abort_reason =
  | Failed of Event.failure
  | Cancelled of
      { reason : string option
      ; data : Yojson.Safe.t option
      }

type operator_repair_reason = Effect_outcome_unknown

type recovery_action =
  | Retire
  | Operator_repair_required of operator_repair_reason

type turn_resume =
  | Resume_turn_absent
  | Resume_turn_open of turn
  | Resume_turn_settled of turn

type provider_resume =
  | Resume_provider_absent
  | Resume_provider_open of provider_attempt
  | Resume_provider_settled of provider_attempt

type error =
  | Admission_failed of Writer.submit_error
  | Mutation_failed of Writer.ticket_error
  | Invalid_provider_attempt of string
  | Scope_unavailable of Writer.read_error
  | Run_not_found
  | Agent_identity_mismatch of
      { expected : string
      ; actual : string
      }
  | Invocation_locator_mismatch
  | Resume_topology_mismatch of string
  | Invalid_tool_result
  | Settlement_failed of Settlement.error

let settlement_error_to_string = function
  | Settlement.Authority_unavailable error -> Writer.read_error_to_string error
  | Settlement.Invocation_not_found -> "execution invocation was not found"
  | Settlement.Invocation_identity_mismatch ->
    "execution invocation identity does not match its durable topology"
  | Settlement.Effect_outcome_unknown -> "tool effect outcome is unknown"
  | Settlement.Attempt_admission_failed error -> Writer.submit_error_to_string error
  | Settlement.Attempt_commit_failed error -> Writer.ticket_error_to_string error
  | Settlement.Receipt_admission_outcome_unknown error ->
    Writer.submit_error_to_string error
  | Settlement.Receipt_settlement_outcome_unknown error ->
    Writer.ticket_error_to_string error
;;

let error_to_string = function
  | Admission_failed error -> Writer.submit_error_to_string error
  | Mutation_failed error -> Writer.ticket_error_to_string error
  | Invalid_provider_attempt detail -> "invalid provider attempt: " ^ detail
  | Scope_unavailable error -> Writer.read_error_to_string error
  | Run_not_found -> "execution run was not found"
  | Agent_identity_mismatch { expected; actual } ->
    Printf.sprintf
      "execution run belongs to agent %S but caller supplied %S"
      expected
      actual
  | Invocation_locator_mismatch ->
    "execution invocation locator does not match durable topology"
  | Resume_topology_mismatch detail -> "execution resume topology mismatch: " ^ detail
  | Invalid_tool_result -> "execution settlement returned an invalid ToolResult"
  | Settlement_failed error -> settlement_error_to_string error
;;

let locator_version = 1

let require_locator_version fields =
  match Json.int_field "version" fields with
  | Ok version when version = locator_version -> Ok ()
  | Ok version ->
    Error (Printf.sprintf "unsupported execution locator version %d" version)
  | Error _ as error -> error
;;

let scope_locator scope = { run_id = Journal.run_id scope.run }
let scope_locator_run_id (locator : scope_locator) = locator.run_id

let scope_locator_to_yojson (locator : scope_locator) =
  `Assoc
    [ "version", `Int locator_version
    ; "run_id", `String (Event.Run_id.to_string locator.run_id)
    ]
;;

let scope_locator_of_yojson json =
  let open Result_syntax in
  let* fields =
    Json.object_fields
      ~context:"execution scope locator"
      ~required:[ "version"; "run_id" ]
      ~optional:[]
      json
  in
  let* () = require_locator_version fields in
  let* run_id = Json.string_field "run_id" fields in
  let+ run_id = Event.Run_id.of_string run_id in
  { run_id }
;;

let invocation_locator_to_yojson (locator : invocation_locator) =
  `Assoc
    [ "version", `Int locator_version
    ; "run_id", `String (Event.Run_id.to_string locator.run_id)
    ; "node_id", `String (Event.Node_id.to_string locator.node)
    ]
;;

let invocation_locator_of_yojson json =
  let open Result_syntax in
  let* fields =
    Json.object_fields
      ~context:"execution invocation locator"
      ~required:[ "version"; "run_id"; "node_id" ]
      ~optional:[]
      json
  in
  let* () = require_locator_version fields in
  let* run_id_text = Json.string_field "run_id" fields in
  let* run_id = Event.Run_id.of_string run_id_text in
  let* node_text = Json.string_field "node_id" fields in
  let+ node = Event.Node_id.of_string node_text in
  { run_id; node }
;;

let transact writer transaction =
  Eio.Fiber.check ();
  match Writer.submit writer transaction with
  | Error error -> Error (Admission_failed error)
  | Ok ticket ->
    (match Eio.Cancel.protect (fun () -> Writer.await ticket) with
     | Error error -> Error (Mutation_failed error)
     | Ok receipt -> Ok receipt.value)
;;

let transact_cleanup writer transaction =
  Eio.Cancel.protect (fun () ->
    match Writer.submit writer transaction with
    | Error error -> Error (Admission_failed error)
    | Ok ticket ->
      (match Writer.await ticket with
       | Error error -> Error (Mutation_failed error)
       | Ok receipt -> Ok receipt.value))
;;

let start ~writer ~agent_name =
  transact writer (Tx.start_run ~agent_name ())
  |> Result.map (fun (run, _event) -> { writer; run })
;;

let resume ~writer ~agent_name (locator : scope_locator) =
  match Writer.find_run writer locator.run_id with
  | Error error -> Error (Scope_unavailable error)
  | Ok None -> Error Run_not_found
  | Ok (Some view) ->
    (match Event.node_kind view.Journal.opened.value with
     | Event.Agent_run { agent_name = durable_agent_name }
       when String.equal agent_name durable_agent_name ->
       Ok { writer; run = view.Journal.run }
     | Event.Agent_run { agent_name = durable_agent_name } ->
       Error
         (Agent_identity_mismatch { expected = durable_agent_name; actual = agent_name })
     | Event.Agent_turn _
     | Event.Provider_attempt _
     | Event.Output_block _
     | Event.Tool_invocation _
     | Event.Tool_attempt -> Error Run_not_found)
;;

let resume_running ~writer ~agent_name locator =
  match resume ~writer ~agent_name locator with
  | Error _ as error -> error
  | Ok scope ->
    (match Writer.find_run writer locator.run_id with
     | Error error -> Error (Scope_unavailable error)
     | Ok (Some { status = Journal.Running; _ }) -> Ok scope
     | Ok (Some { status = Journal.Finished _; _ }) ->
       Error (Resume_topology_mismatch "execution run is already terminal")
     | Ok None -> Error Run_not_found)
;;

let open_turn scope ~ordinal =
  transact
    scope.writer
    (Tx.open_node
       ~run:scope.run
       ~parent:(Journal.run_root scope.run)
       ~kind:(Event.Agent_turn { ordinal })
       ())
  |> Result.map (fun (node, _event) -> { scope; node; ordinal })
;;

let turn_ordinal turn = turn.ordinal

let resume_turn scope ~ordinal =
  match Writer.find_node scope.writer (Journal.run_root scope.run) with
  | Error error -> Error (Scope_unavailable error)
  | Ok None -> Error Run_not_found
  | Ok (Some root) ->
    let matching =
      List.filter_map
        (fun (child : Event.node Journal.event_record) ->
           match Event.node_kind child.value with
           | Event.Agent_turn { ordinal = existing } when existing = ordinal ->
             Some (Event.node_id child.value)
           | Event.Agent_run _
           | Event.Agent_turn _
           | Event.Provider_attempt _
           | Event.Output_block _
           | Event.Tool_invocation _
           | Event.Tool_attempt -> None)
        root.children
    in
    (match matching with
     | [] -> Ok Resume_turn_absent
     | [ node ] ->
       (match Writer.find_node scope.writer node with
        | Error error -> Error (Scope_unavailable error)
        | Ok None -> Error (Resume_topology_mismatch "turn child disappeared")
        | Ok (Some { status = Journal.Open; _ }) ->
          Ok (Resume_turn_open { scope; node; ordinal })
        (* Idempotent completed boundary: a turn already closed [Succeeded] under a
           still-[Running] root is a crash after [close_turn] but before the root
           [finish] (or after the provider close but before this turn's close, once
           the caller finishes that close). Its whole subtree is settled (the
           journal rejects closing a node with open children), so resume surfaces
           the settled outcome instead of aborting the root as Failed. *)
        | Ok (Some { status = Journal.Closed { value = Event.Succeeded; _ }; _ }) ->
          Ok (Resume_turn_settled { scope; node; ordinal })
        | Ok
            (Some
               { status = Journal.Closed { value = Event.Failed _ | Event.Cancelled _; _ }
               ; _
               }) -> Error (Resume_topology_mismatch "requested turn is already closed"))
     | _ :: _ :: _ -> Error (Resume_topology_mismatch "duplicate turn ordinal"))
;;

let resume_current_turn scope =
  match Writer.find_node scope.writer (Journal.run_root scope.run) with
  | Error error -> Error (Scope_unavailable error)
  | Ok None -> Error Run_not_found
  | Ok (Some root) ->
    let turn_children =
      List.filter_map
        (fun (child : Event.node Journal.event_record) ->
           match Event.node_kind child.value with
           | Event.Agent_turn { ordinal } -> Some (Event.node_id child.value, ordinal)
           | Event.Agent_run _
           | Event.Provider_attempt _
           | Event.Output_block _
           | Event.Tool_invocation _
           | Event.Tool_attempt -> None)
        root.children
    in
    (* Resolve every turn child's live status once. The turn identity (ordinal) is
       owned by the durable topology, never reconstructed from mutable agent state:
       an in-progress turn is the single [Open] child; a crash-settled boundary is
       the highest-ordinal [Closed] child (the frontier). *)
    let rec resolve ~open_acc ~closed_acc = function
      | [] -> Ok (open_acc, closed_acc)
      | (node, ordinal) :: rest ->
        (match Writer.find_node scope.writer node with
         | Error error -> Error (Scope_unavailable error)
         | Ok None -> Error (Resume_topology_mismatch "turn child disappeared")
         | Ok (Some { status = Journal.Open; _ }) ->
           resolve ~open_acc:({ scope; node; ordinal } :: open_acc) ~closed_acc rest
         | Ok (Some { status = Journal.Closed { value; _ }; _ }) ->
           resolve
             ~open_acc
             ~closed_acc:(({ scope; node; ordinal }, value) :: closed_acc)
             rest)
    in
    (match resolve ~open_acc:[] ~closed_acc:[] turn_children with
     | Error _ as error -> error
     | Ok (open_turns, closed_turns) ->
       (match open_turns with
        | _ :: _ :: _ -> Error (Resume_topology_mismatch "multiple open agent turns")
        | [ turn ] -> Ok (Resume_turn_open turn)
        | [] ->
          (* No turn is still open: classify the highest-ordinal turn, the crash
             frontier. A [Closed Succeeded] frontier is the idempotent completed
             boundary (#2683) resume replays instead of aborting the root Failed; a
             [Closed Failed]/[Cancelled] frontier stays a fail-closed error; and no
             turns at all is a genuinely fresh resume. *)
          (match closed_turns with
           | [] -> Ok Resume_turn_absent
           | first :: rest ->
             let frontier_turn, frontier_value =
               List.fold_left
                 (fun (best_turn, best_value) (turn, value) ->
                    if turn.ordinal >= best_turn.ordinal
                    then turn, value
                    else best_turn, best_value)
                 first
                 rest
             in
             (match frontier_value with
              | Event.Succeeded -> Ok (Resume_turn_settled frontier_turn)
              | Event.Failed _ | Event.Cancelled _ ->
                Error (Resume_topology_mismatch "requested turn is already closed")))))
;;

let open_provider_attempt turn ~ordinal binding =
  match Event.provider_attempt ~ordinal binding with
  | Error detail -> Error (Invalid_provider_attempt detail)
  | Ok kind ->
    transact
      turn.scope.writer
      (Tx.open_node ~run:turn.scope.run ~parent:turn.node ~kind ())
    |> Result.map (fun (node, _event) -> { turn; node })
;;

let resume_provider_attempt (turn : turn) =
  match Writer.find_node turn.scope.writer turn.node with
  | Error error -> Error (Scope_unavailable error)
  | Ok None -> Error (Resume_topology_mismatch "turn node disappeared")
  | Ok (Some view) ->
    let providers =
      List.filter_map
        (fun (child : Event.node Journal.event_record) ->
           match Event.node_kind child.value with
           | Event.Provider_attempt _ -> Some (Event.node_id child.value)
           | Event.Agent_run _
           | Event.Agent_turn _
           | Event.Output_block _
           | Event.Tool_invocation _
           | Event.Tool_attempt -> None)
        view.children
    in
    (match providers with
     | [] -> Ok Resume_provider_absent
     | [ node ] ->
       (match Writer.find_node turn.scope.writer node with
        | Error error -> Error (Scope_unavailable error)
        | Ok None -> Error (Resume_topology_mismatch "provider child disappeared")
        | Ok (Some { status = Journal.Open; _ }) ->
          Ok (Resume_provider_open { turn; node })
        (* Idempotent completed boundary: a provider attempt already closed
           [Succeeded] under a still-open turn is a crash inside [close_success]
           between the provider close and the turn close. Its invocations are
           settled (the journal rejects closing a node with open children), so the
           caller finishes the interrupted turn close and surfaces the settled
           outcome instead of aborting the root as Failed. *)
        | Ok (Some { status = Journal.Closed { value = Event.Succeeded; _ }; _ }) ->
          Ok (Resume_provider_settled { turn; node })
        | Ok
            (Some
               { status = Journal.Closed { value = Event.Failed _ | Event.Cancelled _; _ }
               ; _
               }) ->
          Error (Resume_topology_mismatch "requested provider attempt is already closed"))
     | _ :: _ :: _ ->
       Error (Resume_topology_mismatch "multiple provider attempts remain open"))
;;

let open_invocation provider ~invocation ~tool_name ~input =
  let scope = provider.turn.scope in
  match
    transact
      scope.writer
      (Tx.open_tool_invocation
         ~run:scope.run
         ~provider_attempt:provider.node
         ~invocation
         ~tool_name
         ~input
         ())
  with
  | Error _ as error -> error
  | Ok (node, _events) ->
    let locator = { run_id = Journal.run_id scope.run; node } in
    Settlement.rebind ~writer:scope.writer ~invocation_node:node
    |> Result.map (fun durable -> { durable; locator; scope })
    |> Result.map_error (fun error -> Settlement_failed error)
;;

let invocation_locator invocation = invocation.locator

let rebind_invocation scope locator =
  if not (Event.Run_id.equal locator.run_id (Journal.run_id scope.run))
  then Error Invocation_locator_mismatch
  else (
    match Settlement.rebind ~writer:scope.writer ~invocation_node:locator.node with
    | Error error -> Error (Settlement_failed error)
    | Ok durable ->
      if Event.Run_id.equal durable.run_id locator.run_id
      then Ok { durable; locator; scope }
      else Error Invocation_locator_mismatch)
;;

let invocation_equal left right =
  String.equal
    (Tool_contract.Invocation.tool_use_id left)
    (Tool_contract.Invocation.tool_use_id right)
  && Tool_contract.Invocation.turn left = Tool_contract.Invocation.turn right
  && Execution_tool_schedule.equal
       (Tool_contract.Invocation.schedule left)
       (Tool_contract.Invocation.schedule right)
  && Tool_contract.Invocation.completion left = Tool_contract.Invocation.completion right
;;

let find_invocation provider ~invocation ~tool_name ~input =
  let scope = provider.turn.scope in
  match Writer.find_node scope.writer provider.node with
  | Error error -> Error (Scope_unavailable error)
  | Ok None -> Error (Resume_topology_mismatch "provider attempt disappeared")
  | Ok (Some view) ->
    let planned_index = Tool_contract.Invocation.planned_index invocation in
    let matching =
      List.filter_map
        (fun (child : Event.node Journal.event_record) ->
           match Event.node_kind child.value with
           | Event.Tool_invocation { schedule; _ }
             when schedule.planned_index = planned_index ->
             Some (Event.node_id child.value)
           | Event.Agent_run _
           | Event.Agent_turn _
           | Event.Provider_attempt _
           | Event.Output_block _
           | Event.Tool_invocation _
           | Event.Tool_attempt -> None)
        view.children
    in
    (match matching with
     | [] -> Ok None
     | [ node ] ->
       let locator = { run_id = Journal.run_id scope.run; node } in
       (match rebind_invocation scope locator with
        | Error _ as error -> error
        | Ok rebound
          when invocation_equal rebound.durable.invocation invocation
               && String.equal rebound.durable.tool_name tool_name
               && Yojson.Safe.equal rebound.durable.input input -> Ok (Some rebound)
        | Ok _ ->
          Error
            (Resume_topology_mismatch
               "tool occurrence identity differs from the restored Agent checkpoint"))
     | _ :: _ :: _ -> Error (Resume_topology_mismatch "duplicate tool occurrence"))
;;

let invocation_progress invocation =
  let scope = invocation.scope in
  match Writer.find_node scope.writer invocation.locator.node with
  | Error error -> Error (Scope_unavailable error)
  | Ok None -> Error (Resume_topology_mismatch "tool invocation disappeared")
  | Ok (Some view) ->
    (match view.materialized, view.children, view.status with
     | Journal.Tool_invocation_state { result = None; _ }, [], Journal.Open ->
       Ok Invocation_unattempted
     | Journal.Tool_invocation_state _, _, _ -> Ok Invocation_attempted_or_settled
     | ( ( Journal.Agent_run_state
         | Journal.Agent_turn_state
         | Journal.Provider_attempt_state _
         | Journal.Output_block_state _
         | Journal.Tool_attempt_state )
       , _
       , _ ) -> Error (Resume_topology_mismatch "invocation changed node kind"))
;;

let settle_unattempted_invocation invocation ~content ~outcome =
  let durable = invocation.durable in
  let result =
    Llm_provider.Types.ToolResult
      { tool_use_id = Tool_contract.Invocation.tool_use_id durable.invocation
      ; content
      ; outcome
      ; json = None
      ; content_blocks = None
      }
  in
  transact
    invocation.scope.writer
    (Tx.settle_unattempted_tool_invocation ~invocation:invocation.locator.node ~result ())
  |> Result.map (fun _events -> ())
;;

let provider_invocations provider =
  let scope = provider.turn.scope in
  match Writer.find_node scope.writer provider.node with
  | Error error -> Error (Scope_unavailable error)
  | Ok None -> Error (Resume_topology_mismatch "provider attempt disappeared")
  | Ok (Some view) ->
    let invocation_nodes =
      List.filter_map
        (fun (child : Event.node Journal.event_record) ->
           match Event.node_kind child.value with
           | Event.Tool_invocation _ -> Some (Event.node_id child.value)
           | Event.Agent_run _
           | Event.Agent_turn _
           | Event.Provider_attempt _
           | Event.Output_block _
           | Event.Tool_attempt -> None)
        view.children
    in
    let rec rebind_all acc = function
      | [] ->
        Ok
          (List.sort
             (fun (left : invocation_authority) (right : invocation_authority) ->
                Int.compare
                  (Tool_contract.Invocation.planned_index left.invocation)
                  (Tool_contract.Invocation.planned_index right.invocation))
             acc)
      | node :: rest ->
        let locator = { run_id = Journal.run_id scope.run; node } in
        (match rebind_invocation scope locator with
         | Error _ as error -> error
         | Ok invocation ->
           rebind_all
             ({ invocation = invocation.durable.invocation
              ; tool_name = invocation.durable.tool_name
              ; input = invocation.durable.input
              }
              :: acc)
             rest)
    in
    rebind_all [] invocation_nodes
;;

let validate_invocation_authority
      (authority : invocation_authority)
      ~turn
      ~planned_index
      ~tool_use_id
      ~tool_name
      ~input
  =
  let invocation = authority.invocation in
  let schedule = Tool_contract.Invocation.schedule invocation in
  match
    Execution_tool_schedule.validate_completion
      ~completion:(Tool_contract.Invocation.completion invocation)
      schedule
  with
  | Error error ->
    Error (Resume_topology_mismatch (Execution_tool_schedule.error_to_string error))
  | Ok () ->
    if
      Tool_contract.Invocation.turn invocation = turn
      && schedule.planned_index = planned_index
      && String.equal (Tool_contract.Invocation.tool_use_id invocation) tool_use_id
      && String.equal authority.tool_name tool_name
      && Yojson.Safe.equal authority.input input
    then Ok ()
    else
      Error
        (Resume_topology_mismatch
           "restored ToolUse identity differs from persisted invocation authority")
;;

let provider_invocations_settled provider =
  match Writer.find_node provider.turn.scope.writer provider.node with
  | Error error -> Error (Scope_unavailable error)
  | Ok None -> Error (Resume_topology_mismatch "provider attempt disappeared")
  | Ok (Some view) ->
    let invocation_nodes =
      List.filter_map
        (fun (child : Event.node Journal.event_record) ->
           match Event.node_kind child.value with
           | Event.Tool_invocation _ -> Some (Event.node_id child.value)
           | Event.Agent_run _
           | Event.Agent_turn _
           | Event.Provider_attempt _
           | Event.Output_block _
           | Event.Tool_attempt -> None)
        view.children
    in
    let rec all_settled = function
      | [] -> Ok true
      | node :: rest ->
        (match Writer.find_node provider.turn.scope.writer node with
         | Error error -> Error (Scope_unavailable error)
         | Ok None -> Error (Resume_topology_mismatch "tool invocation disappeared")
         | Ok
             (Some
                { materialized = Journal.Tool_invocation_state { result = Some _; _ }; _ })
           -> all_settled rest
         | Ok
             (Some
                { materialized = Journal.Tool_invocation_state { result = None; _ }; _ })
           -> Ok false
         | Ok (Some _) ->
           Error (Resume_topology_mismatch "provider child changed node kind"))
    in
    (match invocation_nodes with
     (* All ToolUses were PreToolUse-blocked: blocked_tool_results exist but no
        Tool_invocation nodes were opened (agent_tools.ml Continue-only). With
        result_ids already asserted == expected_ids by the sole caller, an empty
        invocation set is vacuously fully-settled, not unsettled. *)
     | [] -> Ok true
     | nodes -> all_settled nodes)
;;

let tool_result_of_block durable = function
  | Llm_provider.Types.ToolResult { tool_use_id; content; outcome; _ }
    when String.equal
           tool_use_id
           (Tool_contract.Invocation.tool_use_id durable.Settlement.invocation) ->
    Ok
      { invocation = durable.invocation
      ; tool_name = durable.tool_name
      ; input = durable.input
      ; content
      ; outcome
      }
  | Llm_provider.Types.Text _
  | Llm_provider.Types.Thinking _
  | Llm_provider.Types.ReasoningDetails _
  | Llm_provider.Types.RedactedThinking _
  | Llm_provider.Types.ToolUse _
  | Llm_provider.Types.ToolResult _
  | Llm_provider.Types.Image _
  | Llm_provider.Types.Document _
  | Llm_provider.Types.Audio _ -> Error Invalid_tool_result
;;

let provider_settled_invocations provider =
  let scope = provider.turn.scope in
  match Writer.find_node scope.writer provider.node with
  | Error error -> Error (Scope_unavailable error)
  | Ok None -> Error (Resume_topology_mismatch "provider attempt disappeared")
  | Ok (Some view) ->
    let invocation_nodes =
      List.filter_map
        (fun (child : Event.node Journal.event_record) ->
           match Event.node_kind child.value with
           | Event.Tool_invocation _ -> Some (Event.node_id child.value)
           | Event.Agent_run _
           | Event.Agent_turn _
           | Event.Provider_attempt _
           | Event.Output_block _
           | Event.Tool_attempt -> None)
        view.children
    in
    let rec rebind_all acc = function
      | [] ->
        Ok
          (List.sort
             (fun (left : settled_invocation) (right : settled_invocation) ->
                Int.compare
                  (Tool_contract.Invocation.planned_index left.authority.invocation)
                  (Tool_contract.Invocation.planned_index right.authority.invocation))
             acc)
      | node :: rest ->
        let locator = { run_id = Journal.run_id scope.run; node } in
        let open Result_syntax in
        let* rebound = rebind_invocation scope locator in
        let* invocation_view =
          match Writer.find_node scope.writer node with
          | Error error -> Error (Scope_unavailable error)
          | Ok None -> Error (Resume_topology_mismatch "tool invocation disappeared")
          | Ok (Some invocation_view) -> Ok invocation_view
        in
        (match invocation_view.materialized with
         | Journal.Tool_invocation_state { result = Some result; _ } ->
           let* (_ : tool_result) = tool_result_of_block rebound.durable result in
           let authority : invocation_authority =
             { invocation = rebound.durable.invocation
             ; tool_name = rebound.durable.tool_name
             ; input = rebound.durable.input
             }
           in
           rebind_all ({ authority; result } :: acc) rest
         | Journal.Tool_invocation_state { result = None; _ } ->
           Error (Resume_topology_mismatch "tool invocation is not settled")
         | Journal.Agent_run_state
         | Journal.Agent_turn_state
         | Journal.Provider_attempt_state _
         | Journal.Output_block_state _
         | Journal.Tool_attempt_state ->
           Error (Resume_topology_mismatch "provider child changed node kind"))
    in
    rebind_all [] invocation_nodes
;;

let execute_phased invocation ~invoke =
  let durable = invocation.durable in
  let settled =
    Settlement.execute_with_attempt_phased
      durable.authority
      ~invoke:(fun parent_attempt ->
        let start_child ~agent_name =
          transact invocation.scope.writer (Tx.start_run ~parent_attempt ~agent_name ())
          |> Result.map (fun (run, _event) -> { writer = invocation.scope.writer; run })
        in
        let (content, outcome), after_settle =
          invoke ~start_child ~tool_name:durable.tool_name ~input:durable.input
        in
        Settlement.phased_effect
          ~result:
            (Llm_provider.Types.ToolResult
               { tool_use_id = Tool_contract.Invocation.tool_use_id durable.invocation
               ; content
               ; outcome
               ; json = None
               ; content_blocks = None
               })
          ~after_settle)
    |> Result.map_error (fun error -> Settlement_failed error)
  in
  match settled with
  | Error _ as error -> error
  | Ok (Settlement.Executed (block, through, event_count)) ->
    tool_result_of_block durable block
    |> Result.map (fun result -> Executed (result, through, event_count))
  | Ok (Settlement.Replayed block) ->
    tool_result_of_block durable block |> Result.map (fun result -> Replayed result)
;;

let execute invocation ~invoke =
  execute_phased invocation ~invoke:(fun ~start_child ~tool_name ~input ->
    invoke ~start_child ~tool_name ~input, Fun.id)
;;

let close_node writer node terminal =
  transact writer (Tx.close_node ~node terminal) |> Result.map ignore
;;

let close_provider_attempt provider terminal =
  close_node provider.turn.scope.writer provider.node terminal
;;

let close_turn (turn : turn) terminal = close_node turn.scope.writer turn.node terminal

let finish scope terminal =
  transact scope.writer (Tx.finish_run ~run:scope.run terminal) |> Result.map ignore
;;

let abort scope reason =
  let terminal =
    match reason with
    | Failed failure -> Event.Failed failure
    | Cancelled { reason; data } -> Event.Cancelled { reason; data }
  in
  transact_cleanup scope.writer (Tx.abort_run ~run:scope.run terminal)
  |> Result.map ignore
;;

let terminal_recovery_action scope =
  let rec visit = function
    | [] -> Ok Retire
    | node :: rest ->
      (match Writer.find_node scope.writer node with
       | Error error -> Error (Scope_unavailable error)
       | Ok None -> Error (Resume_topology_mismatch "execution descendant disappeared")
       | Ok (Some view) ->
         (match view.Journal.materialized, view.children with
          | Journal.Tool_invocation_state { result = None; _ }, _ :: _ ->
            Ok (Operator_repair_required Effect_outcome_unknown)
          | ( ( Journal.Agent_run_state
              | Journal.Agent_turn_state
              | Journal.Provider_attempt_state _
              | Journal.Output_block_state _
              | Journal.Tool_attempt_state
              | Journal.Tool_invocation_state { result = Some _; _ }
              | Journal.Tool_invocation_state { result = None; _ } )
            , children ) ->
            visit
              (List.rev_append
                 (List.map
                    (fun (child : Event.node Journal.event_record) ->
                       Event.node_id child.value)
                    children)
                 rest)))
  in
  visit [ Journal.run_root scope.run ]
;;

let record_provider_response provider response =
  transact
    provider.turn.scope.writer
    (Tx.update_node ~node:provider.node (Event.Provider_response_snapshot response))
  |> Result.map ignore
;;

let provider_response provider =
  match Writer.find_node provider.turn.scope.writer provider.node with
  | Error error -> Error (Scope_unavailable error)
  | Ok None -> Error (Resume_topology_mismatch "provider attempt node disappeared")
  | Ok
      (Some
         { Journal.materialized =
             Journal.Provider_attempt_state { response = Some response }
         ; _
         }) -> Ok response
  | Ok
      (Some
         { Journal.materialized = Journal.Provider_attempt_state { response = None }; _ })
    -> Error (Resume_topology_mismatch "provider response authority is not materialized")
  | Ok (Some _) ->
    Error
      (Resume_topology_mismatch "provider attempt has an incompatible materialized state")
;;
