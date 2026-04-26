(** A2A MCP Tools - A2A Protocol Wrapped as MCP Tools

    Enables MCP clients (Claude Code, Cursor) to perform A2A-style
    agent-to-agent communication without needing a separate gRPC client.

    Tools:
    - discover: Find available agents and their capabilities
    - query_skill: Get detailed skill information from an agent
    - delegate: Delegate a task to another agent
    - subscribe: Subscribe to agent events

    @see https://github.com/google/A2A for A2A specification
*)

(** Artifact type for delegate *)
type artifact =
  { name : string
  ; mime_type : string
  ; data : string (* base64 encoded or raw text *)
  }
[@@deriving yojson, show]

(** Delegate task type *)
type task_type =
  | Sync (* Wait for completion *)
  | Async (* Return immediately with task ID *)
  | Stream (* Stream results as they arrive *)
[@@deriving show]

let task_type_of_string = function
  | "sync" -> Ok Sync
  | "async" -> Ok Async
  | "stream" -> Ok Stream
  | s -> Error (Printf.sprintf "Unknown task type: %s" s)
;;

(** Delegate result *)
type delegate_result =
  { task_id : string
  ; status : string
  ; result : string option [@default None]
  ; artifacts : artifact list
  }
[@@deriving yojson, show]

(** Subscription event types *)
type event_type =
  | TaskUpdate
  | Broadcast
  | Completion
  | Error
  | HeartbeatTask (** Agent embodiment request — Worker should invoke MODEL *)
[@@deriving show]

let event_type_of_string = function
  | "task_update" -> Ok TaskUpdate
  | "broadcast" -> Ok Broadcast
  | "completion" -> Ok Completion
  | "error" -> Ok Error
  | "heartbeat_task" -> Ok HeartbeatTask
  | s -> Error (Printf.sprintf "Unknown event type: %s" s)
;;

(* ---------- A2A v0.3 Task State Machine ---------- *)

(** A2A v0.3 task states.
    @see https://a2a-protocol.org/latest/specification/ *)
type a2a_task_state =
  | Working (** Processing in progress *)
  | Completed (** Successfully finished *)
  | Failed (** Processing error *)
  | Canceled (** Client-requested cancellation *)
  | Rejected (** Server rejected execution *)
  | Input_required (** Awaiting additional client input *)
  | Auth_required (** Awaiting client authentication *)
[@@deriving show]

let a2a_task_state_to_string = function
  | Working -> "working"
  | Completed -> "completed"
  | Failed -> "failed"
  | Canceled -> "canceled"
  | Rejected -> "rejected"
  | Input_required -> "input_required"
  | Auth_required -> "auth_required"
;;

let a2a_task_state_of_string = function
  | "working" -> Ok Working
  | "completed" -> Ok Completed
  | "failed" -> Ok Failed
  | "canceled" -> Ok Canceled
  | "rejected" -> Ok Rejected
  | "input_required" -> Ok Input_required
  | "auth_required" -> Ok Auth_required
  | s -> Error (Printf.sprintf "Unknown A2A task state: %s" s)
;;

(** Map MASC internal task status to A2A v0.3 state.
    MASC: Todo | Claimed | InProgress | Done | Cancelled
    A2A:  working | completed | failed | canceled | rejected | input_required | auth_required *)
let masc_status_to_a2a (status : Types.task_status) : a2a_task_state =
  match status with
  | Types.Todo -> Working (* pending task = actively in queue *)
  | Types.Claimed _ -> Working (* claimed = agent working on it *)
  | Types.InProgress _ -> Working (* explicit in-progress *)
  | Types.AwaitingVerification _ -> Working (* awaiting verifier action *)
  | Types.Done _ -> Completed (* done = completed *)
  | Types.Cancelled _ -> Canceled (* cancelled = canceled *)
;;

(** A2A v0.3 Task Status object *)
type a2a_task_status =
  { state : a2a_task_state
  ; timestamp : string
  ; message : string option
  }

let a2a_task_status_to_json (s : a2a_task_status) : Yojson.Safe.t =
  `Assoc
    ([ "state", `String (a2a_task_state_to_string s.state)
     ; "timestamp", `String s.timestamp
     ]
     @
     match s.message with
     | None -> []
     | Some m -> [ "message", `String m ])
;;

(** A2A protocol version — parsed from A2A-Version header *)
let default_a2a_version = "0.3"

let parse_a2a_version header_value =
  match header_value with
  | None -> default_a2a_version
  | Some v ->
    let trimmed = String.trim v in
    if String.length trimmed > 0 then trimmed else default_a2a_version
;;
