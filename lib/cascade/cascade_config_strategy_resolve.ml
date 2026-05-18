(** Cascade strategy + priority-tier + concurrency resolution.

    Extracted from [cascade_config.ml]. *)

module Parser = Cascade_config_parser
module Resolve = Cascade_config_resolve

(* One-time warning per (cascade name, raw value) pair so misspelled
   strategy fields do not flood the log on every keeper turn. *)
let strategy_warned : (string * string, unit) Hashtbl.t = Hashtbl.create 4

let warn_unknown_strategy ~name ~raw ~msg ~fallback_kind =
  let key = (name, raw) in
  if not (Hashtbl.mem strategy_warned key) then begin
    Hashtbl.add strategy_warned key ();
    Log.Keeper.warn
      "cascade %s: %s; falling back to %s"
      name msg (Cascade_strategy.kind_to_string fallback_kind)
  end

let invalid_priority_tier_warned : (string * string, unit) Hashtbl.t =
  Hashtbl.create 4

let warn_invalid_priority_tier ~name ~msg ~fallback_kind =
  let key = (name, msg) in
  if not (Hashtbl.mem invalid_priority_tier_warned key) then begin
    Hashtbl.add invalid_priority_tier_warned key ();
    Log.Keeper.warn
      "cascade %s: %s; falling back to %s"
      name msg (Cascade_strategy.kind_to_string fallback_kind)
  end

let default_strategy_kind ?config_path ~name () =
  let (_ : string option) = config_path in
  let (_ : string) = name in
  Cascade_strategy.Failover

let parse_kind_or_default ~name ~default_kind = function
  | None -> default_kind
  | Some raw ->
    match Cascade_strategy.parse_config_kind raw with
    | Ok k -> k
    | Error msg ->
      warn_unknown_strategy ~name ~raw ~msg ~fallback_kind:default_kind;
      default_kind

let cycle_policy_from_loader (cfg : Cascade_config_loader.strategy_config) =
  let d = Cascade_strategy.default_cycle_policy in
  let max_cycles = match cfg.max_cycles with
    | Some n when n >= 1 -> n
    | _ -> d.max_cycles
  in
  let backoff_base_ms = match cfg.backoff_base_ms with
    | Some n when n >= 1 -> n
    | _ -> d.backoff_base_ms
  in
  let backoff_cap_ms = match cfg.backoff_cap_ms with
    | Some n when n >= backoff_base_ms -> n
    | Some _ -> backoff_base_ms       (* cap < base: clamp up *)
    | None -> max d.backoff_cap_ms backoff_base_ms
  in
  { Cascade_strategy.max_cycles; backoff_base_ms; backoff_cap_ms }

let model_ids_of_specs (specs : string list) : string list =
  specs
  |> List.concat_map Parser.expand_auto_model_string
  |> List.filter_map (fun spec ->
         match Parser.split_provider_model spec with
         | Some (_, model_id) when model_id <> "" -> Some model_id
         | _ -> None)
  |> List.sort_uniq String.compare

let normalize_priority_tiers ~config_path ~name raw_tiers =
  (* Probe the active TOML before resolving declarative candidates so an
     unreadable cascade.toml surfaces as a load-failure error instead of the
     generic "no configured models" message — the latter mis-leads
     operators into thinking the profile is empty when the file is broken. *)
  match Cascade_config_loader.load_catalog_source config_path with
  | Error msg ->
      Error
        (Printf.sprintf
           "priority_tier validation skipped: cascade config load failed: %s"
           msg)
  | Ok json ->
  let configured_model_ids =
    Resolve.configured_weighted_entries_from_materialized_json json ~name
    |> List.map (fun (entry : Cascade_config_loader.weighted_entry) -> entry.model)
    |> model_ids_of_specs
  in
  if configured_model_ids = [] then
    Error "priority_tier has no configured models to validate against"
  else
    let normalized =
      raw_tiers
      |> List.filter_map (fun tier ->
             let tier_model_ids =
               model_ids_of_specs tier
               |> List.filter (fun model_id ->
                      List.mem model_id configured_model_ids)
             in
             if tier_model_ids = [] then None else Some tier_model_ids)
    in
    if normalized = [] then
      Error
        "priority_tier tiers did not match any configured candidate model ids"
    else
      Ok normalized

let resolve_strategy ?config_path ~name () =
  match config_path with
  | None -> Cascade_strategy.failover
  | Some path ->
    let default_kind = default_strategy_kind ~config_path:path ~name () in
    let cfg = Cascade_config_loader.resolve_strategy_config
                ~config_path:path ~name in
    let parsed_kind =
      parse_kind_or_default ~name ~default_kind cfg.kind
    in
    let cycle = cycle_policy_from_loader cfg in
    let kind, tiers =
      match parsed_kind with
      | Cascade_strategy.Priority_tier ->
          let result =
            match cfg.tiers with
            | Some raw_tiers ->
                normalize_priority_tiers ~config_path:path ~name raw_tiers
            | None ->
                Error
                  "priority_tier requires a non-empty <name>_tiers configuration"
          in
          (match result with
           | Ok tiers -> (parsed_kind, tiers)
           | Error msg ->
               warn_invalid_priority_tier
                 ~name ~msg ~fallback_kind:default_kind;
               (default_kind, []))
      | _ -> (parsed_kind, [])
    in
    ignore cfg.sticky_ttl_ms;
    ignore cfg.latency_baseline_ms;
    ignore cfg.rate_limit_recency_window_s;
    ignore cfg.rate_limit_decay_base;
    ignore cfg.rate_limit_skip_after;
    ignore cfg.server_error_recency_window_s;
    ignore cfg.server_error_decay_base;
    ignore cfg.server_error_skip_after;
    { Cascade_strategy.kind; cycle; tiers }

let resolve_ollama_max_concurrent ?config_path ~name () =
  match config_path with
  | None -> None
  | Some path ->
    let cfg = Cascade_config_loader.resolve_strategy_config
                ~config_path:path ~name in
    cfg.ollama_max_concurrent

let resolve_cli_max_concurrent ?config_path ~name () =
  match config_path with
  | None -> None
  | Some path ->
    let cfg = Cascade_config_loader.resolve_strategy_config
                ~config_path:path ~name in
    cfg.cli_max_concurrent
