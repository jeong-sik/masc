module List = Stdlib.List

(** Tool_catalog_inference — typed-tool-name -> effect_domain / tool_group.

    Pure inference layer. Given a {!Tool_name.t} variant, returns the
    inferred {!effect_domain} or {!tool_group}. The facade
    [Tool_catalog] re-exports these via type aliasing so the public
    contract in [tool_catalog.mli] is unchanged.

    {b Why split}: this is the largest pure section of [tool_catalog]
    (~410 LoC of typed-name pattern matches with no side effects).
    Moving it out shrinks the facade and isolates churn when new
    [Tool_name] variants are added. *)

type effect_domain =
  | Read_only
  | Masc_workspace
  | Playground_write
  | Host_repo_write

type tool_group =
  | Masc_board
  | Masc_plan
  | Masc_agent
  | Masc_core

let effect_domain_to_string = function
  | Read_only -> "read_only"
  | Masc_workspace -> "masc_workspace"
  | Playground_write -> "playground_write"
  | Host_repo_write -> "host_repo_write"

let tool_group_to_string = function
  | Masc_board -> "masc_board"
  | Masc_plan -> "masc_plan"
  | Masc_agent -> "masc_agent"
  | Masc_core -> "masc_core"

module TN = Tool_name
module TM = Tool_name.Masc

let inferred_effect_domain_of_typed_tool_name = function
  | TN.Masc TM.Deliver
  | TN.Masc TM.Operator_action
  | TN.Masc TM.Start ->
      Some Host_repo_write
  | TN.Masc TM.Agent_fitness
  | TN.Masc TM.Agent_card
  | TN.Masc TM.Agents
  | TN.Masc TM.Board_get
  | TN.Masc TM.Board_curation_read
  | TN.Masc TM.Board_hearths
  | TN.Masc TM.Board_list
  | TN.Masc TM.Board_profile
  | TN.Masc TM.Board_search
  | TN.Masc TM.Board_stats
  | TN.Masc TM.Check
  | TN.Masc TM.Config
  | TN.Masc TM.Dashboard
  | TN.Masc TM.Get_metrics
  | TN.Masc TM.Goal_list
  | TN.Masc TM.Mcp_session
  | TN.Masc TM.Messages
  | TN.Masc TM.Operator_digest
  | TN.Masc TM.Operator_snapshot
  | TN.Masc TM.Plan_get
  | TN.Masc TM.Plan_get_task
  | TN.Masc TM.Status
  | TN.Masc TM.Task_history
  | TN.Masc TM.Tasks
  | TN.Masc TM.Tool_admin_snapshot
  | TN.Masc TM.Tool_help
  | TN.Masc TM.Tool_list
  | TN.Masc TM.Tool_stats
  | TN.Masc TM.Web_fetch
  | TN.Masc TM.Web_search
  | TN.Masc TM.Board_sub_board_get
  | TN.Masc TM.Board_sub_board_list
  | TN.Masc TM.Approval_pending
  | TN.Masc TM.Approval_get ->
      Some Read_only
  | TN.Masc TM.Add_task
  | TN.Masc TM.Agent_update
  | TN.Masc TM.Batch_add_tasks
  | TN.Masc TM.Board_cleanup
  | TN.Masc TM.Board_comment
  | TN.Masc TM.Board_comment_vote
  | TN.Masc TM.Board_curation_submit
  | TN.Masc TM.Board_delete
  | TN.Masc TM.Board_post
  | TN.Masc TM.Board_reaction
  | TN.Masc TM.Board_sub_board_create
  | TN.Masc TM.Board_sub_board_delete
  | TN.Masc TM.Board_sub_board_update
  | TN.Masc TM.Board_vote
  | TN.Masc TM.Broadcast
  | TN.Masc TM.Claim_next
  | TN.Masc TM.Cleanup_zombies
  | TN.Masc TM.Gc
  | TN.Masc TM.Goal_transition
  | TN.Masc TM.Goal_upsert
  | TN.Masc TM.Goal_verify
  | TN.Masc TM.Heartbeat
  | TN.Masc TM.Note_add
  | TN.Masc TM.Operator_confirm
  | TN.Masc TM.Pause
  | TN.Masc TM.Plan_clear_task
  | TN.Masc TM.Plan_init
  | TN.Masc TM.Plan_set_task
  | TN.Masc TM.Plan_update
  | TN.Masc TM.Reset
  | TN.Masc TM.Resume
  | TN.Masc TM.Tool_admin_update
  | TN.Masc TM.Tool_grant
  | TN.Masc TM.Tool_revoke
  | TN.Masc TM.Transition
  | TN.Masc TM.Update_priority ->
      Some Masc_workspace
  | TN.Keeper _ | TN.Masc_keeper _ -> None
let inferred_effect_domain name =
  match Tool_name.of_string name with
  | Some typed_name -> inferred_effect_domain_of_typed_tool_name typed_name
  | None -> None

let tool_group_of_typed_tool_name = function
  | TN.Masc
      ( TM.Board_cleanup
      | TM.Board_comment
      | TM.Board_comment_vote
      | TM.Board_curation_read
      | TM.Board_curation_submit
      | TM.Board_delete
      | TM.Board_get
      | TM.Board_hearths
      | TM.Board_list
      | TM.Board_post
      | TM.Board_profile
      | TM.Board_reaction
      | TM.Board_search
      | TM.Board_stats
      | TM.Board_sub_board_create
      | TM.Board_sub_board_delete
      | TM.Board_sub_board_get
      | TM.Board_sub_board_list
      | TM.Board_sub_board_update
      | TM.Board_vote ) ->
      Some Masc_board
  | TN.Masc
      ( TM.Plan_clear_task
      | TM.Plan_get
      | TM.Plan_get_task
      | TM.Plan_init
      | TM.Plan_set_task
      | TM.Plan_update ) ->
      Some Masc_plan
  | TN.Masc (TM.Agent_fitness | TM.Agent_update | TM.Agent_card | TM.Agents) ->
      Some Masc_agent
  | TN.Masc
      ( TM.Add_task
      | TM.Approval_pending
      | TM.Approval_get
      | TM.Batch_add_tasks
      | TM.Broadcast
      | TM.Check
      | TM.Claim_next
      | TM.Cleanup_zombies
      | TM.Config
      | TM.Dashboard
      | TM.Deliver
      | TM.Gc
      | TM.Get_metrics
      | TM.Goal_list
      | TM.Goal_transition
      | TM.Goal_upsert
      | TM.Goal_verify
      | TM.Heartbeat
      | TM.Mcp_session
      | TM.Messages
      | TM.Note_add
      | TM.Operator_action
      | TM.Operator_confirm
      | TM.Operator_digest
      | TM.Operator_snapshot
      | TM.Pause
      | TM.Reset
      | TM.Resume
      | TM.Start
      | TM.Status
      | TM.Task_history
      | TM.Tasks
      | TM.Tool_admin_snapshot
      | TM.Tool_admin_update
      | TM.Tool_grant
      | TM.Tool_help
      | TM.Tool_list
      | TM.Tool_revoke
      | TM.Tool_stats
      | TM.Transition
      | TM.Update_priority
      | TM.Web_fetch
      | TM.Web_search ) ->
      Some Masc_core
  | TN.Keeper _ | TN.Masc_keeper _ -> None

let tool_group name =
  match Tool_name.of_string name with
  | Some typed_name -> tool_group_of_typed_tool_name typed_name
  | None -> None
