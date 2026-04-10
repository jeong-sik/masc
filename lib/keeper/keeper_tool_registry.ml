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
    orientation (status), session control (extend_turns),
    self-introspection (tools_list), and token budget awareness
    (context_status).  Heartbeat is server-managed via
    keeper_keepalive.ml — no LLM tool call needed.
    Other tools moved to BM25 retrieval to free ranking budget.
    See #4961. *)
let core_always_tools =
  [ "keeper_context_status"; "keeper_tools_list";
    "keeper_stay_silent"; "keeper_tool_search";
    "masc_status"; "extend_turns" ]

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
    "keeper_shell"; "keeper_bash";
    (* VCS: essential for coding keepers *)
    "keeper_pr_workflow"; "keeper_pr_submit"; "keeper_github";
    "keeper_preflight_check";
    (* Review *)
    "keeper_pr_review_read"; "keeper_pr_review_comment"; "keeper_pr_review_reply";
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

(** Derived from [Tool_shard.shard.read_only_tools] metadata.
    Each shard declares which of its tools are read-only at the
    definition site, eliminating drift between tool schemas and
    read-only classification.

    Non-shard tools (injected outside Tool_shard, e.g. keeper_tool_search)
    are listed explicitly below. *)
let non_shard_read_only_tools = [
  "keeper_tool_search";  (* injected by Keeper_tool_policy, not in any shard *)
]

let keeper_read_only_tools =
  Tool_shard.all_read_only_keeper_tools () @ non_shard_read_only_tools
  |> List.sort_uniq String.compare

let keeper_read_only_set : (string, unit) Hashtbl.t =
  let tbl = Hashtbl.create (List.length keeper_read_only_tools) in
  List.iter (fun name -> Hashtbl.replace tbl name ()) keeper_read_only_tools;
  tbl

let is_keeper_read_only_tool (name : string) : bool =
  Hashtbl.mem keeper_read_only_set name

let is_effectively_read_only_tool (name : string) : bool =
  (* Keeper-local check first (bare Hashtbl, no mutex) before
     Tool_dispatch (requires Eio.Mutex acquire). *)
  is_keeper_read_only_tool name
  || Tool_dispatch.is_read_only name
  || Tool_dispatch.is_idempotent name

let has_mutating_side_effect (name : string) : bool =
  not (is_effectively_read_only_tool name)

(* ── Reconcile-safe tools (mutating but idempotent enough) ─── *)

(** Tools that produce side effects but are safe to leave un-reconciled
    after a transient failure or timeout.  Board mutations (post, comment,
    vote) are not strictly idempotent — retries may create duplicate
    content — but duplicate posts are an acceptable cost vs. a permanently
    stuck keeper.  When ALL committed tools in a failed turn belong to
    this set AND the failure is transient, manual_reconcile is skipped.

    Read-only tools (board_list, board_get) are excluded: they never
    appear in [committed_mutating_tools] so including them here would
    be misleading dead entries. *)
let reconcile_safe_tools =
  [ "keeper_board_post"; "keeper_board_comment";
    "keeper_board_vote"; "keeper_board_comment_vote" ]

let reconcile_safe_set : (string, unit) Hashtbl.t =
  let tbl = Hashtbl.create (List.length reconcile_safe_tools) in
  List.iter (fun name -> Hashtbl.replace tbl name ()) reconcile_safe_tools;
  tbl

let is_reconcile_safe_tool (name : string) : bool =
  Hashtbl.mem reconcile_safe_set name

let all_tools_reconcile_safe (names : string list) : bool =
  names <> [] && List.for_all is_reconcile_safe_tool names

(* ── Boring tools (non-productive observation/polling) ─────── *)

(** Tools that gather status but produce no side effects.
    Calling only these tools across consecutive turns indicates a
    polling loop. This shared classification is still useful for
    prompt shaping, telemetry, and tool-diversity heuristics.

    A tool is "boring" if calling it N times yields the same
    information as calling it once, and it mutates nothing.
    [keeper_stay_silent] is included: it is a no-op by design
    and should not be treated as productive work.
    Contrast with [keeper_fs_read] which reads new content, or
    [keeper_board_post] which creates artifacts. *)
let boring_tools =
  [ "masc_status"; "keeper_tasks_list";
    "keeper_context_status"; "keeper_tools_list";
    "keeper_stay_silent" ]

let boring_tools_set : (string, unit) Hashtbl.t =
  let tbl = Hashtbl.create (List.length boring_tools) in
  List.iter (fun name -> Hashtbl.replace tbl name ()) boring_tools;
  tbl

let is_boring_tool (name : string) : bool =
  Hashtbl.mem boring_tools_set name

let prune_boring_tools_for_actionable_turn (tool_names : string list) :
    string list =
  let actionable =
    List.filter (fun name -> not (is_boring_tool name)) tool_names
  in
  if actionable = [] then tool_names else actionable

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
