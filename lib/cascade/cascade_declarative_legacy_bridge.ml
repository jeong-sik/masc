(** RFC-0058 Phase 5 catalog discovery bridge.

    The legacy catalog runtime walks JSON top-level keys for
    [<name>_models] LIST values. After PR #14550 cascade.toml is fully
    declarative ([providers.X], [models.X], [tier.X], [tier-group.X]) and
    the materialised cascade.json no longer emits the legacy
    [<name>_models] shape — so [discover_profiles] returns [] and the
    boot path falls into degraded mode (see [server_runtime_bootstrap]).

    This module is the data-only bridge: given a config path it returns
    [(profile_name, weighted_entries)] pairs derived from the declarative
    cascade — surfacing [tier.<X>] and [tier-group.<X>] under the same
    [weighted_entry] shape the legacy loader produces, so the existing
    [validate_profile_static] pipeline keeps working unchanged.

    Implementation note: depends only on [Cascade_declarative_parser]
    (in the sibling [cascade_decl] sub-library) plus [Provider_adapter]
    for the cascade-prefix lookup.  Resolves tier/tier-group members
    directly against [cascade_binding]/[cascade_alias]/[cascade_model_spec]
    to emit [cascade_prefix:api_name] strings, deliberately avoiding
    [Cascade_declarative_adapter] (which depends on [Cascade_config]
    and would create a cycle with [Cascade_config_loader]). *)

open Cascade_declarative_types

let normalize_id (s : string) : string =
  String.trim s |> String.lowercase_ascii
  |> String.map (fun c -> if c = '-' then '_' else c)

let resolve_provider_prefix (provider_id : string) : string option =
  match Provider_adapter.resolve_adapter_by_cascade_prefix provider_id with
  | Some adapter -> Some adapter.Provider_adapter.cascade_prefix
  | None ->
    let normalized = normalize_id provider_id in
    (match Provider_adapter.resolve_adapter_by_cascade_prefix normalized with
     | Some adapter -> Some adapter.Provider_adapter.cascade_prefix
     | None -> None)

let find_model (cfg : cascade_config) (model_id : string) :
    cascade_model_spec option =
  List.find_opt
    (fun (m : cascade_model_spec) -> String.equal m.id model_id)
    cfg.models

(* Resolve a tier/tier-group member like "codex_cli.codex-spark" or
   "claude_code.haiku.for-tool-rerank" to a [cascade_prefix:api_name]
   model string.  Aliases override the binding shape but share the
   underlying [provider_id]/[model_id], so the model_string itself is
   identical — alias param overrides (max_input, temperature, etc.)
   are runtime-only and do not affect catalog discovery. *)
let member_to_model_string (cfg : cascade_config) (member : string)
    : string option =
  let alias =
    List.find_opt
      (fun (a : cascade_alias) ->
        String.equal (Cascade_declarative_types.alias_key a) member)
      cfg.aliases
  in
  let binding =
    match alias with
    | Some a ->
      List.find_opt
        (fun (b : cascade_binding) ->
          String.equal b.provider_id a.provider_id
          && String.equal b.model_id a.model_id)
        cfg.bindings
    | None ->
      List.find_opt
        (fun (b : cascade_binding) ->
          String.equal (Cascade_declarative_types.binding_key b) member)
        cfg.bindings
  in
  match binding with
  | None -> None
  | Some b ->
    (match resolve_provider_prefix b.provider_id, find_model cfg b.model_id with
     | Some prefix, Some spec ->
       Some (Printf.sprintf "%s:%s" prefix spec.api_name)
     | _ -> None)

let weighted_entry_of_model_string (model : string) : Cascade_weighted_entry.t =
  {
    Cascade_weighted_entry.model;
    weight = 1;
    supports_tool_choice = None;
    secondary = None;
    secondary_supports_tool_choice = None;
  }

let entries_of_tier (cfg : cascade_config) (tier : cascade_tier)
    : (string * Cascade_weighted_entry.t list) =
  let entries =
    List.filter_map (member_to_model_string cfg) tier.members
    |> List.map weighted_entry_of_model_string
  in
  Printf.sprintf "tier.%s" tier.name, entries

let entries_of_tier_group (cfg : cascade_config) (tg : cascade_tier_group)
    : (string * Cascade_weighted_entry.t list) =
  let tier_members =
    List.concat_map
      (fun tier_name ->
        match
          List.find_opt
            (fun (t : cascade_tier) -> String.equal t.name tier_name)
            cfg.tiers
        with
        | Some tier -> tier.members
        | None -> [])
      tg.tiers
  in
  let entries =
    List.filter_map (member_to_model_string cfg) tier_members
    |> List.map weighted_entry_of_model_string
  in
  Printf.sprintf "tier-group.%s" tg.name, entries

let all_declarative_entries ~config_path :
    (string * Cascade_weighted_entry.t list) list option =
  match Cascade_declarative_parser.parse_file config_path with
  | Error _ -> None
  | Ok cfg ->
    let tier_entries = List.map (entries_of_tier cfg) cfg.tiers in
    let group_entries = List.map (entries_of_tier_group cfg) cfg.tier_groups in
    Some (tier_entries @ group_entries)

let weighted_entries_for_profile ~config_path ~name :
    Cascade_weighted_entry.t list option =
  match all_declarative_entries ~config_path with
  | None -> None
  | Some all ->
    (match List.find_opt (fun (n, _) -> String.equal n name) all with
     | Some (_, entries) -> Some entries
     | None -> None)

let declarative_profile_names ~config_path : string list =
  match all_declarative_entries ~config_path with
  | None -> []
  | Some all -> List.map fst all
