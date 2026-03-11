(** Swarm State Persistence tests (Gap B + Gap C).

    - checkpoint_of_yojson roundtrip
    - load_latest_checkpoint (empty / populated)
    - event_entry_of_yojson roundtrip
    - read_recent_events (empty / max_count cap)
*)

open Masc_mcp

let temp_dir () =
  let dir = Filename.temp_file "test_swarm_persist_" "" in
  Unix.unlink dir;
  Unix.mkdir dir 0o755;
  dir

let cleanup_dir dir =
  let rec rm path =
    if Sys.file_exists path then
      if Sys.is_directory path then (
        Array.iter (fun name -> rm (Filename.concat path name)) (Sys.readdir path);
        Unix.rmdir path)
      else Unix.unlink path
  in
  try rm dir with _ -> ()

(* ── Gap B: checkpoint roundtrip ─────────────────────────────── *)

let sample_checkpoint : Team_session_types.checkpoint =
  {
    ts = 1700000000.0;
    ts_iso = "2023-11-14T22:13:20.000Z";
    status = Team_session_types.Running;
    elapsed_sec = 120;
    remaining_sec = 480;
    progress_pct = 25.0;
    done_delta_total = 3;
    done_delta_by_agent = [ ("alice", 2); ("bob", 1) ];
    active_agents = [ "alice"; "bob" ];
  }

let test_checkpoint_roundtrip () =
  let json = Team_session_types.checkpoint_to_yojson sample_checkpoint in
  match Team_session_types.checkpoint_of_yojson json with
  | Error e -> Alcotest.fail ("roundtrip failed: " ^ e)
  | Ok cp ->
      Alcotest.(check (float 0.01)) "ts" sample_checkpoint.ts cp.ts;
      Alcotest.(check string) "ts_iso" sample_checkpoint.ts_iso cp.ts_iso;
      Alcotest.(check string) "status" "running"
        (Team_session_types.status_to_string cp.status);
      Alcotest.(check int) "elapsed_sec" 120 cp.elapsed_sec;
      Alcotest.(check int) "remaining_sec" 480 cp.remaining_sec;
      Alcotest.(check (float 0.01)) "progress_pct" 25.0 cp.progress_pct;
      Alcotest.(check int) "done_delta_total" 3 cp.done_delta_total;
      Alcotest.(check int) "agent count" 2 (List.length cp.done_delta_by_agent);
      Alcotest.(check int) "active count" 2 (List.length cp.active_agents)

let test_checkpoint_of_invalid_json () =
  match Team_session_types.checkpoint_of_yojson (`String "garbage") with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "should fail on invalid json"

(* ── Gap B: load_latest_checkpoint ───────────────────────────── *)

let test_load_latest_checkpoint_empty () =
  let base = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base) (fun () ->
      let config = Room.default_config base in
      let sid = "test-sess-empty" in
      Team_session_store.ensure_session_dirs config sid;
      match Team_session_store.load_latest_checkpoint config sid with
      | None -> ()
      | Some _ -> Alcotest.fail "expected None for empty checkpoints dir")

let test_load_latest_checkpoint_returns_latest () =
  let base = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base) (fun () ->
      let config = Room.default_config base in
      let sid = "test-sess-ckpt" in
      Team_session_store.ensure_session_dirs config sid;
      (* Write two checkpoints with different timestamps *)
      let cp1 = { sample_checkpoint with ts = 1700000001.0; progress_pct = 10.0 } in
      let cp2 = { sample_checkpoint with ts = 1700000002.0; progress_pct = 75.0 } in
      Team_session_store.write_checkpoint config sid cp1;
      Team_session_store.write_checkpoint config sid cp2;
      match Team_session_store.load_latest_checkpoint config sid with
      | None -> Alcotest.fail "expected Some for populated checkpoints dir"
      | Some cp ->
          (* cp2 has higher timestamp → last in sorted order *)
          Alcotest.(check (float 0.01)) "latest progress_pct" 75.0 cp.progress_pct)

(* ── Gap C: event_entry roundtrip ────────────────────────────── *)

let test_event_entry_roundtrip () =
  let entry : Team_session_types.event_entry =
    {
      ts = 1700000000.0;
      ts_iso = "2023-11-14T22:13:20.000Z";
      event_type = "test_event";
      detail = `Assoc [ ("key", `String "value") ];
    }
  in
  let json = Team_session_types.event_entry_to_yojson entry in
  match Team_session_types.event_entry_of_yojson json with
  | Error e -> Alcotest.fail ("event roundtrip failed: " ^ e)
  | Ok e ->
      Alcotest.(check (float 0.01)) "ts" entry.ts e.ts;
      Alcotest.(check string) "event_type" "test_event" e.event_type;
      Alcotest.(check string) "ts_iso" entry.ts_iso e.ts_iso

let test_event_entry_of_invalid_json () =
  match Team_session_types.event_entry_of_yojson (`Int 42) with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "should fail on invalid json"

(* ── Gap C: read_recent_events ───────────────────────────────── *)

let test_read_recent_events_empty () =
  let base = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base) (fun () ->
      let config = Room.default_config base in
      let sid = "test-sess-no-events" in
      Team_session_store.ensure_session_dirs config sid;
      let events =
        Team_session_store.read_recent_events config sid ~max_count:5
      in
      Alcotest.(check int) "empty events" 0 (List.length events))

let test_read_recent_events_capped () =
  let base = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base) (fun () ->
      let config = Room.default_config base in
      let sid = "test-sess-events" in
      Team_session_store.ensure_session_dirs config sid;
      (* Write 10 events *)
      for i = 1 to 10 do
        Team_session_store.append_event config sid
          ~event_type:(Printf.sprintf "evt_%d" i)
          ~detail:(`Assoc [ ("i", `Int i) ])
      done;
      let events =
        Team_session_store.read_recent_events config sid ~max_count:5
      in
      Alcotest.(check int) "capped at 5" 5 (List.length events);
      (* Should be the last 5 events (evt_6..evt_10) *)
      let first = List.hd events in
      Alcotest.(check string) "first is evt_6" "evt_6" first.event_type;
      let last = List.nth events 4 in
      Alcotest.(check string) "last is evt_10" "evt_10" last.event_type)

(* ── Runner ──────────────────────────────────────────────────── *)

let () =
  Alcotest.run "Swarm Persistence (Gap B+C)"
    [
      ( "checkpoint_roundtrip",
        [
          Alcotest.test_case "to/of_yojson" `Quick test_checkpoint_roundtrip;
          Alcotest.test_case "invalid json" `Quick test_checkpoint_of_invalid_json;
        ] );
      ( "load_latest_checkpoint",
        [
          Alcotest.test_case "empty dir → None" `Quick
            test_load_latest_checkpoint_empty;
          Alcotest.test_case "returns latest" `Quick
            test_load_latest_checkpoint_returns_latest;
        ] );
      ( "event_entry_roundtrip",
        [
          Alcotest.test_case "to/of_yojson" `Quick test_event_entry_roundtrip;
          Alcotest.test_case "invalid json" `Quick test_event_entry_of_invalid_json;
        ] );
      ( "read_recent_events",
        [
          Alcotest.test_case "empty → []" `Quick test_read_recent_events_empty;
          Alcotest.test_case "capped at max_count" `Quick
            test_read_recent_events_capped;
        ] );
    ]
