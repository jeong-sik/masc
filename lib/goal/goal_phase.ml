type t =
  | Executing
  | Blocked
  | Paused
  | Completed
  | Dropped

let to_string = function
  | Executing -> "executing"
  | Blocked -> "blocked"
  | Paused -> "paused"
  | Completed -> "completed"
  | Dropped -> "dropped"

let of_string = function
  | "executing" -> Some Executing
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

(* Every phase, declaration order. SSOT for the MCP schema enum and the
   workspace_goals validator so neither hand-rolls the string set (RFC-0089;
   the #8372 anti-pattern). [to_string] is the exhaustive compile-time witness:
   a new constructor breaks it; the round-trip test guards this list. *)
let all =
  [ Executing
  ; Blocked
  ; Paused
  ; Completed
  ; Dropped
  ]

(* Phases from which a keeper can make self-directed progress on the goal. *)
let admits_self_directed_progress = function
  | Executing -> true
  | Blocked | Paused | Completed | Dropped -> false

type action =
  | Request_complete
  | Pause
  | Resume
  | Block
  | Unblock
  | Drop
  | Reopen

let action_to_string = function
  | Request_complete -> "request_complete"
  | Pause -> "pause"
  | Resume -> "resume"
  | Block -> "block"
  | Unblock -> "unblock"
  | Drop -> "drop"
  | Reopen -> "reopen"

(* Every action, declaration order. SSOT for the schema/validator action enum
   (see [all]). [action_to_string] is the exhaustive witness. *)
let all_actions =
  [ Request_complete
  ; Pause
  ; Resume
  ; Block
  ; Unblock
  ; Drop
  ; Reopen
  ]

let action_of_string = function
  | "request_complete" -> Some Request_complete
  | "pause" -> Some Pause
  | "resume" -> Some Resume
  | "block" -> Some Block
  | "unblock" -> Some Unblock
  | "drop" -> Some Drop
  | "reopen" -> Some Reopen
  | _ -> None

let parse_action s =
  String.trim s |> String.lowercase_ascii |> action_of_string

type transition_outcome =
  | Move_to of t
  | Complete

(* Every (phase, action) pair is stated. The catch-all this replaces absorbed
   22 of the 35 pairs, so adding a phase or an action compiled cleanly and the
   new combinations silently became "invalid" — the same FSM sparse-match class
   that produced a runtime Assert_failure in keeper_registry. The compiler now
   refuses a matrix with a hole in it. *)
let decide_transition ~phase ~(action : action) =
  let invalid =
    Error
      (Printf.sprintf "invalid goal transition: %s -> %s"
         (to_string phase) (action_to_string action))
  in
  match phase, action with
  (* Executing: the only phase that can request completion. *)
  | Executing, Request_complete -> Ok Complete
  | Executing, Pause -> Ok (Move_to Paused)
  | Executing, Block -> Ok (Move_to Blocked)
  | Executing, Drop -> Ok (Move_to Dropped)
  | Executing, (Resume | Unblock | Reopen) -> invalid
  (* Paused: resumes or drops; it is not blocked and not finished. *)
  | Paused, Resume -> Ok (Move_to Executing)
  | Paused, Drop -> Ok (Move_to Dropped)
  | Paused, (Request_complete | Pause | Block | Unblock | Reopen) -> invalid
  (* Blocked: unblocks or drops. Completing while blocked would skip the
     impediment rather than resolve it. *)
  | Blocked, Unblock -> Ok (Move_to Executing)
  | Blocked, Drop -> Ok (Move_to Dropped)
  | Blocked, (Request_complete | Pause | Resume | Block | Reopen) -> invalid
  (* Completed and Dropped are terminal: only reopening leaves them. *)
  | Completed, Reopen -> Ok (Move_to Executing)
  | Completed, Drop -> Ok (Move_to Dropped)
  | Completed, (Request_complete | Pause | Resume | Block | Unblock) -> invalid
  | Dropped, Reopen -> Ok (Move_to Executing)
  | Dropped, (Request_complete | Pause | Resume | Block | Unblock | Drop) ->
    invalid
