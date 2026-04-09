open Masc_mcp
open Test_command_plane_v2_support

let control_plane_events_path config =
  Filename.concat (Filename.concat (Room.masc_dir config) "control-plane")
    "events.jsonl"

let operator_action_log_path config =
  Filename.concat (Filename.concat (Room.masc_dir config) "operator")
    "action_log.jsonl"

let write_jsonl_rows path rows =
  let body =
    rows
    |> List.map Yojson.Safe.to_string
    |> String.concat "\n"
  in
  write_text_file path (body ^ "\n")

let trace_ids json =
  json
  |> Yojson.Safe.Util.member "events"
  |> Yojson.Safe.Util.to_list
  |> List.filter_map (fun event ->
         Yojson.Safe.Util.member "trace_id" event
         |> Yojson.Safe.Util.to_string_option)

let event_sources json =
  json
  |> Yojson.Safe.Util.member "events"
  |> Yojson.Safe.Util.to_list
  |> List.filter_map (fun event ->
         Yojson.Safe.Util.member "source" event
         |> Yojson.Safe.Util.to_string_option)

let event_ids json =
  json
  |> Yojson.Safe.Util.member "events"
  |> Yojson.Safe.Util.to_list
  |> List.filter_map (fun event ->
         Yojson.Safe.Util.member "event_id" event
         |> Yojson.Safe.Util.to_string_option)

let make_cp_event ~event_id ~trace_id ~event_type ~ts =
  `Assoc
    [
      ("event_id", `String event_id);
      ("trace_id", `String trace_id);
      ("event_type", `String event_type);
      ("source", `String "control_plane");
      ("ts", `String ts);
      ("detail", `Assoc []);
    ]

let make_operator_row ~trace_id ~action_type ~created_at =
  `Assoc
    [
      ("trace_id", `String trace_id);
      ("actor", `String "dashboard");
      ("action_type", `String action_type);
      ("created_at", `String created_at);
    ]

let test_operation_filter_reads_tail_bounded_event_log () =
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      with_eio_test base_dir @@ fun config ->
      ignore (Room.init config ~agent_name:(Some "owner"));
      (* Write 10 noise rows followed by the matching row.
         With tail-bounded read (limit*3 = 15), the match at the tail
         is within the read window. This tests the actual production
         behavior: only recent events are scanned (#4250). *)
      let noise =
        List.init 10 (fun idx ->
            make_cp_event
              ~event_id:(Printf.sprintf "evt-%02d" idx)
              ~trace_id:(Printf.sprintf "trace-noise-%02d" idx)
              ~event_type:"noise"
              ~ts:(Printf.sprintf "2026-03-23T00:%02d:00Z" idx))
      in
      let match_event =
        make_cp_event ~event_id:"evt-match" ~trace_id:"trace-match"
          ~event_type:"matched" ~ts:"2026-03-23T00:10:00Z"
      in
      write_jsonl_rows (control_plane_events_path config) (noise @ [ match_event ]);
      let json =
        Command_plane_v2.list_traces_json config ~operation_id:"trace-match"
          ~limit:5 ()
      in
      Alcotest.(check bool)
        "filtered operation keeps matching trace event within tail window"
        true
        (List.mem "trace-match" (trace_ids json)))

let test_trace_filter_reads_tail_bounded_operator_log () =
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      with_eio_test base_dir @@ fun config ->
      ignore (Room.init config ~agent_name:(Some "owner"));
      (* Write 10 noise rows followed by the matching row.
         With tail-bounded read (limit*5 = 25), the match at the tail
         is within the read window. This tests the actual production
         behavior: only recent operator log entries are scanned (#4250). *)
      let noise =
        List.init 10 (fun idx ->
            make_operator_row
              ~trace_id:(Printf.sprintf "trace-noise-%02d" idx)
              ~action_type:"operator_action"
              ~created_at:
                (Printf.sprintf "2026-03-23T00:%02d:00Z" idx))
      in
      let match_row =
        make_operator_row ~trace_id:"trace-match" ~action_type:"operator_action"
          ~created_at:"2026-03-23T00:10:00Z"
      in
      write_jsonl_rows (operator_action_log_path config) (noise @ [ match_row ]);
      let json =
        Command_plane_v2.list_traces_json config ~operation_id:"trace-match"
          ~limit:5 ()
      in
      Alcotest.(check bool)
        "filtered trace keeps matching operator event within tail window"
        true
        (List.mem "trace-match" (trace_ids json));
      Alcotest.(check bool)
        "operator source preserved"
        true
        (List.mem "operator" (event_sources json)))

let test_default_trace_view_reuses_cached_operator_events_when_inputs_unchanged () =
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      with_eio_test base_dir @@ fun config ->
      ignore (Room.init config ~agent_name:(Some "owner"));
      write_jsonl_rows (operator_action_log_path config)
        [ make_operator_row ~trace_id:"trace-cached"
            ~action_type:"operator_action"
            ~created_at:"2026-03-23T00:10:00Z" ];
      let first = Command_plane_v2.list_traces_json config ~limit:5 () in
      let second = Command_plane_v2.list_traces_json config ~limit:5 () in
      Alcotest.(check (list string))
        "default trace view reuses synthetic operator event ids"
        (event_ids first) (event_ids second))

let test_default_trace_view_invalidates_cache_when_event_log_changes () =
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      with_eio_test base_dir @@ fun config ->
      ignore (Room.init config ~agent_name:(Some "owner"));
      let initial_event =
        make_cp_event ~event_id:"evt-initial" ~trace_id:"trace-initial"
          ~event_type:"initial" ~ts:"2026-03-23T00:00:00Z"
      in
      write_jsonl_rows (control_plane_events_path config) [ initial_event ];
      ignore (Command_plane_v2.list_traces_json config ~limit:5 ());
      let updated_events =
        [
          initial_event;
          make_cp_event ~event_id:"evt-new" ~trace_id:"trace-new"
            ~event_type:"updated" ~ts:"2026-03-23T00:01:00Z";
        ]
      in
      write_jsonl_rows (control_plane_events_path config) updated_events;
      let now = Unix.gettimeofday () +. 1.0 in
      Unix.utimes (control_plane_events_path config) now now;
      let json = Command_plane_v2.list_traces_json config ~limit:5 () in
      Alcotest.(check bool)
        "default trace cache refreshes after control-plane log change"
        true
        (List.mem "trace-new" (trace_ids json)))
