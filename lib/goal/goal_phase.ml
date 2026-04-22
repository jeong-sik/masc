type t =
  | Executing
  | Awaiting_verification
  | Awaiting_approval
  | Blocked
  | Paused
  | Completed
  | Dropped

let to_string = function
  | Executing -> "executing"
  | Awaiting_verification -> "awaiting_verification"
  | Awaiting_approval -> "awaiting_approval"
  | Blocked -> "blocked"
  | Paused -> "paused"
  | Completed -> "completed"
  | Dropped -> "dropped"

let of_string = function
  | "executing" -> Some Executing
  | "awaiting_verification" -> Some Awaiting_verification
  | "awaiting_approval" -> Some Awaiting_approval
  | "blocked" -> Some Blocked
  | "paused" -> Some Paused
  | "completed" -> Some Completed
  | "dropped" -> Some Dropped
  | _ -> None

let parse s =
  String.trim s |> String.lowercase_ascii |> of_string

let to_yojson t =
  `String (to_string t)

let of_yojson = function
  | `String raw -> (
      match parse raw with
      | Some phase -> Ok phase
      | None -> Error ("goal_phase_of_yojson: " ^ raw))
  | json ->
      Error ("goal_phase_of_yojson: " ^ Yojson.Safe.to_string json)

type action =
  | Request_complete
  | Approve_completion
  | Reject_completion
  | Pause
  | Resume
  | Operator_block
  | Operator_unblock
  | Drop
  | Reopen

let action_to_string = function
  | Request_complete -> "request_complete"
  | Approve_completion -> "approve_completion"
  | Reject_completion -> "reject_completion"
  | Pause -> "pause"
  | Resume -> "resume"
  | Operator_block -> "operator_block"
  | Operator_unblock -> "operator_unblock"
  | Drop -> "drop"
  | Reopen -> "reopen"

let action_of_string = function
  | "request_complete" -> Some Request_complete
  | "approve_completion" -> Some Approve_completion
  | "reject_completion" -> Some Reject_completion
  | "pause" -> Some Pause
  | "resume" -> Some Resume
  | "operator_block" -> Some Operator_block
  | "operator_unblock" -> Some Operator_unblock
  | "drop" -> Some Drop
  | "reopen" -> Some Reopen
  | _ -> None

let parse_action s =
  String.trim s |> String.lowercase_ascii |> action_of_string

type transition_outcome =
  | Move_to of t
  | Open_verification
  | Open_approval
  | Complete

let decide_transition ~phase ~(action : action) ~has_effective_verifier_policy
    ~require_completion_approval =
  match phase, action with
  | Executing, Request_complete ->
      if has_effective_verifier_policy then
        Ok Open_verification
      else if require_completion_approval then
        Ok Open_approval
      else
        Ok Complete
  | Executing, Pause -> Ok (Move_to Paused)
  | Executing, Operator_block -> Ok (Move_to Blocked)
  | Executing, Drop -> Ok (Move_to Dropped)
  | Paused, Resume -> Ok (Move_to Executing)
  | Paused, Drop -> Ok (Move_to Dropped)
  | Blocked, Operator_unblock -> Ok (Move_to Executing)
  | Blocked, Drop -> Ok (Move_to Dropped)
  | Awaiting_approval, Approve_completion -> Ok Complete
  | Awaiting_approval, Reject_completion -> Ok (Move_to Blocked)
  | Awaiting_approval, Drop -> Ok (Move_to Dropped)
  | Awaiting_verification, Drop -> Ok (Move_to Dropped)
  | Completed, Reopen -> Ok (Move_to Executing)
  | Completed, Drop -> Ok (Move_to Dropped)
  | Dropped, Reopen -> Ok (Move_to Executing)
  | _ ->
      Error
        (Printf.sprintf "invalid goal transition: %s -> %s"
           (to_string phase) (action_to_string action))
