module Backpressure = Runtime_candidate_backpressure

type walk_start =
  | Fresh_walk_by of Backpressure.recorder
  | Every_mark_demotes

type policy =
  | Keeper_walk of walk_start
  | Rate_rest_only of { rest_sec : retry_after:float option -> float }

type demotion = Not_demoted | Failed_without_rest | Told_to_rest

let order ~now ~policy ~quota_scope_of ~candidate_backpressure_of candidates =
  let demotion candidate =
    let quota_exhausted = Option.fold ~none:false
      ~some:(fun scope -> Runtime_quota_window.is_exhausted ~scope ~now)
      (quota_scope_of candidate) in
    let observed = Option.bind (candidate_backpressure_of candidate)
      (fun candidate -> Backpressure.candidate_backpressure ~now ~candidate) in
    if quota_exhausted then Told_to_rest
    else match observed with
    | None -> Not_demoted
    | Some {Backpressure.rate_limit; failed_attempt} ->
      let rate_rests = match rate_limit with
        | None -> false
        | Some (Backpressure.Unknown_scope_rate_limit {noted_at; retry_after}) ->
          (match policy with
           | Keeper_walk (Fresh_walk_by _ | Every_mark_demotes) -> true
           | Rate_rest_only {rest_sec} ->
             Float.compare now (noted_at +. rest_sec ~retry_after) < 0) in
      if rate_rests then Told_to_rest
      else match policy, failed_attempt with
        | Rate_rest_only _, (Some _ | None)
        | Keeper_walk (Fresh_walk_by _ | Every_mark_demotes), None -> Not_demoted
        | Keeper_walk walk, Some (Backpressure.Failed_attempt {recorded_by; _}) ->
          (match walk with
           | Fresh_walk_by walker when Backpressure.same_recorder walker recorded_by -> Not_demoted
           | Fresh_walk_by _ | Every_mark_demotes -> Failed_without_rest)
  in
  let placed = List.map (fun candidate -> demotion candidate, candidate) candidates in
  let in_place wanted = List.filter_map (fun (actual, candidate) ->
    match wanted, actual with
    | Not_demoted, Not_demoted | Failed_without_rest, Failed_without_rest
    | Told_to_rest, Told_to_rest -> Some candidate
    | Not_demoted, (Failed_without_rest | Told_to_rest)
    | Failed_without_rest, (Not_demoted | Told_to_rest)
    | Told_to_rest, (Not_demoted | Failed_without_rest) -> None) placed in
  in_place Not_demoted @ in_place Failed_without_rest @ in_place Told_to_rest

type observation =
  | Answered
  | Rate_limited of { retry_after : float option }
  | Hard_quota of { resets_at : float option }

let observe ~candidate ~quota_scope = function
  | Answered ->
    Option.iter (fun candidate -> Backpressure.note_candidate_success ~candidate) candidate;
    Option.iter (fun scope -> Runtime_quota_window.note_succeeded ~scope) quota_scope
  | Rate_limited {retry_after} ->
    Option.iter (fun candidate -> Backpressure.note_rate_limit ~candidate ~retry_after) candidate
  | Hard_quota {resets_at} ->
    Option.iter (fun scope -> match resets_at with
      | Some resets_at -> Runtime_quota_window.note_exhausted ~scope ~resets_at
      | None -> Runtime_quota_window.note_observed_exhausted ~scope) quota_scope

let observe_http_error ~now ~candidate ~quota_scope error =
  let note = observe ~candidate:(Some candidate) ~quota_scope:(Some quota_scope) in
  let hard_quota retry_after =
    let resets_at = Option.map (( +. ) now)
      (Keeper_runtime_failure_route.usable_retry_after retry_after) in
    note (Hard_quota {resets_at}) in
  match error with
  | Llm_provider.Http_client.HttpError {code; body; retry_after_header} ->
    (match Llm_provider.Retry.classify_refusal ~status:code ~body ~retry_after_header with
     | Llm_provider.Retry.RateLimited {retry_after; _} -> note (Rate_limited {retry_after})
     | Llm_provider.Retry.PaymentRequired _ ->
       hard_quota (Llm_provider.Retry.resolve_retry_after
         ~body:(Llm_provider.Http_client.refusal_body_text body) ~header:retry_after_header)
     | Llm_provider.Retry.Overloaded _ | Llm_provider.Retry.ServerError _
     | Llm_provider.Retry.AuthError _ | Llm_provider.Retry.AuthorizationError _
     | Llm_provider.Retry.InvalidRequest _ | Llm_provider.Retry.NotFound _
     | Llm_provider.Retry.ContextOverflow _ | Llm_provider.Retry.InputCapacity _
     | Llm_provider.Retry.NetworkError _ | Llm_provider.Retry.Timeout _ -> ())
  | Llm_provider.Http_client.ProviderFailure {kind; _} ->
    (match kind with
     | Llm_provider.Http_client.Hard_quota {retry_after} -> hard_quota retry_after
     | Llm_provider.Http_client.Capacity_exhausted _
     | Llm_provider.Http_client.Capability_mismatch _
     | Llm_provider.Http_client.Cli_policy_invalid _
     | Llm_provider.Http_client.Cli_startup_failed _
     | Llm_provider.Http_client.Provider_parse_error _
     | Llm_provider.Http_client.Provider_wire_error _
     | Llm_provider.Http_client.Provider_reported_error _
     | Llm_provider.Http_client.Provider_interrupted
     | Llm_provider.Http_client.Response_body_too_large _
     | Llm_provider.Http_client.Empty_completion _
     | Llm_provider.Http_client.Context_overflow _
     | Llm_provider.Http_client.Unknown_provider_failure _ -> ())
  | Llm_provider.Http_client.NetworkError _ | Llm_provider.Http_client.TimeoutError _
  | Llm_provider.Http_client.AcceptRejected _ | Llm_provider.Http_client.ProviderTerminal _ -> ()
