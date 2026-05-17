(** Declarative catalog -> runtime snapshot conversion (RFC-0058 Phase 3).

    Converts an {!adapted_catalog} into a lightweight declarative snapshot
    consumed by {!Cascade_catalog_runtime}.

    This module deliberately does NOT depend on {!Cascade_catalog_runtime}
    to avoid a dependency cycle.  It defines its own mirror types and
    {!Cascade_catalog_runtime} bridges them at the call site.

    @stability Internal *)

open Cascade_declarative_adapter
module Loader = Cascade_config_loader

(* --- Lightweight mirror types (no Cascade_catalog_runtime dependency) --- *)

type candidate = {
  model_string : string;
  provider_cfg : Llm_provider.Provider_config.t;
}

type profile = {
  name : string;
  weighted_entries : Loader.weighted_entry list;
  inference_params : Loader.inference_params;
  strategy : Cascade_strategy.t;
  ollama_max_concurrent : int option;
  cli_max_concurrent : int option;
  candidates : candidate list;
}

type decl_snapshot = {
  source_path : string;
  mtime : float;
  validated_at : float;
  profiles : profile list;
}

(* --- Low-level helpers --- *)

let provider_config_to_model_string (cfg : Llm_provider.Provider_config.t) :
    string =
  Printf.sprintf "%s:%s"
    (Llm_provider.Provider_kind.to_string cfg.Llm_provider.Provider_config.kind)
    cfg.Llm_provider.Provider_config.model_id

(* --- Synthetic weighted_entry reconstruction --- *)

let make_weighted_entry (cfg : Llm_provider.Provider_config.t) :
    Loader.weighted_entry =
  {
    Loader.model = provider_config_to_model_string cfg;
    weight = 1;
    supports_tool_choice = None;
    secondary = None;
    secondary_supports_tool_choice = None;
  }

(* --- Inference params extraction --- *)

let min_positive_max_tokens (configs : Llm_provider.Provider_config.t list) =
  configs
  |> List.filter_map (fun cfg ->
    match cfg.Llm_provider.Provider_config.max_tokens with
    | Some n when n > 0 -> Some n
    | _ -> None)
  |> function
  | [] -> None
  | first :: rest -> Some (List.fold_left min first rest)

let extract_inference_params (configs : Llm_provider.Provider_config.t list) :
    Loader.inference_params =
  match configs with
  | [] ->
    { Loader.temperature = None; max_tokens = None; keep_alive = None;
      num_ctx = None; thinking_enabled = None; thinking_budget = None }
  | first :: _ ->
    { Loader.temperature = first.Llm_provider.Provider_config.temperature;
      max_tokens = min_positive_max_tokens configs;
      keep_alive = None;
      num_ctx = None;
      thinking_enabled = first.Llm_provider.Provider_config.enable_thinking;
      thinking_budget = first.Llm_provider.Provider_config.thinking_budget }

(* --- candidate from Provider_config.t --- *)

let make_candidate (cfg : Llm_provider.Provider_config.t) : candidate =
  { model_string = provider_config_to_model_string cfg;
    provider_cfg = cfg }

(* --- Profile conversion --- *)

let adapted_profile_to_profile (ap : adapted_profile) : profile option =
  match ap.provider_configs with
  | [] -> None
  | configs ->
    let weighted_entries = List.map make_weighted_entry configs in
    let inference_params = extract_inference_params configs in
    let candidates = List.map make_candidate configs in
    Some {
      name = ap.name;
      weighted_entries;
      inference_params;
      strategy = ap.strategy;
      ollama_max_concurrent = ap.ollama_max_concurrent;
      cli_max_concurrent = ap.cli_max_concurrent;
      candidates;
    }

(* --- Catalog conversion --- *)

let adapted_catalog_to_snapshot ~source_path (ac : adapted_catalog) :
    decl_snapshot option =
  let profiles =
    List.filter_map adapted_profile_to_profile ac.profiles
  in
  match profiles with
  | [] -> None
  | _ ->
    let stat =
      try Unix.stat source_path
      with Unix.Unix_error _ ->
        { Unix.st_dev = 0; st_ino = 0; st_kind = S_REG;
          st_perm = 0o644; st_nlink = 1; st_uid = 0; st_gid = 0;
          st_rdev = 0; st_size = 0; st_atime = 0.0; st_mtime = 0.0;
          st_ctime = 0.0 }
    in
    Some {
      source_path;
      mtime = stat.Unix.st_mtime;
      validated_at = Unix.gettimeofday ();
      profiles;
    }

(* --- TOML loading --- *)

type partial_load_result = {
  snapshot : decl_snapshot;
  errors : adapter_error list;
}

let try_load_partial (config_path : string) : partial_load_result option =
  match Cascade_declarative_parser.parse_file config_path with
  | Error _ -> None  (* not a 5-layer TOML *)
  | Ok cfg ->
    let catalog = adapt_config cfg in
    match adapted_catalog_to_snapshot ~source_path:config_path catalog with
    | Some snapshot ->
      Some { snapshot; errors = catalog.errors }
    | None ->
      (* No profile resolvable. Caller falls back to the legacy loader. *)
      None

let try_load_declarative (config_path : string) :
    (decl_snapshot, adapter_error list) result option =
  match try_load_partial config_path with
  | None -> (
    (* Preserve historical behavior: when no profile resolved but the
       parse step itself produced adapter errors, surface them as Error
       so the boot gate can still report the catalog state. *)
    match Cascade_declarative_parser.parse_file config_path with
    | Error _ -> None
    | Ok cfg ->
      let catalog = adapt_config cfg in
      Some (Error catalog.errors))
  | Some { snapshot; errors = [] } -> Some (Ok snapshot)
  | Some { snapshot = _; errors } -> Some (Error errors)

(* --- Route bindings --- *)

let declarative_route_bindings (ac : adapted_catalog) :
    (string * string) list =
  ac.routes

(* --- Snapshot introspection (for parallel validation) --- *)

(* Returns the snapshot's profile names as a sorted, deduplicated set.
   Without [sort_uniq] callers comparing this against another profile
   list (e.g. [validate_path_result]'s parallel validation step) would
   see spurious mismatches whenever the underlying TOML declaration
   order differs from the comparison list's order — which is the
   common case, since the JSON-shape discovery path runs
   [List.sort_uniq String.compare] before building its
   [profile_build]s. *)
let decl_snapshot_profile_names (snap : decl_snapshot) : string list =
  List.map (fun (p : profile) -> p.name) snap.profiles
  |> List.sort_uniq String.compare
