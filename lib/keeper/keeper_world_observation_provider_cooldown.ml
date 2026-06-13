(** Keeper_world_observation_provider_cooldown — Provider cooldown detection
    and capacity-blocking task count.

    Extracted from [keeper_world_observation.ml] during godfile decomposition.

    @since God file decomposition *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile

let fallback_runtime_for_provider_cooldown
      ~(base_runtime : string)
      ~(effective_runtime : string)
  : string option
  =
  let normalized_base = String.trim base_runtime in
  let normalized_effective =
    String.trim effective_runtime
  in
  if not (String.equal normalized_effective normalized_base)
  then Some normalized_base
  else if String.equal normalized_effective (Keeper_config.default_runtime_id ())
  then None
  else Some (Keeper_config.default_runtime_id ())

let scoped_provider_key ~keeper_name provider_key =
  let keeper_name = String.trim keeper_name in
  if String.equal keeper_name "" then provider_key
  else keeper_name ^ "@" ^ provider_key

let provider_cooldown_remaining_sec_for_runtime
      ~(keeper_name : string)
      ~(runtime_id : string)
  : int option
  =
  let runtime_health_keys =
    Provider_runtime_projection.default_execution_model_strings runtime_id
    |> Runtime_provider_binding.runtime_health_keys_of_labels
  in
  match runtime_health_keys with
  | [] -> None
  | _ ->
    let provider_infos =
      List.map
        (fun provider_key ->
           let provider_key = scoped_provider_key ~keeper_name provider_key in
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
      ?(provider_cooldown_remaining_sec = provider_cooldown_remaining_sec_for_runtime)
      ~(meta : keeper_meta)
      ~(claimable_task_count : int)
      ()
  =
  if claimable_task_count <= 0
  then 0
  else (
    let runtime_id = runtime_id_of_meta meta in
    match
      provider_cooldown_remaining_sec
        ~keeper_name:meta.name
        ~runtime_id:(runtime_id)
    with
    | Some _
      when Option.is_none
             (fallback_runtime_for_provider_cooldown
                ~base_runtime:runtime_id
                ~effective_runtime:runtime_id) ->
      claimable_task_count
    | Some _ | None -> 0)
