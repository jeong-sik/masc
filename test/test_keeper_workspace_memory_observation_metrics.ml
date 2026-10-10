open Alcotest

module Ledger = Masc.Workspace_memory_ledger
module Briefing = Masc.Workspace_memory_briefing
module Observe_metrics = Masc.Keeper_workspace_memory_observation_metrics
module Store = Masc.Otel_metric_store

let briefing_name = Keeper_metrics.to_string Keeper_metrics.WorkspaceMemoryBriefingBytes
let claims_name = Keeper_metrics.to_string Keeper_metrics.WorkspaceMemoryLedgerClaims

let summary text = { Briefing.source_ids = ["claim:a"]; text }

let available ~claim_count briefing =
  Ledger.Available
    { ledger_sha256 = String.make 64 'a'
    ; claim_count
    ; conflict_count = 0
    ; classified_count = 0
    ; briefing
    }

let briefing_value keeper status =
  Store.get_metric_value briefing_name ~labels:[("keeper", keeper); ("status", status)] ()
let claims_value keeper =
  Store.get_metric_value claims_name ~labels:[("keeper", keeper)] ()

let test_current_records_bytes_and_claims () =
  let keeper = "obs-current" in
  let text = "the world as the curator synthesized it" in
  Observe_metrics.record ~keeper_name:keeper
    (available ~claim_count:3 (Ok (Briefing.Current (summary text))));
  check (option (float 0.0)) "current briefing bytes recorded"
    (Some (Float.of_int (String.length text)))
    (briefing_value keeper "current");
  check (option (float 0.0)) "claim count recorded alongside"
    (Some 3.0) (claims_value keeper)

let test_stale_records_under_stale_status () =
  let keeper = "obs-stale" in
  let text = "older synthesis, sources changed" in
  Observe_metrics.record ~keeper_name:keeper
    (available ~claim_count:0 (Ok (Briefing.Stale (summary text))));
  check (option (float 0.0)) "stale briefing bytes recorded under stale label"
    (Some (Float.of_int (String.length text)))
    (briefing_value keeper "stale");
  check (option (float 0.0)) "no current-status cell for a stale briefing"
    None (briefing_value keeper "current")

let test_pending_and_unavailable_record_zero () =
  let keeper_pending = "obs-pending" in
  Observe_metrics.record ~keeper_name:keeper_pending
    (available ~claim_count:0 (Ok Briefing.Missing));
  check (option (float 0.0)) "missing publication records zero pending bytes"
    (Some 0.0) (briefing_value keeper_pending "pending");
  let keeper_unavailable = "obs-unavailable" in
  Observe_metrics.record ~keeper_name:keeper_unavailable
    (available ~claim_count:0 (Error "briefing.json: malformed"));
  check (option (float 0.0)) "unreadable briefing records zero unavailable bytes"
    (Some 0.0) (briefing_value keeper_unavailable "unavailable")

let test_missing_ledger_records_nothing () =
  let keeper = "obs-missing" in
  Observe_metrics.record ~keeper_name:keeper Ledger.Missing;
  Observe_metrics.record ~keeper_name:keeper (Ledger.Unavailable "ledger.json: denied");
  check (option (float 0.0)) "missing ledger leaves no briefing cell"
    None (briefing_value keeper "current");
  check (option (float 0.0)) "missing ledger leaves no claim cell"
    None (claims_value keeper)

let () =
  run "keeper_workspace_memory_observation_metrics"
    [ ( "record"
      , [ test_case "current briefing bytes and claim count" `Quick
            test_current_records_bytes_and_claims
        ; test_case "stale briefing recorded under stale status" `Quick
            test_stale_records_under_stale_status
        ; test_case "pending and unreadable briefing record zero" `Quick
            test_pending_and_unavailable_record_zero
        ; test_case "missing ledger records nothing" `Quick
            test_missing_ledger_records_nothing
        ] )
    ]
