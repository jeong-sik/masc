module Event = Execution_event
module Journal = Execution_journal
open Result_syntax

type error =
  | Missing_node of Event.Node_id.t
  | Invalid_tool_fact of Event.Node_id.t
  | Invalid_turn_fact of Event.Node_id.t
  | Invalid_ancestry of Event.Node_id.t

let error_to_string = function
  | Missing_node node -> "bus observation node missing: " ^ Event.Node_id.to_string node
  | Invalid_tool_fact node -> "invalid committed tool fact: " ^ Event.Node_id.to_string node
  | Invalid_turn_fact node -> "invalid committed turn fact: " ^ Event.Node_id.to_string node
  | Invalid_ancestry node -> "invalid committed observation ancestry: " ^ Event.Node_id.to_string node

let project ~find_node event =
  let read node = match find_node node with
    | Some view -> Ok view | None -> Error (Missing_node node) in
  let parent (view : Journal.node_view) = match Event.parent_node_id view.node with
    | Some parent -> read parent
    | None -> Error (Invalid_ancestry (Event.node_id view.node)) in
  let rec ancestry turn (view : Journal.node_view) =
    let node = Event.node_id view.node in
    if not (Event.Run_id.equal (Event.node_run_id view.node) (Event.run_id event))
    then Error (Invalid_ancestry node)
    else match Event.node_kind view.node with
      | Agent_run {agent_name} ->
        (match turn with Some turn -> Ok (agent_name,turn)
         | None -> Error (Invalid_ancestry node))
      | Agent_turn {ordinal} -> let* parent = parent view in ancestry (Some ordinal) parent
      | Provider_attempt _ | Tool_invocation _ | Tool_attempt | Output_block _ ->
        let* parent = parent view in ancestry turn parent in
  let invocation view =
    let node=Event.node_id view.Journal.node in
    let invalid () = Error (Invalid_tool_fact node) in
    match Event.node_kind view.node with
    | Tool_invocation {tool_name;schedule;completion;_} ->
      (match view.materialized with
       | Tool_invocation_state {input;_} ->
         (match input with
          | Some (Llm_provider.Types.ToolUse use) ->
            if not (String.equal tool_name use.name) then invalid ()
            else
              let* agent_name,turn=ancestry None view in
              let* occurrence=Tool_contract.Occurrence.of_strings
                  ~run_id:(Event.Run_id.to_string (Event.run_id event))
                  ~node_id:(Event.Node_id.to_string node)
                  |> Result.map_error (fun _ -> Invalid_tool_fact node) in
              let invocation=Tool_contract.Invocation.of_occurrence occurrence
                  ~tool_use_id:use.id ~turn ~schedule ~completion in
              Ok (agent_name,invocation,tool_name,use.input)
          | None | Some (Text _ | Thinking _ | ReasoningDetails _ | RedactedThinking _
              | ToolResult _ | Image _ | Document _ | Audio _) -> invalid ())
       | Agent_run_state | Agent_turn_state | Provider_attempt_state _ | Output_block_state _
       | Tool_attempt_state -> invalid ())
    | Agent_run _ | Agent_turn _ | Provider_attempt _ | Output_block _ | Tool_attempt -> invalid () in
  let observed payload = Some {Event_bus.meta=Event.envelope event;payload} in
  let turn_progress node_id payload =
    let* view = read node_id in
    match Event.node_kind view.node with
    | Agent_turn _ ->
      let+ agent_name, turn = ancestry None view in
      observed (payload ~agent_name ~turn)
    | Agent_run _ | Provider_attempt _ | Output_block _ | Tool_invocation _ | Tool_attempt ->
      Error (Invalid_turn_fact node_id) in
  match Event.payload event with
  | Node_opened node ->
    (match Event.node_kind node with
     | Tool_attempt ->
       let* view=read (Event.node_id node) in
       let* owner=parent view in
       let+ agent_name,invocation,tool_name,input=invocation owner in
       observed (ToolCalled {agent_name;invocation;tool_name;input})
     | Agent_turn _ ->
       turn_progress (Event.node_id node) (fun ~agent_name ~turn -> TurnStarted {agent_name;turn})
     | Agent_run _ | Provider_attempt _ | Output_block _ | Tool_invocation _ -> Ok None)
  | Node_updated {node_id;update=Turn_ready tool_names} ->
    turn_progress node_id (fun ~agent_name ~turn -> TurnReady {agent_name;turn;tool_names})
  | Node_updated {node_id;update=Provider_response_snapshot response} ->
    (match Option.bind response.telemetry (fun telemetry -> telemetry.Llm_provider.Types.provider_kind) with
     | None -> Ok None
     | Some provider_kind ->
       let* view = read node_id in
       let+ agent_name, turn = ancestry None view in
       let timings = Option.bind response.telemetry (fun telemetry -> telemetry.Llm_provider.Types.timings) in
       observed (InferenceTelemetry
         { agent_name; turn; provider=Llm_provider.Provider_kind.to_string provider_kind
         ; model=response.model
         ; prompt_tokens=Option.map (fun (usage:Llm_provider.Types.api_usage)->usage.input_tokens) response.usage
         ; completion_tokens=Option.map (fun (usage:Llm_provider.Types.api_usage)->usage.output_tokens) response.usage
         ; prompt_ms=Option.bind timings (fun (t:Llm_provider.Types.inference_timings)->t.prompt_ms)
         ; decode_ms=Option.bind timings (fun (t:Llm_provider.Types.inference_timings)->t.predicted_ms)
         ; decode_tok_s=Option.bind timings (fun (t:Llm_provider.Types.inference_timings)->t.predicted_per_second)
         }))
  | Node_updated {node_id;update=Tool_result block} ->
    let* view=read node_id in
    let admitted=List.exists (fun (child:Event.node Journal.event_record) ->
      match Event.node_kind child.value with Tool_attempt -> true
      | Agent_run _ | Agent_turn _ | Provider_attempt _ | Output_block _ | Tool_invocation _ -> false)
      view.children in
    if not admitted then Ok None
    else
      let* agent_name,invocation,tool_name,_input=invocation view in
      (match block with
       | Llm_provider.Types.ToolResult result
         when String.equal result.tool_use_id (Tool_contract.Invocation.tool_use_id invocation) ->
         let output=Llm_provider.Types.tool_result_of_outcome
             ?content_blocks:result.content_blocks ~content:result.content result.outcome in
         Ok (observed (ToolCompleted {agent_name;invocation;tool_name;output}))
       | Text _ | Thinking _ | ReasoningDetails _ | RedactedThinking _ | ToolUse _
       | ToolResult _ | Image _ | Document _ | Audio _ -> Error (Invalid_tool_fact node_id))
  | Node_closed {node_id;terminal=Succeeded} ->
    let* view = read node_id in
    (match Event.node_kind view.node with
     | Agent_turn _ ->
       turn_progress node_id (fun ~agent_name ~turn -> TurnCompleted {agent_name;turn})
     | Agent_run _ | Provider_attempt _ | Output_block _ | Tool_invocation _ | Tool_attempt -> Ok None)
  | Node_updated {update=(Checkpoint_snapshot _ | Provider_event _ | Provider_request_snapshot _
      | Output_delta _ | Output_snapshot _ | Tool_input_delta _ | Tool_input_snapshot _ | Tool_progress _);_}
  | Node_closed {terminal=(Failed _ | Cancelled _);_} -> Ok None
