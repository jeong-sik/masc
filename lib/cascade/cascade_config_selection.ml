(** Cascade selection: weighted-shuffle, health-adjusted ordering, and the
    per-candidate decision trace.

    Extracted from [cascade_config.ml]. *)

module Binding = Cascade_config_provider_binding
module Parser = Cascade_config_parser

(** Weighted shuffle: pick first element by weighted random, then order
    remaining by descending weight.  This gives probabilistic distribution
    of first-attempt provider while maintaining a deterministic fallback
    chain.  Callers preserve backward-compatible fixed ordering by
    skipping shuffle when every weight is 1.

    Algorithm (LiteLLM simple-shuffle inspired):
    1. Compute cumulative weights
    2. Pick random value in [0, total_weight)
    3. Selected item becomes first; rest sorted by weight desc

    @since 0.137.0 *)
(* Shared weighted-shuffle RNG.  Protect draws because [Random.State.int]
   mutates the state and this path can be hit from concurrent server fibers.
   Use [Stdlib.Mutex], not [Eio.Mutex]: selection-trace/dashboard helpers are
   also exercised from non-Eio contexts where [Eio.Mutex] raises
   [Effect.Unhandled(Cancel.Get_context)].  The critical section is a single
   RNG draw, so blocking briefly is acceptable. *)
let weighted_shuffle_rng = Random.State.make_self_init ()
let weighted_shuffle_rng_mu = Stdlib.Mutex.create ()

let weighted_random_int bound =
  Stdlib.Mutex.protect weighted_shuffle_rng_mu (fun () ->
      Random.State.int weighted_shuffle_rng bound)

let weighted_shuffle
    ?(rand_int = weighted_random_int)
    (entries : Cascade_config_loader.weighted_entry list)
    : Cascade_config_loader.weighted_entry list =
  match entries with
  | [] | [_] -> entries
  | first :: rest ->
    let total_weight =
      List.fold_left (fun acc (e : Cascade_config_loader.weighted_entry) ->
          acc + e.weight) 0 entries
    in
    if total_weight <= 0 then entries
    else
      let r = rand_int total_weight in
      let default_selected, default_remaining = (first, rest) in
      (* Find the selected entry via cumulative weight *)
      let rec find_selected cumulative = function
        | [] -> (* fallback: first entry *)
          (default_selected, default_remaining)
        | (e : Cascade_config_loader.weighted_entry) :: rest ->
          let cumulative' = cumulative + e.weight in
          if r < cumulative' then (e, rest)
          else
            let selected, remaining = find_selected cumulative' rest in
            (selected, e :: remaining)
      in
      let selected, remaining = find_selected 0 entries in
      (* Sort remaining by descending weight for fallback priority.
         Use index as tiebreaker to preserve original config order
         among equal-weight entries (stable sort). *)
      let indexed = List.mapi (fun i e -> (i, e)) remaining in
      let sorted_remaining =
        List.sort (fun (i1, (a : Cascade_config_loader.weighted_entry))
                       (i2, (b : Cascade_config_loader.weighted_entry)) ->
            let cmp = compare b.weight a.weight in
            if cmp <> 0 then cmp else compare i1 i2
          ) indexed
        |> List.map snd
      in
      selected :: sorted_remaining

(** Extract the provider-level health key for a "provider:model" string.
    Circuit-breaker state is per provider, not per model id, so
    ["claude_code:auto"] and ["claude_code:sonnet"] share a key while
    ["claude_code:auto"] and ["gemini_cli:auto"] remain independent. *)
let provider_key_of_model_string s =
  match Parser.parse_model_string s with
  | Some cfg -> Binding.provider_health_key_of_config cfg
  | None -> (
      match String.split_on_char ':' s with
      | provider :: _rest when String.trim provider <> "" -> String.trim provider
      | _ -> s)

let order_weighted_entries
    ?(rand_int = weighted_random_int)
    ?rotation_scope
    ?cascade
    (entries : Cascade_config_loader.weighted_entry list) =
  let entries = Parser.maybe_rotate_weighted_entries ?rotation_scope entries in
  let entries = Parser.expand_weighted_auto_entries ?rotation_scope entries in
  let has_weights = List.exists
      (fun (e : Cascade_config_loader.weighted_entry) -> e.weight <> 1)
      entries
  in
  if not has_weights then entries
  else
    let health = Cascade_health_tracker.global in
    let health_adjusted = List.map
        (fun (e : Cascade_config_loader.weighted_entry) ->
           let provider_key = provider_key_of_model_string e.model in
           let ew = Cascade_health_tracker.effective_weight health
               ~provider_key ~config_weight:e.weight in
           { e with weight = ew })
        entries
    in
    (* Filter out zero-weight (cooled-down) providers, but keep at least one *)
    let active = List.filter
        (fun (e : Cascade_config_loader.weighted_entry) -> e.weight > 0)
        health_adjusted
    in
    let effective =
      if active = [] then (
        (* Fail-open: every provider has been cooled by the health
           tracker, but we still serve on the unfiltered list rather
           than failing closed.  Emit a counter so operators can
           alert on this state — see iter 18 commit + iter 12's
           [on_provider_filter_widening] for the structural parallel.
           Counter only ticks when the caller supplied [~cascade];
           internal cascade_config callers without a cascade context
           stay silent until they're audited individually. *)
        Option.iter
          (fun cascade ->
            Cascade_metrics.on_ordering_health_widening ~cascade)
          cascade;
        entries)
      else active
    in
    weighted_shuffle ~rand_int effective

type candidate_info = {
  model_string : string;
  display_model_string : string;
  provider_name : string option;
  display_provider_name : string option;
  runtime_kind : string option;
  expanded_models : string list;
  config_weight : int;
  effective_weight : int;
  success_rate : float;
  in_cooldown : bool;
}

let display_model_string s =
  match Parser.split_provider_model s with
  | Some (provider_name, model_id) ->
      Printf.sprintf "%s:%s" (Binding.display_provider_name provider_name) model_id
  | None -> s

let runtime_kind_of_provider_name provider_name =
  match Binding.runtime_binding_of_label provider_name with
  | Some binding -> Some (Binding.runtime_kind_of_binding binding)
  | None -> None

(** Build a [candidate_info] for a model string given its config weight.
    Reads current health tracker state for [success_rate] / [in_cooldown]
    / [effective_weight], so the trace reflects state at call time. *)
let candidate_info_of_weighted (e : Cascade_config_loader.weighted_entry) =
  let health = Cascade_health_tracker.global in
  let expanded_raw_models = Parser.expand_auto_model_string e.model in
  let provider_keys = List.map provider_key_of_model_string expanded_raw_models in
  let health_rows =
    List.map
      (fun provider_key ->
         let success_rate =
           Cascade_health_tracker.success_rate health ~provider_key
         in
         let in_cooldown =
           Cascade_health_tracker.is_in_cooldown health ~provider_key
         in
         let effective_weight =
           Cascade_health_tracker.effective_weight health
             ~provider_key ~config_weight:e.weight
         in
         (success_rate, in_cooldown, effective_weight))
      provider_keys
  in
  let success_rate =
    let preferred =
      health_rows
      |> List.filter_map (fun (rate, cooled_down, _weight) ->
             if cooled_down then None else Some rate)
    in
    let source =
      match preferred with
      | _ :: _ -> preferred
      | [] -> List.map (fun (rate, _cooled_down, _weight) -> rate) health_rows
    in
    List.fold_left Float.max 0.0 source
  in
  let in_cooldown =
    match health_rows with
    | [] -> false
    | rows -> List.for_all (fun (_rate, cooled_down, _weight) -> cooled_down) rows
  in
  let effective_weight =
    List.fold_left
      (fun acc (_rate, _cooled_down, weight) -> Int.max acc weight)
      0
      health_rows
  in
  let provider_name, display_provider_name, runtime_kind =
    match Parser.split_provider_model e.model with
    | Some (provider_name, _model_id) ->
        let display_name = Binding.display_provider_name provider_name in
        (Some provider_name, Some display_name,
         runtime_kind_of_provider_name provider_name)
    | None -> (None, None, None)
  in
  {
    model_string = e.model;
    display_model_string = display_model_string e.model;
    provider_name;
    display_provider_name;
    runtime_kind;
    expanded_models = List.map display_model_string expanded_raw_models;
    config_weight = e.weight;
    effective_weight;
    success_rate;
    in_cooldown;
  }
