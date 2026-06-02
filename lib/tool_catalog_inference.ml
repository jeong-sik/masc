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

(* PR-S1: domain tool names live in these submodules; [TM.Task]/[TM.Board]/
   [TM.Goal]/[TM.Operator] wrap them into [Masc.t]. *)
module TTask = Tool_name.Task_name
module TBoard = Tool_name.Board_name
module TGoal = Tool_name.Goal_name
module TOp = Tool_name.Operator_name

(* PR-S1: NON-uniform across each domain (Board members split Read_only vs
   Masc_workspace; Operator members split three ways), so this match stays flat
   over [Masc.t] with each domain constructor mechanically wrapped — bucket
   groupings unchanged, exhaustiveness still enforced. *)
let inferred_effect_domain_of_typed_tool_name = function
  | TN.Masc TM.Deliver
  | TN.Masc (TM.Operator TOp.Operator_action)
  | TN.Masc TM.Start ->
      Some Host_repo_write
  | TN.Masc TM.Agent_fitness
  | TN.Masc TM.Agent_card
  | TN.Masc TM.Agents
  | TN.Masc (TM.Board TBoard.Board_get)
  | TN.Masc (TM.Board TBoard.Board_curation_read)
  | TN.Masc (TM.Board TBoard.Board_hearths)
  | TN.Masc (TM.Board TBoard.Board_list)
  | TN.Masc (TM.Board TBoard.Board_profile)
  | TN.Masc (TM.Board TBoard.Board_search)
  | TN.Masc (TM.Board TBoard.Board_stats)
  | TN.Masc TM.Check
  | TN.Masc TM.Config
  | TN.Masc TM.Dashboard
  | TN.Masc TM.Get_metrics
  | TN.Masc (TM.Goal TGoal.Goal_list)
  | TN.Masc TM.Mcp_session
  | TN.Masc TM.Messages
  | TN.Masc (TM.Operator TOp.Operator_digest)
  | TN.Masc (TM.Operator TOp.Operator_snapshot)
  | TN.Masc TM.Plan_get
  | TN.Masc TM.Plan_get_task
  | TN.Masc TM.Status
  | TN.Masc (TM.Task TTask.Task_history)
  | TN.Masc (TM.Task TTask.Tasks)
  | TN.Masc TM.Tool_admin_snapshot
  | TN.Masc TM.Tool_help
  | TN.Masc TM.Tool_list
  | TN.Masc TM.Tool_stats
  | TN.Masc TM.Web_fetch
  | TN.Masc TM.Web_search
  | TN.Masc (TM.Board TBoard.Board_sub_board_get)
  | TN.Masc (TM.Board TBoard.Board_sub_board_list)
  | TN.Masc TM.Approval_pending
  | TN.Masc TM.Approval_get ->
      Some Read_only
  | TN.Masc (TM.Task TTask.Add_task)
  | TN.Masc TM.Agent_update
  | TN.Masc (TM.Task TTask.Batch_add_tasks)
  | TN.Masc (TM.Board TBoard.Board_cleanup)
  | TN.Masc (TM.Board TBoard.Board_comment)
  | TN.Masc (TM.Board TBoard.Board_comment_vote)
  | TN.Masc (TM.Board TBoard.Board_curation_submit)
  | TN.Masc (TM.Board TBoard.Board_delete)
  | TN.Masc (TM.Board TBoard.Board_post)
  | TN.Masc (TM.Board TBoard.Board_reaction)
  | TN.Masc (TM.Board TBoard.Board_sub_board_create)
  | TN.Masc (TM.Board TBoard.Board_sub_board_delete)
  | TN.Masc (TM.Board TBoard.Board_sub_board_update)
  | TN.Masc (TM.Board TBoard.Board_vote)
  | TN.Masc TM.Broadcast
  | TN.Masc (TM.Task TTask.Claim_next)
  | TN.Masc TM.Cleanup_zombies
  | TN.Masc TM.Gc
  | TN.Masc (TM.Goal TGoal.Goal_transition)
  | TN.Masc (TM.Goal TGoal.Goal_upsert)
  | TN.Masc (TM.Goal TGoal.Goal_verify)
  | TN.Masc TM.Heartbeat
  | TN.Masc TM.Note_add
  | TN.Masc (TM.Operator TOp.Operator_confirm)
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
  | TN.Masc (TM.Task TTask.Transition)
  | TN.Masc (TM.Task TTask.Update_priority) ->
      Some Masc_workspace
let inferred_effect_domain name =
  match Tool_name.of_string name with
  | Some typed_name -> inferred_effect_domain_of_typed_tool_name typed_name
  | None -> None

(* PR-S1: in this grouping each domain IS uniform — all Board names map to
   [Masc_board], and all Task/Goal/Operator names map to [Masc_core] — so the
   domains collapse to a single nested wildcard arm each. *)
let tool_group_of_typed_tool_name = function
  | TN.Masc (TM.Board _) ->
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
  | TN.Masc (TM.Task _)
  | TN.Masc (TM.Goal _)
  | TN.Masc (TM.Operator _)
  | TN.Masc
      ( TM.Approval_pending
      | TM.Approval_get
      | TM.Broadcast
      | TM.Check
      | TM.Cleanup_zombies
      | TM.Config
      | TM.Dashboard
      | TM.Deliver
      | TM.Gc
      | TM.Get_metrics
      | TM.Heartbeat
      | TM.Mcp_session
      | TM.Messages
      | TM.Note_add
      | TM.Pause
      | TM.Reset
      | TM.Resume
      | TM.Start
      | TM.Status
      | TM.Tool_admin_snapshot
      | TM.Tool_admin_update
      | TM.Tool_grant
      | TM.Tool_help
      | TM.Tool_list
      | TM.Tool_revoke
      | TM.Tool_stats
      | TM.Web_fetch
      | TM.Web_search ) ->
      Some Masc_core

let tool_group name =
  match Tool_name.of_string name with
  | Some typed_name -> tool_group_of_typed_tool_name typed_name
  | None -> None
