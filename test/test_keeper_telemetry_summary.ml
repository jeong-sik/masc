open Alcotest
open Masc

module Summary = Keeper_telemetry_summary

let test_avg_duration_uses_timed_events_only () =
  Summary.reset ();
  Summary.record_event
    ~keeper_name:"agent-a"
    ~event_kind:"turn"
    ~runtime_id:None
    ~duration_ms:(Some 1000.0)
    ~success:true;
  for _ = 1 to 9 do
    Summary.record_event
      ~keeper_name:"agent-a"
      ~event_kind:"turn"
      ~runtime_id:None
      ~duration_ms:None
      ~success:true
  done;
  let snapshot = Summary.snapshot () in
  match Hashtbl.find_opt snapshot.Summary.per_keeper "agent-a" with
  | None -> fail "missing keeper counters"
  | Some counters ->
    check int "total" 10 counters.Summary.total;
    check (float 0.001) "avg_duration_ms" 1000.0 counters.Summary.avg_duration_ms
;;

let test_record_telemetry_payload_feeds_summary () =
  Summary.reset ();
  Summary.record_telemetry_payload
    (`Assoc
        [ "keeper_name", `String "agent-b"
        ; "event_kind", `String "runtime_execution_built"
        ; "runtime_id", `String "runtime-a"
        ; "duration_ms", `Float 42.5
        ; "success", `Bool true
        ]);
  let snapshot = Summary.snapshot () in
  check int "total events" 1 snapshot.Summary.total_events;
  check int "successful events" 1 snapshot.Summary.successful_events;
  match Hashtbl.find_opt snapshot.Summary.per_keeper "agent-b" with
  | None -> fail "missing keeper counters"
  | Some counters ->
    check int "keeper total" 1 counters.Summary.total;
    check (float 0.001) "avg_duration_ms" 42.5 counters.Summary.avg_duration_ms
;;

let test_record_telemetry_payload_without_keeper_is_ignored () =
  Summary.reset ();
  Summary.record_telemetry_payload
    (`Assoc
        [ "event_kind", `String "runtime_execution_built"
        ; "runtime_id", `String "runtime-a"
        ; "duration_ms", `Float 42.5
        ; "success", `Bool true
        ]);
  let snapshot = Summary.snapshot () in
  check int "total events" 0 snapshot.Summary.total_events;
  check int "per-keeper rows" 0 (Hashtbl.length snapshot.Summary.per_keeper)
;;

let () =
  run
    "keeper_telemetry_summary"
    [ ( "duration_average",
        [ test_case
            "untimed events do not count as zero-duration samples"
            `Quick
            test_avg_duration_uses_timed_events_only
        ; test_case
            "event-bus telemetry payload feeds the summary"
            `Quick
            test_record_telemetry_payload_feeds_summary
        ; test_case
            "event-bus telemetry payload without keeper is ignored"
            `Quick
            test_record_telemetry_payload_without_keeper_is_ignored
        ] )
    ]
