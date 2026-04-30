open Alcotest

module Metrics = Channel_gate_metrics
module Gate_routes = Masc_mcp.Server_routes_http_routes_channel_gate
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

let check_error_kind name expected actual =
  check string name expected (Metrics.error_kind_to_string actual)

let test_error_kind_round_trip () =
  let kind = Metrics.error_kind_of_string "validation" in
  check_error_kind "round trip" "validation" kind

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
      check_error_kind "last_error_kind" "validation" stats.last_error_kind;
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
      check string "last_error redacted" "internal error" stats.last_error;
      check_error_kind "last_error_kind" "internal" stats.last_error_kind;
      check string "last_outcome" "internal_error" stats.last_outcome)

let test_record_validation_error_metric_tracks_request_metadata () =
  with_eio (fun () ->
      let channel = unique_channel "discord-route" in
      let body =
        Yojson.Safe.to_string
          (`Assoc
            [
              ("channel", `String channel);
              ("channel_room_id", `String "room-route");
              ("keeper_name", `String "luna");
            ])
      in
      Gate_routes.record_validation_error_metric ~duration_ms:7 body "invalid payload";
      let stats =
        Metrics.snapshot ()
        |> List.find (fun (row : Metrics.channel_stats) ->
               String.equal row.channel channel)
      in
      check int "message_count" 1 stats.message_count;
      check int "validation_error_count" 1 stats.validation_error_count;
      check string "last_room_id" "room-route" stats.last_room_id;
      check string "last_keeper" "luna" stats.last_keeper;
      check string "last_error" "invalid payload" stats.last_error)

let test_record_validation_error_metric_falls_back_for_invalid_json () =
  with_eio (fun () ->
      let before_messages, before_validation =
        match
          Metrics.snapshot ()
          |> List.find_opt (fun (row : Metrics.channel_stats) ->
                 String.equal row.channel "unknown")
        with
        | Some row -> (row.message_count, row.validation_error_count)
        | None -> (0, 0)
      in
      Gate_routes.record_validation_error_metric ~duration_ms:0 "{invalid"
        "invalid json";
      let stats =
        Metrics.snapshot ()
        |> List.find (fun (row : Metrics.channel_stats) ->
               String.equal row.channel "unknown")
      in
      check int "message_count incremented" (before_messages + 1)
        stats.message_count;
      check int "validation count incremented" (before_validation + 1)
        stats.validation_error_count;
      check string "last_error" "invalid json" stats.last_error)

let test_snapshot_json_reports_health_and_latency () =
  with_eio (fun () ->
      let channel = unique_channel "discord-json" in
      Metrics.record_attempt ~channel ~room_id:"room-1" ~keeper:"sangsu"
        ~duration_ms:10_500 Metrics.Success;
      Metrics.record_attempt ~channel ~room_id:"room-1" ~keeper:"sangsu"
        ~duration_ms:11_500
        (Metrics.Keeper_error "upstream timeout");
      let json = Metrics.snapshot_json () in
      let row = find_channel_json channel json in
      check int "avg_duration_ms uses timed attempts" 11_000
        (row |> U.member "avg_duration_ms" |> U.to_int);
      check int "max_duration_ms" 11_500
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
         (row |> U.member "last_error" |> U.to_string))

let test_snapshot_json_includes_room_bindings () =
  with_eio (fun () ->
      let channel = unique_channel "discord-bindings" in
      Metrics.record_attempt ~channel ~room_id:"room-alpha" ~keeper:"luna"
        ~duration_ms:120 Metrics.Success;
      Metrics.record_attempt ~channel ~room_id:"room-beta" ~keeper:"sangsu"
        ~duration_ms:0
        (Metrics.Keeper_error "keeper offline");
      let json = Metrics.snapshot_json () in
      let bindings =
        json |> U.member "bindings" |> U.to_list
        |> List.filter (fun item ->
               String.equal (item |> U.member "channel" |> U.to_string) channel)
      in
      let alpha =
        bindings
        |> List.find (fun item ->
               String.equal (item |> U.member "room_id" |> U.to_string) "room-alpha")
      in
      let beta =
        bindings
        |> List.find (fun item ->
               String.equal (item |> U.member "room_id" |> U.to_string) "room-beta")
      in
      check string "alpha keeper" "luna"
        (alpha |> U.member "keeper" |> U.to_string);
      check string "alpha health" "healthy"
        (alpha |> U.member "health" |> U.to_string);
      check string "beta last error" "keeper offline"
        (beta |> U.member "last_error" |> U.to_string);
      check string "beta health" "failing"
        (beta |> U.member "health" |> U.to_string))

let test_events_json_filters_newest_first () =
  with_eio (fun () ->
      let channel = unique_channel "discord-events" in
      Metrics.record_attempt ~channel ~room_id:"room-a" ~keeper:"luna"
        ~duration_ms:77 Metrics.Success;
      Metrics.record_attempt ~channel ~room_id:"room-a" ~keeper:"luna"
        ~duration_ms:0
        (Metrics.Keeper_error "upstream timeout");
      Metrics.record_attempt ~channel ~room_id:"room-b" ~keeper:"sangsu"
        ~duration_ms:0
        (Metrics.Validation_error "content is required");
      let json = Metrics.events_json ~channel ~keeper:"luna" ~limit:5 () in
      let rows = json |> U.member "events" |> U.to_list in
      check int "filtered count" 2 (List.length rows);
      let newest = List.hd rows in
      let older = List.nth rows 1 in
      check string "newest room" "room-a"
        (newest |> U.member "room_id" |> U.to_string);
      check string "newest outcome" "keeper_error"
        (newest |> U.member "outcome" |> U.to_string);
      check string "older outcome" "success"
        (older |> U.member "outcome" |> U.to_string);
      check bool "latest seq present" true
        ((json |> U.member "latest_seq" |> U.to_int) >=
         (newest |> U.member "seq" |> U.to_int)))

let test_room_tracking_is_bounded () =
  with_eio (fun () ->
      let channel = unique_channel "discord-rooms" in
      for i = 1 to 300 do
        Metrics.record_attempt ~channel
          ~room_id:(Printf.sprintf "room-%03d" i)
          ~keeper:"luna" ~duration_ms:0 Metrics.Success
      done;
      let stats =
        Metrics.snapshot ()
        |> List.find (fun (row : Metrics.channel_stats) ->
               String.equal row.channel channel)
      in
      check int "room_count capped" 256 stats.room_count;
      check string "last_room_id still updates" "room-300" stats.last_room_id)

let () =
  Alcotest.run "Channel_gate_metrics"
    [
      ( "metrics",
        [
          test_case "error kind round trip" `Quick test_error_kind_round_trip;
          test_case "records connector diagnostics" `Quick
            test_record_attempt_tracks_connector_diagnostics;
          test_case "records internal exception diagnostics" `Quick
            test_record_internal_error_exn_tracks_internal_failures;
          test_case "records validation diagnostics with request metadata" `Quick
            test_record_validation_error_metric_tracks_request_metadata;
          test_case "records validation diagnostics for invalid json" `Quick
            test_record_validation_error_metric_falls_back_for_invalid_json;
           test_case "serializes health and latency" `Quick
             test_snapshot_json_reports_health_and_latency;
           test_case "serializes room bindings" `Quick
             test_snapshot_json_includes_room_bindings;
           test_case "serializes filtered recent events" `Quick
             test_events_json_filters_newest_first;
           test_case "bounds tracked rooms" `Quick
             test_room_tracking_is_bounded;
         ] );
    ]
