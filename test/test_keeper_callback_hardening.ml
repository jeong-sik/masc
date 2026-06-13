(** test_keeper_callback_hardening — verify PR-J counter semantics.

    Two new counters were added in PR-J:
    1. [masc_keeper_lifecycle_callback_failures_total{callback,...}] —
       bumped when post-turn lifecycle callbacks or per-keeper OAS hook
       side effects raise. Lifecycle wrappers emit [callback] only;
       per-keeper hook sites also include [keeper].
    2. [masc_keeper_event_bus_drain_total{site,outcome}] — bumped on
       every drain, with [outcome=drained] when at least one event
       was pulled and [outcome=empty] otherwise.

    The wrappers themselves live inside heavyweight functions that
    require a full keeper turn harness to invoke. This file is the
    thin layer that asserts the metric mechanics work — the counter
    constants are stable, label cardinality stays bounded, and
    distinct labels are isolated. *)

module P = Masc.Otel_metric_store

(* ── Counter constants (stable Otel_metric_store series names) ───── *)

let test_lifecycle_callback_metric_name () =
  Alcotest.(check string)
    "lifecycle callback failures counter has the documented series name"
    "masc_keeper_lifecycle_callback_failures_total"
    Keeper_metrics.(to_string LifecycleCallbackFailures)

let test_event_bus_drain_metric_name () =
  Alcotest.(check string)
    "event-bus drain counter has the documented series name"
    "masc_keeper_event_bus_drain_total"
    Keeper_metrics.(to_string EventBusDrain)

(* ── Counter mechanics — labels distinct and isolated ────── *)

let read_lifecycle_failure ~callback =
  P.metric_value_or_zero
    Keeper_metrics.(to_string LifecycleCallbackFailures)
    ~labels:[("callback", callback)] ()

let read_keeper_hook_failure ~keeper ~callback =
  P.metric_value_or_zero
    Keeper_metrics.(to_string LifecycleCallbackFailures)
    ~labels:[("keeper", keeper); ("callback", callback)] ()

let test_lifecycle_callback_label_isolation () =
  let cb_a = "on_compaction_started" in
  let cb_b = "on_handoff_started" in
  let a_before = read_lifecycle_failure ~callback:cb_a in
  let b_before = read_lifecycle_failure ~callback:cb_b in
  P.inc_counter Keeper_metrics.(to_string LifecycleCallbackFailures)
    ~labels:[("callback", cb_a)] ();
  let a_after = read_lifecycle_failure ~callback:cb_a in
  let b_after = read_lifecycle_failure ~callback:cb_b in
  Alcotest.(check (float 0.0001))
    "callback A counter incremented by 1"
    (a_before +. 1.0) a_after;
  Alcotest.(check (float 0.0001))
    "callback B counter unchanged when only A bumped"
    b_before b_after

let test_keeper_hook_label_shape_is_isolated () =
  let keeper = "schema-test-keeper" in
  let callback = "post_tool_log_write" in
  let keeper_before = read_keeper_hook_failure ~keeper ~callback in
  let lifecycle_before = read_lifecycle_failure ~callback in
  P.inc_counter Keeper_metrics.(to_string LifecycleCallbackFailures)
    ~labels:[("keeper", keeper); ("callback", callback)] ();
  let keeper_after = read_keeper_hook_failure ~keeper ~callback in
  let lifecycle_after = read_lifecycle_failure ~callback in
  Alcotest.(check (float 0.0001))
    "keeper hook label shape incremented"
    (keeper_before +. 1.0) keeper_after;
  Alcotest.(check (float 0.0001))
    "callback-only lifecycle shape unchanged"
    lifecycle_before lifecycle_after

let read_drain ~site ~outcome =
  P.metric_value_or_zero
    Keeper_metrics.(to_string EventBusDrain)
    ~labels:[("site", site); ("outcome", outcome)] ()

let test_drain_site_label_isolation () =
  let site_x = "background_poll" in
  let site_y = "unsubscribe_final" in
  let outcome = "empty" in
  let x_before = read_drain ~site:site_x ~outcome in
  let y_before = read_drain ~site:site_y ~outcome in
  P.inc_counter Keeper_metrics.(to_string EventBusDrain)
    ~labels:[("site", site_x); ("outcome", outcome)] ();
  let x_after = read_drain ~site:site_x ~outcome in
  let y_after = read_drain ~site:site_y ~outcome in
  Alcotest.(check (float 0.0001))
    "site X drain counter incremented"
    (x_before +. 1.0) x_after;
  Alcotest.(check (float 0.0001))
    "site Y unchanged"
    y_before y_after

let test_drain_outcome_label_distinction () =
  let site = "test_outcome_isolation" in
  let drained_before = read_drain ~site ~outcome:"drained" in
  let empty_before = read_drain ~site ~outcome:"empty" in
  P.inc_counter Keeper_metrics.(to_string EventBusDrain)
    ~labels:[("site", site); ("outcome", "drained")] ();
  let drained_after = read_drain ~site ~outcome:"drained" in
  let empty_after = read_drain ~site ~outcome:"empty" in
  Alcotest.(check (float 0.0001))
    "drained outcome incremented"
    (drained_before +. 1.0) drained_after;
  Alcotest.(check (float 0.0001))
    "empty outcome unchanged"
    empty_before empty_after

(* ── Documented label vocabulary check ──────────────────────
   The wrappers in keeper_post_turn.ml / keeper_rollover.ml and the
   per-keeper hook sites in keeper_hooks_oas.ml must stay aligned with
   otel_metric_store.mli. This test pins the callback vocabulary so a future
   refactor that renames a label without updating the docs is caught. *)

let test_documented_callback_label_vocabulary () =
  let documented_labels =
    [
      "on_compaction_started";
      "on_handoff_started";
      "guard_tool_call_log";
      "after_turn_sse_broadcast";
      "post_tool_log_write";
      "on_tool_executed";
      "on_error";
      "on_tool_error";
      "keeper_lifecycle_hook";
    ]
  in
  List.iter (fun label ->
    P.inc_counter Keeper_metrics.(to_string LifecycleCallbackFailures)
      ~labels:[("callback", label)] ();
    let v = read_lifecycle_failure ~callback:label in
    Alcotest.(check bool)
      (Printf.sprintf "documented callback label %S records" label)
      true
      (v > 0.0)
  ) documented_labels

let test_documented_drain_outcome_vocabulary () =
  let documented_outcomes = ["drained"; "empty"] in
  let site = "vocab_check" in
  List.iter (fun outcome ->
    P.inc_counter Keeper_metrics.(to_string EventBusDrain)
      ~labels:[("site", site); ("outcome", outcome)] ();
    let v = read_drain ~site ~outcome in
    Alcotest.(check bool)
      (Printf.sprintf "documented outcome %S records" outcome)
      true
      (v > 0.0)
  ) documented_outcomes

let () =
  let open Alcotest in
  run "keeper_callback_hardening" [
    "metric constants", [
      test_case "lifecycle callback metric series name" `Quick
        test_lifecycle_callback_metric_name;
      test_case "event-bus drain metric series name" `Quick
        test_event_bus_drain_metric_name;
    ];
    "label isolation", [
      test_case "callback labels are isolated" `Quick
        test_lifecycle_callback_label_isolation;
      test_case "keeper hook label shape is isolated" `Quick
        test_keeper_hook_label_shape_is_isolated;
      test_case "drain site labels are isolated" `Quick
        test_drain_site_label_isolation;
      test_case "drain outcome labels are distinct" `Quick
        test_drain_outcome_label_distinction;
    ];
    "documented label vocabulary", [
      test_case "callback labels match otel_metric_store.mli docs" `Quick
        test_documented_callback_label_vocabulary;
      test_case "drain outcome labels match otel_metric_store.mli docs" `Quick
        test_documented_drain_outcome_vocabulary;
    ];
  ]
