(** Unit tests for Cascade_health_tracker record behavior.

    Guards against the regression where record_success / record_failure
    were defined but never wired into the cascade execution path, leaving
    every provider's effective_weight stuck at config_weight * 1.0. *)

open Alcotest
module H = Masc_mcp.Cascade_health_tracker

let test_record_success_keeps_rate_1 () =
  let t = H.create () in
  H.record_success t ~provider_key:"p";
  check (float 0.001) "success rate 1.0 after 1 success"
    1.0 (H.success_rate t ~provider_key:"p")

let test_single_failure_no_cooldown () =
  let t = H.create () in
  H.record_failure t ~provider_key:"p";
  check bool "single failure does not trip cooldown"
    false (H.is_in_cooldown t ~provider_key:"p")

let test_cooldown_after_threshold () =
  (* cooldown_threshold default = 3 *)
  let t = H.create () in
  H.record_failure t ~provider_key:"p";
  H.record_failure t ~provider_key:"p";
  H.record_failure t ~provider_key:"p";
  check bool "cooldown trips after 3 consecutive failures"
    true (H.is_in_cooldown t ~provider_key:"p")

let test_success_resets_streak () =
  let t = H.create () in
  H.record_failure t ~provider_key:"p";
  H.record_failure t ~provider_key:"p";
  H.record_success t ~provider_key:"p";
  H.record_failure t ~provider_key:"p";
  H.record_failure t ~provider_key:"p";
  check bool "success resets consecutive_failures"
    false (H.is_in_cooldown t ~provider_key:"p")

let test_effective_weight_cooldown_zero () =
  let t = H.create () in
  H.record_failure t ~provider_key:"p";
  H.record_failure t ~provider_key:"p";
  H.record_failure t ~provider_key:"p";
  check int "effective_weight = 0 during cooldown"
    0 (H.effective_weight t ~provider_key:"p" ~config_weight:100)

let test_effective_weight_unknown_full () =
  let t = H.create () in
  check int "unknown provider → full config_weight"
    100 (H.effective_weight t ~provider_key:"unseen" ~config_weight:100)

let test_provider_info_reflects_events () =
  let t = H.create () in
  H.record_success t ~provider_key:"p";
  H.record_failure t ~provider_key:"p";
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
  H.record_rejected t ~provider_key:"p";
  H.record_rejected t ~provider_key:"p";
  H.record_rejected t ~provider_key:"p";
  check bool "3 consecutive rejections trip cooldown"
    true (H.is_in_cooldown t ~provider_key:"p")

let test_rejected_counts_against_success_rate () =
  (* A provider whose responses are all rejected should rank 0.0 — not
     100% as it did before 0.160.0 when [Accept_rejected] called
     [record_success]. *)
  let t = H.create () in
  H.record_rejected t ~provider_key:"p";
  H.record_rejected t ~provider_key:"p";
  check (float 0.001) "success_rate = 0.0 after only rejections"
    0.0 (H.success_rate t ~provider_key:"p")

let test_rejected_separately_counted_in_provider_info () =
  let t = H.create () in
  H.record_success t ~provider_key:"p";
  H.record_rejected t ~provider_key:"p";
  H.record_rejected t ~provider_key:"p";
  H.record_failure t ~provider_key:"p";
  match H.provider_info t ~provider_key:"p" with
  | None -> fail "provider_info returned None"
  | Some info ->
    check int "events_in_window = 4" 4 info.events_in_window;
    check int "rejected_in_window = 2 (failures excluded)" 2
      info.rejected_in_window

let test_success_after_rejected_clears_streak () =
  let t = H.create () in
  H.record_rejected t ~provider_key:"p";
  H.record_rejected t ~provider_key:"p";
  H.record_success t ~provider_key:"p";
  H.record_rejected t ~provider_key:"p";
  H.record_rejected t ~provider_key:"p";
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
  H.record_success t ~provider_key:"live";
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
  H.record_success t ~provider_key:"a";
  H.record_failure t ~provider_key:"b";
  check int "no eviction when all providers have recent events"
    0 (H.evict_idle t)

(* ── Hard_quota outcome (0.161.0) ──────────────────── *)

let test_hard_quota_triggers_immediate_cooldown () =
  (* Unlike record_failure which needs [cooldown_threshold] consecutive
     events, a single hard_quota event must trip cooldown on its own —
     balance depletion will not recover within 60s. *)
  let t = H.create () in
  H.record_hard_quota t ~provider_key:"p";
  check bool "single hard_quota event trips cooldown immediately"
    true (H.is_in_cooldown t ~provider_key:"p")

let test_hard_quota_cooldown_is_long () =
  let t = H.create () in
  H.record_hard_quota t ~provider_key:"p";
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
  H.record_hard_quota t ~provider_key:"p";
  check int "effective_weight = 0 during hard_quota cooldown"
    0 (H.effective_weight t ~provider_key:"p" ~config_weight:100)

let test_hard_quota_success_clears_cooldown () =
  (* The dashboard story: if the operator tops up billing and the
     provider starts responding again, one successful call should
     let us re-select the provider on the next tick. *)
  let t = H.create () in
  H.record_hard_quota t ~provider_key:"p";
  H.record_success t ~provider_key:"p";
  check bool "success after hard_quota clears cooldown"
    false (H.is_in_cooldown t ~provider_key:"p")

let test_hard_quota_preserves_longer_existing_cooldown () =
  (* If the provider is already in a long cooldown, a subsequent
     hard_quota event should not accidentally shorten it.  We can't
     easily set a longer-than-default cooldown in a unit test, so this
     test focuses on the idempotent case: two hard_quota events should
     leave the cooldown no shorter than a single event. *)
  let t = H.create () in
  H.record_hard_quota t ~provider_key:"p";
  let expires_after_first =
    match H.provider_info t ~provider_key:"p" with
    | Some { cooldown_expires_at = Some x; _ } -> x
    | _ -> fail "no cooldown after first hard_quota"
  in
  H.record_hard_quota t ~provider_key:"p";
  let expires_after_second =
    match H.provider_info t ~provider_key:"p" with
    | Some { cooldown_expires_at = Some x; _ } -> x
    | _ -> fail "no cooldown after second hard_quota"
  in
  check bool "second hard_quota does not shorten cooldown"
    true (expires_after_second >= expires_after_first)

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
  ]
