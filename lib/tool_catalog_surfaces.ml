(** Tool_catalog_surfaces — Canonical per-surface tool name lists.

    SSOT for tool surface membership. All other modules should derive their
    allowlists from [tools_for_surface] instead of maintaining independent
    hardcoded lists.

    This module is a leaf dependency — it depends only on string lists and
    Env_config. Extracted from tool_catalog.ml to enable SCC cycle-breaking:
    keeper modules can depend on this leaf module instead of the full
    Tool_catalog.

    @since 2.188.0 — God file decomposition Phase 1 *)

(* ================================================================ *)
(* Keeper-internal tools                                            *)
(* ================================================================ *)

let keeper_internal_tools =
  (* keeper_read removed: dead alias for keeper_fs_read with no schema.
     Dispatch still accepts it for backward compat. See #4120.
     keeper_board_delete removed from default shard in #4309.
     keeper_deliberation_decision: Agent_sdk.Structured result schema, not
     a regular tool — does not need a keeper shard entry.
     keeper_unified: cascade name, not a tool. *)
  List.map Tool_name.to_string
    Tool_name.[
      Keeper Stay_silent; Keeper Fs_read; Keeper Fs_edit;
      Keeper Memory_search; Keeper Library_search; Keeper Library_read;
      Keeper Time_now; Keeper Tools_list; Keeper Context_status;
      Keeper Tasks_list; Keeper Tasks_audit;
      Keeper Task_claim; Keeper Task_create; Keeper Task_done;
      Keeper Task_force_release; Keeper Task_force_done;
      Keeper Broadcast;
      Keeper Board_get; Keeper Board_post; Keeper Board_list;
      Keeper Board_comment; Keeper Board_vote;
      Keeper Board_stats; Keeper Board_search;
      Keeper Shell; Keeper Bash; Keeper Pr_workflow;
      Keeper Voice_speak;
      (* keeper_voice_listen is keeper-only; there is no public masc_voice_listen
         counterpart on MCP surfaces. *)
      Keeper Voice_listen;
      Keeper Voice_agent; Keeper Voice_sessions;
      Keeper Voice_session_start; Keeper Voice_session_end;
      (* Tool discovery *)
      Keeper Tool_search;
    ]

(** Immutable alias for keeper-internal tool name membership tests.
    Replaced mutable Hashtbl with plain list — membership via List.mem
    is O(n) but the list is <50 elements, so the overhead is negligible. *)
let keeper_internal_set : string list = keeper_internal_tools

(* keeper_voice_* tools have no masc_* counterpart — default None. *)
let keeper_internal_replacement name =
  let open Tool_name in
  match of_string name with
  | Some (Keeper Board_get) -> Some (to_string (Masc Board_get))
  | Some (Keeper Board_post) -> Some (to_string (Masc Board_post))
  | Some (Keeper Board_list) -> Some (to_string (Masc Board_list))
  | Some (Keeper Board_comment) -> Some (to_string (Masc Board_comment))
  | Some (Keeper Board_vote) -> Some (to_string (Masc Board_vote))
  | Some (Keeper Board_stats) -> Some (to_string (Masc Board_stats))
  | Some (Keeper Board_search) -> Some (to_string (Masc Board_search))
  | Some (Keeper Tasks_list) -> Some (to_string (Masc Tasks))
  | Some (Keeper Broadcast) -> Some (to_string (Masc Broadcast))
  | _ -> None

(* ================================================================ *)
(* Workspace mutation classification                                *)
(* ================================================================ *)

(** Tools that mutate the workspace filesystem. Canonical list shared by
    cdal_contract_bridge.ml and contract_risk.ml. *)
let workspace_mutating_tool_names =
  List.map Tool_name.to_string Tool_name.[ Keeper Fs_edit; Keeper Write ]
  @ [ "edit_text_file"; "file_write" ] (* external/worker tool names *)

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
  | System_internal

let public_mcp_surface_tools =
  List.map Tool_name.to_string
    Tool_name.[
      (* Room lifecycle *)
      Masc Start; Masc Join; Masc Leave; Masc Status;
      (* Messaging *)
      Masc Broadcast; Masc Messages; Masc Who;
      (* Task coordination *)
      Masc Add_task; Masc Batch_add_tasks; Masc Tasks;
      Masc Claim_next; Masc Transition;
      (* Planning *)
      Masc Plan_init; Masc Plan_get; Masc Plan_set_task; Masc Plan_update;
      (* Heartbeat *)
      Masc Heartbeat;
      (* Keeper interaction — most go through Masc_keeper module;
         masc_keeper_msg_result is a Masc-level result delivery. *)
      Masc_keeper Msg; Masc Keeper_msg_result;
      Masc_keeper List; Masc_keeper Status;
      Masc_keeper Up; Masc_keeper Repair; Masc_keeper Reset;
      Masc_keeper Down;
      Masc Persona_list;
      (* Board *)
      Masc Board_post; Masc Board_list; Masc Board_get;
      Masc Board_comment; Masc Board_vote;
      (* Agent discovery *)
      Masc Agents; Masc Dashboard; Masc Agent_card;
      (* Utility *)
      Masc Tool_help; Masc Web_search; Masc Check;
      (* Board extended *)
      Masc Board_comment_vote;
      (* Agent discovery *)
      Masc Agent_timeline;
    ]

let spawned_agent_surface_tools =
  List.map Tool_name.to_string
    Tool_name.[
      Masc Status; Masc Tasks; Masc Claim_next; Masc Transition;
      Masc Task_history; Masc Broadcast; Masc Join; Masc Leave;
      Masc Who; Masc Agent_update; Masc Add_task; Masc Heartbeat;
      Masc Messages;
      Masc Worktree_create; Masc Worktree_remove; Masc Worktree_list;
      Masc Board_list; Masc Board_post; Masc Board_comment;
      Masc Board_vote; Masc Board_get;
      Masc Tool_help; Masc Web_search;
      Masc Spawn;
      (* Phase 2: surface SSOT *)
      Masc Code_delete; Masc Code_edit; Masc Code_git;
      Masc Code_shell; Masc Code_write;
      Masc Deliver;
      Masc Plan_clear_task; Masc Plan_get_task;
      Masc Update_priority;
      Masc Workflow_guide;
    ]

let local_worker_surface_tools =
  List.map Tool_name.to_string
    Tool_name.[
      Masc Status; Masc Tasks; Masc Claim_next; Masc Transition;
      Masc Add_task; Masc Heartbeat;
      Masc Board_post; Masc Board_list; Masc Board_get;
      Masc Board_comment; Masc Board_vote; Masc Board_search;
      Masc Code_search; Masc Code_symbols; Masc Code_read;
      Masc Worktree_create; Masc Worktree_remove; Masc Worktree_list;
      Masc Run_init; Masc Run_plan; Masc Run_log;
      Masc Run_deliverable; Masc Run_get; Masc Run_list;
    ]

let session_min_surface_tools =
  List.map Tool_name.to_string
    Tool_name.[
      Masc Status; Masc Tasks; Masc Claim_next;
      Masc Plan_set_task; Masc Transition; Masc Add_task;
      Masc Broadcast; Masc Heartbeat;
    ]

let admin_surface_tools =
  List.map Tool_name.to_string
    Tool_name.[
      Masc Autoresearch_cycle; Masc Autoresearch_inject;
      Masc Autoresearch_start; Masc Autoresearch_stop;
      Masc Tool_admin_update; Masc Tool_grant; Masc Tool_revoke;
      Masc Tool_admin_snapshot;
      Masc Config;
      (* Phase 2: surface SSOT *)
      Masc_keeper Create_from_persona; Masc_keeper Reset;
      Masc Pause; Masc Resume;
      Masc Runtime_ollama_probe; Masc Tool_list;
    ]

let keeper_internal_surface_tools = keeper_internal_tools

let keeper_denied_surface_tools =
  List.map Tool_name.to_string Tool_name.[ Masc Reset; Masc Spawn ]

let system_internal_surface_tools =
  List.map Tool_name.to_string
    Tool_name.[
      (* MCP protocol internals *)
      Masc Mcp_session;
      (* Session lifecycle — auto-called *)
      Masc Reset;
      (* Maintenance *)
      Masc Cleanup_zombies; Masc Gc;
      (* Agent evaluation — system loop *)
      Masc Agent_fitness;
      (* Internal monitoring *)
      Masc Autoresearch_status;
      Masc Tool_stats; Masc Surface_audit;
      (* Phase 2 addition *)
      Masc Get_metrics;
      (* WebRTC signaling — deprecated as MCP tools but used as HTTP endpoints *)
      Masc Webrtc_offer; Masc Webrtc_answer;
      (* Library tools *)
      Masc Library_add; Masc Library_list; Masc Library_promote;
      Masc Library_read; Masc Library_search;
    ]

(* ================================================================ *)
(* Role catalogs — curated subsets for agent role assignment.        *)
(* These are NOT surfaces; they define what a role *should* see.    *)
(* Consumers must filter them against the tools actually surfaced   *)
(* before exposing them to agents.                                 *)
(* ================================================================ *)

let coordination_role_tools : string list =
  List.map Tool_name.to_string
    Tool_name.[
      Masc Status;
      Masc Tasks;
      Masc Add_task;
      Masc Broadcast;
      Masc Join;
      Masc Leave;
      Masc Who;
      Masc Heartbeat;
      Masc Messages;
      Masc Board_list;
      Masc Board_post;
      Masc Board_comment;
      Masc Board_vote;
      Masc Board_get;
      Masc Claim_next;
      Masc Transition;
      Masc Spawn;
    ]

let execution_role_tools : string list =
  List.map Tool_name.to_string
    Tool_name.[
      Masc Heartbeat;
      Masc Claim_next;
      Masc Transition;
      Masc Broadcast;
      Masc Code_search;
      Masc Code_symbols;
      Masc Code_read;
      Masc Run_init;
      Masc Run_log;
      Masc Run_deliverable;
      Masc Run_get;
      Masc Tool_help;
    ]

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
  | System_internal -> system_internal_surface_tools

let all_surfaces =
  [Public_mcp; Spawned_agent; Local_worker; Session_min;
   Admin; Keeper_internal; Keeper_denied; System_internal]

let surface_sets : (surface * (string, unit) Hashtbl.t) list =
  List.map (fun surface ->
    let tools = tools_for_surface surface in
    let tbl = Hashtbl.create (List.length tools) in
    List.iter (fun name -> Hashtbl.replace tbl name ()) tools;
    (surface, tbl)
  ) all_surfaces

let is_on_surface surface name =
  match List.assoc_opt surface surface_sets with
  | Some tbl -> Hashtbl.mem tbl name
  | None -> false

let surfaces_for_tool name =
  List.filter_map (fun (surface, tbl) ->
    if Hashtbl.mem tbl name then Some surface else None
  ) surface_sets

let surface_to_string = function
  | Public_mcp -> "public_mcp"
  | Spawned_agent -> "spawned_agent"
  | Local_worker -> "local_worker"
  | Session_min -> "session_min"
  | Admin -> "admin"
  | Keeper_internal -> "keeper_internal"
  | Keeper_denied -> "keeper_denied"
  | System_internal -> "system_internal"
