(** Gc_sampler smoke tests (PR-0.2.D).

    Verifies that {!Masc.Gc_sampler.sample_once} writes the GC
    gauges, including [masc_memory_usage_bytes], so
    [Otel_metric_store.metric_value_or_zero] returns
    non-zero values for the cumulative word counters after a single
    sample.  We do not exercise the Eio fiber loop here — that path is
    covered transitively by every server boot.  Coverage of [run]
    would require an Eio scheduler harness, which is out of scope for
    this PR. *)

open Alcotest

module Otel_metric_store = Masc.Otel_metric_store
module Gc_sampler = Masc.Gc_sampler

let metrics_to_check =
  [
    Otel_metric_store.metric_gc_minor_words;
    Otel_metric_store.metric_gc_major_words;
    Otel_metric_store.metric_gc_heap_words;
    Otel_metric_store.metric_gc_live_words;
    Otel_metric_store.metric_gc_compactions;
    Otel_metric_store.metric_gc_promoted_words;
    Otel_metric_store.metric_memory_usage_bytes;
  ]

let test_sample_once_writes_all_gauges () =
  Gc_sampler.sample_once ();
  List.iter
    (fun name ->
       match Otel_metric_store.get_metric_value name () with
       | None ->
           failf "expected gauge %s to be registered after sample_once" name
       | Some _ -> ())
    metrics_to_check

let test_minor_words_advances_after_allocation () =
  Gc_sampler.sample_once ();
  let before =
    Otel_metric_store.metric_value_or_zero Otel_metric_store.metric_gc_minor_words ()
  in
  (* Force an allocation that the minor heap cannot optimise away. *)
  let dummy = ref [] in
  for i = 1 to 10_000 do
    dummy := i :: !dummy
  done;
  ignore (List.length !dummy : int);
  Gc_sampler.sample_once ();
  let after =
    Otel_metric_store.metric_value_or_zero Otel_metric_store.metric_gc_minor_words ()
  in
  check bool "minor_words gauge advances after allocation" true (after >= before)

let test_memory_usage_derives_from_live_words () =
  Gc_sampler.sample_once ();
  let live_words =
    Otel_metric_store.metric_value_or_zero Otel_metric_store.metric_gc_live_words ()
  in
  let memory_usage =
    Otel_metric_store.metric_value_or_zero Otel_metric_store.metric_memory_usage_bytes ()
  in
  let expected = live_words *. float_of_int (Sys.word_size / 8) in
  check (float 0.001) "memory usage bytes derives from live words" expected
    memory_usage

let () =
  run "Gc_sampler"
    [
      ( "sample_once",
        [
          test_case "writes all runtime heap gauges" `Quick
            test_sample_once_writes_all_gauges;
          test_case "minor_words gauge advances after allocation" `Quick
            test_minor_words_advances_after_allocation;
          test_case "memory_usage derives from live_words" `Quick
            test_memory_usage_derives_from_live_words;
        ] );
    ]
