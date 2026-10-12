(* The workspace briefing body reaches a keeper only when it calls
   keeper_workspace_memory_read; the turn prompt carries the ledger digest,
   counts and briefing status. This records the published body's byte size
   and the classified claim count, so their growth can be read from the
   metric store. Both describe the workspace, not the keeper whose turn
   observed them, so they carry no labels: every keeper turn writes the same
   one series. *)

let record (observation : Workspace_memory_ledger.observation) =
  match observation with
  | Workspace_memory_ledger.Missing | Workspace_memory_ledger.Unavailable _ -> ()
  | Workspace_memory_ledger.Available { claim_count; briefing; _ } ->
    Otel_metric_store.set_gauge
      (Keeper_metrics.to_string Keeper_metrics.WorkspaceMemoryLedgerClaims)
      (Float.of_int claim_count);
    (match briefing with
     | Ok (Workspace_memory_briefing.Current summary)
     | Ok (Workspace_memory_briefing.Stale summary) ->
       Otel_metric_store.set_gauge
         (Keeper_metrics.to_string Keeper_metrics.WorkspaceMemoryBriefingBytes)
         (Float.of_int (String.length summary.text))
     | Ok Workspace_memory_briefing.Missing | Error _ ->
       (* No published body was read, so there is no size to record. The
          gauge keeps the last body that was measured. *)
       ())
