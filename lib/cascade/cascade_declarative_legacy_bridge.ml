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
    and would create a cycle with [Cascade_config_loader]).

    Tier-group strategy limitation: tier-groups with
    [strategy = "priority_tier"] (see config/cascade.toml) flatten into
    a single weighted_entry list here — tier boundaries are lost.  The
    legacy loader represents priority_tier via [<name>_tiers] +
    [<name>_strategy], which is not bridged yet.  Callers that need
    priority_tier semantics for a declarative tier-group must wire
    [Cascade_declarative_adapter] (with cycle-safe access) into
    [Cascade_strategy.resolve] in a follow-up; for now this bridge
    surfaces only the union of candidates, which is correct for
    round_robin / failover but loses ordering for priority_tier. *)

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

(* Resolve members and surface drops as a single bounded warning per
   call site.  Silent drops can mask config typos (unknown binding,
   missing provider/model row); the legacy loader hard-fails on the
   equivalent, so the bridge logs at WARN.  The dropped names are
   inlined in the message — bounded by the tier/tier-group member list
   length, which is in the single digits in practice. *)
let resolve_members ~profile_name (cfg : cascade_config) (members : string list)
    : Cascade_weighted_entry.t list =
  let resolved, dropped =
    List.partition_map
      (fun member ->
        match member_to_model_string cfg member with
        | Some s -> Left s
        | None -> Right member)
      members
  in
  (match dropped with
   | [] -> ()
   | _ ->
     Log.warn ~ctx:"CascadeDeclLegacyBridge"
       "profile=%s dropped %d unresolvable member(s): [%s]"
       profile_name
       (List.length dropped)
       (String.concat "; " dropped));
  List.map
    (fun model ->
      { Cascade_weighted_entry.model
      ; weight = 1
      ; supports_tool_choice = None
      ; secondary = None
      ; secondary_supports_tool_choice = None
      })
    resolved

let entries_of_tier (cfg : cascade_config) (tier : cascade_tier)
    : (string * Cascade_weighted_entry.t list) =
  let profile_name = Printf.sprintf "tier.%s" tier.name in
  profile_name, resolve_members ~profile_name cfg tier.members

let entries_of_tier_group (cfg : cascade_config) (tg : cascade_tier_group)
    : (string * Cascade_weighted_entry.t list) =
  let profile_name = Printf.sprintf "tier-group.%s" tg.name in
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
  profile_name, resolve_members ~profile_name cfg tier_members

(* Parsed-config cache keyed by (config_path, mtime).  Mirrors the
   pattern in [Cascade_config_loader] — declarative bridge is consulted
   on every [load_profile_weighted] / [discover_profiles] call, so
   reparsing the TOML each time would amplify boot + dashboard refresh
   cost.  Cache invalidates automatically when the file mtime moves. *)
let cache_lock = Mutex.create ()
let cache : (string, float * cascade_config) Hashtbl.t = Hashtbl.create 4

let read_mtime (path : string) : float option =
  try Some (Unix.stat path).Unix.st_mtime
  with _ -> None

let parse_cached (config_path : string) : cascade_config option =
  let current_mtime = read_mtime config_path in
  let cached =
    Mutex.protect cache_lock (fun () -> Hashtbl.find_opt cache config_path)
  in
  match current_mtime, cached with
  | Some mt, Some (cmt, cfg) when Float.equal mt cmt -> Some cfg
  | _ ->
    (match Cascade_declarative_parser.parse_file config_path with
     | Error _ -> None
     | Ok cfg ->
       (match current_mtime with
        | Some mt ->
          Mutex.protect cache_lock (fun () ->
            Hashtbl.replace cache config_path (mt, cfg))
        | None -> ());
       Some cfg)

(* Names of declarative tier/tier-group profiles that the runtime
   should expose, in the order [(tiers, tier_groups)] — same shape the
   parser emits. *)
let all_declarative_entries ~config_path :
    (string * Cascade_weighted_entry.t list) list option =
  match parse_cached config_path with
  | None -> None
  | Some cfg ->
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

(* Whether a declarative profile name is reachable from any
   [routes.X] target (vs only [system_targets.X]).  Used by the
   catalog loader to default [keeper_assignable] fail-closed: a
   declarative tier-group only flips to [keeper_assignable=true] when
   it is wired into a keeper-facing route, mirroring the legacy
   [<name>_keeper_assignable] override semantics. *)
let is_keeper_routable ~config_path ~name : bool =
  match parse_cached config_path with
  | None -> false
  | Some cfg ->
    List.exists
      (fun (r : cascade_route) -> String.equal r.target name)
      cfg.routes
