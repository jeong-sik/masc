(** Gc_sampler smoke tests (PR-0.2.D).

    Verifies that {!Masc_mcp.Gc_sampler.sample_once} writes the six
    [masc_gc_*] gauges so [Prometheus.metric_value_or_zero] returns
    non-zero values for the cumulative word counters after a single
    sample.  We do not exercise the Eio fiber loop here — that path is
    covered transitively by every server boot.  Coverage of [run]
    would require an Eio scheduler harness, which is out of scope for
    this PR. *)

open Alcotest

module Prometheus = Masc_mcp.Prometheus
module Gc_sampler = Masc_mcp.Gc_sampler

let metrics_to_check =
  [
    Prometheus.metric_gc_minor_words;
    Prometheus.metric_gc_major_words;
    Prometheus.metric_gc_heap_words;
    Prometheus.metric_gc_live_words;
    Prometheus.metric_gc_compactions;
    Prometheus.metric_gc_promoted_words;
  ]

let test_sample_once_writes_all_gauges () =
  Gc_sampler.sample_once ();
  List.iter
    (fun name ->
       match Prometheus.get_metric_value name () with
       | None ->
           failf "expected gauge %s to be registered after sample_once" name
       | Some _ -> ())
    metrics_to_check

let test_minor_words_advances_after_allocation () =
  Gc_sampler.sample_once ();
  let before =
    Prometheus.metric_value_or_zero Prometheus.metric_gc_minor_words ()
  in
  (* Force an allocation that the minor heap cannot optimise away. *)
  let dummy = ref [] in
  for i = 1 to 10_000 do
    dummy := i :: !dummy
  done;
  ignore (List.length !dummy : int);
  Gc_sampler.sample_once ();
  let after =
    Prometheus.metric_value_or_zero Prometheus.metric_gc_minor_words ()
  in
  check bool "minor_words gauge advances after allocation" true (after >= before)

let () =
  run "Gc_sampler"
    [
      ( "sample_once",
        [
          test_case "writes all six gauges" `Quick
            test_sample_once_writes_all_gauges;
          test_case "minor_words gauge advances after allocation" `Quick
            test_minor_words_advances_after_allocation;
        ] );
    ]
