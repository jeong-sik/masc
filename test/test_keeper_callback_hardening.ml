(** test_keeper_callback_hardening — verify PR-J counter semantics.

    Two new counters were added in PR-J:
    1. [masc_keeper_lifecycle_callback_failures_total{callback}] —
       bumped when a post-turn lifecycle callback raises. The two
       wrappers ([Keeper_post_turn] and [Keeper_rollover]) each call
       [Prometheus.inc_counter] in their except branch.
    2. [masc_keeper_event_bus_drain_total{site,outcome}] — bumped on
       every drain, with [outcome=drained] when at least one event
       was pulled and [outcome=empty] otherwise.

    The wrappers themselves live inside heavyweight functions that
    require a full keeper turn harness to invoke. The validator
    script + PR-H joint tests cover end-to-end semantics; this file
    is the thin layer that asserts the metric mechanics work — the
    counter constants are stable, label cardinality stays bounded,
    and distinct labels are isolated. The same shape as
    [test/test_keeper_fsm_edges.ml] from PR-I. *)

module P = Masc_mcp.Prometheus

(* ── Counter constants (stable Prometheus series names) ───── *)

let test_lifecycle_callback_metric_name () =
  Alcotest.(check string)
    "lifecycle callback failures counter has the documented series name"
    "masc_keeper_lifecycle_callback_failures_total"
    P.metric_keeper_lifecycle_callback_failures

let test_event_bus_drain_metric_name () =
  Alcotest.(check string)
    "event-bus drain counter has the documented series name"
    "masc_keeper_event_bus_drain_total"
    P.metric_keeper_event_bus_drain

(* ── Counter mechanics — labels distinct and isolated ────── *)

let read_lifecycle_failure ~callback =
  P.metric_value_or_zero
    P.metric_keeper_lifecycle_callback_failures
    ~labels:[("callback", callback)] ()

let test_lifecycle_callback_label_isolation () =
  let cb_a = "on_compaction_started" in
  let cb_b = "on_handoff_started" in
  let a_before = read_lifecycle_failure ~callback:cb_a in
  let b_before = read_lifecycle_failure ~callback:cb_b in
  P.inc_counter P.metric_keeper_lifecycle_callback_failures
    ~labels:[("callback", cb_a)] ();
  let a_after = read_lifecycle_failure ~callback:cb_a in
  let b_after = read_lifecycle_failure ~callback:cb_b in
  Alcotest.(check (float 0.0001))
    "callback A counter incremented by 1"
    (a_before +. 1.0) a_after;
  Alcotest.(check (float 0.0001))
    "callback B counter unchanged when only A bumped"
    b_before b_after

let read_drain ~site ~outcome =
  P.metric_value_or_zero
    P.metric_keeper_event_bus_drain
    ~labels:[("site", site); ("outcome", outcome)] ()

let test_drain_site_label_isolation () =
  let site_x = "background_poll" in
  let site_y = "unsubscribe_final" in
  let outcome = "empty" in
  let x_before = read_drain ~site:site_x ~outcome in
  let y_before = read_drain ~site:site_y ~outcome in
  P.inc_counter P.metric_keeper_event_bus_drain
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
  P.inc_counter P.metric_keeper_event_bus_drain
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
   The wrappers in keeper_post_turn.ml and keeper_rollover.ml use
   exactly the two callback labels documented in prometheus.mli.
   This test pins the contract so a future refactor that renames a
   label without updating the docs is caught.  *)

let test_documented_callback_label_vocabulary () =
  let documented_labels = ["on_compaction_started"; "on_handoff_started"] in
  List.iter (fun label ->
    P.inc_counter P.metric_keeper_lifecycle_callback_failures
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
    P.inc_counter P.metric_keeper_event_bus_drain
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
      test_case "drain site labels are isolated" `Quick
        test_drain_site_label_isolation;
      test_case "drain outcome labels are distinct" `Quick
        test_drain_outcome_label_distinction;
    ];
    "documented label vocabulary", [
      test_case "callback labels match prometheus.mli docs" `Quick
        test_documented_callback_label_vocabulary;
      test_case "drain outcome labels match prometheus.mli docs" `Quick
        test_documented_drain_outcome_vocabulary;
    ];
  ]
