(** Keeper_tool_registry — declarative tool name lists and schema injection.

    This module is pure data: tool name constants grouped by family,
    plus the mutable schema registry for dynamically injected masc_* tools.
    No access-policy logic lives here; see [Keeper_tool_policy]. *)

open Keeper_types

let dedupe_tool_names names =
  dedupe_keep_order
    (names |> List.map String.trim |> List.filter (fun name -> name <> ""))

(* ── Static tool name lists ────────────────────────────────────── *)

let keeper_coordination_tool_names =
  [ "keeper_tasks_list"; "keeper_task_claim"; "keeper_task_done"; "keeper_broadcast" ]

let keeper_board_tool_names =
  [
    "keeper_board_get";
    "keeper_board_post";
    "keeper_board_comment";
    "keeper_board_vote";
    "keeper_board_list";
    "keeper_board_stats";
    "keeper_board_search";
  ]

let keeper_voice_tool_names =
  [ "keeper_voice_speak"; "keeper_voice_listen"; "keeper_voice_agent";
    "keeper_voice_sessions";
    "keeper_voice_session_start"; "keeper_voice_session_end" ]

let keeper_shell_readonly_tool_names = [ "keeper_shell_readonly" ]

let keeper_governance_tool_names =
  Tool_shard.governance_tools
  |> List.map (fun (t : Types.tool_schema) -> t.name)

let keeper_coding_shard_tool_names =
  Tool_shard.coding_tools
  |> List.map (fun (t : Types.tool_schema) -> t.name)

let keeper_autoresearch_tool_names =
  Tool_shard.autoresearch_keeper_tools
  |> List.map (fun (t : Types.tool_schema) -> t.name)

let keeper_research_loop_tool_names =
  Tool_research.schemas
  |> List.map (fun (t : Types.tool_schema) -> t.name)

let keeper_coding_tool_names = Tool_code_write.tool_names

let keeper_internal_candidate_tool_names =
  Tool_catalog.tools_for_surface Tool_catalog.Keeper_internal

let keeper_voice_tool_schemas =
  match Tool_shard.get_shard "voice" with
  | Some shard -> shard.tools
  | None -> []

let keeper_base_tool_names =
  [ "keeper_time_now"; "keeper_context_status"; "keeper_memory_search" ]

let keeper_filesystem_tool_names = [ "keeper_fs_read" ]
let keeper_library_tool_names = [ "keeper_library_search"; "keeper_library_read" ]

let keeper_core_masc_tool_names =
  [
    "masc_status";
    "masc_messages";
    "masc_broadcast";
    "masc_join";
    "masc_leave";
    "masc_who";
    "masc_heartbeat";
    "masc_tasks";
    "masc_claim_next";
    "masc_transition";
    "masc_add_task";
    "masc_batch_add_tasks";
    "masc_agents";
    "masc_dashboard";
    "masc_agent_card";
    "masc_tool_help";
  ]

let keeper_coding_masc_tool_names =
  [
    "masc_code_search";
    "masc_code_symbols";
    "masc_code_read";
    "masc_worktree_create";
    "masc_worktree_remove";
    "masc_worktree_list";
  ]

(* ── Layer 0: Core tools (always executable, always visible) ───── *)

(** Tools that bypass policy restrictions.  A keeper with Minimal
    preset still needs masc_status/broadcast/heartbeat to function.
    These are the survival-critical tools. *)
let core_always_tools =
  [ "keeper_time_now"; "keeper_context_status";
    "keeper_list_my_tools";
    "masc_status"; "masc_broadcast"; "masc_heartbeat";
    "masc_messages"; "masc_who"; "masc_tool_help";
    "extend_turns" ]

let core_always_set : (string, unit) Hashtbl.t =
  let tbl = Hashtbl.create (List.length core_always_tools) in
  List.iter (fun name -> Hashtbl.replace tbl name ()) core_always_tools;
  tbl

let is_core_always_tool (name : string) : bool =
  Hashtbl.mem core_always_set name

(* ── Dynamic schema injection (masc_* tools) ──────────────────── *)

let masc_schemas_ref : Types.tool_schema list ref = ref []

let injected_masc_tool_names () =
  !masc_schemas_ref
  |> List.map (fun (schema : Types.tool_schema) -> schema.name)
