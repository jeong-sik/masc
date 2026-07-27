let ( let* ) = Result.bind

type snapshot =
  { workspace_identity : string
  ; state_version : int
  ; goal : Goal_store.goal
  ; goal_json : Yojson.Safe.t
  ; completion_claim : string
  ; requesting_agent : string
  ; linked_tasks_json : Yojson.Safe.t
  ; linked_task_ids : string list
  ; child_goals_json : Yojson.Safe.t
  ; evidence_sha256 : string
  }

type seal =
  { snapshot : snapshot
  ; operation_id : string
  ; evaluator_runtime : string
  ; reviewed_at : string
  ; review_prompt_sha256 : string
  }

type commit_error =
  | Snapshot_changed of string
  | Current_evidence_unavailable of string
  | Persistence_failed of string

let snapshot_goal_id snapshot = snapshot.goal.id
let snapshot_goal_json snapshot = snapshot.goal_json
let snapshot_linked_tasks_json snapshot = snapshot.linked_tasks_json
let snapshot_linked_task_ids snapshot = snapshot.linked_task_ids
let snapshot_child_goals_json snapshot = snapshot.child_goals_json
let snapshot_workspace_identity snapshot = snapshot.workspace_identity
let snapshot_state_version snapshot = snapshot.state_version
let snapshot_completion_claim snapshot = snapshot.completion_claim
let snapshot_requesting_agent snapshot = snapshot.requesting_agent

let evidence_from_current
      ~config
      ~workspace_identity
      ~state_version
      ~state_goals
      ~goal
      ~completion_claim
      ~requesting_agent
  =
  let* backlog = Workspace_backlog.read_backlog_current_r config in
  let* links = Workspace_goal_index.read_goal_task_links_current_r config in
  let index =
    Workspace_goal_index.build_goal_task_index
      ~goal_task_links:links
      backlog.Masc_domain.tasks
  in
  let linked_tasks = Workspace_goal_index.tasks_for_goal index ~goal_id:goal.id in
  let linked_tasks_json =
    `List (List.map Masc_domain.task_to_yojson linked_tasks)
  in
  let linked_task_ids =
    List.map (fun (task : Masc_domain.task) -> task.id) linked_tasks
  in
  let child_goals =
    List.filter
      (fun (candidate : Goal_store.goal) ->
         candidate.parent_goal_id = Some goal.id)
      state_goals
  in
  let child_goals_json =
    `List (List.map Goal_store.goal_to_yojson child_goals)
  in
  let goal_json = Goal_store.goal_to_yojson goal in
  let evidence_sha256 =
    Goal_completion_contract.review_evidence_sha256
      ~workspace_identity
      ~goal_json
      ~completion_claim
      ~requesting_agent
      ~linked_tasks_json
      ~linked_task_ids
      ~child_goals_json
  in
  Ok
    { workspace_identity
    ; state_version
    ; goal
    ; goal_json
    ; completion_claim
    ; requesting_agent
    ; linked_tasks_json
    ; linked_task_ids
    ; child_goals_json
    ; evidence_sha256
    }
;;

let capture_snapshot
      ~config
      ~goal
      ~state_version
      ~completion_claim
      ~requesting_agent
  =
  let* workspace_identity = Goal_store.canonical_workspace_identity config in
  if String.trim completion_claim = "" then Error "Goal completion claim must be non-empty"
  else if String.trim requesting_agent = "" then Error "Goal completion requester must be non-empty"
  else
    let state = Goal_store.read_state config in
    if state.version <> state_version then
      Error "Goal store version changed before completion review"
    else
      match List.find_opt (fun (current : Goal_store.goal) -> String.equal current.id goal.id) state.goals with
      | None -> Error "Goal disappeared before completion review"
      | Some current
        when Stdlib.( <> )
               (Goal_store.goal_to_yojson current)
               (Goal_store.goal_to_yojson goal) ->
        Error "Goal changed before completion review"
      | Some current when not (Goal_store.Phase.is_executing current.phase) ->
        Error "Only an executing Goal can enter completion review"
      | Some current ->
        evidence_from_current
          ~config
          ~workspace_identity
          ~state_version
          ~state_goals:state.goals
          ~goal:current
          ~completion_claim
          ~requesting_agent
;;

let seal_approved_review
      ~snapshot
      ~operation_id
      ~evaluator_runtime
      ~reviewed_at
      ~review_prompt_sha256
  =
  { snapshot
  ; operation_id
  ; evaluator_runtime
  ; reviewed_at
  ; review_prompt_sha256
  }
;;

let replace_assoc name value = function
  | `Assoc fields ->
    `Assoc ((name, value) :: List.remove_assoc name fields)
  | _ -> invalid_arg "Goal_state_internal.replace_assoc: expected object"
;;

let target_goal_json goal commit_at =
  Goal_store.goal_to_yojson goal
  |> replace_assoc "phase" (`String "completed")
  |> replace_assoc "completion_review_failure" `Null
  |> replace_assoc "completion_receipt" `Null
  |> replace_assoc "updated_at" (`String commit_at)
;;

let receipt_json seal ~target_goal_json =
  let snapshot = seal.snapshot in
  let completion_digest =
    Goal_completion_contract.completion_digest
      ~workspace_identity:snapshot.workspace_identity
      ~goal_json:target_goal_json
      ~reviewed_goal_updated_at:snapshot.goal.updated_at
      ~goal_id:snapshot.goal.id
      ~expected_version:snapshot.state_version
      ~operation_id:seal.operation_id
      ~evaluator_runtime:seal.evaluator_runtime
      ~reviewed_at:seal.reviewed_at
      ~review_prompt_sha256:seal.review_prompt_sha256
      ~review_evidence_sha256:snapshot.evidence_sha256
      ~completion_claim:snapshot.completion_claim
      ~requesting_agent:snapshot.requesting_agent
      ~linked_task_ids:snapshot.linked_task_ids
  in
  `Assoc
    [ "workspace_identity", `String snapshot.workspace_identity
    ; "expected_state_version", `Int snapshot.state_version
    ; "operation_id", `String seal.operation_id
    ; "completion_digest", `String completion_digest
    ; "review_evidence_sha256", `String snapshot.evidence_sha256
    ; "evaluator_runtime", `String seal.evaluator_runtime
    ; "reviewed_at", `String seal.reviewed_at
    ; "reviewed_goal_updated_at", `String snapshot.goal.updated_at
    ; "review_prompt_sha256", `String seal.review_prompt_sha256
    ; "completion_claim", `String snapshot.completion_claim
    ; "requesting_agent", `String snapshot.requesting_agent
    ; ( "linked_task_ids"
      , `List (List.map (fun id -> `String id) snapshot.linked_task_ids) )
    ]
;;

let goal_equal left right =
  Stdlib.( = )
    (Goal_store.goal_to_yojson left)
    (Goal_store.goal_to_yojson right)
;;

let commit_under_all_locks ~config seal =
  let state = Goal_store.read_state config in
  if state.version <> seal.snapshot.state_version then
    Error (Snapshot_changed "Goal store version changed during completion review")
  else
    match List.find_opt (fun (goal : Goal_store.goal) -> String.equal goal.id seal.snapshot.goal.id) state.goals with
    | None -> Error (Snapshot_changed "Goal disappeared during completion review")
    | Some current when not (goal_equal current seal.snapshot.goal) ->
      Error (Snapshot_changed "Goal changed during completion review")
    | Some current when not (Goal_store.Phase.is_executing current.phase) ->
      Error (Snapshot_changed "Goal is no longer executing")
    | Some current ->
      let* current_snapshot =
        evidence_from_current
          ~config
          ~workspace_identity:seal.snapshot.workspace_identity
          ~state_version:state.version
          ~state_goals:state.goals
          ~goal:current
          ~completion_claim:seal.snapshot.completion_claim
          ~requesting_agent:seal.snapshot.requesting_agent
        |> Result.map_error (fun message -> Current_evidence_unavailable message)
      in
      if not (String.equal current_snapshot.evidence_sha256 seal.snapshot.evidence_sha256) then
        Error (Snapshot_changed "Goal completion evidence changed during review")
      else
        let commit_at = Masc_domain.now_iso () in
        let target_goal_json = target_goal_json current commit_at in
        let completed_goal_json =
          replace_assoc
            "completion_receipt"
            (receipt_json seal ~target_goal_json)
            target_goal_json
        in
        let goals_json =
          `List
            (List.map
               (fun (goal : Goal_store.goal) ->
                  if String.equal goal.id current.id
                  then completed_goal_json
                  else Goal_store.goal_to_yojson goal)
               state.goals)
        in
        let state_json =
          `Assoc
            [ "version", `Int (state.version + 1)
            ; "updated_at", `String commit_at
            ; "goals", goals_json
            ]
        in
        let* () =
          Workspace_utils.write_json_result config (Goal_store.goals_path config) state_json
          |> Result.map_error (fun message -> Persistence_failed message)
        in
        let committed = Goal_store.read_state config in
        (match List.find_opt (fun (goal : Goal_store.goal) -> String.equal goal.id current.id) committed.goals with
         | Some goal when Goal_store.Phase.is_completed goal.phase -> Ok goal
         | Some _ -> Error (Persistence_failed "Committed Goal did not decode as Completed")
         | None -> Error (Persistence_failed "Committed Goal disappeared after write"))
;;

let commit_completed ~config seal =
  let backlog_lock_path = Filename.concat (Workspace_utils.tasks_dir config) ".backlog" in
  try
    Workspace_utils.with_file_lock config backlog_lock_path (fun () ->
      Workspace_utils.with_file_lock
        config
        (Workspace_goal_index.goal_task_links_lock_path config)
        (fun () ->
           Workspace_utils.with_file_lock
             config
             (Goal_store.goals_path config)
             (fun () -> commit_under_all_locks ~config seal)))
  with exn ->
    Error (Persistence_failed (Printexc.to_string exn))
;;
