(* test/test_keeper_compaction_outcome_counter.ml

   #9988 Option B follow-up: verify the centralized observability
   helper [record_compaction_outcome] classifies outcomes
   correctly on the [masc_keeper_compaction_outcome_total]
   counter.

   [outcome=ok]   — [before_tokens > after_tokens], real savings
   [outcome=noop] — [before_tokens <= after_tokens], no savings
                    (the FSM's #9988 branch that keeps
                    [context_overflow] set so operators can
                    escalate). *)

module EC = Masc_mcp.Keeper_exec_context
module Prom = Masc_mcp.Prometheus

let counter_for ~keeper ~outcome =
  Prom.metric_value_or_zero
    EC.compaction_outcome_metric
    ~labels:[ ("keeper", keeper); ("outcome", outcome) ]
    ()

let test_metric_name_stable () =
  (* Dashboards and Grafana rules will be written against this name.
     A rename would break them silently. *)
  Alcotest.(check string)
    "compaction outcome metric name matches canonical form"
    "masc_keeper_compaction_outcome_total"
    EC.compaction_outcome_metric

let test_real_savings_marks_ok () =
  let keeper = "test-keeper-9988b-ok" in
  let before_ok = counter_for ~keeper ~outcome:"ok" in
  let before_noop = counter_for ~keeper ~outcome:"noop" in
  EC.record_compaction_outcome ~keeper_name:keeper
    ~before_tokens:200_000 ~after_tokens:80_000;
  Alcotest.(check (float 0.0001))
    "ok outcome counter +1"
    (before_ok +. 1.0) (counter_for ~keeper ~outcome:"ok");
  Alcotest.(check (float 0.0001))
    "noop outcome counter unchanged"
    before_noop (counter_for ~keeper ~outcome:"noop")

let test_noop_before_equals_after_marks_noop () =
  let keeper = "test-keeper-9988b-noop" in
  let before_ok = counter_for ~keeper ~outcome:"ok" in
  let before_noop = counter_for ~keeper ~outcome:"noop" in
  EC.record_compaction_outcome ~keeper_name:keeper
    ~before_tokens:150_000 ~after_tokens:150_000;
  Alcotest.(check (float 0.0001))
    "noop outcome counter +1"
    (before_noop +. 1.0) (counter_for ~keeper ~outcome:"noop");
  Alcotest.(check (float 0.0001))
    "ok outcome counter unchanged"
    before_ok (counter_for ~keeper ~outcome:"ok")

let test_negative_savings_marks_noop () =
  (* [after > before]: reducer added a wrapper or retry grew the
     payload. Also a degenerate outcome — classify as noop so the
     counter does not over-report success. *)
  let keeper = "test-keeper-9988b-neg" in
  let before_noop = counter_for ~keeper ~outcome:"noop" in
  EC.record_compaction_outcome ~keeper_name:keeper
    ~before_tokens:100_000 ~after_tokens:110_000;
  Alcotest.(check (float 0.0001))
    "negative-savings classified as noop"
    (before_noop +. 1.0) (counter_for ~keeper ~outcome:"noop")

let test_per_keeper_isolation () =
  let a = "test-keeper-9988b-a" in
  let b = "test-keeper-9988b-b" in
  let a_before = counter_for ~keeper:a ~outcome:"ok" in
  let b_before = counter_for ~keeper:b ~outcome:"ok" in
  EC.record_compaction_outcome ~keeper_name:a
    ~before_tokens:100_000 ~after_tokens:50_000;
  Alcotest.(check (float 0.0001))
    "A counter +1" (a_before +. 1.0)
    (counter_for ~keeper:a ~outcome:"ok");
  Alcotest.(check (float 0.0001))
    "B counter unchanged" b_before
    (counter_for ~keeper:b ~outcome:"ok")

let () =
  Alcotest.run "keeper_compaction_outcome_counter_9988b"
    [
      ( "metric_name",
        [
          Alcotest.test_case "canonical name stable" `Quick
            test_metric_name_stable;
        ] );
      ( "outcome_classification",
        [
          Alcotest.test_case "real savings marks ok" `Quick
            test_real_savings_marks_ok;
          Alcotest.test_case "before==after marks noop" `Quick
            test_noop_before_equals_after_marks_noop;
          Alcotest.test_case "after>before marks noop" `Quick
            test_negative_savings_marks_noop;
        ] );
      ( "isolation",
        [
          Alcotest.test_case "per-keeper independent" `Quick
            test_per_keeper_isolation;
        ] );
    ]
