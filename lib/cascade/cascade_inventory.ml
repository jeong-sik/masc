(* See cascade_inventory.mli for module rationale. *)

let score_provider health ~exclude ~keeper_assignable
    (provider : Llm_provider.Provider_config.t) =
  if not keeper_assignable then 0.0
  else
    let provider_key = provider.model_id in
    if List.mem provider_key exclude then 0.0
    else if Cascade_health_tracker.is_in_cooldown health ~provider_key then 0.0
    else
      let success =
        match Cascade_health_tracker.provider_info health ~provider_key with
        | Some info -> info.success_rate
        | None -> 1.0
      in
      let latency =
        Cascade_strategy.latency_score_for_provider health ~provider_key
      in
      success *. latency

type scored_provider = {
  cascade_name : Keeper_cascade_profile.runtime_name;
  provider : Llm_provider.Provider_config.t;
  score : float;
}

(* Pick the highest-score scored_provider whose score is strictly
   positive.  Iteration is left-to-right and ties keep the earlier
   entry; combined with a stable [candidates] order this gives a
   deterministic selection that the caller can reproduce in tests
   without driving an RNG. *)
let best_runner_among ~health ~exclude candidates =
  ignore health;
  let positive =
    List.filter
      (fun (sp : scored_provider) ->
         sp.score > 0.0
         && not (List.mem sp.provider.Llm_provider.Provider_config.model_id
                   exclude))
      candidates
  in
  match positive with
  | [] -> None
  | first :: rest ->
    let pick =
      List.fold_left
        (fun acc sp -> if sp.score > acc.score then sp else acc)
        first rest
    in
    Some pick
