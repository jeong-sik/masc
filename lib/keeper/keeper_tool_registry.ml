(** Keeper_tool_registry -- runtime tool name sources and schema injection.

    Static tool name lists have been moved to config/tool_policy.toml.
    This module retains only runtime-resolved names (Tool_catalog,
    Tool_shard, injected MASC tools), core always-visible tools, and
    dynamic schema injection.

    See Keeper_tool_policy_config for the declarative tool groups and presets. *)

open Keeper_types

let dedupe_tool_names names =
  dedupe_keep_order (names |> List.map String.trim |> List.filter (fun name -> name <> ""))
;;

(* RFC-0160 S7: raw command parsing is centralized in
   {!Keeper_shell_command_parse}; word extraction is owned by
   {!Keeper_shell_command_words}. *)

(* ── Runtime-resolved tool names ─────────────────────────────── *)

let keeper_internal_candidate_tool_names =
  Tool_catalog.tools_for_surface Tool_catalog.Keeper_internal
;;

let keeper_voice_tool_schemas =
  match Tool_shard.get_shard "voice" with
  | Some shard -> shard.tools
  | None -> []
;;

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
  List.map
    Tool_name.to_string
    Tool_name.[ Keeper Context_status; Keeper Stay_silent; Keeper Tool_search ]
  @ [ "extend_turns" ]
;;

(* OAS SDK-provided, not in Tool_name *)

(** Core tools always visible to the LLM.  All other tools are
    discoverable on demand via [keeper_tool_search].

    Pruning policy (Samchon harness principle — fewer tools = higher
    selection accuracy for small models):
    - Removed from core: keeper_time_now (trivial, shell fallback),
      keeper_tasks_audit (admin), keeper_board_delete (admin #4309),
      keeper_board_cleanup (admin).
    - keeper_tools_list moved from core_always to discoverable.
    - Execute stays visible because it is the write-side git path after
      removing legacy PR wrappers.
    - 26 → 20 tools.  9B tool selection accuracy improves with fewer
      choices (vLLM Semantic Router research: k=3-5 optimal for 7-9B).

    Action symmetry preserved: every observation tool has a
    corresponding action tool (fs_read → fs_edit, board_list → board_post,
    shell → github).  This prevents the "read-only polling loop" where
    the model repeatedly observes but cannot find tools to act. *)
let core_discovery_tools =
  core_always_tools
  @ List.map
      Tool_name.to_string
      Tool_name.
        [ (* Coordination *)
          Keeper Broadcast
        ; Keeper Tasks_list
        ; Keeper Task_claim
        ; Keeper Task_done
        ; Keeper Task_create
        ; Keeper Memory_search
        ; (* Board: core interaction *)
          Keeper Board_get
        ; Keeper Board_post
        ; Keeper Board_comment
        ; Keeper Board_vote
        ; Keeper Board_list
        ; Keeper Board_curation_read
        ; Keeper Board_curation_submit
        ; (* VCS + misc *)
          Keeper Preflight_check
        ; (* Review *)
          Keeper Pr_review_read
        ; Keeper Pr_review_comment
        ; Keeper Pr_review_reply
        ; (* Discovery fallback for meta/admin tools *)
          Keeper Tools_list
        ]
  (* RFC-0064/RFC-016x: public capability names replace internal names
     in the LLM-facing discovery surface. *)
  @ Agent_tool_descriptor.public_names ()
;;

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
  List.map Tool_name.to_string Tool_name.[ Keeper Board_cleanup; Keeper Board_delete ]
;;

let core_always_set : (string, unit) Hashtbl.t =
  let tbl = Hashtbl.create (List.length core_always_tools) in
  List.iter (fun name -> Hashtbl.replace tbl name ()) core_always_tools;
  tbl
;;

let is_core_always_tool (name : string) : bool = Hashtbl.mem core_always_set name

(* ── Read-only keeper tools ───────────────────────────────────── *)

(** Derived from [Tool_shard.shard.read_only_tools] metadata.
    Each shard declares which of its tools are read-only at the
    definition site, eliminating drift between tool schemas and
    read-only classification.

    Non-shard tools (injected outside Tool_shard, e.g. keeper_tool_search)
    are listed explicitly below. *)
let non_shard_read_only_tools =
  List.map Tool_name.to_string Tool_name.[ Keeper Tool_search ]
;;

(* injected by Keeper_tool_policy, not in any shard *)

let keeper_read_only_tools =
  Tool_shard.all_read_only_keeper_tools () @ non_shard_read_only_tools
  |> List.sort_uniq String.compare
;;

let keeper_read_only_set : (string, unit) Hashtbl.t =
  let tbl = Hashtbl.create (List.length keeper_read_only_tools) in
  List.iter (fun name -> Hashtbl.replace tbl name ()) keeper_read_only_tools;
  tbl
;;

let is_keeper_read_only_tool (name : string) : bool =
  Hashtbl.mem keeper_read_only_set name
;;

let is_effectively_read_only_tool (name : string) : bool =
  (* Keeper-local check first (bare Hashtbl, no mutex) before
     Tool_dispatch (requires Eio.Mutex acquire). *)
  is_keeper_read_only_tool name
  || Tool_dispatch.is_read_only name
  || Tool_dispatch.is_idempotent name
;;

let has_mutating_side_effect (name : string) : bool =
  not (is_effectively_read_only_tool name)
;;

(* ── Input-aware read-only check ─────────────────────────────
   Some tools mix read-only and mutating subcommands within a single
   tool name. This function inspects JSON input where a live tool has
   such a contract. *)

let git_read_only_actions = [ "diff"; "status"; "log"; "branch"; "fetch" ]

let git_action_of_input (input : Yojson.Safe.t) : string =
  match input with
  | `Assoc fields ->
    (match List.assoc_opt "action" fields with
     | Some (`String s) -> String.lowercase_ascii (String.trim s)
     | _ -> "")
  | _ -> ""
;;

let keeper_shell_read_only_ops =
  [ "pwd"
  ; "ls"
  ; "cat"
  ; "rg"
  ; "git_status"
  ; "find"
  ; "head"
  ; "tail"
  ; "wc"
  ; "tree"
  ; "git_log"
  ; "git_diff"
  ]
;;

let keeper_shell_op (input : Yojson.Safe.t) : string option =
  match input with
  | `Assoc fields ->
    (match List.assoc_opt "op" fields with
     | Some (`String s) -> Some (String.lowercase_ascii (String.trim s))
     | _ -> None)
  | _ -> None
;;

let is_read_only_with_input ~(tool_name : string) ~(input : Yojson.Safe.t) : bool =
  match Tool_name.of_string tool_name with
  | Some (Keeper Shell) ->
    (match keeper_shell_op input with
     | Some op -> List.mem op keeper_shell_read_only_ops
     | None -> false)
  | Some (Masc Code_git) ->
    if is_effectively_read_only_tool tool_name
    then true
    else List.mem (git_action_of_input input) git_read_only_actions
  | Some (Masc Worktree_list) -> true
  | _ -> is_effectively_read_only_tool tool_name
;;

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
      ~(input : Yojson.Safe.t)
  : bool
  =
  if is_read_only_with_input ~tool_name ~input
  then true
  else (
    match Tool_catalog.is_main_worktree_boundary_exempt tool_name with
    | Some exempt -> exempt
    | None -> false)
;;

(* ── Reconcile-safe tools (mutating but idempotent enough) ─── *)

(** Tools that produce side effects but are safe to leave un-reconciled
    after a transient failure or timeout.  Board mutations (post, comment,
    vote) are not strictly idempotent — retries may create duplicate
    content — but duplicate posts are an acceptable cost vs. a permanently
    stuck keeper.  When ALL committed tools in a failed turn belong to
    this set AND the failure is transient, manual_reconcile is skipped.

    [keeper_broadcast]: duplicate broadcast is noise, not data loss.
    [keeper_task_done]: completing the same task twice is a no-op.
    [keeper_task_claim] is NOT safe: it can claim new work and alter the
    keeper/task binding, so retries are not idempotent.

    Read-only tools (board_list, board_get) are excluded: they never
    appear in [committed_mutating_tools] so including them here would
    be misleading dead entries. *)
let reconcile_safe_tools =
  List.map
    Tool_name.to_string
    Tool_name.
      [ Keeper Board_post
      ; Keeper Board_comment
      ; Keeper Board_vote
      ; Keeper Board_comment_vote
      ; Keeper Board_curation_submit
      ; Keeper Broadcast
      ; Keeper Task_done
      ; Masc Board_post
      ; Masc Board_comment
      ; Masc Board_vote
      ; Masc Board_comment_vote
      ; Masc Board_curation_submit
      ; Masc Broadcast
      ]
;;

let reconcile_safe_set : (string, unit) Hashtbl.t =
  let tbl = Hashtbl.create (List.length reconcile_safe_tools) in
  List.iter (fun name -> Hashtbl.replace tbl name ()) reconcile_safe_tools;
  tbl
;;

let is_reconcile_safe_tool (name : string) : bool = Hashtbl.mem reconcile_safe_set name

let all_tools_reconcile_safe (names : string list) : bool =
  names <> [] && List.for_all is_reconcile_safe_tool names
;;

(* ── Dynamic schema injection (masc_* tools) ──────────────────── *)

let masc_schemas_mutex = Stdlib.Mutex.create ()
let masc_schemas_state : Masc_domain.tool_schema list ref = ref []

let set_masc_schemas (schemas : Masc_domain.tool_schema list) =
  Stdlib.Mutex.protect masc_schemas_mutex (fun () -> masc_schemas_state := schemas)
;;

let masc_schemas_snapshot () =
  Stdlib.Mutex.protect masc_schemas_mutex (fun () -> !masc_schemas_state)
;;

let with_masc_schemas_for_test schemas f =
  let previous = masc_schemas_snapshot () in
  Eio_guard.protect
    ~finally:(fun () -> set_masc_schemas previous)
    (fun () ->
       set_masc_schemas schemas;
       f ())
;;

let injected_masc_tool_names () =
  masc_schemas_snapshot ()
  |> List.map (fun (schema : Masc_domain.tool_schema) -> schema.name)
;;

(* ── keeper_tool_search schema ───────────────────────────────── *)

(** SSOT schema for keeper_tool_search.  Defined here because this is
    the keeper tool registry — the canonical owner of keeper-internal tool
    metadata.  Consumed by [keeper_tool_policy.keeper_default_model_tools]. *)
let keeper_tool_search_schema : Masc_domain.tool_schema =
  { name = Tool_name.(to_string (Keeper Tool_search))
  ; description =
      "Search for tools by query describing what you need. Returns tool names, \
       descriptions, and usage guidance. Use when your current tools are insufficient \
       for the task."
  ; input_schema =
      `Assoc
        [ "type", `String "object"
        ; ( "properties"
          , `Assoc
              [ ( "query"
                , `Assoc
                    [ "type", `String "string"
                    ; ( "description"
                      , `String
                          "Natural language description of what you need to do, e.g. \
                           'create a git worktree' or 'manage auth tokens'" )
                    ] )
              ; ( "max_results"
                , `Assoc
                    [ "type", `String "integer"
                    ; "description", `String "Maximum results (default 5, max 10)"
                    ] )
              ] )
        ; "required", `List [ `String "query" ]
        ]
  }
;;
