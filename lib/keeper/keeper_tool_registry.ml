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
    "keeper_stay_silent"; "keeper_tool_search";
    "masc_status"; "masc_heartbeat"; "extend_turns" ]

(** Core tools always visible to the LLM.  All other tools are
    discoverable on demand via [keeper_tool_search].
    This is a cross-preset discovery baseline, not equivalent to any single
    preset: board_core get/post/comment/vote/list are visible by default;
    board_extended (stats/search) remain discoverable via BM25.
    Includes both read and write tools so keepers can complete full
    task lifecycles (read → edit → PR → done).  AllowList filtering
    ensures tools not in the keeper's preset are invisible.

    Action symmetry: every observation tool has a corresponding action tool
    visible by default (fs_read → fs_edit, shell_readonly → bash).
    This prevents the 9B "read-only polling loop" trap where the model
    repeatedly observes but cannot discover the tools needed to act.
    26 tools; 9B handles 21+ tools at 100% accuracy (#5568, #5661). *)
let core_discovery_tools =
  core_always_tools @
  (* Coordination & awareness *)
  [ "keeper_broadcast"; "keeper_tasks_list";
    "keeper_task_claim"; "keeper_task_done"; "keeper_tasks_audit";
    "keeper_memory_search"; "keeper_time_now";
    (* Filesystem: read + write (action symmetry) *)
    "keeper_fs_read"; "keeper_fs_edit";
    (* Board: core interaction *)
    "keeper_board_get"; "keeper_board_post";
    "keeper_board_comment"; "keeper_board_vote"; "keeper_board_list";
    (* Shell: readonly + execution (action symmetry) *)
    "keeper_shell_readonly"; "keeper_bash";
    (* VCS: essential for coding keepers *)
    "keeper_pr_workflow"; "keeper_github";
    (* External search *)
    "masc_web_search";
  ]

let effective_core_tools () = core_discovery_tools

let core_always_set : (string, unit) Hashtbl.t =
  let tbl = Hashtbl.create (List.length core_always_tools) in
  List.iter (fun name -> Hashtbl.replace tbl name ()) core_always_tools;
  tbl

let is_core_always_tool (name : string) : bool =
  Hashtbl.mem core_always_set name

(* ── Read-only keeper tools ───────────────────────────────────── *)

(** Keeper-only tools are declared via [Tool_shard] schemas, so many never
    flow through [Tool_spec.register]. Keep a local read-only SSOT for
    integrity checks that run before or outside full MCP server bootstrap. *)
let keeper_read_only_tools =
  [
    "keeper_stay_silent";
    "keeper_time_now";
    "keeper_context_status";
    "keeper_memory_search";
    "keeper_tools_list";
    "keeper_tool_search";
    "keeper_board_get";
    "keeper_board_list";
    "keeper_board_stats";
    "keeper_board_search";
    "keeper_fs_read";
    "keeper_shell_readonly";
    "keeper_library_search";
    "keeper_library_read";
    "keeper_tasks_list";
    "keeper_tasks_audit";
    "keeper_voice_sessions";
  ]

let keeper_read_only_set : (string, unit) Hashtbl.t =
  let tbl = Hashtbl.create (List.length keeper_read_only_tools) in
  List.iter (fun name -> Hashtbl.replace tbl name ()) keeper_read_only_tools;
  tbl

let is_keeper_read_only_tool (name : string) : bool =
  Hashtbl.mem keeper_read_only_set name

let is_effectively_read_only_tool (name : string) : bool =
  Tool_dispatch.is_read_only name || is_keeper_read_only_tool name

(* ── Boring tools (non-productive observation/polling) ─────── *)

(** Tools that gather status but produce no side effects.
    Calling only these tools across consecutive turns indicates a
    polling loop.  This shared classification is used both by the
    boring-tool gate in [Keeper_hooks_oas] to detect and break such
    loops, and by allowlist gating through [is_boring_tool].

    A tool is "boring" if calling it N times yields the same
    information as calling it once, and it mutates nothing.
    [keeper_stay_silent] is included: it is a no-op by design
    and must not reset the boring-turn counter.
    Contrast with [keeper_fs_read] which reads new content, or
    [keeper_board_post] which creates artifacts. *)
let boring_tools =
  [ "masc_status"; "masc_heartbeat"; "keeper_tasks_list";
    "keeper_context_status"; "keeper_tools_list";
    "keeper_stay_silent" ]

let boring_tools_set : (string, unit) Hashtbl.t =
  let tbl = Hashtbl.create (List.length boring_tools) in
  List.iter (fun name -> Hashtbl.replace tbl name ()) boring_tools;
  tbl

let is_boring_tool (name : string) : bool =
  Hashtbl.mem boring_tools_set name

(* ── Dynamic schema injection (masc_* tools) ──────────────────── *)

let masc_schemas_ref : Types.tool_schema list ref = ref []

let injected_masc_tool_names () =
  !masc_schemas_ref
  |> List.map (fun (schema : Types.tool_schema) -> schema.name)

(* ── keeper_tool_search schema ───────────────────────────────── *)

(** SSOT schema for keeper_tool_search.  Defined here because this is
    the keeper tool registry — the canonical owner of keeper-internal tool
    metadata.  Consumed by [keeper_tool_policy.keeper_default_model_tools]. *)
let keeper_tool_search_schema : Types.tool_schema =
  {
    name = "keeper_tool_search";
    description =
      "Search for tools by query describing what you need. \
       Returns tool names, descriptions, and usage guidance. \
       Use when your current tools are insufficient for the task.";
    input_schema =
      `Assoc [
        ("type", `String "object");
        ("properties", `Assoc [
          ("query", `Assoc [
            ("type", `String "string");
            ("description", `String
              "Natural language description of what you need to \
               do, e.g. 'create a git worktree' or 'manage auth tokens'");
          ]);
          ("max_results", `Assoc [
            ("type", `String "integer");
            ("description", `String "Maximum results (default 5, max 10)");
          ]);
        ]);
        ("required", `List [ `String "query" ]);
      ];
  }
