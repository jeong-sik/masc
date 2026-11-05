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

type denied_actions =
  { first : string
  ; rest : string list
  }

type noncompletion_result =
  { status : noncompletion_status
  ; conversation_id : string option
  ; response : string
  ; error : string option
  ; num_turns : int
  ; usage : usage
  ; denied : denied_actions option
  }

type denied_result =
  { conversation_id : string
  ; model : string
  ; denied : denied_actions
  ; response : string
  ; num_turns : int
  ; usage : usage
  ; tool_steps : int
  ; stderr_tail : string
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
  | Actions_denied of denied_result
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
      ; denied : denied_actions option
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
type terminal = private {
  conversation_id : string;
  model : string;
  permission_mode : permission_mode;
  status : result_status;
  response : string;
  error : string option;
  num_turns : int;
  usage : usage;
  denied : denied_actions option;
  tool_steps : int;
  tool_errors : int;
}

type state
val initial : state
val terminal : state -> terminal option
val read_phase : state -> read_phase
(** Derive the existing idle-read policy from the last accepted step. An
    identical closed-response replay preserves the original state and phase.
    The driver stops reading once [terminal] is present. *)

type obligation =
  | Admit_conversation of { conversation_id : string }
  | Terminal_received
  | Stream of stream_event

type transition
val advance :
  expected_model:string -> expected_cwd:string ->
  conversation_mode:conversation_mode -> state -> wire_event ->
  (transition, error) result
(** Validate the event and compute an immutable candidate plus ordered effects.
    Init: admission, then Turn_started. Result: terminal observation, optional
    unstreamed text, then usage. Step: delta, response completion, native tool.
    A refusal/protocol error produces no effects. No callback exception policy,
    clock, process, persistence or final turn interpretation lives here. *)

val obligations : transition -> obligation list
val next_state : transition -> state
(** The shell must interpret every required effect in order and publish this
    candidate only after all required callbacks return successfully. A candidate
    is not proof of admission, delivery, persistence or effect completion.
    On failure/cancellation retain the prior state. Already interpreted obligations
    are not rolled back; never replay callbacks here. *)
