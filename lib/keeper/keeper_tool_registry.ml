(** Keeper_tool_registry -- runtime tool name sources and schema injection.

    This module retains runtime-resolved names (Tool_catalog, Tool_shard,
    injected MASC tools), core always-available tools, and dynamic schema
    injection. Execution surfaces are resolved from descriptors/registries
    and then denylist-filtered. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile

let dedupe_tool_names names =
  dedupe_keep_order (names |> List.map String.trim |> List.filter (fun name -> name <> ""))
;;

(* RFC-0160 S7: raw command parsing is centralized in {!Exec_policy};
   word extraction is owned by {!Keeper_tool_command_words}. *)

(* ── Runtime-resolved tool names ─────────────────────────────── *)

(* The Agent_internal surface was empty (agent_internal_surface_tools = []),
   so this candidate list has always been empty.  Surface deleted in the
   surface-cut refactor; retained as [] because the [Registry_internal_candidate]
   resolution source and keeper_tool_policy still reference it. *)
let keeper_internal_candidate_tool_names : string list = []
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
    Keeper_tool_name.to_string
    Keeper_tool_name.[ Context_status; Stay_silent; Tool_search ]
  @ [ "extend_turns" ]
;;

(* OAS SDK-provided, not in Tool_name *)

(** Core tools always visible to the LLM.  All other tools are
    discoverable on demand via [keeper_tool_search].

    Pruning policy (Samchon harness principle — fewer tools = higher
    selection accuracy for small models):
    - Removed from core: keeper_time_now (trivial, shell fallback),
      keeper_tasks_audit (admin).
    - keeper_tools_list moved from core_always to discoverable.
    - Execute stays visible because it is the write-side git path after
      removing retired repository mutation wrappers.
    - 26 → 20 tools.  9B tool selection accuracy improves with fewer
      choices (vLLM Semantic Router research: k=3-5 optimal for 7-9B).

    Action symmetry preserved: every observation tool has a
    corresponding action tool (fs_read → fs_edit, board_list → board_post,
    shell → github).  This prevents the "read-only polling loop" where
    the model repeatedly observes but cannot find tools to act. *)
let base_core_tools =
  core_always_tools
  @ List.map
      Keeper_tool_name.to_string
      Keeper_tool_name.
        [ (* Workspace *)
          Broadcast
        ; Tasks_list
        ; Task_claim
        ; Task_done
        ; Task_create
        ; Memory_search
        ; (* Board: core interaction *)
          Board_post_get
        ; Board_post
        ; Board_comment
        ; Board_vote
        ; Board_list
        ; Board_curation_read
        ; Board_curation_submit
        ; (* Discovery fallback for meta/admin tools *)
          Tools_list
        ]
;;

let core_discovery_tools =
  base_core_tools
  (* RFC-0064/RFC-016x: public capability names replace internal names
     in the LLM-facing discovery surface. *)
  @ Keeper_tool_descriptor.public_names ()
;;

let effective_core_tools () = core_discovery_tools
;;

let core_always_set : (string, unit) Hashtbl.t =
  let tbl = Hashtbl.create (List.length core_always_tools) in
  List.iter (fun name -> Hashtbl.replace tbl name ()) core_always_tools;
  tbl
;;

let is_core_always_tool (name : string) : bool = Hashtbl.mem core_always_set name

(* ── Read-only keeper tools ───────────────────────────────────── *)

(** Descriptor-projected read-only tools. This covers non-shard tools and
    descriptor-backed public/workspace tools without adding new string
    mirrors to the registry. *)
let descriptor_read_only_tools = Keeper_tool_descriptor.readonly_internal_names ()

let keeper_read_only_tools =
  Tool_shard.all_read_only_keeper_tools () @ descriptor_read_only_tools
  |> List.sort_uniq String.compare
;;

let keeper_read_only_lookup : (string, unit) Hashtbl.t =
  let tbl = Hashtbl.create (List.length keeper_read_only_tools) in
  List.iter (fun name -> Hashtbl.replace tbl name ()) keeper_read_only_tools;
  tbl
;;

let is_keeper_read_only_tool (name : string) : bool =
  Hashtbl.mem keeper_read_only_lookup name
;;

let is_effectively_read_only_tool (name : string) : bool =
  (* Keeper-local check first (bare Hashtbl, no mutex) before
     descriptor-aware capability lookup. *)
  is_keeper_read_only_tool name
  || Keeper_tool_descriptor_resolution.capability_has Tool_capability.Read_only name
  || Keeper_tool_descriptor_resolution.capability_has Tool_capability.Idempotent name
;;

let has_mutating_side_effect (name : string) : bool =
  not (is_effectively_read_only_tool name)
;;

(* ── Input-aware read-only check ─────────────────────────────
   Some tools mix read-only and mutating subcommands within a single
   tool name. This function inspects JSON input where a live tool has
   such a contract. *)

let is_read_only_with_input ~(tool_name : string) ~(input : Yojson.Safe.t) : bool =
  match Keeper_tool_descriptor_resolution.readonly_for_tool_call ~tool_name ~input with
  | Some readonly -> readonly
  | None -> is_effectively_read_only_tool tool_name
;;

let descriptor_boundary_exempt tool_name =
  match Keeper_tool_descriptor_resolution.descriptor_for_tool_name tool_name with
  | None -> None
  | Some descriptor ->
    (match descriptor.Keeper_tool_descriptor.policy.effect_domain with
     | Some Tool_catalog.Read_only
     | Some Tool_catalog.Masc_workspace
     | Some Tool_catalog.Playground_write -> Some true
     | Some Tool_catalog.Host_repo_write -> Some false
     | None -> None)
;;

let effect_domain_boundary_exempt = function
  | Some Tool_catalog.Read_only
  | Some Tool_catalog.Masc_workspace
  | Some Tool_catalog.Playground_write -> Some true
  | Some Tool_catalog.Host_repo_write -> Some false
  | None -> None
;;

let catalog_boundary_exempt tool_name =
  match effect_domain_boundary_exempt (Tool_catalog.effect_domain tool_name) with
  | Some _ as decision -> decision
  | None ->
    (match
       Keeper_tool_descriptor_resolution.canonical_internal_name_for_tool_name tool_name
     with
     | Some internal_name when not (String.equal internal_name tool_name) ->
       effect_domain_boundary_exempt (Tool_catalog.effect_domain internal_name)
     | Some _ | None -> None)
;;

(* ── Input-aware mutation-boundary bypass ────────────────────
   Some tools do mutate state, but they should not open the
   main-worktree checkpoint boundary because they either:
   - only touch MASC workspace state (tasks, board, broadcast), or
   - operate inside an explicit playground sandbox.

   Keep these tools mutating for reconcile/error handling; this predicate
   only controls whether the per-turn boundary blocks follow-up tools.

   The effect-domain tag is resolved through the descriptor projection first,
   so this boundary no longer has to mirror tool names or infer semantics from
   prefixes. *)
let is_main_worktree_boundary_exempt_with_input
      ~(tool_name : string)
      ~(input : Yojson.Safe.t)
  : bool
  =
  if is_read_only_with_input ~tool_name ~input
  then true
  else (
    match descriptor_boundary_exempt tool_name with
    | Some decision -> decision
    | None ->
      (match catalog_boundary_exempt tool_name with
       | Some decision -> decision
       | None -> false))
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
    Keeper_tool_name.to_string
    Keeper_tool_name.
      [ Board_post
      ; Board_comment
      ; Board_vote
      ; Board_comment_vote
      ; Board_curation_submit
      ; Broadcast
      ; Task_done
      ]
  @ List.map
      Tool_name.Board_name.to_string
      Tool_name.Board_name.
        [ Board_post
        ; Board_comment
        ; Board_vote
        ; Board_comment_vote
        ; Board_curation_submit
        ]
  @ [ "masc_broadcast" ]
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

let injected_masc_tool_names () =
  masc_schemas_snapshot ()
  |> List.map (fun (schema : Masc_domain.tool_schema) -> schema.name)
;;

(* ── Universe-aware effective core tools ─────────────────────── *)

let effective_core_tools () =
  let universe_set =
    injected_masc_tool_names ()
    |> List.fold_left
         (fun acc name -> Set_util.StringSet.add name acc)
         Set_util.StringSet.empty
  in
  let descriptor_publics =
    Keeper_tool_descriptor.public_descriptors
    |> List.filter (fun d -> Set_util.StringSet.mem d.Keeper_tool_descriptor.internal_name universe_set)
    |> List.concat_map Keeper_tool_descriptor.public_names_of_descriptor
  in
  base_core_tools @ descriptor_publics
;;

(* ── keeper_tool_search schema ───────────────────────────────── *)

(** SSOT schema for keeper_tool_search.  Defined here because this is
    the keeper tool registry — the canonical owner of keeper-internal tool
    metadata. *)
let keeper_tool_search_schema : Masc_domain.tool_schema =
  { name = Keeper_tool_name.to_string Keeper_tool_name.Tool_search
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
                           'inspect a repo' or 'manage auth tokens'" )
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
