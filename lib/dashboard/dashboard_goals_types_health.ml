(** Dashboard_goals_types_health — Stage 22 split (was inline in
    dashboard_goals_types.ml).

    Pure approval matching, keeper assignee resolution, and explicit Goal
    FSM projection. Goal phase is the display truth; this module does not
    derive a second operational hierarchy.

    Depends on [Dashboard_goals_types_accessor] for the [tree_node]
    record. Re-included by
    [Dashboard_goals_types] so the public surface is unchanged. *)

open Dashboard_goals_types_accessor

let approval_matches_goal goal_id approval_json =
  let goal_ids = Json_util.get_string_list approval_json "goal_ids" in
  List.mem goal_id goal_ids
  ||
  match Json_util.get_string approval_json "goal_id" with
  | Some pending_goal_id -> String.equal pending_goal_id goal_id
  | None -> false

let keeper_name_matches_meta metas name =
  List.exists (fun (meta : Keeper_meta_contract.keeper_meta) -> String.equal meta.name name) metas

let keeper_name_of_assignee metas assignee =
  match Keeper_identity.canonical_keeper_name_from_agent_name assignee with
  | Some keeper_name -> Some keeper_name
  | None ->
      if keeper_name_matches_meta metas assignee then Some assignee
      else None

let goal_fsm_state_kind = function
  | Goal_phase.Executing -> "executing"
  | Goal_phase.Blocked -> "blocked"
  | Goal_phase.Paused -> "paused"
  | Goal_phase.Completed -> "completed"
  | Goal_phase.Dropped -> "dropped"

let goal_fsm_next_actions ~goal_phase =
  [
    Goal_phase.Request_complete;
    Goal_phase.Pause;
    Goal_phase.Resume;
    Goal_phase.Block;
    Goal_phase.Unblock;
    Goal_phase.Drop;
    Goal_phase.Reopen;
  ]
  |> List.filter (fun action ->
         match
           Goal_phase.decide_transition ~phase:goal_phase ~action
         with
         | Ok _ -> true
         | Error _ -> false)
  |> List.map Goal_phase.action_to_string

let goal_fsm_to_json (goal : Goal_store.goal) (node : tree_node) =
  `Assoc
    [
      ("state", Goal_phase.to_yojson goal.phase);
      ("source", `String "goal.phase");
      ("state_kind", `String (goal_fsm_state_kind goal.phase));
      ( "next_actions",
        `List
          (goal_fsm_next_actions ~goal_phase:goal.phase
          |> List.map (fun action -> `String action)) );
      ("activity_observation", `String node.activity_observation);
    ]
