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

(* Both gauges are workspace values, so each is one unlabeled series. *)
let briefing_bytes () = Store.get_metric_value briefing_name ()
let claims () = Store.get_metric_value claims_name ()
let bytes_of text = Some (Float.of_int (String.length text))

let test_current_records_bytes_and_claims () =
  let text = "the world as the curator synthesized it" in
  Observe_metrics.record (available ~claim_count:3 (Ok (Briefing.Current (summary text))));
  check (option (float 0.0)) "current briefing bytes recorded" (bytes_of text) (briefing_bytes ());
  check (option (float 0.0)) "claim count recorded alongside" (Some 3.0) (claims ())

let test_status_change_keeps_one_series () =
  let current = "synthesis read while sources matched" in
  let stale = "the same body after its sources changed, a little longer" in
  Observe_metrics.record (available ~claim_count:4 (Ok (Briefing.Current (summary current))));
  Observe_metrics.record (available ~claim_count:4 (Ok (Briefing.Stale (summary stale))));
  check (option (float 0.0)) "a stale body replaces the value of the one series"
    (bytes_of stale) (briefing_bytes ());
  check (option (float 0.0)) "no series is kept per briefing status"
    None (Store.get_metric_value briefing_name ~labels:[("status", "current")] ())

let test_unmeasured_briefing_keeps_last_size () =
  let text = "last body that was measured" in
  Observe_metrics.record (available ~claim_count:2 (Ok (Briefing.Current (summary text))));
  Observe_metrics.record (available ~claim_count:7 (Ok Briefing.Missing));
  check (option (float 0.0)) "a missing publication records no size" (bytes_of text) (briefing_bytes ());
  check (option (float 0.0)) "the claim count still follows the ledger" (Some 7.0) (claims ());
  Observe_metrics.record (available ~claim_count:7 (Error "briefing.json: malformed"));
  check (option (float 0.0)) "an unreadable briefing records no size" (bytes_of text) (briefing_bytes ())

let test_missing_ledger_records_nothing () =
  let text = "body before the ledger went away" in
  Observe_metrics.record (available ~claim_count:5 (Ok (Briefing.Current (summary text))));
  Observe_metrics.record Ledger.Missing;
  Observe_metrics.record (Ledger.Unavailable "ledger.json: denied");
  check (option (float 0.0)) "missing ledger leaves the briefing size" (bytes_of text) (briefing_bytes ());
  check (option (float 0.0)) "missing ledger leaves the claim count" (Some 5.0) (claims ())

let () =
  run "keeper_workspace_memory_observation_metrics"
    [ ( "record"
      , [ test_case "current briefing bytes and claim count" `Quick
            test_current_records_bytes_and_claims
        ; test_case "a status change keeps one series" `Quick
            test_status_change_keeps_one_series
        ; test_case "an unmeasured briefing keeps the last size" `Quick
            test_unmeasured_briefing_keeps_last_size
        ; test_case "missing ledger records nothing" `Quick
            test_missing_ledger_records_nothing
        ] )
    ]
