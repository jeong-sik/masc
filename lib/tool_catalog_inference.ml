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
  | Masc_coordination
  | Playground_write
  | Main_worktree_write

type tool_group =
  | Board
  | Knowledge
  | Tasks
  | Voice
  | Filesystem
  | Masc_board
  | Masc_keeper
  | Masc_plan
  | Masc_worktree
  | Masc_code
  | Masc_autoresearch
  | Masc_agent
  | Masc_core

let effect_domain_to_string = function
  | Read_only -> "read_only"
  | Masc_coordination -> "masc_coordination"
  | Playground_write -> "playground_write"
  | Main_worktree_write -> "main_worktree_write"

let tool_group_to_string = function
  | Board -> "board"
  | Knowledge -> "knowledge"
  | Tasks -> "tasks"
  | Voice -> "voice"
  | Filesystem -> "filesystem"
  | Masc_board -> "masc_board"
  | Masc_keeper -> "masc_keeper"
  | Masc_plan -> "masc_plan"
  | Masc_worktree -> "masc_worktree"
  | Masc_code -> "masc_code"
  | Masc_autoresearch -> "masc_autoresearch"
  | Masc_agent -> "masc_agent"
  | Masc_core -> "masc_core"

module TN = Tool_name
module TK = Tool_name.Keeper
module TM = Tool_name.Masc
module TMK = Tool_name.Masc_keeper

let inferred_effect_domain_of_typed_tool_name = function
  | TN.Keeper TK.Bash
  | TN.Keeper TK.Bash_kill
  | TN.Keeper TK.Shell ->
      Some Main_worktree_write
  | TN.Keeper TK.Bash_output
  | TN.Keeper TK.Board_get
  | TN.Keeper TK.Board_list
  | TN.Keeper TK.Board_curation_read
  | TN.Keeper TK.Board_search
  | TN.Keeper TK.Board_stats
  | TN.Keeper TK.Board_sub_board_get
  | TN.Keeper TK.Board_sub_board_list
  | TN.Keeper TK.Code_read
  | TN.Keeper TK.Context_status
  | TN.Keeper TK.Discovery
  | TN.Keeper TK.Fs_read
  | TN.Keeper TK.Library_read
  | TN.Keeper TK.Library_search
  | TN.Keeper TK.Memory_search
  | TN.Keeper TK.Pr_list
  | TN.Keeper TK.Pr_review_read
  | TN.Keeper TK.Pr_status
  | TN.Keeper TK.Preflight_check
  | TN.Keeper TK.Stay_silent
  | TN.Keeper TK.Tasks_audit
  | TN.Keeper TK.Tasks_list
  | TN.Keeper TK.Time_now
  | TN.Keeper TK.Tool_search
  | TN.Keeper TK.Tools_list
  | TN.Keeper TK.Voice_sessions ->
      Some Read_only
  | TN.Keeper TK.Fs_edit
  | TN.Keeper TK.Write ->
      Some Playground_write
  | TN.Keeper TK.Memory_write ->
      Some Masc_coordination
  | TN.Keeper TK.Board_cleanup
  | TN.Keeper TK.Board_comment
  | TN.Keeper TK.Board_comment_vote
  | TN.Keeper TK.Board_curation_submit
  | TN.Keeper TK.Board_delete
  | TN.Keeper TK.Board_post
  | TN.Keeper TK.Board_sub_board_create
  | TN.Keeper TK.Board_sub_board_delete
  | TN.Keeper TK.Board_sub_board_update
  | TN.Keeper TK.Board_vote
  | TN.Keeper TK.Broadcast
  | TN.Keeper TK.Handoff
  | TN.Keeper TK.Ide_annotate
  | TN.Keeper TK.Pr_create
  | TN.Keeper TK.Pr_review_comment
  | TN.Keeper TK.Pr_review_reply
  | TN.Keeper TK.Task_claim
  | TN.Keeper TK.Task_create
  | TN.Keeper TK.Task_done
  | TN.Keeper TK.Task_force_done
  | TN.Keeper TK.Task_force_release
  (* [Memory_write] matched above in [access_of_tool_name] (merged from main);
     removed duplicate that was in [tool_group_of_tool_name] arm. *)
  | TN.Keeper TK.Task_submit_for_verification
  | TN.Keeper TK.Voice_agent
  | TN.Keeper TK.Voice_listen
  | TN.Keeper TK.Voice_session_end
  | TN.Keeper TK.Voice_session_start
  | TN.Keeper TK.Voice_speak ->
      Some Masc_coordination
  | TN.Masc TM.Autoresearch_inject
  | TN.Masc TM.Autoresearch_start
  | TN.Masc TM.Autoresearch_stop
  | TN.Masc TM.Deliver
  | TN.Masc TM.Dispatch_plan
  | TN.Masc TM.Operator_action
  | TN.Masc TM.Spawn
  | TN.Masc TM.Start ->
      Some Main_worktree_write
  | TN.Masc TM.Agent_fitness
  | TN.Masc TM.Agent_card
  | TN.Masc TM.Agents
  | TN.Masc TM.Autoresearch_search_findings
  | TN.Masc TM.Autoresearch_status
  | TN.Masc TM.Board_get
  | TN.Masc TM.Board_curation_read
  | TN.Masc TM.Board_hearths
  | TN.Masc TM.Board_list
  | TN.Masc TM.Board_profile
  | TN.Masc TM.Board_search
  | TN.Masc TM.Board_stats
  | TN.Masc TM.Check
  | TN.Masc TM.Code_read
  | TN.Masc TM.Code_search
  | TN.Masc TM.Code_symbols
  | TN.Masc TM.Config
  | TN.Masc TM.Coordination_fsm_snapshot
  | TN.Masc TM.Dashboard
  | TN.Masc TM.Get_metrics
  | TN.Masc TM.Goal_list
  | TN.Masc TM.Goal_review
  | TN.Masc TM.Mcp_session
  | TN.Masc TM.Messages
  | TN.Masc TM.Operation_status
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
  | TN.Masc TM.Who
  | TN.Masc TM.Workflow_guide
  | TN.Masc TM.Worktree_list
  | TN.Masc TM.Board_sub_board_get
  | TN.Masc TM.Board_sub_board_list
  | TN.Masc TM.Approval_pending
  | TN.Masc TM.Approval_get
  | TN.Masc TM.Webrtc_answer
  | TN.Masc TM.Webrtc_offer ->
      Some Read_only
  | TN.Masc TM.Code_delete
  | TN.Masc TM.Code_edit
  | TN.Masc TM.Code_git
  | TN.Masc TM.Code_shell
  | TN.Masc TM.Code_write
  | TN.Masc TM.Worktree_create
  | TN.Masc TM.Worktree_remove ->
      Some Playground_write
  | TN.Masc TM.Add_task
  | TN.Masc TM.Agent_update
  | TN.Masc TM.Autoresearch_cycle
  | TN.Masc TM.Autoresearch_record_finding
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
  | TN.Masc TM.Join
  | TN.Masc TM.Leave
  | TN.Masc TM.Note_add
  | TN.Masc TM.Operation_pause
  | TN.Masc TM.Operation_start
  | TN.Masc TM.Operation_stop
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
      Some Masc_coordination
  | TN.Masc_keeper TMK.List
  | TN.Masc_keeper TMK.Persona_audit
  | TN.Masc_keeper TMK.Sandbox_status
  | TN.Masc_keeper TMK.Status ->
      Some Read_only
  | TN.Masc_keeper TMK.Clear
  | TN.Masc_keeper TMK.Compact
  | TN.Masc_keeper TMK.Create_from_persona
  | TN.Masc_keeper TMK.Down
  | TN.Masc_keeper TMK.Msg
  | TN.Masc_keeper TMK.Msg_result
  | TN.Masc_keeper TMK.Repair
  | TN.Masc_keeper TMK.Reset
  | TN.Masc_keeper TMK.Sandbox_start
  | TN.Masc_keeper TMK.Sandbox_stop
  | TN.Masc_keeper TMK.Up ->
      Some Masc_coordination

let inferred_effect_domain name =
  match Tool_name.of_string name with
  | Some typed_name -> inferred_effect_domain_of_typed_tool_name typed_name
  | None -> None

let tool_group_of_typed_tool_name = function
  | TN.Keeper
      ( TK.Board_cleanup
      | TK.Board_comment
      | TK.Board_comment_vote
      | TK.Board_curation_read
      | TK.Board_curation_submit
      | TK.Board_delete
      | TK.Board_get
      | TK.Board_list
      | TK.Board_post
      | TK.Board_search
      | TK.Board_stats
      | TK.Board_sub_board_create
      | TK.Board_sub_board_delete
      | TK.Board_sub_board_get
      | TK.Board_sub_board_list
      | TK.Board_sub_board_update
      | TK.Board_vote ) ->
      Some Board
  | TN.Keeper (TK.Memory_search | TK.Memory_write | TK.Library_read | TK.Library_search) ->
      Some Knowledge
  | TN.Keeper
      ( TK.Task_claim
      | TK.Task_create
      | TK.Task_done
      | TK.Task_force_done
      | TK.Task_force_release
      | TK.Task_submit_for_verification
      | TK.Tasks_audit
      | TK.Tasks_list ) ->
      Some Tasks
  | TN.Keeper
      ( TK.Voice_agent
      | TK.Voice_listen
      | TK.Voice_session_end
      | TK.Voice_session_start
      | TK.Voice_sessions
      | TK.Voice_speak ) ->
      Some Voice
  | TN.Keeper (TK.Bash | TK.Fs_edit | TK.Fs_read | TK.Ide_annotate | TK.Shell | TK.Write) ->
      Some Filesystem
  | TN.Keeper
      ( TK.Bash_kill
      | TK.Bash_output
      | TK.Broadcast
      | TK.Code_read
      | TK.Context_status
      | TK.Discovery
      | TK.Handoff
      | TK.Pr_create
      | TK.Pr_list
      | TK.Pr_review_comment
      | TK.Pr_review_read
      | TK.Pr_review_reply
      | TK.Pr_status
      | TK.Preflight_check
      | TK.Stay_silent
      | TK.Time_now
      | TK.Tool_search
      | TK.Tools_list ) ->
      None
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
  | TN.Masc_keeper _ -> Some Masc_keeper
  | TN.Masc
      ( TM.Plan_clear_task
      | TM.Plan_get
      | TM.Plan_get_task
      | TM.Plan_init
      | TM.Plan_set_task
      | TM.Plan_update ) ->
      Some Masc_plan
  | TN.Masc (TM.Worktree_create | TM.Worktree_list | TM.Worktree_remove) ->
      Some Masc_worktree
  | TN.Masc
      ( TM.Code_delete
      | TM.Code_edit
      | TM.Code_git
      | TM.Code_read
      | TM.Code_search
      | TM.Code_shell
      | TM.Code_symbols
      | TM.Code_write ) ->
      Some Masc_code
  | TN.Masc
      ( TM.Autoresearch_cycle
      | TM.Autoresearch_inject
      | TM.Autoresearch_record_finding
      | TM.Autoresearch_search_findings
      | TM.Autoresearch_start
      | TM.Autoresearch_status
      | TM.Autoresearch_stop ) ->
      Some Masc_autoresearch
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
      | TM.Coordination_fsm_snapshot
      | TM.Dashboard
      | TM.Deliver
      | TM.Dispatch_plan
      | TM.Gc
      | TM.Get_metrics
      | TM.Goal_list
      | TM.Goal_review
      | TM.Goal_transition
      | TM.Goal_upsert
      | TM.Goal_verify
      | TM.Heartbeat
      | TM.Join
      | TM.Leave
      | TM.Mcp_session
      | TM.Messages
      | TM.Note_add
      | TM.Operation_pause
      | TM.Operation_start
      | TM.Operation_status
      | TM.Operation_stop
      | TM.Operator_action
      | TM.Operator_confirm
      | TM.Operator_digest
      | TM.Operator_snapshot
      | TM.Pause
      | TM.Reset
      | TM.Resume
      | TM.Spawn
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
      | TM.Web_search
      | TM.Webrtc_answer
      | TM.Webrtc_offer
      | TM.Who
      | TM.Workflow_guide ) ->
      Some Masc_core

let tool_group name =
  match Tool_name.of_string name with
  | Some typed_name -> tool_group_of_typed_tool_name typed_name
  | None -> None
