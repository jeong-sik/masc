(** A2A MCP Tools — A2A Protocol wrapped as MCP tools.

    Enables MCP clients (Claude Code, Cursor) to perform A2A-style
    agent-to-agent communication without a separate gRPC client.

    @see <https://github.com/google/A2A> A2A specification *)

(** {1 Delegate artifact} *)

type artifact =
  { name : string
  ; mime_type : string
  ; data : string (** base64 encoded or raw text *)
  }
[@@deriving yojson, show]

(** {1 Delegate task types} *)

type task_type =
  | Sync (** Wait for completion. *)
  | Async (** Return immediately with task ID. *)
  | Stream (** Stream results as they arrive. *)
[@@deriving show]

val task_type_of_string : string -> (task_type, string) result

(** {1 Delegate result} *)

type delegate_result =
  { task_id : string
  ; status : string
  ; result : string option [@default None]
  ; artifacts : artifact list
  }
[@@deriving yojson, show]

(** {1 Subscription event types} *)

type event_type =
  | TaskUpdate
  | Broadcast
  | Completion
  | Error
  | HeartbeatTask (** Agent embodiment request — Worker should invoke MODEL. *)
[@@deriving show]

val event_type_of_string : string -> (event_type, string) result

(** {1 A2A v0.3 Task State Machine}

    @see <https://a2a-protocol.org/latest/specification/> *)

type a2a_task_state =
  | Working (** Processing in progress. *)
  | Completed (** Successfully finished. *)
  | Failed (** Processing error. *)
  | Canceled (** Client-requested cancellation. *)
  | Rejected (** Server rejected execution. *)
  | Input_required (** Awaiting additional client input. *)
  | Auth_required (** Awaiting client authentication. *)
[@@deriving show]

val a2a_task_state_to_string : a2a_task_state -> string
val a2a_task_state_of_string : string -> (a2a_task_state, string) result

(** Map MASC internal task status to A2A v0.3 state.

    - [Todo]/[Claimed]/[InProgress]/[AwaitingVerification] → [Working]
    - [Done] → [Completed]
    - [Cancelled] → [Canceled] *)
val masc_status_to_a2a : Types.task_status -> a2a_task_state

(** {1 A2A v0.3 Task Status object} *)

type a2a_task_status =
  { state : a2a_task_state
  ; timestamp : string
  ; message : string option
  }

val a2a_task_status_to_json : a2a_task_status -> Yojson.Safe.t

(** {1 A2A protocol version} *)

(** Default version string when no header is supplied. *)
val default_a2a_version : string

(** [parse_a2a_version header]: returns the trimmed header value when
    present and non-empty; otherwise returns {!default_a2a_version}. *)
val parse_a2a_version : string option -> string
