(** Tool_catalog_surfaces — Canonical per-surface tool name lists.

    SSOT for tool surface membership. All other modules should derive their
    allowlists from [tools_for_surface] instead of maintaining independent
    hardcoded lists.

    This module is a leaf dependency — it depends only on string lists and
    Env_config. Extracted from tool_catalog.ml to enable SCC cycle-breaking.

    @since 2.188.0 — God file decomposition Phase 1 *)

let schedule_request_surface_tools =
  [ "masc_schedule_create"
  ; "masc_schedule_update"
  ; "masc_schedule_list"
  ; "masc_schedule_get"
  ; "masc_schedule_cancel"
  ]
;;

let public_schedule_surface_tools = schedule_request_surface_tools
(* TEL-OK: pure surface membership constants; tool-call telemetry is emitted by
   the dispatch/runtime boundary. *)

(* ================================================================ *)
(* Curated tool-name lists                                          *)
(* ================================================================ *)

(* These are flat, consumer-owned tool-name lists.  The [surface] actor
   classification type and its dispatch/reverse-lookup machinery were deleted
   in the surface-cut refactor — tools are a flat list, and each consumer
   projects the subset it needs by referencing the named list directly. *)

let public_mcp_surface_tools =
  [ (* Workspace lifecycle *)
    "masc_start"
  ; "masc_status"
  ; (* Messaging *)
    "masc_broadcast"
  ; "masc_messages"
  ; (* Task workspace *)
    "masc_add_task"
  ; "masc_batch_add_tasks"
  ; "masc_tasks"
  ; "masc_transition"
  ; (* Planning *)
    "masc_goal_list"
  ; "masc_goal_upsert"
  ; "masc_goal_transition"
  ; "masc_plan_set_task"
  ; (* Heartbeat *)
    "masc_heartbeat"
  ; (* Keeper runtime front door. *)
    "masc_keeper_list"
  ; "masc_keeper_status"
  ; "masc_keeper_waiting_inventory"
  ; "masc_keeper_up"
  ; "masc_keeper_down"
  ; (* [masc_keeper_msg] is the operator's front door for sending a keeper a
       direct message: submit -> operation_id, then poll
       [masc_keeper_delegate_status]. It already had a real handler
       (Keeper_tool_surface.handle_keeper_msg) reachable only from the HTTP
       copilot chat route and the board-context-inference caller; this adds
       the MCP tools/call path so an operator can reach the same handler
       without going through either adapter. *)
    "masc_keeper_msg"
  ; (* [masc_keeper_delegate_status] is the read-side counterpart operators
       need to poll the operation_id that masc_keeper_msg / masc_keeper_delegate
       return; it was already catalog-owned as a read_state_tool but missing
       from this surface, so an operator could submit a turn but never observe
       it settle. *)
    "masc_keeper_delegate_status"
  ; (* Board. [masc_board_reaction] is intentionally public: it is the
       operator/client counterpart to existing board comment/vote actions.
       [masc_board_search] is the read counterpart operators need to locate a
       post before calling masc_board_post_get/comment/vote on it. *)
    "masc_board_post"
  ; "masc_board_list"
  ; "masc_board_post_get"
  ; "masc_board_search"
  ; "masc_board_comment"
  ; "masc_board_vote"
  ; "masc_board_curation_read"
  ; "masc_board_curation_submit"
  ; "masc_board_reaction"
  ; (* Task workspace read-side: operators need the history of a task they
       did not submit themselves (e.g. one another Keeper claimed). *)
    "masc_task_history"
  (* [masc_fusion_status] deliberately stays off this surface: RFC-0266 §7
     Phase 3 scopes it to the calling keeper's own fusion runs ("a run owned
     by a different keeper is reported as not found" -- see
     Keeper_tool_in_process_runtime.mli), and it has no external Tool_dispatch
     tag registration, so an operator caller could only ever see an empty
     result. Making it operator-visible would require a real scoping redesign
     (target-keeper field + contract change), not a whitelist entry. See
     masc#28963 / masc#28960. *)
  ]
  @ public_schedule_surface_tools
  @
  [ (* Agent discovery *)
    "masc_agent_card"
  ; (* Utility *)
    "masc_tool_help"
  ; "masc_check"
  ; (* Board extended *)
    "masc_board_comment_vote"
  ; (* Agent discovery *)
    "masc_agent_timeline"
  ]
;;

let spawned_agent_surface_tools =
  [ (* Asking the operator, and reading back what came of it. Both belong on
       the Keeper surface rather than the operator one: the Keeper is the side
       that asks, and an operator answers over HTTP, not by calling a tool. *)
    "masc_ask"
  ; "masc_ask_status"
  ; "masc_ask_withdraw"
  ; "masc_status"
  ; "masc_tasks"
  ; "masc_transition"
  ; "masc_task_history"
  ; "masc_broadcast"
  ; "masc_add_task"
  ; "masc_heartbeat"
  ; "masc_messages"
  ; "masc_goal_list"
  ; "masc_goal_upsert"
  ; "masc_goal_transition"
  ; "masc_board_list"
  ; "masc_board_post"
  ; "masc_board_comment"
  ; "masc_board_vote"
  ; "masc_board_post_get"
  ; "masc_board_search"
  ; "masc_board_stats"
  ; "masc_board_profile"
  ; "masc_board_hearths"
  ; "masc_board_curation_read"
  ; "masc_board_curation_submit"
  ; "masc_board_sub_board_create"
  ; "masc_board_sub_board_list"
  ; "masc_board_sub_board_get"
  ; "masc_board_sub_board_update"
  ; "masc_board_sub_board_delete"
  ; "masc_tool_help"
  ; (* Phase 2: surface SSOT *)
    "masc_plan_clear_task"
  ; "masc_plan_get_task"
  ; "masc_update_priority"
  ]
;;

let session_min_surface_tools =
  [ "masc_status"
  ; "masc_tasks"
  ; "masc_plan_set_task"
  ; "masc_transition"
  ; "masc_add_task"
  ; "masc_goal_list"
  ; "masc_goal_upsert"
  ; "masc_goal_transition"
  ; "masc_broadcast"
  ; "masc_heartbeat"
  ]
;;
