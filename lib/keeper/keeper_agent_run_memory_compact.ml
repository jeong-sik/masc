let compact_if_needed ~config ~(meta : Keeper_types.keeper_meta) ~cascade_name_string ?provider_filter () =
  try
    let memory_summarizer =
      Keeper_memory_llm_summary.make
        ?provider_filter
        ~cascade_name:cascade_name_string
        ~keeper_name:meta.name
        ()
    in
    let compaction =
      Keeper_memory_bank.compact_memory_bank_if_needed
        ?summarizer:memory_summarizer
        config
        meta
    in
    if compaction.performed
    then
      Log.Keeper.info
        "keeper:%s memory_compacted before=%d after=%d dropped=%d"
        meta.name
        compaction.before_notes
        compaction.after_notes
        compaction.dropped_notes
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    Prometheus.inc_counter
      Keeper_metrics.metric_keeper_dispatch_event_failures
      ~labels:[ "keeper", meta.name; "site", "compaction" ]
      ();
    Log.Keeper.warn
      "keeper:%s cascade=%s compaction failed: %s"
      meta.name
      (Keeper_types.cascade_name_of_meta meta)
      (Printexc.to_string exn)
;;
