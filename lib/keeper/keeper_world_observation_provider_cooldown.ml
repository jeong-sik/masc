(** Keeper_world_observation_provider_cooldown — Provider cooldown detection
    and capacity-blocking task count.

    Extracted from [keeper_world_observation.ml] during godfile decomposition.

    @since God file decomposition *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile

let fallback_cascade_for_provider_cooldown
      ~(base_cascade : string)
      ~(effective_cascade : string)
  : string option
  =
  let normalized_base = String.trim base_cascade in
  let normalized_effective =
    String.trim effective_cascade
  in
  if not (String.equal normalized_effective normalized_base)
  then Some normalized_base
  else if String.equal normalized_effective (Keeper_config.default_cascade_name ())
  then None
  else Some (Keeper_config.default_cascade_name ())

let provider_cooldown_remaining_sec_for_cascade
      ~(cascade_name : string)
  : int option
  =
  let runtime_health_keys =
    Provider_runtime_projection.default_execution_model_strings cascade_name
    |> Cascade_runtime_candidate.runtime_health_keys_of_labels
  in
  match runtime_health_keys with
  | [] -> None
  | _ ->
    let provider_infos =
      List.map
        (fun provider_key ->
           Keeper_binding_health.provider_info
             Keeper_binding_health.global
             ~provider_key)
        runtime_health_keys
    in
    if not (List.for_all Option.is_some provider_infos)
    then None
    else (
      let provider_infos = List.filter_map Fun.id provider_infos in
      if
        not
          (List.for_all
             (fun info -> info.Keeper_binding_health.in_cooldown)
             provider_infos)
      then None
      else (
        let now = Time_compat.now () in
        provider_infos
        |> List.filter_map (fun info -> info.Keeper_binding_health.cooldown_expires_at)
        |> List.map (fun expires_at ->
          int_of_float (Float.max 0.0 (Float.ceil (expires_at -. now))))
        |> function
        | [] -> Some 0
        | first :: rest -> Some (List.fold_left min first rest)))

let provider_capacity_blocked_task_count
      ?(provider_cooldown_remaining_sec = provider_cooldown_remaining_sec_for_cascade)
      ~(meta : keeper_meta)
      ~(claimable_task_count : int)
      ()
  =
  if claimable_task_count <= 0
  then 0
  else (
    let cascade_name = cascade_name_of_meta meta in
    match
      provider_cooldown_remaining_sec
        ~cascade_name:(cascade_name)
    with
    | Some _
      when Option.is_none
             (fallback_cascade_for_provider_cooldown
                ~base_cascade:cascade_name
                ~effective_cascade:cascade_name) ->
      claimable_task_count
    | Some _ | None -> 0)
