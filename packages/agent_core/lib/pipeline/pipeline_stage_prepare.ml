open Types
open Agent_types
open Agent_trace
open Result_syntax

(** Stage 1/2 helpers extracted from [Pipeline].

    These functions stay internal to the library. [Pipeline] re-exports them
    via local aliases so existing tests and call sites remain unchanged while
    the file is split by stage responsibility. *)

let _stage_log = Log.create ~module_name:"pipeline_stage_prepare" ()

(* Shared with Pipeline via Pipeline_common (re-raises Eio cancellation);
   the thin wrapper keeps this module's log label. *)
let safe_publish bus event = Pipeline_common.safe_publish ~log:_stage_log bus event

let stage_input ?raw_trace_run ?clock ~turn agent =
  let ts = Pipeline_common.timestamp_now ?clock () in
  set_lifecycle agent ~ready_at:ts Ready;
  let previous_pending = agent.pending_input in
  let before_decision =
    invoke_hook_with_trace
      agent
      ?raw_trace_run
      ~turn
      ~hook_name:"before_turn"
      agent.options.hooks.before_turn
      (Hooks.BeforeTurn { turn; messages = agent.state.messages })
  in
  let prepared = match before_decision with
  | Hooks.ElicitInput req ->
    (match agent.options.elicitation with
     | Some cb ->
       let response = cb req in
       (match agent.options.event_bus with
        | Some bus ->
          safe_publish
            bus
            (Event_bus.mk_event
               (ElicitationCompleted
                  { agent_name = agent.state.config.name
                  ; question = req.question
                  ; response
                  }))
        | None -> ());
       let message = Agent_elicitation.message_of_response
           ~metadata:[] ~question:req.question response in
       update_state agent (fun s -> {s with messages=Util.snoc s.messages message});
       Ok ()
     | None ->
       let input_required =
         Agent_elicitation.input_required_of_request
           ~agent_name:agent.state.config.name
           ~created_at:ts
           req
       in
       (match Agent_lifecycle_events.current_invocation_id () with
        | None -> Error (Error.Internal "input pause has no lifecycle invocation owner")
        | Some run_id ->
          let* () = Agent_input_checkpoint.install agent
              {Agent_input_request.run_id;request=input_required} in
          Error (Error.Agent (InputRequired input_required))))
  | Hooks.Nudge nudge_msg ->
    (* Keep BeforeTurn nudge behavior identical to the inlined pipeline path:
         append it as a User message so it is seen in this same turn. *)
    update_state agent (fun s ->
      { s with
        messages =
          Util.snoc
            s.messages
            { origin = Recovery_instruction; role = User
            ; content = [ Text nudge_msg ]
            ; name = None
            ; tool_call_id = None
            ; metadata = []
            }
      });
    Ok ()
  | Hooks.Continue -> Ok ()
  | Hooks.HookFailed { stage; detail } ->
    Error
      (Pipeline_common.hook_failed_core_error
         ~hook_name:"before_turn"
         ~stage
         ~tool_name:None
         ~tool_use_id:None
         ~detail)
  | Hooks.AdjustParams _ | Hooks.ElicitToolApproval _ | Hooks.Block _ ->
    (* Reject illegal hook decisions with a typed error instead of crashing.
       [Hooks.invoke_validated] normally filters these out; this branch guards
       against a validation bypass or future hook matrix drift. [Block] is
       legal only at pre_tool_use, so it is illegal here. *)
    Error
      (Pipeline_common.illegal_hook_decision_core_error
         ~hook_name:"before_turn"
         ~stage:Hooks.Before_turn
         ~decision:before_decision)
  in
  match prepared with
  | Error _ as error -> error
  | Ok () ->
    (* The accepted input stage is shared by sync, streaming, low-level and
       restored execution drivers. Started/validation rejection never gets
       here; a replacement that arrived during a callback remains current. *)
    Agent_input_checkpoint.consume agent previous_pending
;;


(* [Agent_turn.last_tool_results_from] reads history blocks as they are: the
   outcome stays typed and the media, if any, stay by reference. *)
let%test "last_tool_results_from keeps each result's id, content and outcome" =
  let failed = Tool_failed { failure_kind = Reported_tool_error; error_class = None } in
  let msgs =
    [ { origin = Llm_provider.Types.Conversation;  role = Tool
      ; content =
          [ ToolResult
              { tool_use_id = "t1"
              ; content = "ok payload"
              ; outcome = Tool_succeeded
              ; json = Some (`Assoc [ "rows", `Int 2 ])
              ; content_blocks = None
              }
          ; ToolResult
              { tool_use_id = "t2"
              ; content = "boom"
              ; outcome = failed
              ; json = None
              ; content_blocks = None
              }
          ]
      ; name = None
      ; tool_call_id = None
      ; metadata = []
      }
    ]
  in
  Agent_turn.last_tool_results_from msgs
  = [ { Hooks.tool_use_id = "t1"
      ; content = "ok payload"
      ; outcome = Tool_succeeded
      ; content_blocks = None
      }
    ; { tool_use_id = "t2"; content = "boom"; outcome = failed; content_blocks = None }
    ]
;;

let prepare_turn_for_agent agent ~turn_params =
  Agent_turn.prepare_turn
    ~media_store:agent.media_store
    ~tools:agent.tools
    ~messages:agent.state.messages
    ~turn_params
    ?model_input_projection:agent.model_input_projection
    ()
;;

let stage_parse ?raw_trace_run ?clock ~turn agent =
  let* turn_params =
    match
      Agent_turn.resolve_turn_params
        ~hooks:agent.options.hooks
        ~messages:agent.state.messages
        ~turn
        ~invoke_hook:(fun ~hook_name hook event ->
          invoke_hook_with_trace agent ?raw_trace_run ~turn ~hook_name hook event)
    with
    | Ok params -> Ok params
    | Error (Agent_turn.Hook_failed { stage; detail }) ->
      Error
        (Pipeline_common.hook_failed_core_error
           ~hook_name:"before_turn_params"
           ~stage
           ~tool_name:None
           ~tool_use_id:None
           ~detail)
    | Error (Agent_turn.Illegal_decision decision) ->
      Error
        (Pipeline_common.illegal_hook_decision_core_error
           ~hook_name:"before_turn_params"
           ~stage:Hooks.Before_turn_params
           ~decision)
  in
  let base_config = agent.state.config in
  let turn_config =
    { base_config with
      temperature =
        (match turn_params.temperature with
         | Some _ as t -> t
         | None -> base_config.temperature)
    ; reasoning_effort =
        (match turn_params.reasoning_effort with
         | Some _ as effort -> effort
         | None -> base_config.reasoning_effort)
    ; enable_thinking =
        (match turn_params.enable_thinking with
         | Some _ as t -> t
         | None -> base_config.enable_thinking)
    ; preserve_thinking =
        (match turn_params.preserve_thinking with
         | Some _ as t -> t
         | None -> base_config.preserve_thinking)
    ; tool_choice =
        (match turn_params.tool_choice with
         | Some _ as t -> t
         | None -> base_config.tool_choice)
    ; system_prompt =
        (let base =
           match turn_params.system_prompt_override with
           | Some _ as prompt -> prompt
           | None -> base_config.system_prompt
         in
         Option.map Llm_provider.Utf8_sanitize.sanitize base)
    }
  in
  (match agent.options.event_bus with
   | Some bus ->
     safe_publish
       bus
       { meta =
           Event_bus.mk_envelope
             ~correlation_id:
               (match Option.bind agent.options.raw_trace Raw_trace.session_id with
                | Some session_id -> session_id
                | None -> Event_bus.fresh_id ())
             ~run_id:
               (match
                  Option.bind (lifecycle_snapshot agent) (fun s -> s.current_run_id)
                with
                | Some run_id -> run_id
                | None -> Event_bus.fresh_id ())
             ()
       ; payload = TurnStarted { agent_name = agent.state.config.name; turn }
       }
   | None -> ());
  let* prep = prepare_turn_for_agent agent ~turn_params in
  let ready_tool_names = prep.visible_tool_names in
  (* TurnReady reports the exact caller-supplied tool list the LLM will see
     this turn. Downstream substrate observability subscribers use this
     to verify deterministically
     which tools the autonomous agent actually has access to, before
     making claims about LLM behaviour from a missing tool call.
     Sibling of TurnStarted (announce) and TurnCompleted (post-LLM). *)
  (match agent.options.event_bus with
   | Some bus ->
     safe_publish
       bus
       { meta =
           Event_bus.mk_envelope
             ~correlation_id:
               (match Option.bind agent.options.raw_trace Raw_trace.session_id with
                | Some session_id -> session_id
                | None -> Event_bus.fresh_id ())
             ~run_id:
               (match
                  Option.bind (lifecycle_snapshot agent) (fun s -> s.current_run_id)
                with
                | Some run_id -> run_id
                | None -> Event_bus.fresh_id ())
             ()
       ; payload =
           TurnReady
             { agent_name = agent.state.config.name; turn; tool_names = ready_tool_names }
       }
   | None -> ());
  Ok (prep, turn_config, turn_params)
;;
