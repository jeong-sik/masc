open Masc_mcp

let get_ok = function
  | Ok x -> x
  | Error e -> Alcotest.fail e

let make_base_dir () =
  let pid = Unix.getpid () in
  let r = Random.int 1_000_000 in
  Filename.concat (Filename.get_temp_dir_name ()) (Printf.sprintf "masc-trpg-sqlite-%d-%d" pid r)

let make_event ~seq ~room_id =
  Trpg_engine_event.make
    ~seq
    ~room_id
    ~ts:(Printf.sprintf "2026-02-15T01:00:%02dZ" seq)
    ~event_type:Trpg_engine_event.Turn_started
    ~payload:(`Assoc [ ("n", `Int seq) ])
    ()

let seq_of_event (e : Trpg_engine_event.t) = e.seq

let sqlite_db_path base_dir =
  Filename.concat (Filename.concat base_dir "trpg") "events.sqlite3"

let test_read_events_skips_malformed_rows () =
  let base_dir = make_base_dir () in
  let room_id = "room-sql-malformed" in
  get_ok (Trpg_engine_store_sqlite.append_event ~base_dir ~event:(make_event ~seq:1 ~room_id));
  let db = Sqlite3.db_open (sqlite_db_path base_dir) in
  let raw_insert =
    Printf.sprintf
      "INSERT INTO trpg_events(room_id, seq, ts, event_type, actor_id, payload) \
       VALUES('%s', 2, '2026-02-15T01:00:02Z', 'unknown.event', 'ghost', '{}')"
      room_id
  in
  (match Sqlite3.exec db raw_insert with
  | Sqlite3.Rc.OK -> ()
  | rc ->
      ignore (Sqlite3.db_close db);
      Alcotest.failf "raw insert failed: %s" (Sqlite3.Rc.to_string rc));
  ignore (Sqlite3.db_close db);
  get_ok (Trpg_engine_store_sqlite.append_event ~base_dir ~event:(make_event ~seq:3 ~room_id));
  let all = get_ok (Trpg_engine_store_sqlite.read_events ~base_dir ~room_id) in
  Alcotest.(check (list int)) "skip malformed row" [ 1; 3 ] (List.map seq_of_event all);
  let tail = get_ok (Trpg_engine_store_sqlite.read_events_after ~base_dir ~room_id ~after_seq:2) in
  Alcotest.(check (list int)) "tail after seq=2" [ 3 ] (List.map seq_of_event tail)

let test_append_and_read_events () =
  let base_dir = make_base_dir () in
  let room_id = "room-sql-1" in
  get_ok (Trpg_engine_store_sqlite.append_event ~base_dir ~event:(make_event ~seq:1 ~room_id));
  get_ok (Trpg_engine_store_sqlite.append_event ~base_dir ~event:(make_event ~seq:2 ~room_id));
  get_ok (Trpg_engine_store_sqlite.append_event ~base_dir ~event:(make_event ~seq:3 ~room_id));
  let all = get_ok (Trpg_engine_store_sqlite.read_events ~base_dir ~room_id) in
  Alcotest.(check (list int)) "seq order" [ 1; 2; 3 ] (List.map seq_of_event all);
  let tail = get_ok (Trpg_engine_store_sqlite.read_events_after ~base_dir ~room_id ~after_seq:1) in
  Alcotest.(check (list int)) "after seq=1" [ 2; 3 ] (List.map seq_of_event tail)

let test_snapshot_roundtrip () =
  let base_dir = make_base_dir () in
  let room_id = "room-sql-2" in
  let state =
    Trpg_engine_types.initial_room_state
      ~room_id
      ~scenario_id:"negotiation-v1"
      ~dm_control:Trpg_engine_types.Human
      ~turn_order:[ "a"; "b" ]
    |> fun s -> { s with phase = Trpg_engine_types.Round; current_turn_index = Some 1; round = 3 }
  in
  get_ok
    (Trpg_engine_store_sqlite.write_snapshot
       ~base_dir
       ~room_id
       ~last_seq:5
       ~ts:"2026-02-15T10:30:00Z"
       ~state);
  let snap = get_ok (Trpg_engine_store_sqlite.read_snapshot ~base_dir ~room_id) in
  match snap with
  | None -> Alcotest.fail "snapshot should exist"
  | Some s ->
      Alcotest.(check int) "last_seq" 5 s.last_seq;
      Alcotest.(check string) "phase" "round" (Trpg_engine_types.string_of_phase s.state.phase)

let test_recovery_tail_events () =
  let base_dir = make_base_dir () in
  let room_id = "room-sql-3" in
  List.iter
    (fun seq ->
      get_ok (Trpg_engine_store_sqlite.append_event ~base_dir ~event:(make_event ~seq ~room_id)))
    [ 1; 2; 3; 4; 5 ];
  let state =
    Trpg_engine_types.initial_room_state
      ~room_id
      ~scenario_id:"trust-public-goods-v1"
      ~dm_control:Trpg_engine_types.Keeper
      ~turn_order:[ "p1"; "p2"; "p3" ]
  in
  get_ok
    (Trpg_engine_store_sqlite.write_snapshot
       ~base_dir
       ~room_id
       ~last_seq:3
       ~ts:"2026-02-15T11:00:00Z"
       ~state);
  let snapshot_opt, tail = get_ok (Trpg_engine_store_sqlite.load_recovery ~base_dir ~room_id) in
  (match snapshot_opt with
  | None -> Alcotest.fail "expected snapshot"
  | Some s -> Alcotest.(check int) "snapshot last_seq" 3 s.last_seq);
  Alcotest.(check (list int)) "tail seq" [ 4; 5 ] (List.map seq_of_event tail)

let () =
  Alcotest.run "TRPG Engine Store Sqlite"
    [
      ( "events",
        [
          Alcotest.test_case "append + read + filter" `Quick test_append_and_read_events;
          Alcotest.test_case "skip malformed row" `Quick test_read_events_skips_malformed_rows;
        ] );
      ("snapshot", [ Alcotest.test_case "write + read" `Quick test_snapshot_roundtrip ]);
      ("recovery", [ Alcotest.test_case "snapshot + tail events" `Quick test_recovery_tail_events ]);
    ]
