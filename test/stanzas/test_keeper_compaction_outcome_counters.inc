; Compaction outcome counters — which outcome moved the streak.

(test
 (name test_keeper_compaction_outcome_counters)
 (modules test_keeper_compaction_outcome_counters)
 (libraries masc_test_deps masc.keeper_metrics masc.otel_metric_store))
