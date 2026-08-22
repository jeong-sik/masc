type t =
  | Executing
  | Blocked
  | Paused
  | Verifying
  | Completed
  | Dropped

let to_string = function
  | Executing -> "executing"
  | Blocked -> "blocked"
  | Paused -> "paused"
  | Verifying -> "verifying"
  | Completed -> "completed"
  | Dropped -> "dropped"

let of_string = function
  | "executing" -> Some Executing
  | "blocked" -> Some Blocked
  | "paused" -> Some Paused
  | "verifying" -> Some Verifying
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
  ; Verifying
  ; Completed
  ; Dropped
  ]

(* Phases from which a keeper can make self-directed progress on the goal.
   [Verifying] admits continued progress on the linked tasks while the
   completion proof is judged out-of-band (RFC-0387 stage 2): the gate holds
   the phase, not the work — a keeper whose goal entered [Verifying] must
   still see it as its own (P0-1 of the stage-2 review). *)
let admits_self_directed_progress = function
  | Executing -> true
  | Verifying -> true
  | Blocked | Paused | Completed | Dropped -> false

type action =
  | Request_complete
  | Pause
  | Resume
  | Block
  | Unblock
  | Drop
  | Reopen
  | Record_proof_proven
  | Record_proof_refuted

let action_to_string = function
  | Request_complete -> "request_complete"
  | Pause -> "pause"
  | Resume -> "resume"
  | Block -> "block"
  | Unblock -> "unblock"
  | Drop -> "drop"
  | Reopen -> "reopen"
  | Record_proof_proven -> "record_proof_proven"
  | Record_proof_refuted -> "record_proof_refuted"

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
  ; Record_proof_proven
  ; Record_proof_refuted
  ]

let action_of_string = function
  | "request_complete" -> Some Request_complete
  | "pause" -> Some Pause
  | "resume" -> Some Resume
  | "block" -> Some Block
  | "unblock" -> Some Unblock
  | "drop" -> Some Drop
  | "reopen" -> Some Reopen
  | "record_proof_proven" -> Some Record_proof_proven
  | "record_proof_refuted" -> Some Record_proof_refuted
  | _ -> None

let parse_action s =
  String.trim s |> String.lowercase_ascii |> action_of_string

module Public_action = struct
  type t =
    | Request_complete
    | Pause
    | Resume
    | Block
    | Unblock
    | Drop
    | Reopen

  let to_action : t -> action = function
    | Request_complete -> (Request_complete : action)
    | Pause -> (Pause : action)
    | Resume -> (Resume : action)
    | Block -> (Block : action)
    | Unblock -> (Unblock : action)
    | Drop -> (Drop : action)
    | Reopen -> (Reopen : action)
  ;;

  let to_string action = action_to_string (to_action action)

  let of_string = function
    | "request_complete" -> Some Request_complete
    | "pause" -> Some Pause
    | "resume" -> Some Resume
    | "block" -> Some Block
    | "unblock" -> Some Unblock
    | "drop" -> Some Drop
    | "reopen" -> Some Reopen
    | _ -> None
  ;;

  let parse raw =
    String.trim raw |> String.lowercase_ascii |> of_string
  ;;

  let all = [ Request_complete; Pause; Resume; Block; Unblock; Drop; Reopen ]
end


type outcome =
  | Move_to of t
  | Already of t


(* Every (phase, action) pair is stated. The catch-all this replaces absorbed
   22 of the 35 pairs, so adding a phase or an action compiled cleanly and the
   new combinations silently became "invalid" — the same FSM sparse-match class
   that produced a runtime Assert_failure in keeper_registry. The compiler now
   refuses a matrix with a hole in it (6 phases x 11 actions since RFC-0387
   stage 2 added [Verifying] and the four gate actions). *)
(* The diagonal -- an action whose target phase the goal already occupies --
   answers [Already]. It used to answer "invalid goal transition", which is the
   opposite of what the Task FSM says for the same shape: there, Cancel on a
   Cancelled task and Done_action on a Done task both return the status
   unchanged. Two domains a Keeper reaches for in one breath disagreed about
   whether asking for a state you are in is an error.

   The live log shows what that cost. A reconciliation event fired four times
   for one already-completed Goal, and the Keeper's own notes on the refused
   calls read "Goal already completed at 08:57:35Z. This is a duplicate
   reconciliation event" and "Already completed at 09:00:32Z. Stale racing
   event." It knew, it reported accurately, and it was refused.

   [Already] is not [Move_to]: the caller must not write or emit a phase event
   for it, or a repeated report would produce repeated history. *)
let decide_transition ~phase ~(action : action) =
  let invalid =
    Error
      (Printf.sprintf "invalid goal transition: %s -> %s"
         (to_string phase) (action_to_string action))
  in
  match phase, action with
  (* Executing: the only phase that can request completion. RFC-0387 stage 2:
     the request no longer completes the goal — it enters [Verifying], and
     only the verifier's [Record_proof_proven] reaches [Completed]. Resume,
     Unblock and Reopen all target Executing, which is where the goal already
     is. *)
  | Executing, Request_complete -> Ok (Move_to Verifying)
  | Executing, Pause -> Ok (Move_to Paused)
  | Executing, Block -> Ok (Move_to Blocked)
  | Executing, Drop -> Ok (Move_to Dropped)
  | Executing, (Resume | Unblock | Reopen) -> Ok (Already Executing)
  | Executing, (Record_proof_proven | Record_proof_refuted) -> invalid
  (* Paused: resumes or drops; it is not blocked and not finished. *)
  | Paused, Resume -> Ok (Move_to Executing)
  | Paused, Drop -> Ok (Move_to Dropped)
  | Paused, Pause -> Ok (Already Paused)
  | Paused,
    ( Request_complete | Block | Unblock | Reopen
    | Record_proof_proven | Record_proof_refuted ) -> invalid
  (* Blocked: unblocks or drops. Completing while blocked would skip the
     impediment rather than resolve it. *)
  | Blocked, Unblock -> Ok (Move_to Executing)
  | Blocked, Drop -> Ok (Move_to Dropped)
  | Blocked, Block -> Ok (Already Blocked)
  | Blocked,
    ( Request_complete | Pause | Resume | Reopen
    | Record_proof_proven | Record_proof_refuted ) -> invalid
  (* Verifying (RFC-0387 stage 2): the completion request is in the pipeline
     and the proof is judged out-of-band. Only the verifier's proof actions
     leave the phase; a repeated [Request_complete] is the explicit retry the
     RFC substitutes for wall-clock expiry, so it answers [Already] and the
     handler reports (and re-arms) the pending proof. Pausing mid-verdict is
     out of scope (RFC-0387 §7). *)
  | Verifying, Record_proof_proven -> Ok (Move_to Completed)
  | Verifying, Record_proof_refuted -> Ok (Move_to Executing)
  | Verifying, Request_complete -> Ok (Already Verifying)
  | Verifying, (Pause | Resume | Block | Unblock | Drop | Reopen) -> invalid
  (* Completed and Dropped are terminal: only reopening leaves them.
     [Dropped, Request_complete] stays invalid -- completion is not the phase a
     dropped goal is in, so it is a real request for a state change, not a
     restatement. Reopen first. *)
  | Completed, Reopen -> Ok (Move_to Executing)
  | Completed, Drop -> Ok (Move_to Dropped)
  | Completed, Request_complete -> Ok (Already Completed)
  | Completed,
    ( Pause | Resume | Block | Unblock
    | Record_proof_proven | Record_proof_refuted ) -> invalid
  | Dropped, Reopen -> Ok (Move_to Executing)
  | Dropped, Drop -> Ok (Already Dropped)
  | Dropped,
    ( Request_complete | Pause | Resume | Block | Unblock
    | Record_proof_proven | Record_proof_refuted ) -> invalid
