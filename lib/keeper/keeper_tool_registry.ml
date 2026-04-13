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
    session control (extend_turns),
    self-introspection (tools_list), and token budget awareness
    (context_status).  Heartbeat is server-managed via
    keeper_keepalive.ml — no LLM tool call needed.
    Other tools moved to BM25 retrieval to free ranking budget.
    See #4961. *)
let core_always_tools =
  [ "keeper_context_status"; "keeper_tools_list";
    "keeper_stay_silent"; "keeper_tool_search";
    "extend_turns" ]

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
    "keeper_board_delete"; "keeper_board_cleanup";
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

(* ── Input-aware read-only check ─────────────────────────────
   Some tools (keeper_github, masc_code_git) mix read-only and mutating
   subcommands within a single tool name. This function inspects the
   JSON input to distinguish calls with no side effects. *)

let gh_read_only_prefixes =
  [ "pr list"; "pr view"; "pr diff"; "pr checks"; "pr status"
  ; "issue list"; "issue view"; "issue status"
  ; "repo view"; "repo list"
  ; "release list"; "release view"
  ]

(** [is_gh_api_read_only cmd_lower] returns true when a `gh api ...`
    invocation is effectively a GET request with no mutation side effects.
    `gh api` defaults to GET, but becomes mutating when:
    - `-X`/`--method` specifies POST/PUT/PATCH/DELETE
    - `-f`/`-F`/`--field`/`--raw-field` is present (implies POST)
    - The subcommand is `graphql` (always POST)
    The input [cmd_lower] must already be lowercased and trimmed. *)
let is_gh_api_read_only (cmd_lower : string) : bool =
  if not (String.length cmd_lower >= 3
          && String.sub cmd_lower 0 3 = "api") then false
  else
    let rest = String.trim (String.sub cmd_lower 3 (String.length cmd_lower - 3)) in
    (* graphql subcommand is always POST *)
    if String.length rest >= 7 && String.sub rest 0 7 = "graphql" then false
    else
      let tokens = String.split_on_char ' ' cmd_lower in
      let has_method_flag =
        let rec check = function
          | [] -> false
          | tok :: rest_toks ->
            if tok = "-x" || tok = "--method" then
              (* next token is the method *)
              (match rest_toks with
               | method_tok :: _ ->
                 method_tok <> "get"
               | [] -> true (* flag with no value — conservative: mutating *))
            else if (String.length tok > 3
                     && String.sub tok 0 3 = "-x=") then
              let method_val = String.sub tok 3 (String.length tok - 3) in
              method_val <> "get"
            else if (String.length tok > 9
                     && String.sub tok 0 9 = "--method=") then
              let method_val = String.sub tok 9 (String.length tok - 9) in
              method_val <> "get"
            else check rest_toks
        in
        check tokens
      in
      let has_field_flag =
        List.exists (fun tok ->
          tok = "-f" || tok = "-ff"
          || String.length tok > 3 && String.sub tok 0 3 = "-f="
          || tok = "--field" || tok = "--raw-field"
          || String.length tok > 8 && String.sub tok 0 8 = "--field="
        ) tokens
      in
      not has_method_flag && not has_field_flag

(** Extract the effective gh command string from keeper_github JSON input.
    [handle_keeper_github] uses [cmd] first; if empty, falls back to
    joining [args].  This function mirrors that logic so the read-only
    classification matches what actually executes. *)
let gh_effective_cmd (input : Yojson.Safe.t) : string =
  match input with
  | `Assoc fields ->
    let cmd =
      match List.assoc_opt "cmd" fields with
      | Some (`String s) -> String.trim s
      | _ -> ""
    in
    if cmd <> "" then cmd
    else
      let args =
        match List.assoc_opt "args" fields with
        | Some (`List items) ->
          List.filter_map (function `String s -> Some s | _ -> None) items
        | _ -> []
      in
      if args <> [] then String.concat " " args else ""
  | _ -> ""

let git_read_only_actions =
  [ "diff"; "status"; "log"; "branch"; "fetch" ]

let git_action_of_input (input : Yojson.Safe.t) : string =
  match input with
  | `Assoc fields ->
    (match List.assoc_opt "action" fields with
     | Some (`String s) -> String.lowercase_ascii (String.trim s)
     | _ -> "")
  | _ -> ""

let is_read_only_with_input ~(tool_name : string) ~(input : Yojson.Safe.t) : bool =
  if is_effectively_read_only_tool tool_name then true
  else match tool_name with
  | "keeper_github" ->
    let cmd = gh_effective_cmd input in
    let cmd_lower = String.lowercase_ascii cmd in
    if cmd_lower = "" then false
    else if String.length cmd_lower >= 3
            && String.sub cmd_lower 0 3 = "api" then
      is_gh_api_read_only cmd_lower
    else
      List.exists (fun prefix ->
        String.length cmd_lower >= String.length prefix
        && String.sub cmd_lower 0 (String.length prefix) = prefix
      ) gh_read_only_prefixes
  | "masc_code_git" -> List.mem (git_action_of_input input) git_read_only_actions
  | "masc_worktree_list" -> true
  | _ -> false

(* ── Input-aware mutation-boundary bypass ────────────────────
   Some tools do mutate state, but they should not open the
   main-worktree checkpoint boundary because they either:
   - only touch MASC coordination state (tasks, board, broadcast), or
   - operate inside an explicit worktree/playground sandbox.

   Keep these tools mutating for reconcile/error handling; this predicate
   only controls whether the per-turn boundary blocks follow-up tools.

   DESIGN SMELL — see [keeper_tool_registry.mli] follow-up: the allowlist
   is hardcoded by tool name, so it drifts whenever a new tool is added
   (or renamed) in [keeper_tool_registry]/[masc_mcp.ml].  The [keeper_*]
   and [masc_*] name prefixes carry no effect-domain semantics — e.g.,
   [keeper_task_claim] and [masc_claim_next] both claim a task but this
   predicate listed only the former until #6671 (this change).  The
   structural fix is to tag every tool spec with an
   [effect_domain = Read_only | Masc_coordination | Playground_write |
   Main_worktree_write] variant and derive this predicate from the tag,
   so the OCaml exhaustiveness checker catches missing entries at
   compile time.  Tracked as follow-up; the minimal patch below unblocks
   keepers first. *)
let is_main_worktree_boundary_exempt_with_input
    ~(tool_name : string)
    ~(input : Yojson.Safe.t) : bool =
  if is_read_only_with_input ~tool_name ~input then true
  else
    match tool_name with
    | "keeper_task_claim" | "keeper_task_done" | "keeper_tasks_list"
    | "keeper_board_post" | "keeper_board_comment" | "keeper_board_vote"
    | "keeper_board_list" | "keeper_board_get"
    (* Board delete and cleanup are MASC-state-only mutations (board
       post store), not main-worktree writes.  Missing here until #6692
       caused [janitor] to hit a mutation-boundary block loop at
       2026-04-12 01:15:25 KST: the first [keeper_board_delete] in a
       cleanup turn succeeded and opened the boundary, and every
       subsequent [keeper_board_delete] in the same turn was blocked
       by the [pre_tool_use_guard], burning the turn budget without
       progress.  The [masc_board_delete] alias was already exempt at
       line 283 but its [keeper_*] counterpart had drifted out of this
       list — same structural gap fixed by #6681 for [masc_claim_next]. *)
    | "keeper_board_delete" | "keeper_board_cleanup"
    | "keeper_broadcast" -> true
    (* MASC coordination aliases for the [keeper_*] entries above.
       These share the same name with a [masc_] prefix because they are
       exposed via the masc-mcp tool surface instead of the per-keeper
       surface, but their effect is identical: MASC task/board state
       only, never the main worktree.  Missing here until #6671 caused
       [masc_improver] to hang after [masc_add_task] opened a boundary:
       the follow-up [masc_claim_next] was blocked, the LLM looped on
       text-only responses, and the turn exhausted cascade budget on
       [max_tokens] — all downstream of this allowlist gap.  See log
       timestamp 2026-04-12 09:40:58 "pre_tool_use guard blocked
       masc_claim_next". *)
    | "masc_tasks" | "masc_add_task" | "masc_claim_next"
    | "masc_batch_add_tasks" | "masc_plan_init" | "masc_plan_set_task"
    | "masc_plan_update" | "masc_plan_get" | "masc_transition"
    | "masc_broadcast" | "masc_messages" | "masc_status"
    | "masc_dashboard" | "masc_agents" | "masc_agent_card"
    | "masc_board_post" | "masc_board_comment" | "masc_board_vote"
    | "masc_board_comment_vote" | "masc_board_delete"
    | "masc_board_list" | "masc_board_get" | "masc_board_stats"
    | "masc_board_hearths" | "masc_board_profile" -> true
    | "masc_code_edit" | "masc_code_write" | "masc_code_delete"
    | "masc_code_shell" | "masc_code_git" | "masc_worktree_create"
    | "keeper_pr_submit" | "keeper_fs_edit" -> true
    | _ -> false

(* ── Reconcile-safe tools (mutating but idempotent enough) ─── *)

(** Tools that produce side effects but are safe to leave un-reconciled
    after a transient failure or timeout.  Board mutations (post, comment,
    vote) are not strictly idempotent — retries may create duplicate
    content — but duplicate posts are an acceptable cost vs. a permanently
    stuck keeper.  When ALL committed tools in a failed turn belong to
    this set AND the failure is transient, manual_reconcile is skipped.

    [keeper_broadcast]: duplicate broadcast is noise, not data loss.
    [keeper_task_done]: completing the same task twice is a no-op.
    [keeper_task_claim] is NOT safe: claim_next_r auto-releases a
    previous claim and selects a new task, so retries are not idempotent.

    Read-only tools (board_list, board_get) are excluded: they never
    appear in [committed_mutating_tools] so including them here would
    be misleading dead entries. *)
let reconcile_safe_tools =
  [ "keeper_board_post"; "keeper_board_comment";
    "keeper_board_vote"; "keeper_board_comment_vote";
    "keeper_broadcast";
    "keeper_task_done";
    "masc_board_post"; "masc_board_comment";
    "masc_board_vote"; "masc_board_comment_vote";
    "masc_broadcast" ]

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
    "keeper_stay_silent"; "keeper_board_list";
    "masc_board_list" ]

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
