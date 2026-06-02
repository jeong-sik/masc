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

(* ================================================================ *)
(* Keeper-internal tools                                            *)
(* ================================================================ *)

let keeper_internal_tools =
  [ "keeper_stay_silent"
  ; "tool_read_file"
  ; "tool_edit_file"
  ; "tool_write_file"
  ; "keeper_ide_annotate"
  ; "keeper_memory_search"
  ; "keeper_memory_write"
  ; "keeper_library_search"
  ; "keeper_library_read"
  ; "keeper_time_now"
  ; "keeper_tools_list"
  ; "keeper_context_status"
  ; "keeper_tasks_list"
  ; "keeper_tasks_audit"
  ; "keeper_task_claim"
  ; "keeper_task_create"
  ; "keeper_task_done"
  ; "keeper_task_submit_for_verification"
  ; "keeper_task_force_release"
  ; "keeper_task_force_done"
  ; "keeper_broadcast"
  ; "keeper_board_get"
  ; "keeper_board_post"
  ; "keeper_board_list"
  ; "keeper_board_comment"
  ; "keeper_board_vote"
  ; "keeper_board_stats"
  ; "keeper_board_search"
  ; "keeper_board_curation_read"
  ; "keeper_board_curation_submit"
  ; "tool_search_files"
  ; "tool_execute"
  ; "keeper_voice_speak"
  ; "keeper_voice_listen"
  ; "keeper_voice_agent"
  ; "keeper_voice_sessions"
  ; "keeper_voice_session_start"
  ; "keeper_voice_session_end"
  ; "keeper_tool_search"
  ]
;;

let keeper_internal_replacement = function
  | "keeper_board_get" -> Some "masc_board_get"
  | "keeper_board_post" -> Some "masc_board_post"
  | "keeper_board_list" -> Some "masc_board_list"
  | "keeper_board_comment" -> Some "masc_board_comment"
  | "keeper_board_vote" -> Some "masc_board_vote"
  | "keeper_board_stats" -> Some "masc_board_stats"
  | "keeper_board_search" -> Some "masc_board_search"
  | "keeper_board_curation_read" -> Some "masc_board_curation_read"
  | "keeper_board_curation_submit" -> Some "masc_board_curation_submit"
  | "keeper_tasks_list" -> Some "masc_tasks"
  | "keeper_broadcast" -> Some "masc_broadcast"
  | _ -> None
;;

(* ================================================================ *)
(* Surface type + canonical lists                                   *)
(* ================================================================ *)

type surface =
  | Public_mcp
  | Spawned_agent
  | Local_worker
  | Session_min
  | Admin
  | Keeper_internal
  | Keeper_denied
  | Agent_internal
  | System_internal

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
  ; "masc_claim_next"
  ; "masc_transition"
  ; (* Planning *)
    "masc_goal_list"
  ; "masc_goal_upsert"
  ; "masc_goal_transition"
  ; "masc_goal_verify"
  ; "masc_plan_init"
  ; "masc_plan_get"
  ; "masc_plan_set_task"
  ; "masc_plan_update"
  ; (* Heartbeat *)
    "masc_heartbeat"
  ; (* Persona authoring is operator-visible. *)
    "masc_persona_list"
  ; "masc_persona_schema"
  ; "masc_persona_generate"
  ; "masc_persona_save"
  ; (* Board. [masc_board_reaction] is intentionally public: it is the
       operator/client counterpart to existing board comment/vote actions. *)
    "masc_board_post"
  ; "masc_board_list"
  ; "masc_board_get"
  ; "masc_board_comment"
  ; "masc_board_vote"
  ; "masc_board_curation_read"
  ; "masc_board_curation_submit"
  ; "masc_board_reaction"
  ; (* Agent discovery *)
    "masc_agents"
  ; "masc_agent_card"
  ; "masc_dashboard"
  ; (* Utility *)
    "masc_tool_help"
  ; "masc_web_search"
  ; "masc_web_fetch"
  ; "masc_check"
  ; (* Approval queue/detail *)
    "masc_approval_pending"
  ; "masc_approval_get"
  ; (* Board extended *)
    "masc_board_comment_vote"
  ; (* Agent discovery *)
    "masc_agent_timeline"
  ]
;;

let spawned_agent_surface_tools =
  [ "masc_status"
  ; "masc_tasks"
  ; "masc_claim_next"
  ; "masc_transition"
  ; "masc_task_history"
  ; "masc_broadcast"
  ; "masc_agent_update"
  ; "masc_add_task"
  ; "masc_heartbeat"
  ; "masc_messages"
  ; "masc_goal_list"
  ; "masc_goal_upsert"
  ; "masc_goal_transition"
  ; "masc_goal_verify"
  ; "masc_board_list"
  ; "masc_board_post"
  ; "masc_board_comment"
  ; "masc_board_vote"
  ; "masc_board_get"
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
  ; "masc_web_search"
  ; "masc_web_fetch"
  ; (* Phase 2: surface SSOT *)
    "masc_deliver"
  ; "masc_plan_clear_task"
  ; "masc_plan_get_task"
  ; "masc_note_add"
  ; "masc_update_priority"
  ]
;;

let local_worker_surface_tools =
  [ "masc_status"
  ; "masc_tasks"
  ; "masc_claim_next"
  ; "masc_transition"
  ; "masc_add_task"
  ; "masc_heartbeat"
  ; "masc_agents"
  ; "masc_agent_card"
  ; "masc_goal_list"
  ; "masc_goal_upsert"
  ; "masc_goal_transition"
  ; "masc_goal_verify"
  ; "masc_board_post"
  ; "masc_board_list"
  ; "masc_board_get"
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
  ; "masc_run_log"
  ; "masc_run_deliverable"
  ; "masc_run_get"
  ; "masc_run_list"
  ]
;;

let session_min_surface_tools =
  [ "masc_status"
  ; "masc_tasks"
  ; "masc_claim_next"
  ; "masc_plan_set_task"
  ; "masc_transition"
  ; "masc_add_task"
  ; "masc_goal_list"
  ; "masc_goal_upsert"
  ; "masc_goal_transition"
  ; "masc_goal_verify"
  ; "masc_broadcast"
  ; "masc_heartbeat"
  ]
;;

let admin_surface_tools =
  [ "masc_tool_admin_update"
  ; "masc_tool_grant"
  ; "masc_tool_revoke"
  ; "masc_tool_admin_snapshot"
  ; "masc_config"
  ; (* Phase 2: surface SSOT *)
    "masc_persona_generate"
  ; "masc_persona_save"
  ; "masc_board_delete"
  ; "masc_pause"
  ; "masc_resume"
  ; "masc_runtime_verify"
  ; "masc_runtime_ollama_probe"
  ; "masc_tool_list"
  ]
;;

let keeper_internal_surface_tools = keeper_internal_tools

let keeper_denied_surface_tools =
  [ "masc_reset"
  ; "masc_tool_grant"
  ; "masc_tool_revoke"
  ; "masc_tool_admin_update"
  ; "masc_tool_admin_snapshot"
  ; "masc_config"
  ; "masc_persona_generate"
  ; "masc_persona_save"
  ; "masc_keeper_create_from_persona"
  ; "masc_pause"
  ; "masc_resume"
  ]
;;

let system_internal_surface_tools =
  [ (* MCP protocol internals *)
    "masc_mcp_session"
  ; (* Session lifecycle — auto-called *)
    "masc_reset"
  ; (* Maintenance *)
    "masc_cleanup_zombies"
  ; "masc_gc"
  ; (* Agent evaluation — system loop *)
    "masc_agent_fitness"
  ; (* Internal monitoring *)
    "masc_tool_stats"
  ; "masc_surface_audit"
  ; (* Phase 2 addition *)
    "masc_get_metrics"
  ; (* Library tools *)
    "masc_library_add"
  ; "masc_library_list"
  ; "masc_library_promote"
  ; "masc_library_read"
  ; "masc_library_search"
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
  ; "masc_board_get"
  ; "masc_board_sub_board_list"
  ; "masc_board_sub_board_get"
  ; "masc_claim_next"
  ; "masc_transition"
  ]
;;

let execution_role_tools : string list =
  [ "masc_heartbeat"
  ; "masc_claim_next"
  ; "masc_transition"
  ; "masc_broadcast"
  ; "masc_run_init"
  ; "masc_run_log"
  ; "masc_run_deliverable"
  ; "masc_run_get"
  ; "masc_tool_help"
  ]
;;

let agent_internal_surface_tools = keeper_internal_surface_tools

(* ================================================================ *)
(* Surface query functions                                          *)
(* ================================================================ *)

let tools_for_surface = function
  | Public_mcp -> public_mcp_surface_tools
  | Spawned_agent -> spawned_agent_surface_tools
  | Local_worker -> local_worker_surface_tools
  | Session_min -> session_min_surface_tools
  | Admin -> admin_surface_tools
  | Keeper_internal -> keeper_internal_surface_tools
  | Keeper_denied -> keeper_denied_surface_tools
  | Agent_internal -> agent_internal_surface_tools
  | System_internal -> system_internal_surface_tools
;;

let all_surfaces =
  [ Public_mcp
  ; Spawned_agent
  ; Local_worker
  ; Session_min
  ; Admin
  ; Keeper_internal
  ; Keeper_denied
  ; System_internal
  ]
;;

let build_surface_set tools =
  let tbl = Hashtbl.create (List.length tools) in
  List.iter (fun name -> Hashtbl.replace tbl name ()) tools;
  tbl
;;

(* Per-surface membership tables, bound once at module load.  Direct
   variant match (below) replaces a List.assoc_opt scan over an
   (surface * Hashtbl) association list — the latter required linear
   structural-equality comparison of variants on every call. *)
let public_mcp_set = build_surface_set public_mcp_surface_tools
let spawned_agent_set = build_surface_set spawned_agent_surface_tools
let local_worker_set = build_surface_set local_worker_surface_tools
let session_min_set = build_surface_set session_min_surface_tools
let admin_set = build_surface_set admin_surface_tools
let keeper_internal_set = build_surface_set keeper_internal_surface_tools
let keeper_denied_set = build_surface_set keeper_denied_surface_tools
let agent_internal_set = keeper_internal_set
let system_internal_set = build_surface_set system_internal_surface_tools

let set_for_surface = function
  | Public_mcp -> public_mcp_set
  | Spawned_agent -> spawned_agent_set
  | Local_worker -> local_worker_set
  | Session_min -> session_min_set
  | Admin -> admin_set
  | Keeper_internal -> keeper_internal_set
  | Keeper_denied -> keeper_denied_set
  | Agent_internal -> agent_internal_set
  | System_internal -> system_internal_set
;;

let surface_sets : (surface * (string, unit) Hashtbl.t) list =
  List.map (fun surface -> surface, set_for_surface surface) all_surfaces
;;

let is_on_surface surface name =
  Hashtbl.mem (set_for_surface surface) name
;;

let surfaces_for_tool name =
  List.filter_map
    (fun (surface, tbl) -> if Hashtbl.mem tbl name then Some surface else None)
    surface_sets
;;

let surface_to_string = function
  | Public_mcp -> "public_mcp"
  | Spawned_agent -> "spawned_agent"
  | Local_worker -> "local_worker"
  | Session_min -> "session_min"
  | Admin -> "admin"
  | Keeper_internal -> "keeper_internal"
  | Keeper_denied -> "keeper_denied"
  | Agent_internal -> "agent_internal"
  | System_internal -> "system_internal"
;;
