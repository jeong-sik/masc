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
  if keeper_name_matches_meta metas assignee then Some assignee else None

let goal_fsm_state_kind = Goal_phase.to_string

let goal_fsm_next_actions ~goal_phase =
  Goal_phase.Public_action.all
  |> List.filter (fun action -> Goal_phase.moves_goal ~phase:goal_phase
         ~action:(Goal_phase.Public_action.to_action action))
  |> List.map Goal_phase.Public_action.to_string

let goal_fsm_to_json (goal : Goal_store.goal) (node : tree_node) =
  `Assoc
    [
      ("state", `String (Goal_phase.to_string goal.phase));
      ("resume_phase", Goal_phase.resume_phase_to_yojson goal.phase);
      ("source", `String "goal.phase");
      ("state_kind", `String (goal_fsm_state_kind goal.phase));
      ( "next_actions",
        `List
          (goal_fsm_next_actions ~goal_phase:goal.phase
          |> List.map (fun action -> `String action)) );
      ("activity_observation", `String node.activity_observation);
    ]
