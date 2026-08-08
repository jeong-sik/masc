(** OAS Runtime wire protocol types.

    Defines the full request/response/event protocol between the OAS
    runtime and its consumers (CLI, IDE, coordinators).

    @since 0.50.0

    @stability Evolving
    @since 0.93.1 *)

(** {1 Session State} *)

type phase =
  | Bootstrapping
  | Running
  | Input_required
  | Waiting_on_workers
  | Finalizing
  | Completed
  | Failed
  | Cancelled
[@@deriving yojson, show]

type participant_state =
  | Planned
  | Starting
  | Live
  | Idle
  | Done
  | Failed_participant
  | Detached
[@@deriving yojson, show]

type participant =
  { name : string
  ; role : string option
  ; aliases : string list
  ; worker_id : string option
  ; runtime_actor : string option
  ; requested_provider : string option
  ; requested_model : string option
  ; provider : string option
  ; model : string option
  ; resolved_provider : string option
  ; resolved_model : string option
  ; state : participant_state
  ; summary : string option
  ; accepted_at : float option
  ; ready_at : float option
  ; first_progress_at : float option
  ; started_at : float option
  ; finished_at : float option
  ; last_progress_at : float option
  ; last_error : string option
  }
[@@deriving yojson, show]

type artifact =
  { artifact_id : string
  ; name : string
  ; kind : string
  ; mime_type : string
  ; path : string option
  ; inline_content : string option
  ; size_bytes : int
  ; created_at : float
  }
[@@deriving yojson, show]

type input_request =
  { request_id : string
  ; participant_name : string option
  ; question : string
  ; schema : Yojson.Safe.t option
  ; timeout_s : float option
  ; created_at : float
  }
[@@deriving yojson, show]

type input_response =
  | Input_answer of Yojson.Safe.t
  | Input_declined
  | Input_timeout
[@@deriving yojson, show]

(** Runtime session — wire protocol record. *)
type session =
  { session_id : string
  ; goal : string
  ; title : string option
  ; tag : string option
  ; phase : phase
  ; created_at : float
  ; updated_at : float
  ; provider : string option
  ; model : string option
  ; system_prompt : string option
  ; workdir : string option
  ; planned_participants : string list
  ; participants : participant list
  ; artifacts : artifact list
  ; pending_input : input_request option [@default None]
  ; turn_count : int
  ; last_seq : int
  ; outcome : string option
  }
[@@deriving yojson, show]

(** {1 Protocol Messages} *)

type init_request =
  { session_root : string option
  ; provider : string option
  ; model : string option
  ; include_partial_messages : bool
  ; setting_sources : string list
  ; resume_session : string option
  ; cwd : string option
  }
[@@deriving yojson, show]

type init_response =
  { sdk_name : string
  ; sdk_version : string
  ; runtime_version : string
  ; protocol_version : string
  ; capabilities : string list
  }
[@@deriving yojson, show]

type start_request =
  { session_id : string option
  ; goal : string
  ; participants : string list
  ; provider : string option
  ; model : string option
  ; system_prompt : string option
  ; workdir : string option
  }
[@@deriving yojson, show]

type update_settings_request = { model : string option } [@@deriving yojson, show]

type record_turn_request =
  { actor : string option
  ; message : string
  }
[@@deriving yojson, show]

type provide_input_request =
  { request_id : string
  ; response : input_response
  }
[@@deriving yojson, show]

type spawn_agent_request =
  { participant_name : string
  ; role : string option
  ; prompt : string
  ; provider : string option
  ; model : string option
  ; system_prompt : string option
  }
[@@deriving yojson, show]

type attach_artifact_request =
  { name : string
  ; kind : string
  ; content : string
  }
[@@deriving yojson, show]

type checkpoint_request = { label : string option } [@@deriving yojson, show]
type finalize_request = { reason : string option } [@@deriving yojson, show]

type command =
  | Record_turn of record_turn_request
  | Request_input of input_request
  | Provide_input of provide_input_request
  | Spawn_agent of spawn_agent_request
  | Update_session_settings of update_settings_request
  | Attach_artifact of attach_artifact_request
  | Checkpoint of checkpoint_request
  | Request_finalize of finalize_request
[@@deriving yojson, show]

(** {1 Events} *)

type start_event =
  { goal : string
  ; participants : string list
  }
[@@deriving yojson, show]

type turn_event =
  { actor : string option
  ; message : string
  }
[@@deriving yojson, show]

type input_provided_event =
  { request_id : string
  ; participant_name : string option
  ; response : input_response
  }
[@@deriving yojson, show]

type spawn_event =
  { participant_name : string
  ; role : string option
  ; prompt : string
  ; provider : string option
  ; model : string option
  }
[@@deriving yojson, show]

type completion_anomaly = private Dropped_output_deltas of { count : int }
[@@deriving show]

type completion_anomaly_error = Non_positive_dropped_output_delta_count of int
[@@deriving show]

(** [dropped_output_deltas ~count] constructs evidence that output deltas were
    dropped. [count] must be positive; zero means that no anomaly exists and
    must therefore be represented by [None] at the caller. *)
val dropped_output_deltas
  :  count:int
  -> (completion_anomaly, completion_anomaly_error) result

val completion_anomaly_to_yojson : completion_anomaly -> Yojson.Safe.t
val completion_anomaly_of_yojson : Yojson.Safe.t -> (completion_anomaly, string) result

type failure_cause =
  | Execution_error of string
  | Persistence_failure of
      { phase : string
      ; detail : string
      }
[@@deriving yojson, show]

(** Text projection of a typed participant failure for reports and projected
    session state. Runtime events retain {!failure_cause} as their only failure
    representation. *)
val failure_cause_to_string : failure_cause -> string

(** Identity and trace fields shared by every participant lifecycle event.
    The lifecycle-specific wrappers below keep completion and failure evidence
    disjoint in the type system and in canonical runtime JSON. *)
type participant_event_common =
  { participant_name : string
  ; summary : string option
  ; provider : string option
  ; model : string option
  ; raw_trace_run_id : string option [@default None]
  }
[@@deriving yojson, show]

type participant_live_event = { participant : participant_event_common }
[@@deriving yojson, show]

(** Successful completion evidence. A failure cause cannot be attached to this
    payload. *)
type participant_completed_event =
  { participant : participant_event_common
  ; stop_reason : string option [@default None]
  ; completion_anomaly : completion_anomaly option [@default None]
  }
[@@deriving yojson, show]

(** Failed participant evidence. [failure_cause] is mandatory. *)
type participant_failed_event =
  { participant : participant_event_common
  ; failure_cause : failure_cause
  }
[@@deriving yojson, show]

type output_delta_event =
  { participant_name : string
  ; delta : string
  ; raw_trace_run_id : string option [@default None]
  }
[@@deriving yojson, show]

type artifact_event =
  { artifact_id : string
  ; name : string
  ; kind : string
  ; mime_type : string
  ; path : string
  ; size_bytes : int
  }
[@@deriving yojson, show]

type checkpoint_event =
  { label : string option
  ; path : string
  }
[@@deriving yojson, show]

type completion_event = { outcome : string option } [@@deriving yojson, show]

type event_kind =
  | Session_started of start_event
  | Session_settings_updated of update_settings_request
  | Turn_recorded of turn_event
  | Input_required of input_request
  | Input_provided of input_provided_event
  | Agent_spawn_requested of spawn_event
  | Agent_became_live of participant_live_event
  | Agent_output_delta of output_delta_event
  | Agent_completed of participant_completed_event
  | Agent_failed of participant_failed_event
  | Artifact_attached of artifact_event
  | Checkpoint_saved of checkpoint_event
  | Finalize_requested of finalize_request
  | Session_completed of completion_event
  | Session_failed of completion_event
[@@deriving yojson, show]

type event =
  { seq : int
  ; ts : float
  ; kind : event_kind
  }
[@@deriving yojson, show]

(** {1 Reports and Proofs} *)

type report =
  { session_id : string
  ; summary : string list
  ; markdown : string
  ; generated_at : float
  }
[@@deriving yojson, show]

type proof_check =
  { name : string
  ; passed : bool
  }
[@@deriving yojson, show]

type proof =
  { session_id : string
  ; ok : bool
  ; checks : proof_check list
  ; evidence : string list
  ; generated_at : float
  }
[@@deriving yojson, show]

(** {1 Request / Response Envelopes} *)

type request =
  | Initialize of init_request
  | Start_session of start_request
  | Apply_command of
      { session_id : string
      ; command : command
      }
  | Status of { session_id : string }
  | Events of
      { session_id : string
      ; after_seq : int option
      }
  | Finalize of
      { session_id : string
      ; reason : string option
      }
  | Report of { session_id : string }
  | Prove of { session_id : string }
  | Shutdown
[@@deriving yojson, show]

type response =
  | Initialized of init_response
  | Session_started_response of session
  | Command_applied of session
  | Status_response of session
  | Events_response of event list
  | Finalized of session
  | Report_response of report
  | Prove_response of proof
  | Shutdown_ack
  | Error_response of string
[@@deriving yojson, show]

type protocol_message =
  | Request_message of
      { request_id : string
      ; request : request
      }
  | Response_message of
      { request_id : string
      ; response : response
      }
  | Event_message of
      { session_id : string option
      ; event : event
      }
  | System_message of
      { level : string
      ; message : string
      }
[@@deriving yojson, show]

(** {1 Serialization} *)

val request_to_json : request -> Yojson.Safe.t
val request_of_json : Yojson.Safe.t -> (request, string) result
val response_to_json : response -> Yojson.Safe.t
val response_of_json : Yojson.Safe.t -> (response, string) result
val protocol_message_to_json : protocol_message -> Yojson.Safe.t
val protocol_message_of_json : Yojson.Safe.t -> (protocol_message, string) result
val request_to_string : request -> string
val response_to_string : response -> string
val protocol_message_to_string : protocol_message -> string
val request_of_string : string -> (request, string) result
val response_of_string : string -> (response, string) result
val protocol_message_of_string : string -> (protocol_message, string) result
val protocol_version : string
