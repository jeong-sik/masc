open Alcotest

module Metrics = Masc_mcp.Channel_gate_metrics
module U = Yojson.Safe.Util

let unique_channel prefix =
  Printf.sprintf "%s-%d-%.0f" prefix (Unix.getpid ())
    (Unix.gettimeofday () *. 1_000_000.)

let with_eio f =
  Eio_main.run @@ fun _env ->
  Eio_guard.enable ();
  Fun.protect ~finally:Eio_guard.disable f

let find_channel_json channel json =
  json
  |> U.member "channels"
  |> U.to_list
  |> List.find (fun item ->
         String.equal (item |> U.member "channel" |> U.to_string) channel)

let with_env name value_opt f =
  let original = Sys.getenv_opt name in
  let restore () =
    match original with
    | Some value -> Unix.putenv name value
    | None -> Unix.putenv name ""
  in
  Fun.protect
    ~finally:restore
    (fun () ->
      (match value_opt with
      | Some value -> Unix.putenv name value
      | None -> Unix.putenv name "");
      f ())

let test_record_attempt_tracks_connector_diagnostics () =
  with_eio (fun () ->
      let channel = unique_channel "discord-metrics" in
      Metrics.record_attempt ~channel:("  " ^ channel ^ "  ") ~room_id:"room-a" ~keeper:"  luna  "
        ~duration_ms:1200 Metrics.Success;
      Metrics.record_attempt ~channel ~room_id:"room-b" ~keeper:"luna"
        ~duration_ms:0
        (Metrics.Validation_error "content is required");
      Metrics.record_attempt ~channel ~room_id:"room-b" ~keeper:"luna"
        ~duration_ms:0 Metrics.Duplicate;
      let stats =
        Metrics.snapshot ()
        |> List.find (fun (row : Metrics.channel_stats) ->
               String.equal row.channel channel)
      in
      check int "message_count includes duplicates" 3 stats.message_count;
      check int "success_count" 1 stats.success_count;
      check int "error_count excludes duplicates" 1 stats.error_count;
      check int "duplicate_count" 1 stats.duplicate_count;
      check int "validation_error_count" 1 stats.validation_error_count;
      check int "room_count counts unique rooms" 2 stats.room_count;
      check string "last_keeper trimmed" "luna" stats.last_keeper;
      check string "last_error_kind" "validation" stats.last_error_kind;
      check string "last_outcome" "duplicate" stats.last_outcome;
      check string "last_room_id" "room-b" stats.last_room_id)

let test_record_internal_error_exn_tracks_internal_failures () =
  with_eio (fun () ->
      let channel = unique_channel "discord-internal" in
      Metrics.record_internal_error_exn
        ~channel
        ~room_id:"room-z"
        ~keeper:"  sangsu  "
        ~duration_ms:42
        (Failure "boom");
      let stats =
        Metrics.snapshot ()
        |> List.find (fun (row : Metrics.channel_stats) ->
               String.equal row.channel channel)
      in
      check int "message_count" 1 stats.message_count;
      check int "error_count" 1 stats.error_count;
      check int "internal_error_count" 1 stats.internal_error_count;
      check string "last_keeper trimmed" "sangsu" stats.last_keeper;
      check string "last_error_kind" "internal" stats.last_error_kind;
      check string "last_outcome" "internal_error" stats.last_outcome)

let test_snapshot_json_reports_health_and_latency () =
  with_env "MASC_CHANNEL_GATE_SLOW_MS" (Some "250") (fun () ->
      with_eio (fun () ->
          let channel = unique_channel "discord-json" in
          Metrics.record_attempt ~channel ~room_id:"room-1" ~keeper:"sangsu"
            ~duration_ms:280 Metrics.Success;
          Metrics.record_attempt ~channel ~room_id:"room-1" ~keeper:"sangsu"
            ~duration_ms:320
            (Metrics.Keeper_error "upstream timeout");
          let json = Metrics.snapshot_json () in
          let row = find_channel_json channel json in
          check int "avg_duration_ms uses timed attempts" 300
            (row |> U.member "avg_duration_ms" |> U.to_int);
          check int "max_duration_ms" 320
            (row |> U.member "max_duration_ms" |> U.to_int);
          check int "slow_count" 2
            (row |> U.member "slow_count" |> U.to_int);
          check int "slow_rate_pct" 100
            (row |> U.member "slow_rate_pct" |> U.to_int);
          check int "success_rate_pct ignores duplicates" 50
            (row |> U.member "success_rate_pct" |> U.to_int);
          check string "health" "failing"
            (row |> U.member "health" |> U.to_string);
          check string "last_error" "upstream timeout"
            (row |> U.member "last_error" |> U.to_string)))

let () =
  Alcotest.run "Channel_gate_metrics"
    [
      ( "metrics",
        [
          test_case "records connector diagnostics" `Quick
            test_record_attempt_tracks_connector_diagnostics;
          test_case "records internal exception diagnostics" `Quick
            test_record_internal_error_exn_tracks_internal_failures;
          test_case "serializes health and latency" `Quick
            test_snapshot_json_reports_health_and_latency;
        ] );
    ]
