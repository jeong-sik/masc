type resumable = Resume_executing | Resume_verifying | Resume_awaiting_confirmation

type t =
  | Executing | Verifying | Awaiting_confirmation | Completed | Dropped
  | Paused of resumable | Blocked of resumable

module Kind = struct
  type t = Executing | Verifying | Awaiting_confirmation | Completed | Dropped | Paused | Blocked
  let all = [Executing; Verifying; Awaiting_confirmation; Completed; Dropped; Paused; Blocked]
  let to_string = function
    | Executing -> "executing" | Verifying -> "verifying"
    | Awaiting_confirmation -> "awaiting_confirmation"
    | Completed -> "completed" | Dropped -> "dropped"
    | Paused -> "paused" | Blocked -> "blocked"
  let parse raw =
    let raw = String.lowercase_ascii (String.trim raw) in
    List.find_opt (fun kind -> String.equal (to_string kind) raw) all
end

let kind : t -> Kind.t = function
  | Executing -> Kind.Executing | Verifying -> Kind.Verifying
  | Awaiting_confirmation -> Kind.Awaiting_confirmation
  | Completed -> Kind.Completed | Dropped -> Kind.Dropped
  | Paused _ -> Kind.Paused | Blocked _ -> Kind.Blocked

let to_string phase = Kind.to_string (kind phase)
let of_string = function
  | "executing" -> Some Executing | "verifying" -> Some Verifying
  | "awaiting_confirmation" -> Some Awaiting_confirmation
  | "completed" -> Some Completed | "dropped" -> Some Dropped
  | _ -> None
let parse s = of_string (String.lowercase_ascii (String.trim s))
let restore = function
  | Resume_executing -> Executing | Resume_verifying -> Verifying
  | Resume_awaiting_confirmation -> Awaiting_confirmation
let resume_phase = function
  | Paused target | Blocked target -> Some (restore target)
  | Executing | Verifying | Awaiting_confirmation | Completed | Dropped -> None
let resume_phase_to_yojson phase = match resume_phase phase with
  | None -> `Null | Some target -> `String (to_string target)
let to_yojson phase = match resume_phase phase with
  | None -> `String (to_string phase)
  | Some target -> `Assoc ["state", `String (to_string phase); "resume_phase", `String (to_string target)]
let decode phase target =
  match phase, target with
  | ("paused" | "blocked"), `String raw ->
      let target = match raw with
        | "executing" -> Some Resume_executing | "verifying" -> Some Resume_verifying
        | "awaiting_confirmation" -> Some Resume_awaiting_confirmation | _ -> None in
      (match target with
       | None -> Error "suspended Goal requires a live resume_phase"
       | Some target -> Ok (if phase = "paused" then Paused target else Blocked target))
  | ("paused" | "blocked"), _ -> Error "suspended Goal requires resume_phase"
  | _, `Null -> (match parse phase with Some phase -> Ok phase | None -> Error ("unknown Goal phase: " ^ phase))
  | _, _ -> Error "only a suspended Goal may carry resume_phase"
let of_yojson = function
  | `String raw -> decode raw `Null
  | `Assoc fields when List.sort String.compare (List.map fst fields) = ["resume_phase"; "state"] ->
      (match List.assoc "state" fields with
       | `String ("paused" | "blocked" as phase) -> decode phase (List.assoc "resume_phase" fields)
       | _ -> Error "suspension state must be paused or blocked")
  | _ -> Error "invalid Goal lifecycle value"
let of_fields = function
  | `Assoc fields ->
      (match List.assoc_opt "phase" fields with
       | Some (`String phase) ->
           decode phase (match List.assoc_opt "resume_phase" fields with None -> `Null | Some target -> target)
       | _ -> Error "Goal phase must be a string")
  | _ -> Error "Goal must be an object"
let all =
  [ Executing; Verifying; Awaiting_confirmation; Completed; Dropped
  ; Paused Resume_executing; Paused Resume_verifying; Paused Resume_awaiting_confirmation
  ; Blocked Resume_executing; Blocked Resume_verifying; Blocked Resume_awaiting_confirmation ]
let admits_self_directed_progress = function
  | Executing | Verifying -> true
  | Awaiting_confirmation | Completed | Dropped | Paused _ | Blocked _ -> false
let criterion_changed = function
  | Paused _ -> Paused Resume_executing | Blocked _ -> Blocked Resume_executing
  | Executing | Verifying | Awaiting_confirmation | Completed -> Executing
  | Dropped -> Dropped

type action =
  | Request_complete | Drop | Reopen | Pause | Resume | Block | Unblock
  | Record_proof_proven | Confirm_completion | Record_proof_refuted
let action_to_string = function
  | Request_complete -> "request_complete" | Drop -> "drop" | Reopen -> "reopen"
  | Pause -> "pause" | Resume -> "resume" | Block -> "block" | Unblock -> "unblock"
  | Record_proof_proven -> "record_proof_proven" | Confirm_completion -> "confirm_completion"
  | Record_proof_refuted -> "record_proof_refuted"
let all_actions = [Request_complete; Drop; Reopen; Pause; Resume; Block; Unblock;
                   Record_proof_proven; Confirm_completion; Record_proof_refuted]
let action_of_string raw = List.find_opt (fun action -> action_to_string action = raw) all_actions
module Public_action = struct
  type t = Request_complete | Drop | Reopen | Pause | Resume | Block | Unblock
  let to_action : t -> action = function
    | Request_complete -> Request_complete | Drop -> Drop | Reopen -> Reopen
    | Pause -> Pause | Resume -> Resume | Block -> Block | Unblock -> Unblock
  let to_string action = action_to_string (to_action action)
  let all = [Request_complete; Drop; Reopen; Pause; Resume; Block; Unblock]
  let of_string raw = List.find_opt (fun action -> to_string action = raw) all
  let parse raw = of_string (String.lowercase_ascii (String.trim raw))
end

type outcome = Move_to of t | Already of t
let decide_transition ~phase ~(action : action) =
  let invalid = Error (Printf.sprintf "invalid goal transition: %s -> %s"
                        (to_string phase) (action_to_string action)) in
  match phase, action with
  (* Executing: the only phase that can request completion. RFC-0387 stage 2:
     the request no longer completes the goal — it enters [Verifying], and
     the verifier's [Record_proof_proven] reaches [Awaiting_confirmation]. Reopen
     targets Executing, which is where the goal already is. *)
  | Executing, Request_complete -> Ok (Move_to Verifying)
  | Executing, Drop -> Ok (Move_to Dropped)
  | Executing, Reopen -> Ok (Already Executing)
  | Executing, (Confirm_completion | Record_proof_proven | Record_proof_refuted) -> invalid
  (* Verifying (RFC-0387 stage 2): the completion request is in the pipeline
     and the proof is judged out-of-band. The verifier's proof actions leave
     the phase with a verdict; a repeated [Request_complete] is the explicit
     retry the RFC substitutes for wall-clock expiry, so it answers [Already]
     and the handler reports (and re-arms) the pending proof.

     The operator can also leave without a verdict: [Drop] abandons the goal
     and [Reopen] returns it to [Executing], clearing the pending request.
     Without these a verifier lane that never answers holds the goal in
     [Verifying] with no way out. A verdict that arrives after either one
     names a phase the goal is no longer in and is refused.
     [Confirm_completion] stays invalid: there is no proof to confirm yet. *)
  | Verifying, Record_proof_proven -> Ok (Move_to Awaiting_confirmation)
  | Verifying, Record_proof_refuted -> Ok (Move_to Executing)
  | Verifying, Request_complete -> Ok (Already Verifying)
  | Verifying, Drop -> Ok (Move_to Dropped)
  | Verifying, Reopen -> Ok (Move_to Executing)
  | Verifying, Confirm_completion -> invalid
  (* Completed and Dropped are terminal: only reopening leaves them.
     [Dropped, Request_complete] stays invalid -- completion is not the phase a
     dropped goal is in, so it is a real request for a state change, not a
     restatement. Reopen first. *)
  | Completed, Reopen -> Ok (Move_to Executing)
  | Completed, Drop -> Ok (Move_to Dropped)
  | Completed, Request_complete -> Ok (Already Completed)
  | Completed, Confirm_completion -> Ok (Already Completed)
  | Completed, (Record_proof_proven | Record_proof_refuted) -> invalid
  | Dropped, Reopen -> Ok (Move_to Executing)
  | Dropped, Drop -> Ok (Already Dropped)
  | Dropped,
    ( Confirm_completion | Request_complete | Record_proof_proven | Record_proof_refuted ) -> invalid

  | Awaiting_confirmation, Confirm_completion -> Ok (Move_to Completed)
  | Awaiting_confirmation, Request_complete -> Ok (Already Awaiting_confirmation)
  | Awaiting_confirmation, Reopen -> Ok (Move_to Executing)
  | Awaiting_confirmation, Drop -> Ok (Move_to Dropped)
  | Awaiting_confirmation, (Record_proof_proven | Record_proof_refuted) -> invalid

  | (Paused _ | Blocked _), Drop -> Ok (Move_to Dropped)
  | (Paused _ | Blocked _), Reopen -> Ok (Move_to Executing)
  | (Paused _ | Blocked _),
    (Request_complete | Confirm_completion | Record_proof_proven | Record_proof_refuted) -> invalid

  | Executing, Pause -> Ok (Move_to (Paused Resume_executing))
  | Verifying, Pause -> Ok (Move_to (Paused Resume_verifying))
  | Awaiting_confirmation, Pause -> Ok (Move_to (Paused Resume_awaiting_confirmation))
  | Blocked target, Pause -> Ok (Move_to (Paused target))
  | Paused _, Pause -> Ok (Already phase)
  | Executing, Block -> Ok (Move_to (Blocked Resume_executing))
  | Verifying, Block -> Ok (Move_to (Blocked Resume_verifying))
  | Awaiting_confirmation, Block -> Ok (Move_to (Blocked Resume_awaiting_confirmation))
  | Paused target, Block -> Ok (Move_to (Blocked target))
  | Blocked _, Block -> Ok (Already phase)
  | Paused target, Resume | Blocked target, Unblock -> Ok (Move_to (restore target))
  | (Executing | Verifying | Awaiting_confirmation), (Resume | Unblock) -> Ok (Already phase)
  | Paused _, Unblock | Blocked _, Resume -> invalid
  | (Completed | Dropped), (Pause | Resume | Block | Unblock) -> invalid

let moves_goal ~phase ~action =
  match decide_transition ~phase ~action with
  (* Explicit arms: [Ok _] would absorb a new outcome and widen every list
     built from this without a compiler error. *)
  | Ok (Move_to _) -> true
  | Ok (Already _) -> false
  | Error _ -> false
;;
