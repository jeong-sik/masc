open Types
open Result_syntax

let tool_use_ids blocks =
  List.filter_map
    (function
      | ToolUse { id; _ } -> Some id
      | Text _
      | Thinking _
      | ReasoningDetails _
      | RedactedThinking _
      | ToolResult _
      | Image _
      | Document _
      | Audio _ -> None)
    blocks
;;

let tool_result_ids blocks =
  List.filter_map
    (function
      | ToolResult { tool_use_id; _ } -> Some tool_use_id
      | Text _
      | Thinking _
      | ReasoningDetails _
      | RedactedThinking _
      | ToolUse _
      | Image _
      | Document _
      | Audio _ -> None)
    blocks
;;

let last_tool_turn messages =
  let rec find messages_after_rev = function
    | [] -> None
    | message :: rest ->
      (match message.role with
       | Assistant ->
         let tool_blocks =
           List.filter
             (function
               | ToolUse _ -> true
               | Text _
               | Thinking _
               | ReasoningDetails _
               | RedactedThinking _
               | ToolResult _
               | Image _
               | Document _
               | Audio _ -> false)
             message.content
         in
         (match tool_blocks with
          | [] -> None
          | tool_blocks -> Some (tool_blocks, tool_use_ids tool_blocks, messages_after_rev))
       | System | User | Tool -> find (message :: messages_after_rev) rest)
  in
  find [] (List.rev messages)
;;

let recovered_tool_results messages_after =
  List.find_map
    (fun (message : Types.message) ->
       let results =
         List.filter
           (function
             | ToolResult _ -> true
             | Text _
             | Thinking _
             | ReasoningDetails _
             | RedactedThinking _
             | ToolUse _
             | Image _
             | Document _
             | Audio _ -> false)
           message.content
       in
       match results with
       | [] -> None
       | results -> Some results)
    messages_after
;;

type settled_replay =
  | Replay_tools_settled of
      { tool_uses : Types.content_block Nonempty.t
      ; tool_results : Types.content_block list
      }
  | Replay_terminal of Types.message

type settled_tool_authority =
  | All_pre_tool_use_blocked
  | Durable_invocations of Execution_agent_scope.invocation_authority list

let settled_tool_authority = function
  | [] -> All_pre_tool_use_blocked
  | invocations -> Durable_invocations invocations
;;

let last_assistant_message messages =
  List.fold_left
    (fun acc (message : Types.message) ->
       match message.role with
       | Assistant -> Some message
       | System | User | Tool -> acc)
    None
    messages
;;

(* Classify a [Closed Succeeded] turn resumed under a still-[Running] root. The
   turn's effects are durably settled (the journal rejects closing a node with
   open children), so resume surfaces the settled outcome rather than
   re-executing. A completed tool turn — its ToolResults already recovered into
   the restored After_tool_results_appended checkpoint — continues the run loop;
   a terminal turn (final assistant response, no pending tool calls) completes the
   run. A tool turn whose recovered results do not match its restored ToolUse
   checkpoint stays an error (fail-closed on inconsistent topology). *)
let classify_settled agent =
  match last_tool_turn agent.Agent_types.state.messages with
  | Some (tool_blocks, expected_ids, messages_after) ->
    let* tool_blocks =
      match Nonempty.of_list tool_blocks with
      | Some tool_blocks -> Ok tool_blocks
      | None ->
        Error
          (Error.Internal
             "durable execution resume settled tool turn restored no ToolUse blocks")
    in
    (match recovered_tool_results messages_after with
     | Some tool_results when tool_result_ids tool_results = expected_ids ->
       Ok (Replay_tools_settled { tool_uses = tool_blocks; tool_results })
     | Some _ ->
       Error
         (Error.Internal
            "durable execution resume settled turn ToolResult identities differ from the \
             restored ToolUse checkpoint")
     | None ->
       Error
         (Error.Internal
            "durable execution resume settled tool turn is missing its recovered \
             ToolResults"))
  | None ->
    (match last_assistant_message agent.Agent_types.state.messages with
     | Some message -> Ok (Replay_terminal message)
     | None ->
       Error
         (Error.Internal
            "durable execution resume settled terminal turn has no restored assistant \
             message"))
;;

(* Idempotent completed boundary: the turn is already [Closed Succeeded] under a
   still-[Running] root (crash between the provider close, the turn close, and the
   root finish of a fully-settled turn). Complete any interrupted [close_success]
   (close the still-open turn), then surface the already-settled turn outcome so
   the run loop advances exactly as the un-crashed run would have — replaying the
   settled results without re-executing effects and without aborting the root as
   Failed. [tools_settled] is the completed-tool-turn outcome; [terminal] wraps
   the reconstructed final assistant response. *)
let run_settled agent boundary ~all_pre_tool_use_blocked ~tools_settled ~terminal =
  let* replay = classify_settled agent in
  match replay with
  | Replay_tools_settled { tool_uses; tool_results } ->
    let* response = Pipeline_execution_scope.settled_response boundary in
    let* () =
      Pipeline_terminal_tool.validate_response_tool_uses
        ~response
        ~tool_uses:(Nonempty.to_list tool_uses)
    in
    let turn = agent.Agent_types.state.turn_count - 1 in
    if turn < 0
    then
      Error
        (Error.Internal
           "durable execution resume settled tool turn has an invalid turn counter")
    else
      let* invocations = Pipeline_execution_scope.settled_invocations boundary in
      let* outcome =
        match settled_tool_authority invocations with
        | All_pre_tool_use_blocked -> Ok all_pre_tool_use_blocked
        | Durable_invocations invocations ->
          tools_settled ~response ~turn ~invocations ~tool_results tool_uses
      in
      let+ () = Pipeline_execution_scope.finalize_settled boundary in
      outcome
  | Replay_terminal message ->
    let* response = Pipeline_execution_scope.settled_response boundary in
    let* invocations = Pipeline_execution_scope.settled_invocations boundary in
    (match invocations with
     | _ :: _ ->
       Error
         (Error.Internal
            "durable execution resume terminal turn contains persisted tool invocations")
     | [] ->
       if response.content <> message.content
       then
         Error
           (Error.Internal
              "persisted provider response content differs from the restored terminal \
               checkpoint")
       else (
         let outcome = terminal response in
         let+ () = Pipeline_execution_scope.finalize_settled boundary in
         outcome))
;;

let run
      agent
      execution
      ~execute
      ~settled_before_checkpoint
      ~all_pre_tool_use_blocked
      ~already_settled
  =
  let outcome =
    let* response = Pipeline_execution_scope.provider_response execution in
    match last_tool_turn agent.Agent_types.state.messages with
    | None ->
      Error
        (Error.Internal
           "durable execution resume found an open provider attempt without a restored \
            ToolUse checkpoint")
    | Some (tool_blocks, expected_ids, messages_after) ->
      let* () =
        Pipeline_terminal_tool.validate_response_tool_uses
          ~response
          ~tool_uses:tool_blocks
      in
      (match recovered_tool_results messages_after with
       | None ->
         (match Nonempty.of_list tool_blocks with
          | None ->
            Error
              (Error.Internal
                 "durable execution resume restored an empty ToolUse checkpoint")
          | Some tool_blocks ->
            (match Pipeline_execution_scope.provider execution with
             | None ->
               Error
                 (Error.Internal "durable execution resume lost its provider authority")
             | Some provider ->
               Execution_context.with_provider_attempt provider (fun () ->
                 let* settled = Pipeline_execution_scope.invocations_settled execution in
                 if not settled
                 then execute ~response tool_blocks
                 else
                   let* persisted =
                     Pipeline_execution_scope.settled_invocations_with_results execution
                   in
                   match persisted with
                   | [] ->
                     (* A pre-execution hook can produce a model-visible result
                         without opening an invocation. With no persisted result
                         authority, safely re-run admission rather than inventing
                         a result. *)
                     execute ~response tool_blocks
                   | persisted ->
                     let invocations =
                       List.map
                         (fun (settled : Execution_agent_scope.settled_invocation) ->
                            settled.authority)
                         persisted
                     in
                     let tool_results =
                       List.map
                         (fun (settled : Execution_agent_scope.settled_invocation) ->
                            settled.result)
                         persisted
                     in
                     settled_before_checkpoint
                       ~response
                       ~turn:(Pipeline_execution_scope.turn_ordinal execution)
                       ~invocations
                       ~tool_results
                       tool_blocks)))
       | Some tool_results when tool_result_ids tool_results = expected_ids ->
         let* settled = Pipeline_execution_scope.invocations_settled execution in
         if settled
         then (
           match Nonempty.of_list tool_blocks with
           | Some tool_blocks ->
             let* invocations = Pipeline_execution_scope.invocations execution in
             (match settled_tool_authority invocations with
              | All_pre_tool_use_blocked -> Ok all_pre_tool_use_blocked
              | Durable_invocations invocations ->
                already_settled
                  ~response
                  ~turn:(Pipeline_execution_scope.turn_ordinal execution)
                  ~invocations
                  ~tool_results
                  tool_blocks)
           | None ->
             Error
               (Error.Internal
                  "durable execution resume restored an empty ToolUse checkpoint"))
         else
           Error
             (Error.Internal
                "durable execution resume checkpoint contains ToolResults but journal \
                 settlement is incomplete")
       | Some _ ->
         Error
           (Error.Internal
              "durable execution resume ToolResult identities differ from the restored \
               ToolUse checkpoint"))
  in
  match outcome with
  | Error _ as error -> error
  | Ok outcome ->
    Pipeline_execution_scope.close_success execution |> Result.map (fun () -> outcome)
;;

(* Dispatch one pipeline turn against the durable-execution scope. Consume the
   one-shot resume flag and classify what the restored scope found at the durable
   turn frontier: [Active] resumes an in-progress turn/provider via {!run};
   [Settled] surfaces an already-settled boundary via {!run_settled}; [Fresh] (no
   resume requested, or nothing left to resume) runs a new turn via [fresh]. The
   resume flag is consumed here — before [fresh] — exactly as the pre-crash run
   would have, so effects and order match the non-resumed path. The turn identity
   passed to [execute] is read from the durable turn ([turn_ordinal]), never
   reconstructed from mutable agent state, so a resumed tool turn is traced under
   the same ordinal the crashed run used. *)
let dispatch
      agent
      ~execute
      ~tools_settled_before_checkpoint
      ~tools_settled
      ~all_pre_tool_use_blocked
      ~terminal
      ~fresh
  =
  let* resumed =
    if Execution_context.take_resume_once ()
    then Pipeline_execution_scope.resume_current (Execution_context.agent_scope ())
    else Ok Pipeline_execution_scope.Fresh
  in
  match resumed with
  | Pipeline_execution_scope.Active execution ->
    let turn = Pipeline_execution_scope.turn_ordinal execution in
    run
      agent
      execution
      ~execute:(execute ~turn)
      ~settled_before_checkpoint:tools_settled_before_checkpoint
      ~all_pre_tool_use_blocked
      ~already_settled:tools_settled
  | Pipeline_execution_scope.Settled boundary ->
    run_settled agent boundary ~all_pre_tool_use_blocked ~tools_settled ~terminal
  | Pipeline_execution_scope.Fresh -> fresh ()
;;
