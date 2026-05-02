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
    session control (extend_turns), token budget awareness
    (context_status), tool discovery (tool_search), and the
    no-op safety valve (stay_silent).
    keeper_tools_list moved to BM25-discoverable: it is a debugging
    aid, not survival-critical, and occupied a slot that small models
    wasted on meta-introspection instead of productive action.
    See #4961. *)
let core_always_tools =
  List.map Tool_name.to_string
    Tool_name.[ Keeper Context_status; Keeper Stay_silent; Keeper Tool_search ]
  @ [ "extend_turns" ] (* OAS SDK-provided, not in Tool_name *)

(** Core tools always visible to the LLM.  All other tools are
    discoverable on demand via [keeper_tool_search].

    Pruning policy (Samchon harness principle — fewer tools = higher
    selection accuracy for small models):
    - Removed from core: keeper_time_now (trivial, shell fallback),
      keeper_tasks_audit (admin), keeper_board_delete (admin #4309),
      keeper_board_cleanup (admin).
    - keeper_tools_list moved from core_always to discoverable.
    - keeper_bash stays visible because it is the write-side git path
      after removing legacy PR wrappers.
    - 26 → 20 tools.  9B tool selection accuracy improves with fewer
      choices (vLLM Semantic Router research: k=3-5 optimal for 7-9B).

    Action symmetry preserved: every observation tool has a
    corresponding action tool (fs_read → fs_edit, board_list → board_post,
    shell → github).  This prevents the "read-only polling loop" where
    the model repeatedly observes but cannot find tools to act. *)
let core_discovery_tools =
  core_always_tools @
  List.map Tool_name.to_string
    Tool_name.[
      (* Coordination *)
      Keeper Broadcast; Keeper Tasks_list;
      Keeper Task_claim; Keeper Task_done; Keeper Task_create;
      Keeper Memory_search;
      (* Filesystem: read + write (action symmetry) *)
      Keeper Fs_read; Keeper Fs_edit;
      (* Board: core interaction *)
      Keeper Board_get; Keeper Board_post;
      Keeper Board_comment; Keeper Board_vote; Keeper Board_list;
      (* Shell + VCS *)
      Keeper Shell;
      Keeper Bash;
      Keeper Preflight_check;
      (* Review *)
      Keeper Pr_review_read; Keeper Pr_review_comment; Keeper Pr_review_reply;
      (* Discovery fallback for meta/admin tools *)
      Keeper Tools_list;
      (* External search *)
      Masc Web_search;
    ]

let effective_core_tools () = core_discovery_tools

(** Keeper tools that the dispatcher accepts but that are intentionally
    withheld from the visible/core set — served only when a keeper
    opts in via [policy_config.also_allow] (e.g. the [optional] group
    in [config/tool_policy.toml]).

    Must stay in sync with [Keeper_exec_tools.execute_keeper_tool_call]
    match arms.  Exported so [Tool_registration_check] can recognise
    them as legitimate runtime names instead of flagging them as
    orphan toml entries (#7696). *)
let keeper_admin_dispatched_tools =
  List.map Tool_name.to_string
    Tool_name.[ Keeper Board_cleanup; Keeper Board_delete ]

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
let non_shard_read_only_tools =
  List.map Tool_name.to_string
    Tool_name.[ Keeper Tool_search ] (* injected by Keeper_tool_policy, not in any shard *)

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
   Some tools (keeper_shell, masc_code_git) mix read-only and mutating
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
    The input [cmd_lower] must already be lowercased and trimmed.

    Phase A F5 (2026-04-27): tokenize first, then match on the typed
    structure.  Pre-fix used [String.is_prefix] which silently classified
    [api2 ...] (a hypothetical sibling subcommand) as a gh-api call and
    [graphqlx ...] as the graphql subcommand.  User hard rule: "no
    string matching for classification". *)
let is_gh_api_read_only (cmd_lower : string) : bool =
  let tokens =
    cmd_lower
    |> String.split_on_char ' '
    |> List.filter (fun token -> token <> "")
  in
  match tokens with
  | "api" :: rest_after_api ->
    let is_graphql_subcommand =
      match rest_after_api with
      | "graphql" :: _ -> true
      | _ -> false
    in
    if is_graphql_subcommand then false
    else
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
                     && String.starts_with tok ~prefix:"-x=") then
              let method_val = String.sub tok 3 (String.length tok - 3) in
              method_val <> "get"
            else if (String.length tok > 9
                     && String.starts_with tok ~prefix:"--method=") then
              let method_val = String.sub tok 9 (String.length tok - 9) in
              method_val <> "get"
            else check rest_toks
        in
        check tokens
      in
      let has_field_flag =
        List.exists (fun tok ->
          tok = "-f" || tok = "-ff"
          || String.length tok > 3 && String.starts_with tok ~prefix:"-f="
          || tok = "--field" || tok = "--raw-field"
          || String.length tok > 8 && String.starts_with tok ~prefix:"--field="
        ) tokens
      in
      not has_method_flag && not has_field_flag
  | _ -> false

(** Extract the effective gh command string from keeper_shell op=gh input.
    [keeper_exec_shell] uses the [cmd] field. *)
let normalize_gh_command (cmd : string) : string =
  let tokens =
    cmd
    |> String.trim
    |> String.split_on_char ' '
    |> List.map String.trim
    |> List.filter (fun token -> token <> "")
  in
  let rec drop_leading_gh = function
    | token :: rest when String_util.equals_ci token "gh" ->
        drop_leading_gh rest
    | remaining -> remaining
  in
  String.concat " " (drop_leading_gh tokens)

let gh_effective_cmd (input : Yojson.Safe.t) : string =
  match input with
  | `Assoc fields ->
    (match List.assoc_opt "cmd" fields with
     | Some (`String s) -> normalize_gh_command s
     | _ -> "")
  | _ -> ""

(** Check if keeper_shell input has op="gh". *)
let is_shell_gh_op (input : Yojson.Safe.t) : bool =
  match input with
  | `Assoc fields ->
    (match List.assoc_opt "op" fields with
     | Some (`String s) -> String.trim s = "gh"
     | _ -> false)
  | _ -> false

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
  match Tool_name.of_string tool_name with
  | Some (Keeper Shell) when is_shell_gh_op input ->
    (* keeper_shell with op=gh is input-aware: gh commands can mutate state
       even though the tool itself is marked read-only by default. *)
    let cmd = gh_effective_cmd input in
    let cmd_lower = String.lowercase_ascii cmd in
    if cmd_lower = "" then false
    else if String.starts_with cmd_lower ~prefix:"api" then
      is_gh_api_read_only cmd_lower
    else
      List.exists (fun prefix ->
        String.starts_with cmd_lower ~prefix
      ) gh_read_only_prefixes
  | Some (Masc Code_git) ->
    if is_effectively_read_only_tool tool_name then true
    else List.mem (git_action_of_input input) git_read_only_actions
  | Some (Masc Worktree_list) -> true
  | _ -> is_effectively_read_only_tool tool_name

(* ── Input-aware mutation-boundary bypass ────────────────────
   Some tools do mutate state, but they should not open the
   main-worktree checkpoint boundary because they either:
   - only touch MASC coordination state (tasks, board, broadcast), or
   - operate inside an explicit worktree/playground sandbox.

   Keep these tools mutating for reconcile/error handling; this predicate
   only controls whether the per-turn boundary blocks follow-up tools.

   The effect-domain tag is resolved through [Tool_catalog], so this boundary
   no longer has to mirror tool names or infer semantics from prefixes. *)
let is_main_worktree_boundary_exempt_with_input
    ~(tool_name : string)
    ~(input : Yojson.Safe.t) : bool =
  if is_read_only_with_input ~tool_name ~input then true
  else
    match Tool_catalog.is_main_worktree_boundary_exempt tool_name with
    | Some exempt -> exempt
    | None -> false

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
  List.map Tool_name.to_string
    Tool_name.[
      Keeper Board_post; Keeper Board_comment;
      Keeper Board_vote; Keeper Board_comment_vote;
      Keeper Broadcast;
      Keeper Task_done;
      Masc Board_post; Masc Board_comment;
      Masc Board_vote; Masc Board_comment_vote;
      Masc Broadcast;
    ]

let reconcile_safe_set : (string, unit) Hashtbl.t =
  let tbl = Hashtbl.create (List.length reconcile_safe_tools) in
  List.iter (fun name -> Hashtbl.replace tbl name ()) reconcile_safe_tools;
  tbl

let is_reconcile_safe_tool (name : string) : bool =
  Hashtbl.mem reconcile_safe_set name

let all_tools_reconcile_safe (names : string list) : bool =
  names <> [] && List.for_all is_reconcile_safe_tool names

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
    name = Tool_name.(to_string (Keeper Tool_search));
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
