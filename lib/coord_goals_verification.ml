(** Verification helpers for goal-management tool handlers. *)

let goal_policy_nodes goals =
  List.map
    (fun (goal : Goal_store.goal) ->
       { Goal_verification.goal_id = goal.id
       ; parent_goal_id = goal.parent_goal_id
       ; verifier_policy = goal.verifier_policy
       })
    goals
;;

let verification_summary_json
      ?latest_request
      (goal : Goal_store.goal)
      (effective_policy : Goal_verification.policy_snapshot option)
      (open_request : Goal_verification.goal_verification_request option)
  =
  let latest_request =
    match latest_request with
    | Some request -> Some request
    | None -> open_request
  in
  let effective_policy_json =
    match effective_policy with
    | None -> `Null
    | Some policy -> Goal_verification.policy_snapshot_to_yojson policy
  in
  let open_request_json =
    match open_request with
    | None -> `Null
    | Some request -> Goal_verification.goal_verification_request_to_yojson request
  in
  let latest_request_json =
    match latest_request with
    | None -> `Null
    | Some request -> Goal_verification.goal_verification_request_to_yojson request
  in
  let approve_count, reject_count, remaining_possible =
    let summary_request =
      match open_request with
      | Some request -> Some request
      | None -> latest_request
    in
    match summary_request with
    | None -> 0, 0, 0
    | Some request ->
      ( Goal_verification.count_votes ~decision:Goal_verification.Approve request
      , Goal_verification.count_votes ~decision:Goal_verification.Reject request
      , Goal_verification.remaining_possible_votes request )
  in
  `Assoc
    [ "phase", Goal_phase.to_yojson goal.phase
    ; "effective_policy", effective_policy_json
    ; "open_request", open_request_json
    ; "latest_request", latest_request_json
    ; "approve_count", `Int approve_count
    ; "reject_count", `Int reject_count
    ; "remaining_possible", `Int remaining_possible
    ; "pending_verification_count", `Int (if Option.is_none open_request then 0 else 1)
    ]
;;

let update_goal_phase
      (ctx : Coord_types.context)
      (goal : Goal_store.goal)
      ~phase
      ?note
      ?active_verification_request_id
      ?(clear_active_verification_request = false)
      ()
  =
  let last_review_note, last_review_at =
    match note with
    | Some note -> Some note, Some (Masc_domain.now_iso ())
    | None -> goal.last_review_note, goal.last_review_at
  in
  Goal_store.update_goal ctx.config ~goal_id:goal.id (fun current ->
    { current with
      phase
    ; status = Goal_store.goal_status_of_phase phase
    ; active_verification_request_id =
        (if clear_active_verification_request
         then None
         else (
           match active_verification_request_id with
           | Some value -> Some value
           | None -> current.active_verification_request_id))
    ; last_review_note
    ; last_review_at
    })
;;

let actor_must_be_operator action =
  match action with
  | Goal_phase.Operator_block
  | Goal_phase.Operator_unblock
  | Goal_phase.Approve_completion
  | Goal_phase.Reject_completion -> true
  | Goal_phase.Request_complete
  | Goal_phase.Pause
  | Goal_phase.Resume
  | Goal_phase.Drop
  | Goal_phase.Reopen -> false
;;

let emit_goal_event ctx ~goal_id ~event_type ~payload =
  Goal_verification.emit_event ctx.Coord_types.config ~goal_id ~event_type ~payload
;;
