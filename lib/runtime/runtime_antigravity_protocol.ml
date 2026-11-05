(** Immutable transitions for already-decoded Antigravity events.
    This private owner performs no I/O or callbacks. The public runtime reexports
    the canonical types while retaining its existing explicit interface. *)

type read_phase =
  | Awaiting_admission
  | Model_turn
  | Tool_step_running

type conversation_mode =
  | Start
  | Resume of { conversation_id : string }

type usage =
  { input_tokens : int
  ; output_tokens : int
  ; thinking_tokens : int
  ; cache_read_tokens : int
  ; total_tokens : int
  }

type permission_mode =
  | Always_proceed
  | Request_review
  | Unrecognized_permission_mode of string

type response_ending = Response_done | Response_error

type noncompletion_status =
  | Canceled
  | Interrupted
  | Invalid
  | Waiting
  | Running

type stream_event =
  | Turn_started of
      { conversation_id : string
      ; model : string
      }
  | Text_delta of
      { step_index : int option
      ; text : string
      }
  | Text_completed of { step_index : int; ending : response_ending }
  | Native_tool_started of Runtime_native_tools.observation
  | Native_tool_finished of Runtime_native_tools.finished
  | Usage_reported of
      { conversation_id : string
      ; model : string
      ; num_turns : int
      ; usage : usage
      }
  | Turn_finished of { text : string }

type noncompletion_result =
  { status : noncompletion_status
  ; conversation_id : string option
  ; response : string
  ; error : string option
  ; num_turns : int
  ; usage : usage
  }

type error =
  | Invalid_config of string
  | Spawn_failed of string
  | Protocol_error of
      { stage : string
      ; detail : string
      }
  | State_callback_failed of string
  | Turn_failed of string
  | Result_not_completed of noncompletion_result
  | Process_exited of string
  | Unhandled_exception of string
  | Child_fd_ceiling_exceeded of
      { count : int option
      ; ceiling : int
      }
  | Timeout of float

type wire_event =
  | Init of
      { conversation_id : string
      ; model : string
      ; cwd : string
      ; permission_mode : permission_mode
      }
  | Step_update of
      { conversation_id : string option
      ; step_index : int option
      ; state : step_state
      ; step_type : step_type
      ; tool_name : string option
      ; (* The piece of the answer this frame carries. agy sends it on the
           [Agent_response] steps as the model writes, so the text reaches a
           reader while the turn runs rather than only in the result event
           (measured 2026-09-18, agy 1.2.6). *)
        text_delta : string option
      }
  | Result of
      { (* [None] two ways: the CLI refuses a bad invocation with a single
           result event and never opens a conversation, or a live result
           restates the identity as blank. Init is the one event that states
           it. *)
        conversation_id : string option
      ; status : result_status
      ; response : string
      ; error : string option
      ; num_turns : int
      ; usage : usage
      }

and step_state =
  | Active
  | Done
  | Step_error

and step_type =
  | Agent_response
  | System_message
  | Tool
  | User_input
  | Internal
  | Checkpoint
  | Unrecognized of string

and result_status =
  | Success
  | Result_error
  | Not_completed of noncompletion_status

(** A terminal observation always carries the previously admitted identity.
    This projection is available only after a Result transition; no phase can
    contain a terminal result without an admitted init. *)
type terminal = {
  conversation_id : string;
  model : string;
  permission_mode : permission_mode;
  status : result_status;
  response : string;
  error : string option;
  num_turns : int;
  usage : usage;
  tool_steps : int;
  tool_errors : int;
}

type running =
  { conversation_id : string
  ; model : string
  ; permission_mode : permission_mode
  ; tool_steps : int
  ; tool_errors : int
  ; last_step : (step_type * step_state) option
  ; closed_responses : (int * (response_ending * string option)) list
  ; text_streamed : bool
  }

type received_result =
  { status : result_status
  ; response : string
  ; error : string option
  ; num_turns : int
  ; usage : usage
  }

type state =
  | Awaiting_init
  | Admitted of running
  | Completed of { running : running; result : received_result }

let initial = Awaiting_init

let terminal (state : state) : terminal option =
  match state with
  | Awaiting_init | Admitted _ -> None
  | Completed { running; result } ->
    Some
      { conversation_id = running.conversation_id
      ; model = running.model
      ; permission_mode = running.permission_mode
      ; status = result.status
      ; response = result.response
      ; error = result.error
      ; num_turns = result.num_turns
      ; usage = result.usage
      ; tool_steps = running.tool_steps
      ; tool_errors = running.tool_errors
      }

(* Only an ACTIVE tool update changes the existing idle-read phase. *)
let read_phase (state : state) : read_phase =
  match state with
  | Awaiting_init -> Awaiting_admission
  | Admitted running | Completed { running; result = _ } ->
    (match running.last_step with
     | Some (Tool, Active) -> Tool_step_running
     | None
     | Some (Tool, (Done | Step_error))
     | Some
         ( ( Agent_response
           | System_message
           | User_input
           | Internal
           | Checkpoint
           | Unrecognized _ )
         , (Active | Done | Step_error) ) -> Model_turn)

type obligation =
  | Admit_conversation of { conversation_id : string }
  | Terminal_received
  | Stream of stream_event

type transition = { candidate : state; required : obligation list }

let obligations (transition : transition) = transition.required
let next_state (transition : transition) = transition.candidate

let protocol_error stage detail = Error (Protocol_error { stage; detail })
let ( let* ) result f = Result.bind result f

let expected_conversation_id = function
  | Start -> None
  | Resume { conversation_id } -> Some conversation_id

let verify_identity ~stage ~expected actual =
  match expected with
  | Some value when not (String.equal value actual) ->
    protocol_error
      stage
      (Printf.sprintf "conversation identity mismatch: expected %S, got %S" value actual)
  | None | Some _ -> Ok ()

(* An omitted/blank restatement makes no identity claim. The admitted init
   remains the identity source for all later observations. *)
let verify_restatement ~stage ~expected = function
  | None -> Ok ()
  | Some actual -> verify_identity ~stage ~expected:(Some expected) actual

let advance ~expected_model ~expected_cwd ~conversation_mode
    (state : state) (event : wire_event) : (transition, error) result =
  match event with
  | Init { conversation_id; model; cwd; permission_mode } ->
    let stage = "init event" in
    (match state with
     | Admitted _ | Completed _ ->
       protocol_error stage "received more than one init event"
     | Awaiting_init ->
       let* () =
         verify_identity ~stage
           ~expected:(expected_conversation_id conversation_mode) conversation_id
       in
       if not (String.equal model expected_model) then
         protocol_error stage
           (Printf.sprintf "model mismatch: expected %S, got %S" expected_model model)
       else if not (String.equal cwd expected_cwd) then
         protocol_error stage
           (Printf.sprintf "cwd mismatch: expected %S, got %S" expected_cwd cwd)
       else
         let running : running =
           { conversation_id; model; permission_mode; tool_steps = 0; tool_errors = 0
           ; last_step = None; closed_responses = []; text_streamed = false }
         in
         Ok
           { candidate = Admitted running
           ; required =
               [ Admit_conversation { conversation_id }
               ; Stream (Turn_started { conversation_id; model })
               ]
           })
  | Step_update
      { conversation_id; step_index; state = step_state; step_type; tool_name
      ; text_delta } ->
    let stage = "step_update event" in
    let* running =
      match state with
      | Awaiting_init -> protocol_error stage "received step_update before init"
      | Completed { running; result = _ } ->
        let* () =
          verify_restatement ~stage ~expected:running.conversation_id conversation_id
        in
        protocol_error stage "received step_update after result"
      | Admitted running ->
        let* () =
          verify_restatement ~stage ~expected:running.conversation_id conversation_id
        in
        Ok running
    in
    let ending =
      match step_type, step_state with
      | Agent_response, Done -> Some Response_done
      | Agent_response, Step_error -> Some Response_error
      | Agent_response, Active
      | (System_message | Tool | User_input | Internal | Checkpoint | Unrecognized _),
        (Active | Done | Step_error) -> None
    in
    let* replay =
      match
        Option.bind step_index
          (fun index -> List.assoc_opt index running.closed_responses)
      with
      | None -> Ok false
      | Some (previous_ending, previous_delta) ->
        (match ending with
         | Some ending when ending = previous_ending
             && (text_delta = previous_delta || text_delta = None
                 || text_delta = Some "") -> Ok true
         | Some _ | None ->
           protocol_error stage "response content changed after its step ended")
    in
    if replay then
      (* Preserve the original state, including last_step/read phase. *)
      Ok { candidate = state; required = [] }
    else
      (* Only a response step carries the answer. Text on any other step is
         not the reply and does not reach the reader as one. *)
      let streamed, text_obligations =
        match step_type, text_delta with
        | Agent_response, Some text when text <> "" ->
          true, [ Stream (Text_delta { step_index; text }) ]
        | Agent_response, (Some _ | None)
        | (System_message | Tool | User_input | Internal | Checkpoint | Unrecognized _),
          (Some _ | None) -> false, []
      in
      let closed_responses, completion_obligations =
        match step_index, ending with
        | Some step_index, Some ending ->
          ( (step_index, (ending, text_delta)) :: running.closed_responses
          , [ Stream (Text_completed { step_index; ending }) ] )
        | (Some _ | None), None | None, Some _ -> running.closed_responses, []
      in
      let is_tool = step_type = Tool in
      let native_obligations =
        if is_tool then
          let observation : Runtime_native_tools.observation =
            { identity =
                Option.map
                  (fun step_index ->
                    Runtime_native_tools.Provider_step
                      { conversation_id = running.conversation_id; step_index })
                  step_index
            ; tool_name
            ; origin =
                (match tool_name with
                 | Some "call_mcp_tool" -> Runtime_native_tools.Mcp_wrapper
                 | Some _ | None -> Runtime_native_tools.Built_in)
            }
          in
          match step_state with
          | Active -> [ Stream (Native_tool_started observation) ]
          | Done ->
            [ Stream
                (Native_tool_finished
                   { observation
                   ; completion =
                       { outcome = Runtime_native_tools.Completion_reported
                       ; exit_code = None }
                   }) ]
          | Step_error ->
            [ Stream
                (Native_tool_finished
                   { observation
                   ; completion =
                       { outcome = Runtime_native_tools.Error_reported
                       ; exit_code = None }
                   }) ]
        else []
      in
      let running =
        { running with
          closed_responses
        ; tool_steps = running.tool_steps + if is_tool && step_state = Active then 1 else 0
        ; tool_errors = running.tool_errors + if is_tool && step_state = Step_error then 1 else 0
        ; last_step = Some (step_type, step_state)
        ; text_streamed = running.text_streamed || streamed
        }
      in
      Ok
        { candidate = Admitted running
        ; required = text_obligations @ completion_obligations @ native_obligations
        }
  | Result { conversation_id; status; response; error; num_turns; usage } ->
    let stage = "result event" in
    let* running =
      match state, status with
      | Awaiting_init, Result_error ->
        Error
          (Turn_failed
             (match error with
              | Some detail -> detail
              | None -> "status=ERROR before init"))
      | Awaiting_init, Success -> protocol_error stage "received result before init"
      | Awaiting_init, Not_completed status ->
        Error (Result_not_completed { status; conversation_id; response; error; num_turns; usage })
      | Completed { running; result = _ }, (Success | Result_error | Not_completed _) ->
        let* () =
          verify_restatement ~stage ~expected:running.conversation_id conversation_id
        in
        protocol_error stage "received more than one result event"
      | Admitted running, (Success | Result_error | Not_completed _) ->
        let* () =
          verify_restatement ~stage ~expected:running.conversation_id conversation_id
        in
        Ok running
    in
    let text_obligations =
      if running.text_streamed then []
      else
        match status with
        | Success -> [ Stream (Text_delta { step_index = None; text = response }) ]
        | Result_error ->
          if Agent_core.Response_shape.has_deliverable_content
               (Agent_core.Response_shape.summarize_blocks
                  [ Llm_provider.Types.Text response ])
          then [ Stream (Text_delta { step_index = None; text = response }) ]
          else []
        | Not_completed _ -> []
    in
    let result : received_result = { status; response; error; num_turns; usage } in
    Ok
      { candidate = Completed { running; result }
      ; required =
          Terminal_received
          :: (text_obligations
              @ [ Stream
                    (Usage_reported
                       { conversation_id = running.conversation_id
                       ; model = running.model
                       ; num_turns
                       ; usage
                       }) ])
      }
