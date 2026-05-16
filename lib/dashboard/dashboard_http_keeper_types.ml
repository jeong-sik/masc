(** Dashboard_http_keeper_types — pure helpers extracted from
    Dashboard_http_keeper (2327 LoC godfile).

    See dashboard_http_keeper_types.mli for rationale. *)

let health_ctx_critical = Env_config_keeper.DashboardHealth.ctx_critical
let health_ctx_warn = Env_config_keeper.DashboardHealth.ctx_warn
let health_penalty_critical = Env_config_keeper.DashboardHealth.penalty_critical
let health_penalty_warn = Env_config_keeper.DashboardHealth.penalty_warn
let runtime_warning_ctx_ratio =
  Env_config_keeper.DashboardHealth.runtime_warning_ctx_ratio

let live_keeper_cascade_name (raw : string) =
  Keeper_cascade_profile.resolve_live raw

let compute_health_score
    ~restart_count ~max_restarts ~recent_crash_count
    ~is_dead ~context_ratio =
  if is_dead then 0
  else
    let budget_penalty =
      if max_restarts <= 0 then 0.0
      else
        let ratio = float_of_int restart_count /. float_of_int max_restarts in
        Float.min 1.0 ratio *. 40.0
    in
    let crash_penalty =
      Float.min 30.0 (float_of_int recent_crash_count *. 10.0)
    in
    let context_penalty =
      if context_ratio > health_ctx_critical then health_penalty_critical
      else if context_ratio > health_ctx_warn then health_penalty_warn
      else 0.0
    in
    let raw = 100.0 -. budget_penalty -. crash_penalty -. context_penalty in
    Int.max 0 (Int.min 100 (Float.to_int raw))

let estimate_dead_eta_sec ~restart_count ~max_restarts =
  if max_restarts <= 0 || restart_count >= max_restarts then None
  else
    let total = ref 0.0 in
    for i = restart_count to max_restarts - 1 do
      total := !total +. Keeper_supervisor.backoff_delay i
    done;
    Some !total

let prompt_block_json key =
  let resolved = Prompt_registry.resolve_prompt key in
  `Assoc
    [
      ("key", `String key);
      ("source", `String resolved.source);
      ("text", `String resolved.effective);
    ]

let tokens_per_sec_json ~tokens ~latency_ms =
  if tokens <= 0 || latency_ms <= 0 then `Null
  else `Float ((float_of_int tokens *. 1000.0) /. float_of_int latency_ms)

let last_latency_ms_json latency_ms =
  if latency_ms <= 0 then `Null else `Int latency_ms
