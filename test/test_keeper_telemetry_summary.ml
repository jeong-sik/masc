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

let () =
  run
    "keeper_telemetry_summary"
    [ ( "duration_average",
        [ test_case
            "untimed events do not count as zero-duration samples"
            `Quick
            test_avg_duration_uses_timed_events_only
        ] )
    ]
