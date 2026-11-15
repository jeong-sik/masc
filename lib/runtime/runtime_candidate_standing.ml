module Backpressure = Runtime_candidate_backpressure

type walk_start =
  | Fresh_walk_by of Backpressure.recorder
  | Every_mark_demotes

type policy =
  | Keeper_walk of
      { start : walk_start
      ; rest_sec : retry_after:float option -> float
      }

type demotion = Not_demoted | Failed_without_rest | Told_to_rest

let quota_rests ~now ~quota_scope_of candidate =
  Option.fold ~none:false
    ~some:(fun scope -> Runtime_quota_window.is_exhausted ~scope ~now)
    (quota_scope_of candidate)

let observed ~now ~candidate_backpressure_of candidate =
  Option.bind (candidate_backpressure_of candidate)
    (fun candidate -> Backpressure.candidate_backpressure ~now ~candidate)

let rate_rests ~now ~rest_sec = function
  | None -> false
  | Some (Backpressure.Unknown_scope_rate_limit {noted_at; retry_after}) ->
    Float.compare now (noted_at +. rest_sec ~retry_after) < 0

(* Stable partition by demotion class, declared order kept inside each. *)
let in_demotion_order demotion candidates =
  let placed = List.map (fun candidate -> demotion candidate, candidate) candidates in
  let in_place wanted = List.filter_map (fun (actual, candidate) ->
    match wanted, actual with
    | Not_demoted, Not_demoted | Failed_without_rest, Failed_without_rest
    | Told_to_rest, Told_to_rest -> Some candidate
    | Not_demoted, (Failed_without_rest | Told_to_rest)
    | Failed_without_rest, (Not_demoted | Told_to_rest)
    | Told_to_rest, (Not_demoted | Failed_without_rest) -> None) placed in
  in_place Not_demoted @ in_place Failed_without_rest @ in_place Told_to_rest

let order ~now ~policy ~quota_scope_of ~candidate_backpressure_of candidates =
  let (Keeper_walk {start = walk; rest_sec}) = policy in
  let demotion candidate =
    if quota_rests ~now ~quota_scope_of candidate then Told_to_rest
    else match observed ~now ~candidate_backpressure_of candidate with
    | None -> Not_demoted
    | Some {Backpressure.rate_limit; failed_attempt} ->
      if rate_rests ~now ~rest_sec rate_limit then Told_to_rest
      else match failed_attempt with
        | None -> Not_demoted
        | Some (Backpressure.Failed_attempt {recorded_by; _}) ->
          (match walk with
           | Fresh_walk_by walker when Backpressure.same_recorder walker recorded_by -> Not_demoted
           | Fresh_walk_by _ | Every_mark_demotes -> Failed_without_rest)
  in
  in_demotion_order demotion candidates

type 'a exact_order =
  { walk : 'a list
  ; held : ('a * float) list
  }

(* A rate-limited candidate rests on the path rest a Keeper walk uses: its
   usable Retry-After (at least one second), or the configured floor clamped
   to the fallback cap. The three exact walks each passed this same rest. *)
let exact_rate_rest_sec ~retry_after =
  Keeper_runtime_failure_route.path_rest_sec
    ~cap_sec:Env_config_keeper.KeeperKeepalive.rate_limit_backoff_cap_sec
    ~retry_class:Keeper_runtime_failure_route.Rate_limited
    ~retry_after_hint:retry_after

(* The time the provider stated for [candidate] while it is still ahead at
   [now]: its quota scope's stated reset, or the end of its own usable
   Retry-After, whichever is later. A rest MASC chose states no time. *)
let stated_until ~now ~quota_scope_of ~candidate_backpressure_of candidate =
  let scope_reset =
    Option.bind (quota_scope_of candidate) (fun scope ->
      match Runtime_quota_window.rest ~scope ~now with
      | Some (Runtime_quota_window.Reset_stated resets_at) -> Some resets_at
      | Some (Runtime_quota_window.Observed_until _) | None -> None) in
  let retry_after_ends =
    match observed ~now ~candidate_backpressure_of candidate with
    | Some { Backpressure.rate_limit =
               Some (Backpressure.Unknown_scope_rate_limit {noted_at; retry_after})
           ; failed_attempt = _ } ->
      Option.bind (Keeper_runtime_failure_route.usable_retry_after retry_after)
        (fun hint ->
           let ends = noted_at +. hint in
           if Float.compare now ends < 0 then Some ends else None)
    | Some {Backpressure.rate_limit = None; failed_attempt = _} | None -> None in
  match scope_reset, retry_after_ends with
  | Some reset, Some ends -> Some (Float.max reset ends)
  | (Some _ as until), None | None, (Some _ as until) -> until
  | None, None -> None

let order_exact ~now ~quota_scope_of ~candidate_backpressure_of candidates =
  let held, callable = List.partition_map (fun candidate ->
    match stated_until ~now ~quota_scope_of ~candidate_backpressure_of candidate with
    | Some until -> Either.Left (candidate, until)
    | None -> Either.Right candidate) candidates in
  (* Failed-attempt marks belong to Keeper walks; an exact walk does not
     read them. *)
  let demotion candidate =
    if quota_rests ~now ~quota_scope_of candidate then Told_to_rest
    else match observed ~now ~candidate_backpressure_of candidate with
    | None -> Not_demoted
    | Some {Backpressure.rate_limit; failed_attempt = _} ->
      if rate_rests ~now ~rest_sec:exact_rate_rest_sec rate_limit then Told_to_rest
      else Not_demoted
  in
  { walk = in_demotion_order demotion callable; held }

type observation =
  | Answered
  | Rate_limited of { retry_after : float option }
  | Hard_quota of
      { source : Runtime_quota_window.refusal
      ; resets_at : float option
      }
  | Credential_refused of { noted_at : float }

let observe ~candidate ~quota_scope = function
  | Answered ->
    Option.iter (fun candidate -> Backpressure.note_candidate_success ~candidate) candidate;
    Option.iter (fun scope ->
      Runtime_quota_window.note_succeeded ~scope;
      Runtime_credential_refusal.note_answered ~scope) quota_scope
  | Credential_refused {noted_at} ->
    Option.iter (fun scope ->
      Runtime_credential_refusal.note_refused ~scope ~at:noted_at) quota_scope
  | Rate_limited {retry_after} ->
    Option.iter (fun candidate -> Backpressure.note_rate_limit ~candidate ~retry_after) candidate
  | Hard_quota {source; resets_at} ->
    Option.iter (fun scope -> match resets_at with
      | Some resets_at -> Runtime_quota_window.note_exhausted ~scope ~source ~resets_at
      | None -> Runtime_quota_window.note_observed_exhausted ~scope ~source) quota_scope

let observe_http_error ~now ~candidate ~quota_scope error =
  let note = observe ~candidate:(Some candidate) ~quota_scope:(Some quota_scope) in
  let hard_quota source retry_after =
    let resets_at = Option.map (( +. ) now)
      (Keeper_runtime_failure_route.usable_retry_after retry_after) in
    note (Hard_quota {source; resets_at}) in
  match error with
  | Llm_provider.Http_client.HttpError {code; body; retry_after_header} ->
    (match Llm_provider.Retry.classify_refusal ~status:code ~body ~retry_after_header with
     | Llm_provider.Retry.RateLimited {retry_after; _} -> note (Rate_limited {retry_after})
     | Llm_provider.Retry.PaymentRequired _ ->
       hard_quota Runtime_quota_window.Payment_refused (Llm_provider.Retry.resolve_retry_after
         ~body:(Llm_provider.Http_client.refusal_body_text body) ~header:retry_after_header)
     | Llm_provider.Retry.Overloaded _ | Llm_provider.Retry.ServerError _
     | Llm_provider.Retry.AuthError _ | Llm_provider.Retry.AuthorizationError _
     | Llm_provider.Retry.InvalidRequest _ | Llm_provider.Retry.NotFound _
     | Llm_provider.Retry.ContextOverflow _ | Llm_provider.Retry.InputCapacity _
     | Llm_provider.Retry.NetworkError _ | Llm_provider.Retry.Timeout _ -> ())
  | Llm_provider.Http_client.ProviderFailure {kind; _} ->
    (match kind with
     | Llm_provider.Http_client.Hard_quota {retry_after} ->
       hard_quota Runtime_quota_window.Provider_quota_refused retry_after
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
