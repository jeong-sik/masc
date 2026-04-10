(** Tool_access_role — Role-based tool access policy builder.

    Derived mechanically from legacy_permission_for_tool in auth.ml.
    Each tool's required permission determines which role tier it belongs to:
    - Reader tier: CanReadState, CanJoin, CanLeave
    - Worker tier: CanAddTask, CanClaimTask, CanCompleteTask, CanBroadcast,
                   CanOpenPortal, CanSendPortal, CanCreateWorktree,
                   CanRemoveWorktree
    - Admin tier:  CanInit, CanReset, CanAdmin

    @since 2.204.0 *)

(* ================================================================ *)
(* Admin-only tools (CanInit + CanReset + CanAdmin)                  *)
(* ================================================================ *)

let admin_only_tools =
  [
    (* CanInit *)
    "masc_init";
    "masc_auth_enable";
    "masc_auth_disable";
    "masc_auth_revoke";
    (* CanReset *)
    "masc_reset";
    (* CanAdmin — autoresearch *)
    "masc_autoresearch_start";
    "masc_autoresearch_swarm_start";
    "masc_autoresearch_cycle";
    "masc_autoresearch_inject";
    "masc_autoresearch_stop";
    (* CanAdmin — command-plane policy *)
    "masc_policy_freeze_unit";
    "masc_policy_kill_switch";
    (* CanAdmin — board moderation *)
    "masc_board_delete";
    (* CanAdmin — auth *)
    "masc_auth_create_token";
    (* CanAdmin — tool administration *)
    "masc_tool_grant";
    "masc_tool_revoke";
    "masc_tool_admin_update";
  ]

(* ================================================================ *)
(* Worker-only tools (CanAddTask + CanClaimTask + CanCompleteTask +  *)
(*                    CanBroadcast + CanOpenPortal + CanSendPortal + *)
(*                    CanCreateWorktree + CanRemoveWorktree + CanVote) *)
(* ================================================================ *)

let worker_only_tools =
  [
    (* CanAddTask *)
    "masc_add_task";
    (* CanClaimTask *)
    "masc_claim_next";
    (* CanCompleteTask *)
    "masc_done";
    "masc_update_priority";
    "masc_transition";
    "masc_release";
    (* CanBroadcast — messaging *)
    "masc_broadcast";
    "masc_listen";
    "masc_heartbeat";
    (* CanBroadcast — transport *)
    "masc_webrtc_offer";
    "masc_webrtc_answer";
    "channel_gate";
    (* CanBroadcast — capability registry *)
    "masc_register_capabilities";
    "masc_find_by_capability";
    (* CanBroadcast — agent management *)
    "masc_agent_update";
    "masc_operator_action";
    "masc_operator_confirm";
    (* CanBroadcast — keeper management *)
    "masc_keeper_up";
    "masc_keeper_down";
    "masc_keeper_msg";
    "masc_keeper_msg_result";
    "masc_keeper_repair";
    "masc_keeper_reconcile";
    "masc_keeper_create_from_persona";
    (* CanBroadcast — org units *)
    "masc_unit_define";
    "masc_unit_reparent";
    "masc_unit_reassign";
    (* CanBroadcast — operations *)
    "masc_operation_start";
    "masc_operation_checkpoint";
    "masc_operation_pause";
    "masc_operation_resume";
    "masc_operation_stop";
    "masc_operation_finalize";
    (* CanBroadcast — dispatch *)
    "masc_dispatch_assign";
    "masc_dispatch_rebalance";
    "masc_dispatch_escalate";
    "masc_dispatch_recall";
    (* CanBroadcast — policy decisions *)
    "masc_policy_approve";
    "masc_policy_deny";
    "masc_policy_update";
    (* CanBroadcast — maintenance *)
    "masc_cleanup_zombies";
    (* CanBroadcast — board writes *)
    "masc_board_post";
    "masc_board_comment";
    "masc_board_vote";
    "masc_board_comment_vote";
    (* CanOpenPortal *)
    "masc_portal_open";
    "masc_portal_close";
    (* CanSendPortal *)
    "masc_portal_send";
    (* CanCreateWorktree *)
    "masc_worktree_create";
    (* CanRemoveWorktree *)
    "masc_worktree_remove";
  ]

(* ================================================================ *)
(* Role → Policy                                                     *)
(* ================================================================ *)

let policy_for_role : Types.agent_role -> Tool_access_policy.t = function
  | Admin ->
      { Tool_access_policy.allow = All; deny = Empty }
  | Worker ->
      {
        allow =
          Diff { base = All; exclude = Names admin_only_tools };
        deny = Empty;
      }
  | Reader ->
      {
        allow =
          Diff
            {
              base = All;
              exclude =
                Union [ Names admin_only_tools; Names worker_only_tools ];
            };
        deny = Empty;
      }
