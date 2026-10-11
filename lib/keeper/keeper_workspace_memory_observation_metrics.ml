(* 2026-10-11 audit P2-10: the workspace briefing summary reaches keeper turns
   with no size cap anywhere in its path, and no observation point recorded
   its size, so growth was invisible. This records the observed byte size
   (and the cheap ledger claim count alongside it) as gauges at the keeper
   turn boundary. Observation only: nothing here caps, gates, or truncates. *)

let briefing_status_bytes briefing =
  match briefing with
  | Ok (Workspace_memory_briefing.Current summary) -> "current", String.length summary.text
  | Ok (Workspace_memory_briefing.Stale summary) -> "stale", String.length summary.text
  | Ok Workspace_memory_briefing.Missing -> "pending", 0
  | Error _ -> "unavailable", 0

let record ~keeper_name (observation : Workspace_memory_ledger.observation) =
  match observation with
  | Workspace_memory_ledger.Missing | Workspace_memory_ledger.Unavailable _ -> ()
  | Workspace_memory_ledger.Available { claim_count; briefing; _ } ->
    let status, bytes = briefing_status_bytes briefing in
    Otel_metric_store.set_gauge
      (Keeper_metrics.to_string Keeper_metrics.WorkspaceMemoryBriefingBytes)
      ~labels:[("keeper", keeper_name); ("status", status)]
      (Float.of_int bytes);
    Otel_metric_store.set_gauge
      (Keeper_metrics.to_string Keeper_metrics.WorkspaceMemoryLedgerClaims)
      ~labels:[("keeper", keeper_name)]
      (Float.of_int claim_count)
