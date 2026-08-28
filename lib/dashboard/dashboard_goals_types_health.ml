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

let goal_fsm_state_kind = function
  | Goal_phase.Executing -> "executing"
  | Goal_phase.Verifying -> "verifying"
  | Goal_phase.Completed -> "completed"
  | Goal_phase.Dropped -> "dropped"

let goal_fsm_next_actions ~goal_phase =
  [
    Goal_phase.Request_complete;
    Goal_phase.Drop;
    Goal_phase.Reopen;
    (* RFC-0387 stage 2: the verifier's proof commits are the only moves out
       of [Verifying]; on every other phase they are invalid and the filter
       below drops them. Criterion verdicts are phase-neutral ([Already]), so
       they never read as a next step. *)
    Goal_phase.Record_proof_proven;
    Goal_phase.Record_proof_refuted;
  ]
  |> List.filter (fun action ->
         match
           Goal_phase.decide_transition ~phase:goal_phase ~action
         with
         (* Next actions are the ones that move the goal. [Already] is accepted
            by the tool but changes nothing, and listing "pause" under a paused
            goal reads as a step that is still to come. Written as an explicit
            arm because [Ok _] would have absorbed the new outcome and widened
            this list without a compiler error. *)
         | Ok (Goal_phase.Move_to _) -> true
         | Ok (Goal_phase.Already _) -> false
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
