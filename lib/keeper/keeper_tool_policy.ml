(** Keeper_tool_policy — tool access control, presets, and allowed-tool resolution.

    Preset definitions are loaded from [config/tool_policy.toml] at startup
    via {!Keeper_tool_policy_config}.  See that module for the config format.

    Consumes [Keeper_tool_registry] for candidate aggregation and core tools.
    Produces the access-policy types and functions used by the dispatch layer. *)

open Keeper_types
open Keeper_alerting
open Keeper_tool_registry

(* ─�� Config-driven preset resolution ─────────────────────────────── *)

let policy_config : Keeper_tool_policy_config.t option ref = ref None

let init_policy_config ~base_path =
  match Keeper_tool_policy_config.load ~base_path with
  | Ok cfg ->
    policy_config := Some cfg;
    Log.Keeper.info "tool policy config loaded: %d presets, %d groups"
      (List.length (Keeper_tool_policy_config.preset_names cfg))
      (List.length (Keeper_tool_policy_config.group_names cfg))
  | Error msg ->
    Log.Keeper.error "tool policy config load failed: %s" msg;
    failwith (Printf.sprintf "tool policy config load failed: %s" msg)

let preset_name_of_tool_preset = function
  | Minimal -> "minimal"
  | Messaging -> "messaging"
  | Coding -> "coding"
  | Research -> "research"
  | Full -> "full"

(* ── Denied-tool set (O(1) lookup) ────────────────────────────── *)

let keeper_denied_set : (string, unit) Hashtbl.t =
  let tbl = Hashtbl.create 32 in
  List.iter (fun name -> Hashtbl.replace tbl name ())
    (Tool_catalog.tools_for_surface Tool_catalog.Keeper_denied);
  tbl

let dedupe_tool_schemas (schemas : Types.tool_schema list) =
  let seen = Hashtbl.create (max 16 (List.length schemas)) in
  List.filter
    (fun (schema : Types.tool_schema) ->
      if Hashtbl.mem seen schema.name then
        false
      else (
        Hashtbl.replace seen schema.name ();
        true))
    schemas

let is_keeper_denied (name : string) : bool =
  Hashtbl.mem keeper_denied_set name

(* ── Schema injection filter ──────────────────────────────────── *)

let keeper_mcp_context_required_tools =
  Tool_schemas_inline.schemas
  |> List.map (fun (schema : Types.tool_schema) -> schema.name)

let is_keeper_mcp_context_required name =
  List.mem name keeper_mcp_context_required_tools
  || Tool_dispatch.is_mcp_context_required name

let inject_masc_schemas (schemas : Types.tool_schema list) =
  let supported_in_keeper name =
    if Tool_dispatch.is_registered name then
      true
    else if not (Tool_dispatch.is_tag_registry_initialized ()) then
      true
    else
      match Tool_dispatch.lookup_tag name with
      | Some Tool_dispatch.Mod_inline
      | Some Tool_dispatch.Mod_compact
      | Some Tool_dispatch.Mod_keeper
      | Some Tool_dispatch.Mod_operator
      | Some Tool_dispatch.Mod_control ->
          false
      | Some _ -> true
      | None -> false
  in
  (* masc_board_* tools that have keeper_board_* wrappers with auto-injected
     author/voter fields. Exposing both leads to the LLM calling the raw
     masc_* variant without the required author, causing "author is required". *)
  let has_keeper_board_wrapper name =
    match name with
    | "masc_board_comment" | "masc_board_post"
    | "masc_board_vote" | "masc_board_delete" -> true
    | _ -> false
  in
  masc_schemas_ref :=
    List.filter (fun (s : Types.tool_schema) ->
      String.starts_with ~prefix:"masc_" s.name
      && not (is_keeper_mcp_context_required s.name)
      && supported_in_keeper s.name
      && not (is_keeper_denied s.name)
      && not (has_keeper_board_wrapper s.name))
      schemas

let select_existing_masc_tool_names names =
  let injected = injected_masc_tool_names () in
  names
  |> List.filter (fun name -> List.mem name injected)
  |> dedupe_tool_names

(* ── Candidate aggregation ────────────────────────────────────── *)

let keeper_base_candidate_tool_names () =
  dedupe_tool_names
    ( keeper_internal_candidate_tool_names
    @ keeper_voice_tool_names
    @ keeper_governance_tool_names
    @ keeper_coding_shard_tool_names
    @ keeper_coding_tool_names
    @ keeper_autoresearch_tool_names
    @ injected_masc_tool_names () )

let explicit_optional_candidate_tool_names (meta : keeper_meta) =
  let requested =
    match meta.tool_access with
    | Preset { also_allow; _ } -> also_allow
    | Custom allowlist -> allowlist
  in
  requested
  |> List.filter (fun name -> List.mem name keeper_optional_board_tool_names)
  |> dedupe_tool_names

(* ── Presets (config-driven) ───────────────────────────────────── *)

let preset_allowlist preset =
  let name = preset_name_of_tool_preset preset in
  match !policy_config with
  | None ->
    Log.Keeper.error
      "tool policy config not loaded; preset '%s' resolves to empty. \
       Call init_policy_config at startup." name;
    []
  | Some cfg ->
    let injected = injected_masc_tool_names () in
    let masc_filter tool_name = List.mem tool_name injected in
    match Keeper_tool_policy_config.resolve_preset cfg name ~masc_filter () with
    | Some Keeper_tool_policy_config.All_candidates ->
      (* all_candidates = true: return full candidate set *)
      keeper_base_candidate_tool_names ()
    | Some (Keeper_tool_policy_config.Subset tools) -> dedupe_tool_names tools
    | None ->
      Log.Keeper.error "preset '%s' not defined in config/tool_policy.toml" name;
      []

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
  let candidate_names =
    dedupe_tool_names
      (keeper_base_candidate_tool_names () @ explicit_optional_candidate_tool_names meta)
  in
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
  if Keeper_tool_registry.is_core_always_tool name then
    (* Core tools bypass candidate_set — only deny_set blocks them *)
    not (Hashtbl.mem lookup.deny_set name)
  else if not (Hashtbl.mem lookup.candidate_set name) then
    false
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

(** Preset-scoped universe: preset allowlist + core_always - denied.
    Strict subset of [keeper_universe_tool_names].  Used for BM25 indexing
    to improve signal-to-noise ratio: a Minimal keeper indexes ~30 tools
    instead of 244+.  Execution gate still uses the full universe so
    externally-granted tools (tool_overlay) remain callable.
    See #4637 (Samchon harness: absence > prohibition). *)
let keeper_preset_universe_tool_names (meta : keeper_meta) : string list =
  let lookup = tool_access_lookup_of_meta meta in
  let preset_tools =
    match meta.tool_access with
    | Preset { preset; also_allow } ->
        preset_allowlist preset @ also_allow
    | Custom allowlist -> allowlist
  in
  let from_preset =
    preset_tools
    |> List.filter (fun name ->
         Hashtbl.mem lookup.candidate_set name
         && not (Hashtbl.mem lookup.deny_set name))
  in
  let from_core =
    Keeper_tool_registry.core_always_tools
    |> List.filter (fun name -> not (Hashtbl.mem lookup.deny_set name))
  in
  dedupe_tool_names (from_preset @ from_core)

(** Preset-scoped model tool schemas for BM25 indexing.
    Returns schemas only for the preset-scoped universe. *)
let keeper_preset_universe_model_tools (meta : keeper_meta) : Types.tool_schema list =
  let scoped = keeper_preset_universe_tool_names meta in
  let all_schemas =
    (keeper_default_model_tools meta)
    @ Tool_shard.autoresearch_keeper_tools
    @ Tool_shard.coding_tools
    @ Tool_code_write.schemas
    @ (keeper_universe_masc_tool_schemas meta)
  in
  all_schemas
  |> List.filter (fun tool -> List.mem tool.Types.name scoped)
  |> dedupe_tool_schemas

let keeper_allowed_model_tools ?(write_done = false) (meta : keeper_meta) :
    Types.tool_schema list =
  let allowed = keeper_allowed_tool_names ~write_done meta in
  if allowed = [] then
    []
  else
    let all_schemas =
      (keeper_default_model_tools meta)
      @ Tool_shard.autoresearch_keeper_tools
      @ Tool_shard.coding_tools
      @ Tool_code_write.schemas
      @ (keeper_masc_tool_schemas meta)
    in
    let result =
      all_schemas
      |> List.filter (fun tool -> List.mem tool.Types.name allowed)
      |> dedupe_tool_schemas
    in
    let count = List.length result in
    if count > 100 then
      Log.Keeper.warn
        "tool policy allows %d schemas (~%dKB). Progressive disclosure \
         limits actual LLM context to ~20-40, but universe build cost scales \
         with policy size. Consider a narrower preset or custom allowlist."
        count (count * 470 / 1024);
    result

(** Universe model tool schemas for make_tools.
    Returns schemas for all universe tools so Agent.run() can call them. *)
let keeper_universe_model_tools (meta : keeper_meta) : Types.tool_schema list =
  let universe = keeper_universe_tool_names meta in
  let all_schemas =
    (keeper_default_model_tools meta)
    @ Tool_shard.autoresearch_keeper_tools
    @ Tool_shard.coding_tools
    @ Tool_code_write.schemas
    @ (keeper_universe_masc_tool_schemas meta)
  in
  all_schemas
  |> List.filter (fun tool -> List.mem tool.Types.name universe)
  |> dedupe_tool_schemas
