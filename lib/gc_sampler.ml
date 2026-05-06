(** GC stats sampler. Polls [Gc.quick_stat] every [interval] seconds and
    exports runtime heap gauges via {!Prometheus}. See [.mli] for contract. *)

let word_size_bytes = float_of_int (Sys.word_size / 8)

let sample_once () =
  let s = Gc.quick_stat () in
  Prometheus.set_gauge Prometheus.metric_gc_minor_words s.minor_words;
  Prometheus.set_gauge Prometheus.metric_gc_major_words s.major_words;
  Prometheus.set_gauge Prometheus.metric_gc_promoted_words s.promoted_words;
  Prometheus.set_gauge Prometheus.metric_gc_heap_words
    (float_of_int s.heap_words);
  Prometheus.set_gauge Prometheus.metric_gc_live_words
    (float_of_int s.live_words);
  Prometheus.set_gauge Prometheus.metric_memory_usage_bytes
    (float_of_int s.live_words *. word_size_bytes);
  Prometheus.set_gauge Prometheus.metric_gc_compactions
    (float_of_int s.compactions)

let run ~sw ~clock ~interval =
  Eio.Fiber.fork ~sw (fun () ->
    let rec loop () =
      (try sample_once ()
       with
       | Eio.Cancel.Cancelled _ as e -> raise e
       | exn ->
         (* Sampler must never crash the host fiber: a Gc.quick_stat
            failure would be a runtime invariant violation, but we
            still log and continue rather than tear down sw. *)
         Log.Server.warn "Gc_sampler.sample_once failed: %s"
           (Printexc.to_string exn));
      Eio.Time.sleep clock interval;
      loop ()
    in
    loop ())
