(** Keeper_tool_registry -- runtime tool name sources and schema injection.

    Static tool name lists have been moved to config/tool_policy.toml.
    This module retains only runtime-resolved names (Tool_catalog,
    Tool_shard, injected MASC tools), core always-visible tools, and
    dynamic schema injection.

    See Keeper_tool_policy_config for the declarative tool groups and presets. *)

open Keeper_types

let dedupe_tool_names names =
  dedupe_keep_order
    (names |> List.map String.trim |> List.filter (fun name -> name <> ""))

(* ── Runtime-resolved tool names ─────────────────────────────── *)

let keeper_internal_candidate_tool_names =
  Tool_catalog.tools_for_surface Tool_catalog.Keeper_internal

let keeper_voice_tool_schemas =
  match Tool_shard.get_shard "voice" with
  | Some shard -> shard.tools
  | None -> []

(* ── Layer 0: Core tools (always executable, always visible) ───── *)

(** Tools that bypass policy restrictions.  Survival-critical only:
    orientation (status), liveness (heartbeat), session control
    (extend_turns), self-introspection (tools_list), and token
    budget awareness (context_status).  Other tools moved to BM25
    retrieval to free ranking budget.  See #4961. *)
let core_always_tools =
  [ "keeper_context_status"; "keeper_tools_list";
    "masc_status"; "masc_heartbeat"; "extend_turns" ]

(** Expanded core set for tool-discovery mode.  These tools are always
    visible when [MASC_KEEPER_TOOL_DISCOVERY=true]; all other tools are
    discoverable via [keeper_tool_search]. *)
let core_discovery_tools =
  [ (* Session survival *)
    "keeper_context_status"; "keeper_tool_search"; "extend_turns";
    (* Liveness *)
    "masc_status"; "masc_heartbeat";
    (* Coordination essentials *)
    "keeper_broadcast"; "keeper_tasks_list";
    "keeper_task_claim"; "keeper_task_done";
    (* Knowledge *)
    "keeper_memory_search"; "keeper_time_now";
    (* Filesystem *)
    "keeper_fs_read";
    (* Board essentials *)
    "keeper_board_get"; "keeper_board_post"; "keeper_board_comment";
  ]

let tool_discovery_enabled () : bool =
  match Sys.getenv_opt "MASC_KEEPER_TOOL_DISCOVERY" with
  | Some ("true" | "1") -> true
  | _ -> false

let effective_core_tools () =
  if tool_discovery_enabled () then core_discovery_tools
  else core_always_tools

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

(* ── keeper_tool_search schema ───────────────────────────────── *)

(** Schema defined in Tool_shard.keeper_model_tools (standalone_keeper_schemas).
    Extracted by name to avoid duplication. *)
let keeper_tool_search_schema : Types.tool_schema =
  match List.find_opt
    (fun (s : Types.tool_schema) -> s.name = "keeper_tool_search")
    Tool_shard.keeper_model_tools
  with
  | Some s -> s
  | None -> failwith "keeper_tool_search schema missing from Tool_shard.keeper_model_tools"
