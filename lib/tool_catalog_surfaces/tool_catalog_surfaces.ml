module Format = Stdlib.Format
module Map = Stdlib.Map
module Set = Stdlib.Set
module Queue = Stdlib.Queue
module Hashtbl = Stdlib.Hashtbl
module Mutex = Stdlib.Mutex
module Option = Stdlib.Option
module Result = Stdlib.Result
module Sys = Stdlib.Sys
module Filename = Stdlib.Filename
module List = Stdlib.List
module Array = Stdlib.Array
module String = Stdlib.String
module Char = Stdlib.Char
module Int = Stdlib.Int
module Float = Stdlib.Float

(** Tool_catalog_surfaces — Canonical per-surface tool name lists.

    SSOT for tool surface membership. All other modules should derive their
    allowlists from [tools_for_surface] instead of maintaining independent
    hardcoded lists.

    This module is a leaf dependency — it depends only on string lists and
    Env_config. Extracted from tool_catalog.ml to enable SCC cycle-breaking.

    @since 2.188.0 — God file decomposition Phase 1 *)

(* ================================================================ *)
(* Workspace mutation classification                                *)
(* ================================================================ *)

(** Tools that mutate the workspace filesystem. Canonical list shared by
    cdal_contract_bridge.ml and contract_risk.ml. *)
let workspace_mutating_tool_names =
  [ "tool_edit_file"; "tool_write_file"; "create_text_file"; "edit_text_file"; "file_write" ]
;;

let schedule_request_surface_tools =
  [ "masc_schedule_create"
  ; "masc_schedule_list"
  ; "masc_schedule_get"
  ; "masc_schedule_cancel"
  ]
;;

let public_schedule_surface_tools = schedule_request_surface_tools
let keeper_schedule_surface_tools = schedule_request_surface_tools
(* TEL-OK: pure surface membership constants; tool-call telemetry is emitted by
   the dispatch/runtime boundary. *)
let spawned_agent_schedule_surface_tools = []
let local_worker_schedule_surface_tools = []
let schedule_surface_tools = schedule_request_surface_tools

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
  ; "masc_plan_init"
  ; "masc_plan_get"
  ; "masc_plan_set_task"
  ; "masc_plan_update"
  ; (* Heartbeat *)
    "masc_heartbeat"
  ; (* Keeper runtime front door. *)
    "masc_keeper_list"
  ; "masc_keeper_status"
  ; "masc_keeper_waiting_inventory"
  ; "masc_keeper_up"
  ; "masc_keeper_down"
  ; (* Persona authoring is operator-visible. *)
    "masc_persona_list"
  ; "masc_persona_create"
  ; "masc_persona_update"
  ; "masc_persona_delete"
  ; (* Board. [masc_board_reaction] is intentionally public: it is the
       operator/client counterpart to existing board comment/vote actions. *)
    "masc_board_post"
  ; "masc_board_list"
  ; "masc_board_post_get"
  ; "masc_board_comment"
  ; "masc_board_vote"
  ; "masc_board_curation_read"
  ; "masc_board_curation_submit"
  ; "masc_board_reaction"
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
  [ "masc_status"
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
    "masc_deliver"
  ; "masc_plan_clear_task"
  ; "masc_plan_get_task"
  ; "masc_note_add"
  ; "masc_update_priority"
  ]
  @ spawned_agent_schedule_surface_tools
;;

let local_worker_surface_tools =
  [ "masc_status"
  ; "masc_tasks"
  ; "masc_transition"
  ; "masc_add_task"
  ; "masc_heartbeat"
  ; "masc_agent_card"
  ; "masc_goal_list"
  ; "masc_goal_upsert"
  ; "masc_goal_transition"
  ; "masc_board_post"
  ; "masc_board_list"
  ; "masc_board_post_get"
  ; "masc_board_comment"
  ; "masc_board_vote"
  ; "masc_board_search"
  ; "masc_board_stats"
  ; "masc_board_profile"
  ; "masc_board_hearths"
  ; "masc_board_curation_read"
  ; "masc_board_sub_board_create"
  ; "masc_board_sub_board_list"
  ; "masc_board_sub_board_get"
  ; "masc_board_sub_board_update"
  ; "masc_board_sub_board_delete"
  ; "masc_board_curation_submit"
  ; "masc_run_init"
  ; "masc_run_plan"
  ; "masc_run_get"
  ; "masc_run_list"
  ]
  @ local_worker_schedule_surface_tools
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

(* ================================================================ *)
(* Role catalogs — curated subsets for agent role assignment.        *)
(* These are NOT surfaces; they define what a role *should* see.    *)
(* Consumers must filter them against the tools actually surfaced   *)
(* before exposing them to agents.                                 *)
(* ================================================================ *)

let workspace_role_tools : string list =
  [ "masc_status"
  ; "masc_tasks"
  ; "masc_add_task"
  ; "masc_broadcast"
  ; "masc_heartbeat"
  ; "masc_messages"
  ; "masc_board_list"
  ; "masc_board_post"
  ; "masc_board_comment"
  ; "masc_board_vote"
  ; "masc_board_post_get"
  ; "masc_board_sub_board_list"
  ; "masc_board_sub_board_get"
  ; "masc_transition"
  ]
;;

let execution_role_tools : string list =
  [ "masc_heartbeat"
  ; "masc_transition"
  ; "masc_broadcast"
  ; "masc_run_init"
  ; "masc_run_get"
  ; "masc_tool_help"
  ]
;;
