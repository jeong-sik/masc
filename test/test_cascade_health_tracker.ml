(** Unit tests for Cascade_health_tracker record behavior.

    Guards against the regression where record_success / record_failure
    were defined but never wired into the cascade execution path, leaving
    every provider's effective_weight stuck at config_weight * 1.0. *)

open Alcotest
module H = Masc_mcp.Cascade_health_tracker
module P = Masc_mcp.Prometheus

let kind value = H.error_kind_of_string value

let provider_block_metric_labels provider_key = [("provider", provider_key)]

let provider_block_duration_sum provider_key =
  P.metric_value_or_zero P.metric_keeper_provider_block_duration_sec
    ~labels:(provider_block_metric_labels provider_key) ()

let provider_block_duration_count provider_key =
  P.metric_value_or_zero (P.metric_keeper_provider_block_duration_sec ^ "_count")
    ~labels:(provider_block_metric_labels provider_key) ()

let test_record_success_keeps_rate_1 () =
  let t = H.create () in
  H.record_success t ~provider_key:"p" ();
  check (float 0.001) "success rate 1.0 after 1 success"
    1.0 (H.success_rate t ~provider_key:"p")

let test_single_failure_no_cooldown () =
  let t = H.create () in
  H.record_failure t ~provider_key:"p" ();
  check bool "single failure does not trip cooldown"
    false (H.is_in_cooldown t ~provider_key:"p")

let test_cooldown_after_threshold () =
  (* cooldown_threshold default = 3 *)
  let t = H.create () in
  H.record_failure t ~provider_key:"p" ();
  H.record_failure t ~provider_key:"p" ();
  H.record_failure t ~provider_key:"p" ();
  check bool "cooldown trips after 3 consecutive failures"
    true (H.is_in_cooldown t ~provider_key:"p")

let test_success_resets_streak () =
  let t = H.create () in
  H.record_failure t ~provider_key:"p" ();
  H.record_failure t ~provider_key:"p" ();
  H.record_success t ~provider_key:"p" ();
  H.record_failure t ~provider_key:"p" ();
  H.record_failure t ~provider_key:"p" ();
  check bool "success resets consecutive_failures"
    false (H.is_in_cooldown t ~provider_key:"p")

let test_effective_weight_cooldown_zero () =
  let t = H.create () in
  H.record_failure t ~provider_key:"p" ();
  H.record_failure t ~provider_key:"p" ();
  H.record_failure t ~provider_key:"p" ();
  check int "effective_weight = 0 during cooldown"
    0 (H.effective_weight t ~provider_key:"p" ~config_weight:100)

let test_effective_weight_unknown_full () =
  let t = H.create () in
  check int "unknown provider → full config_weight"
    100 (H.effective_weight t ~provider_key:"unseen" ~config_weight:100)

let test_provider_info_reflects_events () =
  let t = H.create () in
  H.record_success t ~provider_key:"p" ();
  H.record_failure t ~provider_key:"p" ();
  match H.provider_info t ~provider_key:"p" with
  | None -> fail "provider_info returned None after record calls"
  | Some info ->
    check int "events_in_window = 2" 2 info.events_in_window;
    check int "consecutive_failures = 1" 1 info.consecutive_failures;
    check int "no rejected events yet" 0 info.rejected_in_window

(* ── Rejected outcome (0.160.0) ────────────────────── *)

let test_rejected_counts_as_failure_for_cooldown () =
  (* Cooldown_threshold defaults to 3.  Rejected must count toward the
     same consecutive-failure streak as hard errors so a provider whose
     outputs are unusable eventually stops being retried. *)
  let t = H.create () in
  H.record_rejected t ~provider_key:"p" ();
  H.record_rejected t ~provider_key:"p" ();
  H.record_rejected t ~provider_key:"p" ();
  check bool "3 consecutive rejections trip cooldown"
    true (H.is_in_cooldown t ~provider_key:"p")

let test_rejected_counts_against_success_rate () =
  (* A provider whose responses are all rejected should rank 0.0 — not
     100% as it did before 0.160.0 when [Accept_rejected] called
     [record_success]. *)
  let t = H.create () in
  H.record_rejected t ~provider_key:"p" ();
  H.record_rejected t ~provider_key:"p" ();
  check (float 0.001) "success_rate = 0.0 after only rejections"
    0.0 (H.success_rate t ~provider_key:"p")

let test_rejected_separately_counted_in_provider_info () =
  let t = H.create () in
  H.record_success t ~provider_key:"p" ();
  H.record_rejected t ~provider_key:"p" ();
  H.record_rejected t ~provider_key:"p" ();
  H.record_failure t ~provider_key:"p" ();
  match H.provider_info t ~provider_key:"p" with
  | None -> fail "provider_info returned None"
  | Some info ->
    check int "events_in_window = 4" 4 info.events_in_window;
    check int "rejected_in_window = 2 (failures excluded)" 2
      info.rejected_in_window

let test_success_after_rejected_clears_streak () =
  let t = H.create () in
  H.record_rejected t ~provider_key:"p" ();
  H.record_rejected t ~provider_key:"p" ();
  H.record_success t ~provider_key:"p" ();
  H.record_rejected t ~provider_key:"p" ();
  H.record_rejected t ~provider_key:"p" ();
  check bool "success resets rejected streak"
    false (H.is_in_cooldown t ~provider_key:"p")

(* ── evict_idle (0.160.0) ──────────────────────────── *)

let test_evict_idle_drops_no_event_providers () =
  (* Unknown providers were never recorded — they do not appear in
     the tracker at all, so evict_idle is a no-op for them.  We model
     an idle provider by recording an event, then simulating time
     passage via direct state manipulation is not exposed, so instead
     we create one active and one that was recorded long ago by
     forcing event cleanup through the internal record path.

     This test exercises the behavioral guarantee:
     all_providers transparently removes entries whose rolling
     window is empty (no events) and whose cooldown is not active. *)
  let t = H.create () in
  H.record_success t ~provider_key:"live" ();
  (* A provider with zero recorded events is simply not in the
     tracker.  But we can exercise the post-cooldown empty-window
     path by recording then relying on window_sec elapse — not
     practical in unit test.  Use the contract instead: evict_idle
     is idempotent on a tracker where every provider has events. *)
  check int "evict_idle returns 0 when everyone has fresh events"
    0 (H.evict_idle t);
  match H.provider_info t ~provider_key:"live" with
  | Some _ -> ()
  | None -> fail "evict_idle dropped a provider with fresh events"

let test_evict_idle_returns_zero_when_all_active () =
  let t = H.create () in
  H.record_success t ~provider_key:"a" ();
  H.record_failure t ~provider_key:"b" ();
  check int "no eviction when all providers have recent events"
    0 (H.evict_idle t)

(* ── Provider block duration histogram (P-DASH-13) ──────────── *)

let test_provider_block_duration_observed_after_failure_threshold () =
  let provider_key = "p-dash-13-failure-threshold" in
  let t = H.create () in
  check (float 0.001) "no histogram count before failures" 0.0
    (provider_block_duration_count provider_key);
  H.record_failure t ~provider_key ();
  H.record_failure t ~provider_key ();
  check (float 0.001) "below threshold does not observe cooldown" 0.0
    (provider_block_duration_count provider_key);
  H.record_failure t ~provider_key ();
  check (float 0.001) "threshold observes exactly once" 1.0
    (provider_block_duration_count provider_key);
  check bool "recorded block duration is positive" true
    (provider_block_duration_sum provider_key > 0.0)

let test_provider_block_duration_observed_for_immediate_cooldowns () =
  let t = H.create () in
  let soft_provider = "p-dash-13-soft-rl" in
  let hard_provider = "p-dash-13-hard-quota" in
  let terminal_provider = "p-dash-13-terminal" in
  H.record_soft_rate_limited t ~provider_key:soft_provider ~retry_after_s:30.0 ();
  check (float 0.001) "soft 429 count" 1.0
    (provider_block_duration_count soft_provider);
  check (float 0.001) "soft 429 observes Retry-After seconds" 30.0
    (provider_block_duration_sum soft_provider);
  H.record_hard_quota t ~provider_key:hard_provider ();
  check (float 0.001) "hard quota count" 1.0
    (provider_block_duration_count hard_provider);
  check bool "hard quota duration is long" true
    (provider_block_duration_sum hard_provider > 300.0);
  H.record_terminal_failure t ~provider_key:terminal_provider ();
  check (float 0.001) "terminal failure count" 1.0
    (provider_block_duration_count terminal_provider);
  check bool "terminal failure duration is long" true
    (provider_block_duration_sum terminal_provider > 300.0)

let test_provider_block_duration_skips_non_extending_cooldown () =
  let provider_key = "p-dash-13-no-shortening" in
  let t = H.create () in
  H.record_hard_quota t ~provider_key ();
  let count_after_hard_quota = provider_block_duration_count provider_key in
  let sum_after_hard_quota = provider_block_duration_sum provider_key in
  H.record_soft_rate_limited t ~provider_key ();
  check (float 0.001) "shorter cooldown does not add observation"
    count_after_hard_quota (provider_block_duration_count provider_key);
  check (float 0.001) "shorter cooldown does not add duration"
    sum_after_hard_quota (provider_block_duration_sum provider_key)

(* ── Hard_quota outcome (0.161.0) ──────────────────── *)

let test_hard_quota_triggers_immediate_cooldown () =
  (* Unlike record_failure which needs [cooldown_threshold] consecutive
     events, a single hard_quota event must trip cooldown on its own —
     balance depletion will not recover within 60s. *)
  let t = H.create () in
  H.record_hard_quota t ~provider_key:"p" ();
  check bool "single hard_quota event trips cooldown immediately"
    true (H.is_in_cooldown t ~provider_key:"p")

let test_hard_quota_cooldown_is_long () =
  let t = H.create () in
  H.record_hard_quota t ~provider_key:"p" ();
  match H.provider_info t ~provider_key:"p" with
  | None -> fail "provider_info returned None after record_hard_quota"
  | Some info ->
    let now = Unix.gettimeofday () in
    (match info.cooldown_expires_at with
     | None -> fail "expected cooldown_expires_at = Some _, got None"
     | Some expires ->
       let remaining = expires -. now in
       (* Should be close to hard_quota_cooldown_sec (default 3600.0),
          significantly longer than cooldown_sec (60.0).  Use 300s as
          the lower bound to be robust to env overrides in CI. *)
       check bool
         (Printf.sprintf "hard_quota cooldown (%.0fs) >> regular cooldown (60s)" remaining)
         true (remaining > 300.0))

let test_hard_quota_effective_weight_zero () =
  let t = H.create () in
  H.record_hard_quota t ~provider_key:"p" ();
  check int "effective_weight = 0 during hard_quota cooldown"
    0 (H.effective_weight t ~provider_key:"p" ~config_weight:100)

let test_hard_quota_success_clears_cooldown () =
  (* The dashboard story: if the operator tops up billing and the
     provider starts responding again, one successful call should
     let us re-select the provider on the next tick. *)
  let t = H.create () in
  H.record_hard_quota t ~provider_key:"p" ();
  H.record_success t ~provider_key:"p" ();
  check bool "success after hard_quota clears cooldown"
    false (H.is_in_cooldown t ~provider_key:"p")

let test_hard_quota_preserves_longer_existing_cooldown () =
  (* If the provider is already in a long cooldown, a subsequent
     hard_quota event should not accidentally shorten it.  We can't
     easily set a longer-than-default cooldown in a unit test, so this
     test focuses on the idempotent case: two hard_quota events should
     leave the cooldown no shorter than a single event. *)
  let t = H.create () in
  H.record_hard_quota t ~provider_key:"p" ();
  let expires_after_first =
    match H.provider_info t ~provider_key:"p" with
    | Some { cooldown_expires_at = Some x; _ } -> x
    | _ -> fail "no cooldown after first hard_quota"
  in
  H.record_hard_quota t ~provider_key:"p" ();
  let expires_after_second =
    match H.provider_info t ~provider_key:"p" with
    | Some { cooldown_expires_at = Some x; _ } -> x
    | _ -> fail "no cooldown after second hard_quota"
  in
  check bool "second hard_quota does not shorten cooldown"
    true (expires_after_second >= expires_after_first)

(* ── Fingerprint counter (Phase 0 trust observability) ──────────── *)

let info_or_fail t ~provider_key =
  match H.provider_info t ~provider_key with
  | Some info -> info
  | None -> failwith "expected provider_info to be present"

let test_fingerprint_same_classification_accumulates () =
  let t = H.create () in
  H.record_failure t ~provider_key:"p"
    ~error_kind:(kind "timeout") ~error_reason:"deadline exceeded" ();
  H.record_failure t ~provider_key:"p"
    ~error_kind:(kind "timeout") ~error_reason:"deadline exceeded" ();
  H.record_failure t ~provider_key:"p"
    ~error_kind:(kind "timeout") ~error_reason:"deadline exceeded" ();
  let info = info_or_fail t ~provider_key:"p" in
  check int "exactly one fingerprint bucket"
    1 (List.length info.top_fingerprints);
  match info.top_fingerprints with
  | [ (_, count) ] ->
    check int "fingerprint count = 3" 3 count
  | _ -> failwith "unreachable"

let test_fingerprint_distinct_reasons_split () =
  let t = H.create () in
  H.record_failure t ~provider_key:"p"
    ~error_kind:(kind "failure") ~error_reason:"reason A" ();
  H.record_failure t ~provider_key:"p"
    ~error_kind:(kind "failure") ~error_reason:"reason B" ();
  let info = info_or_fail t ~provider_key:"p" in
  check int "two distinct fingerprints"
    2 (List.length info.top_fingerprints)

let test_fingerprint_top_3_cap () =
  let t = H.create () in
  for i = 1 to 5 do
    let r = Printf.sprintf "reason %d" i in
    H.record_failure t ~provider_key:"p"
      ~error_kind:(kind "failure") ~error_reason:r ()
  done;
  let info = info_or_fail t ~provider_key:"p" in
  check int "top_fingerprints capped at 3"
    3 (List.length info.top_fingerprints)

let test_fingerprint_unclassified_when_kind_missing () =
  let t = H.create () in
  H.record_failure t ~provider_key:"p" ();
  let info = info_or_fail t ~provider_key:"p" in
  match info.top_fingerprints with
  | [ (fp, _) ] ->
    check string "fingerprint defaults to unclassified"
      "unclassified" fp
  | _ -> failwith "expected 1 fingerprint"

let test_last_failure_at_set_on_failure () =
  let t = H.create () in
  H.record_failure t ~provider_key:"p" ~error_kind:(kind "failure") ();
  let info_after = info_or_fail t ~provider_key:"p" in
  check bool "last_failure_at populated after failure"
    true (info_after.last_failure_at <> None)

let test_last_failure_at_none_for_pure_success () =
  let t = H.create () in
  H.record_success t ~provider_key:"p" ();
  H.record_success t ~provider_key:"p" ();
  let info = info_or_fail t ~provider_key:"p" in
  check bool "last_failure_at stays None after success-only events"
    true (info.last_failure_at = None)

let test_fingerprint_top_sorted_descending () =
  let t = H.create () in
  (* low: 1, medium: 2, high: 3 *)
  H.record_failure t ~provider_key:"p"
    ~error_kind:(kind "failure") ~error_reason:"low" ();
  H.record_failure t ~provider_key:"p"
    ~error_kind:(kind "failure") ~error_reason:"medium" ();
  H.record_failure t ~provider_key:"p"
    ~error_kind:(kind "failure") ~error_reason:"medium" ();
  H.record_failure t ~provider_key:"p"
    ~error_kind:(kind "failure") ~error_reason:"high" ();
  H.record_failure t ~provider_key:"p"
    ~error_kind:(kind "failure") ~error_reason:"high" ();
  H.record_failure t ~provider_key:"p"
    ~error_kind:(kind "failure") ~error_reason:"high" ();
  let info = info_or_fail t ~provider_key:"p" in
  match info.top_fingerprints with
  | (_, c1) :: (_, c2) :: (_, c3) :: _ ->
    check bool "descending" true (c1 >= c2 && c2 >= c3);
    check int "highest count" 3 c1
  | _ -> failwith "expected at least 3 fingerprints"

(* ── Terminal_failure outcome (#10285) ───────────────── *)

let test_terminal_failure_triggers_immediate_cooldown () =
  let t = H.create () in
  H.record_terminal_failure t ~provider_key:"kimi-for-coding" ();
  check bool "single terminal_failure event trips cooldown immediately"
    true (H.is_in_cooldown t ~provider_key:"kimi-for-coding")

let test_terminal_failure_cooldown_is_long () =
  let t = H.create () in
  H.record_terminal_failure t ~provider_key:"kimi-for-coding" ();
  match H.provider_info t ~provider_key:"kimi-for-coding" with
  | None -> fail "provider_info returned None after record_terminal_failure"
  | Some info ->
    let now = Unix.gettimeofday () in
    (match info.cooldown_expires_at with
     | None -> fail "expected cooldown_expires_at = Some _, got None"
     | Some expires ->
       let remaining = expires -. now in
       check bool
         (Printf.sprintf "terminal_failure cooldown (%.0fs) >> regular cooldown (60s)" remaining)
         true (remaining > 300.0))

let test_terminal_failure_effective_weight_zero () =
  let t = H.create () in
  H.record_terminal_failure t ~provider_key:"kimi-for-coding" ();
  check int "effective_weight = 0 during terminal_failure cooldown"
    0 (H.effective_weight t ~provider_key:"kimi-for-coding" ~config_weight:100)

let test_terminal_failure_success_clears_cooldown () =
  let t = H.create () in
  H.record_terminal_failure t ~provider_key:"kimi-for-coding" ();
  H.record_success t ~provider_key:"kimi-for-coding" ();
  check bool "success after terminal_failure clears cooldown"
    false (H.is_in_cooldown t ~provider_key:"kimi-for-coding")

let test_terminal_failure_preserves_longer_existing_cooldown () =
  let t = H.create () in
  H.record_terminal_failure t ~provider_key:"kimi-for-coding" ();
  let expires_after_first =
    match H.provider_info t ~provider_key:"kimi-for-coding" with
    | Some { cooldown_expires_at = Some x; _ } -> x
    | _ -> fail "no cooldown after first terminal_failure"
  in
  H.record_terminal_failure t ~provider_key:"kimi-for-coding" ();
  let expires_after_second =
    match H.provider_info t ~provider_key:"kimi-for-coding" with
    | Some { cooldown_expires_at = Some x; _ } -> x
    | _ -> fail "no cooldown after second terminal_failure"
  in
  check bool "second terminal_failure does not shorten cooldown"
    true (expires_after_second >= expires_after_first)

let test_terminal_failure_records_fingerprint () =
  let t = H.create () in
  H.record_terminal_failure t ~provider_key:"kimi-for-coding"
    ~error_kind:(kind "resumable_cli_session")
    ~error_reason:"kimi exited with code 1: session conflict" ();
  let info = info_or_fail t ~provider_key:"kimi-for-coding" in
  match info.top_fingerprints with
  | [ (fp, count) ] ->
    check bool "terminal failure fingerprint keeps kind"
      true (String.starts_with ~prefix:"resumable_cli_session" fp);
    check int "terminal failure fingerprint count" 1 count
  | _ -> failwith "expected exactly one terminal failure fingerprint"

(* ── Soft_rate_limited outcome (HTTP 429) ───────────────────── *)

let test_soft_rate_limit_triggers_immediate_cooldown () =
  (* The whole point of the new outcome: a single 429 must trip cooldown
     so the cascade's next selection tick falls over to a different
     provider — without waiting for [cooldown_threshold] consecutive
     failures the way [record_failure] does. *)
  let t = H.create () in
  H.record_soft_rate_limited t ~provider_key:"p" ();
  check bool "single 429 trips cooldown immediately"
    true (H.is_in_cooldown t ~provider_key:"p")

let test_soft_rate_limit_default_cooldown_short () =
  (* When no Retry-After is supplied, cooldown defaults to
     [soft_rate_limit_cooldown_sec] (10s by default).  We only assert
     bounds — the constant is env-tunable so an exact compare would be
     brittle in CI.  Lower bound > 0 (cooldown active), upper bound
     well under hard_quota_cooldown_sec to confirm we picked the soft
     bucket, not the hard one. *)
  let t = H.create () in
  H.record_soft_rate_limited t ~provider_key:"p" ();
  match H.provider_info t ~provider_key:"p" with
  | None | Some { cooldown_expires_at = None; _ } ->
    fail "expected cooldown_expires_at = Some _"
  | Some { cooldown_expires_at = Some expires; _ } ->
    let now = Unix.gettimeofday () in
    let remaining = expires -. now in
    check bool
      (Printf.sprintf "soft_rl default cooldown remaining=%.1fs > 0" remaining)
      true (remaining > 0.0);
    check bool
      (Printf.sprintf "soft_rl default cooldown remaining=%.1fs << hard_quota (3600s)" remaining)
      true (remaining < 300.0)

let test_soft_rate_limit_honors_retry_after () =
  (* Retry-After=30 should produce a ~30s cooldown, materially longer
     than the 10s default.  This is the core of the Retry-After plumbing. *)
  let t = H.create () in
  H.record_soft_rate_limited t ~provider_key:"p" ~retry_after_s:30.0 ();
  match H.provider_info t ~provider_key:"p" with
  | None | Some { cooldown_expires_at = None; _ } ->
    fail "expected cooldown_expires_at = Some _"
  | Some { cooldown_expires_at = Some expires; _ } ->
    let now = Unix.gettimeofday () in
    let remaining = expires -. now in
    check bool
      (Printf.sprintf "Retry-After=30 → cooldown ≈ 30s, got %.1fs" remaining)
      true (remaining > 25.0 && remaining < 35.0)

let test_soft_rate_limit_clamps_oversized_retry_after () =
  (* A misclassified hard quota that returns Retry-After=999999 must
     not silently produce a multi-day blackout; the implementation
     clamps to [soft_rate_limit_max_clamp_sec] (default 120s).  Caller
     is responsible for upgrading sustained 429 bursts to record_hard_quota. *)
  let t = H.create () in
  H.record_soft_rate_limited t ~provider_key:"p" ~retry_after_s:999_999.0 ();
  match H.provider_info t ~provider_key:"p" with
  | None | Some { cooldown_expires_at = None; _ } ->
    fail "expected cooldown_expires_at = Some _"
  | Some { cooldown_expires_at = Some expires; _ } ->
    let now = Unix.gettimeofday () in
    let remaining = expires -. now in
    check bool
      (Printf.sprintf "Retry-After clamped to ≤120s, got %.1fs" remaining)
      true (remaining <= 121.0)

let test_soft_rate_limit_negative_retry_after_uses_default () =
  (* Caller plumbing bugs (negative or zero retry_after_s) must fall
     back to the default cooldown rather than skipping cooldown entirely
     — the 429 still happened. *)
  let t = H.create () in
  H.record_soft_rate_limited t ~provider_key:"p" ~retry_after_s:(-5.0) ();
  check bool "negative retry_after still trips cooldown"
    true (H.is_in_cooldown t ~provider_key:"p")

let test_soft_rate_limit_success_clears_cooldown () =
  (* The recovery story: as soon as the provider responds successfully,
     it should be re-eligible.  The transient 429 is per-request, not a
     sticky failure mode like hard_quota. *)
  let t = H.create () in
  H.record_soft_rate_limited t ~provider_key:"p" ();
  H.record_success t ~provider_key:"p" ();
  check bool "success after 429 clears cooldown"
    false (H.is_in_cooldown t ~provider_key:"p")

let test_soft_rate_limit_does_not_shorten_hard_quota () =
  (* If the provider was already in a long hard_quota cooldown, a
     subsequent 429 must not accidentally shorten that to 10s. *)
  let t = H.create () in
  H.record_hard_quota t ~provider_key:"p" ();
  let expires_after_quota =
    match H.provider_info t ~provider_key:"p" with
    | Some { cooldown_expires_at = Some x; _ } -> x
    | _ -> fail "no cooldown after hard_quota"
  in
  H.record_soft_rate_limited t ~provider_key:"p" ();
  let expires_after_soft =
    match H.provider_info t ~provider_key:"p" with
    | Some { cooldown_expires_at = Some x; _ } -> x
    | _ -> fail "cooldown unexpectedly cleared by soft 429"
  in
  check bool "soft 429 must not shorten existing hard_quota cooldown"
    true (expires_after_soft >= expires_after_quota)

let test_soft_rate_limit_records_fingerprint () =
  let t = H.create () in
  H.record_soft_rate_limited t ~provider_key:"claude-cli"
    ~error_kind:(kind "http_429")
    ~error_reason:"rate limit exceeded for tier" ();
  let info = info_or_fail t ~provider_key:"claude-cli" in
  match info.top_fingerprints with
  | [ (fp, count) ] ->
    check bool "soft 429 fingerprint keeps kind"
      true (String.starts_with ~prefix:"http_429" fp);
    check int "soft 429 fingerprint count" 1 count
  | _ -> failwith "expected exactly one soft 429 fingerprint"

(* ── Latency ring buffer / p50 / p95 ───────────────────────── *)

let test_latency_unrecorded_yields_none () =
  let t = H.create () in
  H.record_success t ~provider_key:"p" ();
  let info = info_or_fail t ~provider_key:"p" in
  check (option (float 0.001)) "p50 None when no latency recorded"
    None info.p50_latency_ms;
  check (option (float 0.001)) "p95 None when no latency recorded"
    None info.p95_latency_ms;
  check int "latency_samples 0 when no latency recorded"
    0 info.latency_samples

let test_latency_single_sample_p50_eq_p95 () =
  let t = H.create () in
  H.record_success t ~provider_key:"p" ~latency_ms:42.0 ();
  let info = info_or_fail t ~provider_key:"p" in
  check (option (float 0.001)) "p50 = single sample"
    (Some 42.0) info.p50_latency_ms;
  check (option (float 0.001)) "p95 = single sample"
    (Some 42.0) info.p95_latency_ms;
  check int "latency_samples 1" 1 info.latency_samples

let test_latency_p50_is_median () =
  let t = H.create () in
  List.iter
    (fun ms -> H.record_success t ~provider_key:"p" ~latency_ms:ms ())
    [10.0; 20.0; 30.0; 40.0; 50.0];
  let info = info_or_fail t ~provider_key:"p" in
  (* 5 samples sorted: 10 20 30 40 50; rank 0.50 * 4 = 2.0 → buf.(2) = 30 *)
  check (option (float 0.001)) "p50 of 5 evenly spaced = median"
    (Some 30.0) info.p50_latency_ms;
  check int "latency_samples 5" 5 info.latency_samples

let test_latency_p95_above_p50 () =
  (* Monotonicity property: with non-degenerate samples, p95 >= p50. *)
  let t = H.create () in
  List.iter
    (fun ms -> H.record_success t ~provider_key:"p" ~latency_ms:ms ())
    [50.0; 100.0; 150.0; 200.0; 250.0; 300.0; 1000.0];
  let info = info_or_fail t ~provider_key:"p" in
  let p50 = match info.p50_latency_ms with Some x -> x | None -> 0.0 in
  let p95 = match info.p95_latency_ms with Some x -> x | None -> 0.0 in
  check bool
    (Printf.sprintf "p95=%.1f >= p50=%.1f" p95 p50)
    true (p95 >= p50)

let test_latency_ring_drops_oldest () =
  (* When the ring overflows, the oldest sample must be evicted.  Push
     [latency_ring_size + 5] samples; the populated count saturates at
     the ring size and the smallest 5 (which were pushed first) must be
     gone, so the median shifts. *)
  let t = H.create () in
  let ring = H.latency_ring_size in
  if ring <= 0 then
    skip ()
  else begin
    (* Push small first (would-be oldest), then the bulk of larger
       samples that will dominate the populated ring. *)
    for i = 1 to 5 do
      H.record_success t ~provider_key:"p" ~latency_ms:(float_of_int i) ()
    done;
    for _ = 1 to ring do
      H.record_success t ~provider_key:"p" ~latency_ms:1000.0 ()
    done;
    let info = info_or_fail t ~provider_key:"p" in
    (* The first 5 (1..5 ms) should have been overwritten, leaving only
       1000.0 samples in the ring. *)
    check int
      (Printf.sprintf "ring saturates at latency_ring_size=%d" ring)
      ring info.latency_samples;
    check (option (float 0.001))
      "p50 = 1000 once oldest were evicted"
      (Some 1000.0) info.p50_latency_ms
  end

let test_latency_drops_invalid_samples () =
  let t = H.create () in
  H.record_success t ~provider_key:"p" ~latency_ms:0.0 ();
  H.record_success t ~provider_key:"p" ~latency_ms:(-5.0) ();
  H.record_success t ~provider_key:"p" ~latency_ms:Float.nan ();
  H.record_success t ~provider_key:"p" ~latency_ms:Float.infinity ();
  let info = info_or_fail t ~provider_key:"p" in
  (* All four are invalid; tracker should retain nothing. *)
  check int "invalid latency samples dropped" 0 info.latency_samples;
  check (option (float 0.001)) "p50 None after only invalid samples"
    None info.p50_latency_ms

let test_latency_only_recorded_on_success () =
  (* Failures must not contribute to the percentile.  A 200ms successful
     call and a 200ms timeout are not the same signal. *)
  let t = H.create () in
  H.record_failure t ~provider_key:"p" ();
  H.record_rejected t ~provider_key:"p" ();
  H.record_hard_quota t ~provider_key:"p" ();
  H.record_success t ~provider_key:"p" ~latency_ms:99.0 ();
  let info = info_or_fail t ~provider_key:"p" in
  check int "only 1 latency sample (from the success)"
    1 info.latency_samples;
  check (option (float 0.001)) "p50 = the single success sample"
    (Some 99.0) info.p50_latency_ms

(* ── recent_outcome_count window queries ─────────────────────── *)

let test_recent_outcome_count_unknown_provider_zero () =
  (* Untracked providers carry no events — count must be 0 even with a
     generous window.  Used by [rate_limit_score_for_provider] to
     return the optimistic 1.0 default for never-seen providers. *)
  let t = H.create () in
  let n = H.recent_outcome_count t
            ~provider_key:"never-seen"
            ~outcome:H.Outcome_soft_rate_limited
            ~window_s:60.0
  in
  check int "unknown provider → 0" 0 n

let test_recent_outcome_count_zero_window_returns_zero () =
  (* Non-positive window is a sentinel for "feature off" — the helper
     must short-circuit before touching the storage so a kill-switch
     env (RECENCY_WINDOW_S=0) is genuinely a no-op. *)
  let t = H.create () in
  H.record_soft_rate_limited t ~provider_key:"p" ();
  check int "window=0 → 0"
    0 (H.recent_outcome_count t
         ~provider_key:"p"
         ~outcome:H.Outcome_soft_rate_limited
         ~window_s:0.0)

let test_recent_outcome_count_filters_by_outcome () =
  (* Per-outcome filter: a provider with both Failure and
     Soft_rate_limited events must surface only the requested kind. *)
  let t = H.create () in
  H.record_failure t ~provider_key:"p" ();
  H.record_soft_rate_limited t ~provider_key:"p" ();
  H.record_soft_rate_limited t ~provider_key:"p" ();
  check int "soft_rate_limited count = 2"
    2 (H.recent_outcome_count t
         ~provider_key:"p"
         ~outcome:H.Outcome_soft_rate_limited
         ~window_s:60.0);
  check int "failure count = 1"
    1 (H.recent_outcome_count t
         ~provider_key:"p"
         ~outcome:H.Outcome_failure
         ~window_s:60.0)

let test_recent_outcome_count_success_separate () =
  (* Success path is its own bucket — recording one success and three
     soft 429s must show 1 success and 3 rate-limit hits. *)
  let t = H.create () in
  H.record_success t ~provider_key:"p" ();
  H.record_soft_rate_limited t ~provider_key:"p" ();
  H.record_soft_rate_limited t ~provider_key:"p" ();
  H.record_soft_rate_limited t ~provider_key:"p" ();
  check int "success counts independently"
    1 (H.recent_outcome_count t
         ~provider_key:"p"
         ~outcome:H.Outcome_success
         ~window_s:60.0);
  check int "rate_limit counts independently"
    3 (H.recent_outcome_count t
         ~provider_key:"p"
         ~outcome:H.Outcome_soft_rate_limited
         ~window_s:60.0)

let () =
  run "cascade_health_tracker" [
    "record", [
      test_case "record_success keeps rate at 1.0" `Quick
        test_record_success_keeps_rate_1;
      test_case "single failure does not cooldown" `Quick
        test_single_failure_no_cooldown;
      test_case "cooldown after threshold" `Quick
        test_cooldown_after_threshold;
      test_case "success resets streak" `Quick
        test_success_resets_streak;
      test_case "effective_weight zero in cooldown" `Quick
        test_effective_weight_cooldown_zero;
      test_case "unknown provider full weight" `Quick
        test_effective_weight_unknown_full;
      test_case "provider_info reflects events" `Quick
        test_provider_info_reflects_events;
    ];
    "rejected", [
      test_case "rejected counts toward cooldown" `Quick
        test_rejected_counts_as_failure_for_cooldown;
      test_case "rejected lowers success_rate" `Quick
        test_rejected_counts_against_success_rate;
      test_case "rejected_in_window split from failures" `Quick
        test_rejected_separately_counted_in_provider_info;
      test_case "success clears rejected streak" `Quick
        test_success_after_rejected_clears_streak;
    ];
    "evict_idle", [
      test_case "zero eviction on active tracker" `Quick
        test_evict_idle_drops_no_event_providers;
      test_case "all-active → no eviction" `Quick
        test_evict_idle_returns_zero_when_all_active;
    ];
    "provider_block_duration", [
      test_case "failure threshold observes one block duration" `Quick
        test_provider_block_duration_observed_after_failure_threshold;
      test_case "immediate cooldown outcomes observe block durations" `Quick
        test_provider_block_duration_observed_for_immediate_cooldowns;
      test_case "non-extending cooldown does not double-count" `Quick
        test_provider_block_duration_skips_non_extending_cooldown;
    ];
    "hard_quota", [
      test_case "single event trips immediate cooldown" `Quick
        test_hard_quota_triggers_immediate_cooldown;
      test_case "cooldown duration is long (≫ 60s)" `Quick
        test_hard_quota_cooldown_is_long;
      test_case "effective_weight = 0 during hard_quota cooldown" `Quick
        test_hard_quota_effective_weight_zero;
      test_case "success after hard_quota clears cooldown" `Quick
        test_hard_quota_success_clears_cooldown;
      test_case "second hard_quota does not shorten cooldown" `Quick
        test_hard_quota_preserves_longer_existing_cooldown;
    ];
    "fingerprint", [
      test_case "same classification accumulates" `Quick
        test_fingerprint_same_classification_accumulates;
      test_case "distinct reasons → distinct fingerprints" `Quick
        test_fingerprint_distinct_reasons_split;
      test_case "top_fingerprints capped at 3" `Quick
        test_fingerprint_top_3_cap;
      test_case "missing kind defaults to unclassified" `Quick
        test_fingerprint_unclassified_when_kind_missing;
      test_case "last_failure_at populated on failure" `Quick
        test_last_failure_at_set_on_failure;
      test_case "last_failure_at stays None on success-only" `Quick
        test_last_failure_at_none_for_pure_success;
      test_case "top_fingerprints sorted descending" `Quick
        test_fingerprint_top_sorted_descending;
    ];
    "terminal_failure", [
      test_case "single event trips immediate cooldown" `Quick
        test_terminal_failure_triggers_immediate_cooldown;
      test_case "cooldown duration is long (≫ 60s)" `Quick
        test_terminal_failure_cooldown_is_long;
      test_case "effective_weight = 0 during terminal_failure cooldown" `Quick
        test_terminal_failure_effective_weight_zero;
      test_case "success after terminal_failure clears cooldown" `Quick
        test_terminal_failure_success_clears_cooldown;
      test_case "second terminal_failure does not shorten cooldown" `Quick
        test_terminal_failure_preserves_longer_existing_cooldown;
      test_case "terminal_failure records fingerprint" `Quick
        test_terminal_failure_records_fingerprint;
    ];
    "soft_rate_limit", [
      test_case "single 429 trips immediate cooldown" `Quick
        test_soft_rate_limit_triggers_immediate_cooldown;
      test_case "default cooldown is short (between 0 and hard_quota)" `Quick
        test_soft_rate_limit_default_cooldown_short;
      test_case "Retry-After honored in cooldown duration" `Quick
        test_soft_rate_limit_honors_retry_after;
      test_case "oversized Retry-After clamped" `Quick
        test_soft_rate_limit_clamps_oversized_retry_after;
      test_case "negative Retry-After falls back to default" `Quick
        test_soft_rate_limit_negative_retry_after_uses_default;
      test_case "success clears 429 cooldown" `Quick
        test_soft_rate_limit_success_clears_cooldown;
      test_case "soft 429 must not shorten longer cooldown" `Quick
        test_soft_rate_limit_does_not_shorten_hard_quota;
      test_case "soft 429 records fingerprint" `Quick
        test_soft_rate_limit_records_fingerprint;
    ];
    "latency", [
      test_case "no latency recorded → percentiles None" `Quick
        test_latency_unrecorded_yields_none;
      test_case "single sample → p50 = p95 = sample" `Quick
        test_latency_single_sample_p50_eq_p95;
      test_case "p50 of evenly spaced samples is median" `Quick
        test_latency_p50_is_median;
      test_case "p95 ≥ p50 (monotonicity)" `Quick
        test_latency_p95_above_p50;
      test_case "ring drops oldest on overflow" `Quick
        test_latency_ring_drops_oldest;
      test_case "invalid samples (NaN, ≤0, inf) are dropped" `Quick
        test_latency_drops_invalid_samples;
      test_case "latency only recorded on Success" `Quick
        test_latency_only_recorded_on_success;
    ];
    "recent_outcome_count", [
      test_case "unknown provider returns 0" `Quick
        test_recent_outcome_count_unknown_provider_zero;
      test_case "non-positive window returns 0" `Quick
        test_recent_outcome_count_zero_window_returns_zero;
      test_case "filters by outcome kind" `Quick
        test_recent_outcome_count_filters_by_outcome;
      test_case "success counts independently" `Quick
        test_recent_outcome_count_success_separate;
    ];
  ]
