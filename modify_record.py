import re

with open('lib/cascade/cascade_health_tracker.ml', 'r') as f:
    ml = f.read()

# Replace the body of match outcome with ...
old_record_body = '''    match outcome with
    | Success ->
      state.consecutive_failures <- 0;
      (* Clear cooldown on success — provider recovered *)
      state.cooldown_until <- 0.0;
      (* Append latency sample when caller provided one.  Non-success
         outcomes don't contribute to the percentile — a 200ms timeout
         and a 200ms successful response are not the same signal. *)
      (match latency_ms with
       | Some ms -> push_latency state ms
       | None -> ())
    | Failure | Rejected ->
      (* Rejected responses indicate unusable output (gate reject, empty
         body, schema miss).  Treat identically to Failure for cooldown
         and consecutive-failure tracking — a provider whose responses
         are consistently rejected is as useless as one that never
         responds.  The outcome tag is preserved in [events] so
         [provider_info] can count Rejected separately for dashboards. *)
      state.consecutive_failures <- state.consecutive_failures + 1;
      bump_failure_fp ();
      if state.consecutive_failures >= cooldown_threshold then begin
        let new_until = now +. cooldown_sec in
        if new_until > state.cooldown_until then begin
          state.cooldown_until <- new_until;
          Prometheus.observe_histogram Prometheus.metric_keeper_provider_block_duration_sec
            ~labels:[("provider", provider_key)] cooldown_sec
        end
      end
    | Soft_rate_limited ->
      (* Transient HTTP 429.  Apply an immediate short cooldown so the
         current cascade cycle skips this provider for the next selection
         tick — without forcing the [cooldown_threshold] count-to-three
         that [Failure] uses.  Honor caller-supplied Retry-After when
         present; clamp positive values to [soft_rate_limit_max_clamp_sec]
         to prevent a misclassified hard quota from silently producing
         a multi-minute blackout.  Negative / zero / absent values fall
         back to [soft_rate_limit_cooldown_sec].  As with the other
         immediate-cooldown paths, never shorten an already-longer
         cooldown (e.g. concurrent hard_quota + soft_rl events). *)
      state.consecutive_failures <- state.consecutive_failures + 1;
      bump_failure_fp ();
      let cooldown_dur =
        match retry_after_s with
        | Some s when s > 0.0 -> Float.min s soft_rate_limit_max_clamp_sec
        | _ -> soft_rate_limit_cooldown_sec
      in
      let new_until = now +. cooldown_dur in
      if new_until > state.cooldown_until then begin
        state.cooldown_until <- new_until;
        Prometheus.observe_histogram Prometheus.metric_keeper_provider_block_duration_sec
          ~labels:[("provider", provider_key)] cooldown_dur
      end
    | Hard_quota ->
      (* Hard-quota errors (balance depleted, quota exceeded, resource
         exhausted) don't recover on short-window retries — set a long
         cooldown immediately regardless of [consecutive_failures].  We
         still increment the counter for dashboard continuity.  Preserve
         an already-longer cooldown (e.g. if two hard-quota events fire
         concurrently and the second arrives first in wall time). *)
      state.consecutive_failures <- state.consecutive_failures + 1;
      bump_failure_fp ();
      let new_until = now +. hard_quota_cooldown_sec in
      if new_until > state.cooldown_until then begin
        state.cooldown_until <- new_until;
        Prometheus.observe_histogram Prometheus.metric_keeper_provider_block_duration_sec
          ~labels:[("provider", provider_key)] hard_quota_cooldown_sec
      end
    | Terminal_failure ->
      (* Terminal structural errors are not quota exhaustion, but they have the
         same retry shape: the next cascade tick will hit the same provider
         state and fail again.  Cool down immediately to keep fallback from
         becoming a hidden tax on every request.  #10441: the
         [apply_trust_failure_locked] step was removed by #10412 (Phase 1
         revert).  Keep [bump_failure_fp] for fingerprint history but discard
         its return value — there's no trust adjustment to feed it into. *)
      state.consecutive_failures <- state.consecutive_failures + 1;
      bump_failure_fp ();
      let new_until = now +. terminal_failure_cooldown_sec in
      if new_until > state.cooldown_until then begin
        state.cooldown_until <- new_until;
        Prometheus.observe_histogram Prometheus.metric_keeper_provider_block_duration_sec
          ~labels:[("provider", provider_key)] terminal_failure_cooldown_sec
      end)'''

new_record_body = '''    match outcome with
    | Success ->
      Circuit_breaker.record_success t.breaker ~agent_id:provider_key;
      (match latency_ms with
       | Some ms -> push_latency state ms
       | None -> ())
    | Failure | Rejected ->
      Circuit_breaker.record_failure t.breaker ~agent_id:provider_key ~reason:(make_fingerprint ?error_kind ?error_reason ());
      bump_failure_fp ()
    | Soft_rate_limited ->
      let cooldown_dur =
        match retry_after_s with
        | Some s when s > 0.0 -> Float.min s soft_rate_limit_max_clamp_sec
        | _ -> soft_rate_limit_cooldown_sec
      in
      Circuit_breaker.force_open t.breaker ~agent_id:provider_key ~reason:"Soft_rate_limited" ~duration_sec:cooldown_dur;
      bump_failure_fp ();
      Prometheus.observe_histogram Prometheus.metric_keeper_provider_block_duration_sec
        ~labels:[("provider", provider_key)] cooldown_dur
    | Hard_quota ->
      Circuit_breaker.force_open t.breaker ~agent_id:provider_key ~reason:"Hard_quota" ~duration_sec:hard_quota_cooldown_sec;
      bump_failure_fp ();
      Prometheus.observe_histogram Prometheus.metric_keeper_provider_block_duration_sec
        ~labels:[("provider", provider_key)] hard_quota_cooldown_sec
    | Terminal_failure ->
      Circuit_breaker.force_open t.breaker ~agent_id:provider_key ~reason:"Terminal_failure" ~duration_sec:terminal_failure_cooldown_sec;
      bump_failure_fp ();
      Prometheus.observe_histogram Prometheus.metric_keeper_provider_block_duration_sec
        ~labels:[("provider", provider_key)] terminal_failure_cooldown_sec)'''

if old_record_body in ml:
    ml = ml.replace(old_record_body, new_record_body)
    with open('lib/cascade/cascade_health_tracker.ml', 'w') as f:
        f.write(ml)
    print("Success: Replaced record function.")
else:
    print("Error: Could not find the old record body to replace.")

