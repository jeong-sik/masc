module Event = Execution_event
module Journal = Execution_journal
module Writer = Execution_lane_writer

type t =
  { writer : Writer.t
  ; invocation_node : Event.Node_id.t
  }

type durable_invocation =
  { authority : t
  ; run_id : Event.Run_id.t
  ; invocation : Tool_contract.Invocation.t
  ; tool_name : string
  ; input : Yojson.Safe.t
  }

type status =
  | Ready_to_execute
  | Outcome_unknown
  | Settled of Llm_provider.Types.content_block

type error =
  | Authority_unavailable of Writer.read_error
  | Invocation_not_found
  | Invocation_identity_mismatch
  | Effect_outcome_unknown
  | Attempt_admission_failed of Writer.submit_error
  | Attempt_commit_failed of Writer.ticket_error
  | Receipt_admission_outcome_unknown of Writer.submit_error
  | Receipt_settlement_outcome_unknown of Writer.ticket_error

type execution =
  | Executed of Llm_provider.Types.content_block * Journal.cursor * int
  | Replayed of Llm_provider.Types.content_block

type phased_effect =
  { result : Llm_provider.Types.content_block
  ; after_settle : unit -> unit
  }

let phased_effect ~result ~after_settle = { result; after_settle }

let read_node writer node =
  match Writer.find_node writer node with
  | Error error -> Error (Authority_unavailable error)
  | Ok None -> Error Invocation_not_found
  | Ok (Some view) -> Ok view
;;

let parent_node view = Event.parent_node_id view.Journal.node

let rebind ~writer ~invocation_node =
  let open Result_syntax in
  let* invocation_view = read_node writer invocation_node in
  let* provider_attempt, run_id, tool_use_id, schedule, completion, tool_name, input =
    match
      ( Event.node_kind invocation_view.node
      , parent_node invocation_view
      , invocation_view.materialized )
    with
    | ( Event.Tool_invocation { provider_tool_use_id; tool_name; schedule; completion }
      , Some parent
      , Journal.Tool_invocation_state
          { input = Some (Llm_provider.Types.ToolUse { id; name; input }); _ } )
      when Option.equal String.equal provider_tool_use_id (Some id)
           && String.equal tool_name name ->
      Ok
        ( parent
        , Event.node_run_id invocation_view.node
        , id
        , schedule
        , completion
        , tool_name
        , input )
    | ( ( Event.Agent_run _
        | Event.Agent_turn _
        | Event.Provider_attempt _
        | Event.Output_block _
        | Event.Tool_invocation _
        | Event.Tool_attempt )
      , (None | Some _)
      , _ ) -> Error Invocation_identity_mismatch
  in
  let* provider_view = read_node writer provider_attempt in
  let* turn_node =
    match Event.node_kind provider_view.node, parent_node provider_view with
    | Event.Provider_attempt _, Some parent
      when Event.Run_id.equal run_id (Event.node_run_id provider_view.node) -> Ok parent
    | Event.Provider_attempt _, None
    | Event.Provider_attempt _, Some _
    | ( ( Event.Agent_run _
        | Event.Agent_turn _
        | Event.Output_block _
        | Event.Tool_invocation _
        | Event.Tool_attempt )
      , _ ) -> Error Invocation_identity_mismatch
  in
  let* turn_view = read_node writer turn_node in
  match Event.node_kind turn_view.node with
  | Event.Agent_turn { ordinal }
    when Event.Run_id.equal run_id (Event.node_run_id turn_view.node) ->
    Ok
      { authority = { writer; invocation_node }
      ; run_id
      ; invocation =
          Tool_contract.Invocation.create ~tool_use_id ~turn:ordinal ~schedule ~completion
      ; tool_name
      ; input
      }
  | Event.Agent_turn _
  | Event.Agent_run _
  | Event.Provider_attempt _
  | Event.Output_block _
  | Event.Tool_invocation _
  | Event.Tool_attempt -> Error Invocation_identity_mismatch
;;

let status authority =
  match read_node authority.writer authority.invocation_node with
  | Error _ as error -> error
  | Ok view ->
    (match view.materialized, view.children, view.status with
     | Journal.Tool_invocation_state { result = Some result; _ }, _, _ ->
       Ok (Settled result)
     | Journal.Tool_invocation_state { result = None; _ }, [], Journal.Open ->
       Ok Ready_to_execute
     | ( Journal.Tool_invocation_state { result = None; _ }
       , _
       , (Journal.Open | Journal.Closed _) ) -> Ok Outcome_unknown
     | ( ( Journal.Agent_run_state
         | Journal.Agent_turn_state
         | Journal.Provider_attempt_state _
         | Journal.Output_block_state _
         | Journal.Tool_attempt_state )
       , _
       , _ ) -> Error Invocation_identity_mismatch)
;;

let await_accepted ticket = Eio.Cancel.protect (fun () -> Writer.await ticket)

let begin_attempt authority =
  Eio.Fiber.check ();
  match
    Writer.submit
      authority.writer
      (Journal.Transaction.begin_tool_attempt ~invocation:authority.invocation_node ())
  with
  | Error error -> Error (Attempt_admission_failed error)
  | Ok ticket ->
    (match await_accepted ticket with
     | Error error -> Error (Attempt_commit_failed error)
     | Ok committed ->
       let node, _event = committed.value in
       Ok node)
;;

let settle authority attempt result =
  let transaction =
    Journal.Transaction.settle_tool_attempt
      ~attempt
      ~invocation:authority.invocation_node
      ~result
      ()
  in
  Eio.Cancel.protect (fun () ->
    match Writer.submit authority.writer transaction with
    | Error error -> Error (Receipt_admission_outcome_unknown error)
    | Ok ticket ->
      (match Writer.await ticket with
       | Error error -> Error (Receipt_settlement_outcome_unknown error)
       | Ok committed -> Ok (result, committed.through, committed.group_event_count)))
;;

let execute_with_attempt_phased_internal authority ~after_attempt_committed ~invoke =
  let open Result_syntax in
  let* current = status authority in
  match current with
  | Settled result -> Ok (Replayed result)
  | Outcome_unknown -> Error Effect_outcome_unknown
  | Ready_to_execute ->
    let* attempt = begin_attempt authority in
    after_attempt_committed ();
    let phase = invoke attempt in
    let+ committed, through, event_count = settle authority attempt phase.result in
    phase.after_settle ();
    Executed (committed, through, event_count)
;;

let execute_with_attempt_phased authority ~invoke =
  execute_with_attempt_phased_internal authority ~after_attempt_committed:Fun.id ~invoke
;;

let execute_with_attempt authority ~invoke =
  execute_with_attempt_phased authority ~invoke:(fun attempt ->
    { result = invoke attempt; after_settle = Fun.id })
;;

let execute authority ~invoke =
  execute_with_attempt authority ~invoke:(fun _ -> invoke ())
;;

module For_testing = struct
  let execute_with_attempt_after_attempt_committed
        authority
        ~after_attempt_committed
        ~invoke
    =
    execute_with_attempt_phased_internal
      authority
      ~after_attempt_committed
      ~invoke:(fun attempt -> phased_effect ~result:(invoke attempt) ~after_settle:Fun.id)
  ;;
end
