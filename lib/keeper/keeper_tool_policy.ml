(** Keeper_tool_policy — tool access control, presets, and allowed-tool resolution.

    Consumes [Keeper_tool_registry] for tool name lists.
    Produces the access-policy types and functions used by the dispatch layer. *)

open Keeper_types
open Keeper_alerting
open Keeper_tool_registry

(* ── Denied-tool set (O(1) lookup) ────────────────────────────── *)

let keeper_denied_set : (string, unit) Hashtbl.t =
  let tbl = Hashtbl.create 32 in
  List.iter (fun name -> Hashtbl.replace tbl name ())
    (Tool_catalog.tools_for_surface Tool_catalog.Keeper_denied);
  tbl

let is_keeper_denied (name : string) : bool =
  Hashtbl.mem keeper_denied_set name

(* ── Schema injection filter ──────────────────────────────────── *)

let inject_masc_schemas (schemas : Types.tool_schema list) =
  masc_schemas_ref :=
    List.filter (fun (s : Types.tool_schema) ->
      String.starts_with ~prefix:"masc_" s.name
      && not (is_keeper_denied s.name))
      schemas

let select_existing_masc_tool_names names =
  let injected = injected_masc_tool_names () in
  names
  |> List.filter (fun name -> List.mem name injected)
  |> dedupe_tool_names

(* ── Candidate aggregation ────────────────────────────────────── *)

let keeper_all_candidate_tool_names () =
  dedupe_tool_names
    ( keeper_internal_candidate_tool_names
    @ keeper_voice_tool_names
    @ keeper_governance_tool_names
    @ keeper_coding_shard_tool_names
    @ keeper_coding_tool_names
    @ keeper_autoresearch_tool_names
    @ keeper_research_loop_tool_names
    @ keeper_voice_tool_names
    @ injected_masc_tool_names () )

(* ── Presets ──────────────────────────────────────────────────── *)

let preset_allowlist = function
  | Minimal ->
      dedupe_tool_names
        ( keeper_base_tool_names
        @ select_existing_masc_tool_names [ "masc_status"; "masc_tool_help" ] )
  | Messaging ->
      dedupe_tool_names
        ( keeper_base_tool_names
        @ keeper_board_tool_names
        @ keeper_coordination_tool_names
        @ keeper_voice_tool_names
        @ keeper_governance_tool_names
        @ select_existing_masc_tool_names keeper_core_masc_tool_names )
  | Coding ->
      dedupe_tool_names
        ( keeper_base_tool_names
        @ keeper_filesystem_tool_names
        @ keeper_library_tool_names
        @ keeper_shell_readonly_tool_names
        @ keeper_coordination_tool_names
        @ keeper_coding_shard_tool_names
        @ keeper_coding_tool_names
        @ select_existing_masc_tool_names
            (keeper_core_masc_tool_names @ keeper_coding_masc_tool_names) )
  | Research ->
      dedupe_tool_names
        ( keeper_base_tool_names
        @ keeper_filesystem_tool_names
        @ keeper_library_tool_names
        @ keeper_shell_readonly_tool_names
        @ keeper_coordination_tool_names
        @ keeper_board_tool_names
        @ keeper_governance_tool_names
        @ keeper_autoresearch_tool_names
        @ keeper_research_loop_tool_names
        @ select_existing_masc_tool_names keeper_core_masc_tool_names )
  | Full -> keeper_all_candidate_tool_names ()

let tool_policy_of_meta (meta : keeper_meta) =
  let allow =
    match meta.tool_access with
    | Preset { preset; also_allow } ->
        Tool_access_policy.Names (preset_allowlist preset @ also_allow)
    | Custom allowlist ->
        Tool_access_policy.Names allowlist
  in
  {
    Tool_access_policy.allow;
    deny = Tool_access_policy.Names meta.tool_denylist;
  }

(* ── Access lookup (O(1) per tool) ────────────────────────────── *)

type tool_access_lookup = {
  candidate_names : string list;
  candidate_set : (string, unit) Hashtbl.t;
  allow_set : (string, unit) Hashtbl.t;
  deny_set : (string, unit) Hashtbl.t;
}

let tool_name_set names =
  let tbl = Hashtbl.create (max 16 (List.length names)) in
  List.iter (fun name -> Hashtbl.replace tbl name ()) names;
  tbl

let tool_access_lookup_of_meta (meta : keeper_meta) =
  let candidate_names = keeper_all_candidate_tool_names () in
  let candidate_set = tool_name_set candidate_names in
  let allow_names =
    Tool_access_policy.resolve
      ~candidates:candidate_names
      (tool_policy_of_meta meta)
    |> List.filter (fun name -> Hashtbl.mem candidate_set name)
    |> dedupe_tool_names
  in
  {
    candidate_names;
    candidate_set;
    allow_set = tool_name_set allow_names;
    deny_set = tool_name_set meta.tool_denylist;
  }

let filter_by_access ~(lookup : tool_access_lookup) (name : string) : bool =
  Hashtbl.mem lookup.candidate_set name
  && Hashtbl.mem lookup.allow_set name
  && not (Hashtbl.mem lookup.deny_set name)

(** Universe check: candidate minus denied, ignoring policy allowlist.
    Core tools and BM25-discovered tools use this gate at execution time. *)
let filter_by_universe ~(lookup : tool_access_lookup) (name : string) : bool =
  Hashtbl.mem lookup.candidate_set name
  && not (Hashtbl.mem lookup.deny_set name)

(** Execution gate: core tools bypass policy, others require policy allowlist.
    All tools must exist in candidate_set — rejects hallucinated tool names. *)
let can_execute ~(lookup : tool_access_lookup) (name : string) : bool =
  if not (Hashtbl.mem lookup.candidate_set name
          || Keeper_tool_registry.is_core_always_tool name) then
    false
  else if Keeper_tool_registry.is_core_always_tool name then
    filter_by_universe ~lookup name
  else
    filter_by_access ~lookup name

(* ── Public query functions ───────────────────────────────────── *)

let keeper_masc_tool_names (meta : keeper_meta) : string list =
  let lookup = tool_access_lookup_of_meta meta in
  !masc_schemas_ref
  |> List.filter_map (fun (schema : Types.tool_schema) ->
    if filter_by_access ~lookup schema.name
    then Some schema.name
    else None)

let keeper_masc_tool_schemas (meta : keeper_meta) : Types.tool_schema list =
  let lookup = tool_access_lookup_of_meta meta in
  !masc_schemas_ref
  |> List.filter (fun (schema : Types.tool_schema) -> filter_by_access ~lookup schema.name)

(* ── Layer 2: Universe (all executable tools, policy-independent) ── *)

(** Universe masc_* schemas: candidate minus denied, no policy filter.
    Used by make_tools to build Tool.t for BM25 retrieval scope. *)
let keeper_universe_masc_tool_schemas (meta : keeper_meta) : Types.tool_schema list =
  let lookup = tool_access_lookup_of_meta meta in
  !masc_schemas_ref
  |> List.filter (fun (schema : Types.tool_schema) ->
    filter_by_universe ~lookup schema.name)

let keeper_default_model_tools (_meta : keeper_meta) : Types.tool_schema list =
  keeper_model_tools @ keeper_voice_tool_schemas

let keeper_allowed_tool_names ?(write_done = false) (meta : keeper_meta) :
    string list =
  if write_done then
    []
  else
    let lookup = tool_access_lookup_of_meta meta in
    lookup.candidate_names
    |> List.filter (fun name -> filter_by_access ~lookup name)
    |> dedupe_tool_names

(** Universe tool names: candidates minus denied, no policy filter.
    Superset of keeper_allowed_tool_names.  BM25 indexes this set so
    progressive disclosure can discover tools beyond the active preset.
    Core tools are always included even if masc_schemas haven't been
    injected yet (startup race) or the tool is not in any preset. *)
let keeper_universe_tool_names (meta : keeper_meta) : string list =
  let lookup = tool_access_lookup_of_meta meta in
  let from_candidates =
    lookup.candidate_names
    |> List.filter (fun name -> filter_by_universe ~lookup name)
  in
  let from_core =
    Keeper_tool_registry.core_always_tools
    |> List.filter (fun name -> not (Hashtbl.mem lookup.deny_set name))
  in
  dedupe_tool_names (from_candidates @ from_core)

let keeper_allowed_model_tools ?(write_done = false) (meta : keeper_meta) :
    Types.tool_schema list =
  let allowed = keeper_allowed_tool_names ~write_done meta in
  if allowed = [] then
    []
  else
    let all_schemas =
      (keeper_default_model_tools meta)
      @ Tool_research.schemas
      @ Tool_shard.autoresearch_keeper_tools
      @ Tool_shard.coding_tools
      @ Tool_code_write.schemas
      @ (keeper_masc_tool_schemas meta)
    in
    let result =
      all_schemas
      |> List.filter (fun tool -> List.mem tool.Types.name allowed)
    in
    let count = List.length result in
    if count > 100 then
      Log.Keeper.warn
        "tool budget exceeded: %d schemas in LLM context (~%dKB estimated). \
         Consider using a narrower preset or custom allowlist."
        count (count * 470 / 1024);
    result

(** Universe model tool schemas for make_tools.
    Returns schemas for all universe tools so Agent.run() can call them. *)
let keeper_universe_model_tools (meta : keeper_meta) : Types.tool_schema list =
  let universe = keeper_universe_tool_names meta in
  let all_schemas =
    (keeper_default_model_tools meta)
    @ Tool_research.schemas
    @ Tool_shard.autoresearch_keeper_tools
    @ Tool_shard.coding_tools
    @ Tool_code_write.schemas
    @ (keeper_universe_masc_tool_schemas meta)
  in
  all_schemas
  |> List.filter (fun tool -> List.mem tool.Types.name universe)
