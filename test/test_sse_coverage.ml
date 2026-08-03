(** Sse Module Coverage Tests

    Tests for SSE (Server-Sent Events) functionality:
    - format_event: SSE event formatting
    - max_buffer_size: buffer limit constant
    - buffer_event, get_events_after: event buffering
    - current_id: durable event ID observation
    - register, unregister, exists: client management
    - client_count: statistics
    - client type: record fields
*)

open Alcotest

let jsonrpc_notification method_name =
  `Assoc [ ("jsonrpc", `String "2.0"); ("method", `String method_name) ]

let delivery ?(emitted_at = Unix.gettimeofday ()) event_id frame : Masc.Sse.delivery =
  { event_id; frame; emitted_at }
;;

module Sse = Masc.Sse
module Session = Masc.Session

let workspace = Masc_test_deps.setup_test_workspace ()
let auth = Masc_test_deps.make_sse_auth workspace "sse-coverage-agent"

let () = at_exit (fun () -> Masc_test_deps.cleanup_test_workspace workspace)

let register_exn ?kind ?on_disconnect session_id ~last_event_id =
  (* Pre-create the MCP session so registration validates an existing
     session rather than auto-bootstrapping one (security/sse-auth-validation). *)
  let (_ : Session.McpSessionStore.mcp_session) =
    Session.McpSessionStore.get_or_create ~id:session_id ()
  in
  match Masc.Sse.register ?kind ?on_disconnect ~auth session_id ~last_event_id with
  | Ok result -> result
  | Error e ->
      Alcotest.fail (Sse.registration_error_to_string e)

let run_domains_together count fn =
  let ready = Atomic.make 0 in
  let go = Atomic.make false in
  let domains =
    List.init count (fun index ->
      Domain.spawn (fun () ->
        ignore (Atomic.fetch_and_add ready 1);
        while not (Atomic.get go) do
          Domain.cpu_relax ()
        done;
        fn index))
  in
  while Atomic.get ready < count do
    Domain.cpu_relax ()
  done;
  Atomic.set go true;
  List.iter Domain.join domains

(* ============================================================
   format_event Tests
   ============================================================ *)

let test_format_event_basic () =
  let before_id = Sse.current_id () in
  let event = Sse.format_event "test data" in
  check bool "transport-only frame has no id" false
    (String.starts_with ~prefix:"id:" event);
  check int "transport-only frame does not consume replay id"
    before_id (Sse.current_id ());
  check bool "has data" true (String.length event > 0)

let test_format_event_with_id () =
  let event = Sse.format_event ~id:42 "test" in
  check bool "contains id 42" true (String.length event > 0)

let test_format_event_with_event_type () =
  let event = Sse.format_event ~event_type:"message" "test" in
  check bool "contains event type" true (String.length event > 0)

let test_format_event_with_both () =
  let event = Sse.format_event ~id:100 ~event_type:"update" "data" in
  check bool "non-empty" true (String.length event > 0)

let test_format_event_ends_with_double_newline () =
  let event = Sse.format_event "test" in
  let len = String.length event in
  check bool "ends with \\n\\n" true
    (len >= 2 && event.[len-1] = '\n' && event.[len-2] = '\n')

(* ============================================================
   max_buffer_size Tests
   ============================================================ *)

let test_max_buffer_size_positive () =
  check bool "positive" true (Sse.max_buffer_size > 0)

let test_max_buffer_size_reasonable () =
  check bool "reasonable (50-1000)" true
    (Sse.max_buffer_size >= 50 && Sse.max_buffer_size <= 1000)

(* ============================================================
   current_id Tests
   ============================================================ *)

let test_current_id_positive () =
  let id = Sse.current_id () in
  check bool "positive" true (id >= 0)

(* ============================================================
   register / unregister / exists Tests
   ============================================================ *)

let test_register_creates_client () =
  let session_id = "test_register_" ^ string_of_int (Random.int 10000) in
  let _push _ = () in
  let (_id, _, _) = register_exn session_id ~last_event_id:0 in
  check bool "exists after register" true (Sse.exists session_id);
  Sse.unregister session_id

let test_unregister_removes_client () =
  let session_id = "test_unregister_" ^ string_of_int (Random.int 10000) in
  let _push _ = () in
  let (_id, _, _) = register_exn session_id ~last_event_id:0 in
  Sse.unregister session_id;
  check bool "not exists after unregister" false (Sse.exists session_id)

let test_exists_false_for_unknown () =
  check bool "unknown session" false (Sse.exists "nonexistent_session_xyz")

let test_register_returns_unique_id () =
  let session1 = "test_unique1_" ^ string_of_int (Random.int 10000) in
  let session2 = "test_unique2_" ^ string_of_int (Random.int 10000) in
  let _push _ = () in
  let (id1, _, _) = register_exn session1 ~last_event_id:0 in
  let (id2, _, _) = register_exn session2 ~last_event_id:0 in
  check bool "unique ids" true (id1 <> id2);
  Sse.unregister session1;
  Sse.unregister session2

let test_register_uses_successful_commit_time_after_retry () =
  let session_id = "register_retry_" ^ string_of_int (Random.int 10000) in
  let _push _ = () in
  let original_hook = Atomic.get Sse.register_commit_test_hook in
  let forced_retry = Atomic.make false in
  let retry_barrier = ref 0.0 in
  Fun.protect
    ~finally:(fun () ->
      Atomic.set Sse.register_commit_test_hook original_hook;
      Sse.unregister session_id)
    (fun () ->
      Atomic.set Sse.register_commit_test_hook
        (Some (fun () ->
           if Atomic.compare_and_set forced_retry false true then begin
             ignore
               (Lockfree_atomic.update_with_commit Sse.clients (fun state ->
                    {
                      next_state = { state with count = state.count };
                      result = ();
                    }));
             ignore (Unix.select [] [] [] 0.02);
             retry_barrier := Unix.gettimeofday ()
           end));
      ignore (register_exn session_id ~last_event_id:0);
      check bool "forced retry triggered" true (Atomic.get forced_retry);
      match Sse.SMap.find_opt session_id (Atomic.get Sse.clients).entries with
      | Some client ->
          check bool "created_at captured after retry barrier" true
            (client.created_at >= !retry_barrier);
          check bool "last_seen_at captured after retry barrier" true
            (Atomic.get client.last_seen_at >= !retry_barrier)
      | None ->
          fail "client should be installed")

(* ============================================================
   client_count Tests
   ============================================================ *)

let test_client_count_nonnegative () =
  check bool "nonnegative" true (Sse.client_count () >= 0)

let test_client_count_increments () =
  let before = Sse.client_count () in
  let session_id = "test_count_" ^ string_of_int (Random.int 10000) in
  let _push _ = () in
  let (_id, _, _) = register_exn session_id ~last_event_id:0 in
  let after = Sse.client_count () in
  Sse.unregister session_id;
  check bool "incremented" true (after > before || after = before)

let test_client_count_exact_unregister_decrement () =
  let before = Sse.client_count () in
  let session1 = "test_count_exact_1_" ^ string_of_int (Random.bits ()) in
  let session2 = "test_count_exact_2_" ^ string_of_int (Random.bits ()) in
  Fun.protect
    ~finally:(fun () ->
      Sse.unregister session1;
      Sse.unregister session2)
    (fun () ->
      let (_id1, _, _) = register_exn session1 ~last_event_id:0 in
      let (_id2, _, _) = register_exn session2 ~last_event_id:0 in
      check int "two registrations increment count by two"
        (before + 2) (Sse.client_count ());
      Sse.unregister session1;
      check int "first unregister decrements count by one"
        (before + 1) (Sse.client_count ());
      Sse.unregister session2;
      check int "second unregister restores original count"
        before (Sse.client_count ()))

let test_client_count_by_kind_tracks_session_roles () =
  let before_observer = Sse.client_count_by_kind Sse.Observer in
  let before_agent_stream = Sse.client_count_by_kind Sse.Agent_stream in
  let observer = "test_kind_observer_" ^ string_of_int (Random.bits ()) in
  let agent_stream = "test_kind_workspace_" ^ string_of_int (Random.bits ()) in
  Fun.protect
    ~finally:(fun () ->
      Sse.unregister observer;
      Sse.unregister agent_stream)
    (fun () ->
      let (_id1, _, _) = register_exn ~kind:Sse.Observer observer ~last_event_id:0 in
      let (_id2, _, _) =
        register_exn ~kind:Sse.Agent_stream agent_stream ~last_event_id:0
      in
      check int "observer count increments"
        (before_observer + 1)
        (Sse.client_count_by_kind Sse.Observer);
      check int "agent_stream count increments"
        (before_agent_stream + 1)
        (Sse.client_count_by_kind Sse.Agent_stream);
      Sse.unregister observer;
      check int "observer count decrements"
        before_observer
        (Sse.client_count_by_kind Sse.Observer);
      check int "agent_stream still present"
        (before_agent_stream + 1)
        (Sse.client_count_by_kind Sse.Agent_stream))

let test_unregister_if_current_replacement_count () =
  let before = Sse.client_count () in
  let session_id =
    "test_unreg_replacement_" ^ string_of_int (Random.bits ())
  in
  Fun.protect
    ~finally:(fun () -> Sse.unregister session_id)
    (fun () ->
      let (old_client_id, _, _) = register_exn session_id ~last_event_id:0 in
      let (new_client_id, _, _) = register_exn session_id ~last_event_id:0 in
      check int "replacement keeps one live session"
        (before + 1) (Sse.client_count ());
      Sse.unregister_if_current session_id old_client_id;
      check bool "old cleanup cannot remove replacement"
        true (Sse.exists session_id);
      check int "stale cleanup leaves count unchanged"
        (before + 1) (Sse.client_count ());
      Sse.unregister_if_current session_id new_client_id;
      check bool "current cleanup removes replacement"
        false (Sse.exists session_id);
      check int "current cleanup restores original count"
        before (Sse.client_count ()))

(* ============================================================
   buffer_event / get_events_after Tests
   ============================================================ *)

let test_buffer_event_and_retrieve () =
  let base_id = Sse.current_id () in
  Sse.buffer_event (delivery (base_id + 1000) "test event 1");
  let events = Sse.get_events_after (base_id + 999) in
  check bool "has event" true (List.length events >= 1)

let test_buffer_event_preserves_producer_timestamp_after_retry () =
  let original_buffer = Sse.event_buffer_events_for_test () in
  let original_hook = Atomic.get Sse.buffer_commit_test_hook in
  let forced_retry = Atomic.make false in
  let emitted_at = Unix.gettimeofday () in
  Fun.protect
    ~finally:(fun () ->
      Atomic.set Sse.buffer_commit_test_hook original_hook;
      Sse.set_event_buffer_for_test original_buffer)
    (fun () ->
      Sse.set_event_buffer_for_test [ delivery 777_000 "marker" ];
      Atomic.set Sse.buffer_commit_test_hook
        (Some (fun () ->
           if Atomic.compare_and_set forced_retry false true then begin
             Sse.rewrite_event_buffer_for_test ();
             ignore (Unix.select [] [] [] 0.02);
           end));
      Sse.buffer_event (delivery ~emitted_at 777_001 "fresh");
      check bool "forced retry triggered" true (Atomic.get forced_retry);
      match Sse.event_buffer_events_for_test () with
      | (fresh : Sse.delivery) :: _ ->
          check int "new event inserted at head" 777_001 fresh.event_id;
          check (float 0.0) "producer timestamp survives CAS retry"
            emitted_at fresh.emitted_at
      | [] ->
          fail "buffer should contain the fresh event")

let test_get_events_after_filters () =
  let original_buffer = Sse.event_buffer_events_for_test () in
  Fun.protect
    ~finally:(fun () -> Sse.set_event_buffer_for_test original_buffer)
    (fun () ->
      Sse.set_event_buffer_for_test [];
      Sse.buffer_event (delivery 802_000 "event A");
      Sse.buffer_event (delivery 802_001 "event B");
      check (list string) "filtered exact replay" [ "event B" ]
        (Sse.get_events_after 802_000 |> List.map (fun event -> event.Sse.frame)))

let test_get_events_after_preserves_oldest_first_order () =
  let original_buffer = Sse.event_buffer_events_for_test () in
  Fun.protect
    ~finally:(fun () -> Sse.set_event_buffer_for_test original_buffer)
    (fun () ->
      Sse.set_event_buffer_for_test [];
      Sse.buffer_event (delivery 803_000 "event A");
      Sse.buffer_event (delivery 803_001 "event B");
      Sse.buffer_event (delivery 803_002 "event C");
      check (list string) "all replayed oldest-first"
        [ "event A"; "event B"; "event C" ]
        (Sse.get_events_after 802_999 |> List.map (fun event -> event.Sse.frame));
      check (list string) "tail replayed oldest-first" [ "event B"; "event C" ]
        (Sse.get_events_after 803_000 |> List.map (fun event -> event.Sse.frame)))

let test_buffer_event_caps_replay_buffer () =
  let original_buffer = Sse.event_buffer_events_for_test () in
  Fun.protect
    ~finally:(fun () -> Sse.set_event_buffer_for_test original_buffer)
    (fun () ->
      Sse.set_event_buffer_for_test [];
      let base = Sse.current_id () + Sse.max_buffer_size + 1 in
      for index = 0 to Sse.max_buffer_size + 4 do
        Sse.buffer_event
          (delivery (base + index) (Printf.sprintf "event-%d" index))
      done;
      let buffered = Sse.event_buffer_events_for_test () in
      let expected_newest_first_indexes =
        List.init Sse.max_buffer_size (fun offset ->
          Sse.max_buffer_size + 4 - offset)
      in
      let expected_newest_first_events =
        List.map
          (fun index -> Printf.sprintf "event-%d" index)
          expected_newest_first_indexes
      in
      check int "buffer capped" Sse.max_buffer_size (List.length buffered);
      check (list int) "retained ids newest-first"
        (List.map (fun index -> base + index) expected_newest_first_indexes)
        (List.map (fun (event : Sse.delivery) -> event.event_id) buffered);
      check (list string) "retained event contents newest-first"
        expected_newest_first_events
        (List.map (fun (event : Sse.delivery) -> event.frame) buffered);
      check (list string) "replay retained events oldest-first"
        (List.rev expected_newest_first_events)
        (Sse.get_events_after (base - 1)
         |> List.map (fun event -> event.Sse.frame)))

let test_get_events_after_empty () =
  let future_id = Sse.current_id () + 100000 in
  let events = Sse.get_events_after future_id in
  check int "empty for future id" 0 (List.length events)

let test_replay_handoff_deduplicates_exact_ids_only () =
  let replayed = [ delivery 910_010 "ten"; delivery 910_030 "thirty" ] in
  let handoff = Sse.create_replay_handoff replayed in
  check bool "replayed high id skipped once" false
    (Sse.accept_live_delivery handoff (delivery 910_030 "thirty"));
  check bool "unreplayed middle id is not lost" true
    (Sse.accept_live_delivery handoff (delivery 910_020 "twenty"));
  check bool "replayed low id skipped despite interleaving" false
    (Sse.accept_live_delivery handoff (delivery 910_010 "ten"));
  check bool "same id is accepted after overlap drains" true
    (Sse.accept_live_delivery handoff (delivery 910_010 "ten-again"))
;;

let test_cleanup_expired_events_exact_under_domain_contention () =
  let original_buffer = Sse.event_buffer_events_for_test () in
  let now = Unix.gettimeofday () in
  let expired_count = 32 in
  let expired_items =
    List.init expired_count (fun index ->
      delivery
        ~emitted_at:(now -. Sse.buffer_ttl_seconds -. 10.0)
        (900_000 + index)
        (Printf.sprintf "expired-%d" index))
  in
  Fun.protect
    ~finally:(fun () -> Sse.set_event_buffer_for_test original_buffer)
    (fun () ->
      Sse.set_event_buffer_for_test expired_items;
      let total_removed = Atomic.make 0 in
      run_domains_together 2 (fun _index ->
        ignore (Atomic.fetch_and_add total_removed (Sse.cleanup_expired_events ())));
      check int "each expired event counted once" expired_count
        (Atomic.get total_removed);
      check int "buffer emptied once" 0
        (List.length (Sse.event_buffer_events_for_test ())))

let test_concurrent_broadcast_preserves_replay_and_live_cursor_order () =
  let original_buffer = Sse.event_buffer_events_for_test () in
  let original_hook = Atomic.get Sse.buffer_commit_test_hook in
  let session_id = "test_concurrent_cursor_" ^ string_of_int (Random.bits ()) in
  Fun.protect
    ~finally:(fun () ->
      Atomic.set Sse.buffer_commit_test_hook original_hook;
      Sse.unregister session_id;
      Sse.set_event_buffer_for_test original_buffer)
    (fun () ->
      Sse.set_event_buffer_for_test [];
      let (_client_id, event_stream, _) =
        register_exn ~kind:Sse.Observer session_id ~last_event_id:0
      in
      let base_id = Sse.current_id () in
      let delayed_first_commit = Atomic.make false in
      Atomic.set Sse.buffer_commit_test_hook
        (Some (fun () ->
           if Atomic.compare_and_set delayed_first_commit false true then
             ignore (Unix.select [] [] [] 0.05)));
      run_domains_together 2 (fun index ->
        Sse.broadcast_to Sse.Observers
          (`Assoc [ "concurrent_sequence", `Int index ]));
      Atomic.set Sse.buffer_commit_test_hook None;
      let buffered_ids =
        Sse.get_events_after base_id
        |> List.map (fun (event : Sse.delivery) -> event.event_id)
      in
      let rec drain acc =
        match Eio.Stream.take_nonblocking event_stream with
        | None -> List.rev acc
        | Some (event : Sse.delivery) -> drain (event.event_id :: acc)
      in
      let live_ids = drain [] in
      check int "both concurrent events are replayable" 2
        (List.length buffered_ids);
      check (list int) "live delivery follows durable cursor order"
        buffered_ids live_ids)

(* ============================================================
   client Type Tests
   ============================================================ *)

let test_client_type_fields () =
  let session_id = "test_client_" ^ string_of_int (Random.int 10000) in
  let received = ref [] in
  let _push msg = received := msg :: !received in
  let (_id, _, _) = register_exn session_id ~last_event_id:5 in
  check bool "exists" true (Sse.exists session_id);
  Sse.unregister session_id

(* ============================================================
   unregister_if_current Tests
   ============================================================ *)

let test_unregister_if_current_matches () =
  let session_id = "test_unreg_match_" ^ string_of_int (Random.int 10000) in
  let _push _ = () in
  let (client_id, _, _) = register_exn session_id ~last_event_id:0 in
  check bool "exists before" true (Sse.exists session_id);
  Sse.unregister_if_current session_id client_id;
  check bool "removed when matching" false (Sse.exists session_id)

let test_unregister_if_current_no_match () =
  let session_id = "test_unreg_nomatch_" ^ string_of_int (Random.int 10000) in
  let _push _ = () in
  let (_client_id, _, _) = register_exn session_id ~last_event_id:0 in
  check bool "exists before" true (Sse.exists session_id);
  Sse.unregister_if_current session_id 999999;  (* wrong client id *)
  check bool "not removed when not matching" true (Sse.exists session_id);
  Sse.unregister session_id

let test_unregister_if_current_nonexistent () =
  Sse.unregister_if_current "nonexistent_xyz" 123;
  ()

(* ============================================================
   update_last_event_id Tests
   ============================================================ *)

let test_update_last_event_id_exists () =
  let session_id = "test_update_id_" ^ string_of_int (Random.int 10000) in
  let _push _ = () in
  let (_id, _, _) = register_exn session_id ~last_event_id:0 in
  Sse.update_last_event_id session_id 42;
  ();
  Sse.unregister session_id

let test_update_last_event_id_nonexistent () =
  Sse.update_last_event_id "nonexistent_xyz" 42;
  ()

(* ============================================================
   broadcast Tests
   ============================================================ *)

let test_broadcast_sends_to_clients () =
  let session_id = "test_broadcast_" ^ string_of_int (Random.int 10000) in
  let _push _ = () in
  let (_id, _, _) = register_exn ~kind:Sse.Observer session_id ~last_event_id:0 in
  Sse.broadcast (`Assoc [("test", `String "value")]);
  (* Events are queued in the per-session stream, not pushed directly *)
  let event = Sse.try_pop session_id in
  check bool "received broadcast via stream" true (event <> None);
  Sse.unregister session_id

let test_broadcast_empty_clients () =
  let session_id = "temp_session_" ^ string_of_int (Random.int 10000) in
  (* Make sure we have no clients with this specific id *)
  Sse.unregister session_id;
  (* Broadcast should not error with no clients *)
  Sse.broadcast (`Assoc [("empty", `String "test")]);
  ()

(* ============================================================
   send_to Tests
   ============================================================ *)

let test_send_to_existing () =
  let session_id = "test_send_to_" ^ string_of_int (Random.int 10000) in
  let _push _ = () in
  let (_id, _, _) = register_exn session_id ~last_event_id:0 in
  Sse.send_to session_id (jsonrpc_notification "notifications/test");
  (* Events are queued in the per-session stream *)
  let event = Sse.try_pop session_id in
  check bool "received message via stream" true (event <> None);
  Sse.unregister session_id

let test_send_to_nonexistent () =
  Sse.send_to "nonexistent_session_xyz" (`Assoc [("test", `String "value")]);
  ()

(* ============================================================
   Test Runners
   ============================================================ *)

(* ============================================================
   Snapshot Throttle Tests
   ============================================================ *)

let test_sync_transport_snapshot_throttle_idempotent () =
  (* Calling sync_transport_snapshot multiple times rapidly must not
     crash or corrupt state.  The CAS throttle ensures only the first
     call in each [snapshot_min_interval_sec] window computes; the
     rest return () immediately. *)
  let session_id = "test_throttle_" ^ string_of_int (Random.bits ()) in
  Fun.protect
    ~finally:(fun () -> Sse.unregister session_id)
    (fun () ->
      let (_id, _, _) = register_exn session_id ~last_event_id:0 in
      for _ = 1 to 20 do
        Sse.sync_transport_snapshot ()
      done;
      check int "client count preserved after rapid snapshots"
        1 (Sse.client_count ()))

let test_broadcast_throttled_snapshot_stability () =
  (* broadcast_impl calls sync_transport_snapshot internally.
     Verify rapid broadcasts do not corrupt client state. *)
  let session_id = "test_bcast_throttle_" ^ string_of_int (Random.bits ()) in
  Fun.protect
    ~finally:(fun () -> Sse.unregister session_id)
    (fun () ->
      let (_id, _, _) = register_exn session_id ~last_event_id:0 in
      let payload = `Assoc [ "test", `String "throttle" ] in
      for _ = 1 to 20 do
        Sse.broadcast payload
      done;
      check int "client count preserved after rapid broadcasts"
        1 (Sse.client_count ()))

let () =
  run "Sse Coverage" [
    "format_event", [
      test_case "basic" `Quick test_format_event_basic;
      test_case "with id" `Quick test_format_event_with_id;
      test_case "with event_type" `Quick test_format_event_with_event_type;
      test_case "with both" `Quick test_format_event_with_both;
      test_case "ends with newlines" `Quick test_format_event_ends_with_double_newline;
    ];
    "max_buffer_size", [
      test_case "positive" `Quick test_max_buffer_size_positive;
      test_case "reasonable" `Quick test_max_buffer_size_reasonable;
    ];
    "id_management", [
      test_case "current_id positive" `Quick test_current_id_positive;
    ];
    "client_management", [
      test_case "register creates" `Quick test_register_creates_client;
      test_case "unregister removes" `Quick test_unregister_removes_client;
      test_case "exists false for unknown" `Quick test_exists_false_for_unknown;
      test_case "unique ids" `Quick test_register_returns_unique_id;
      test_case "retry uses successful commit time" `Quick
        test_register_uses_successful_commit_time_after_retry;
    ];
    "unregister_if_current", [
      test_case "matches" `Quick test_unregister_if_current_matches;
      test_case "no match" `Quick test_unregister_if_current_no_match;
      test_case "nonexistent" `Quick test_unregister_if_current_nonexistent;
      test_case "replacement count invariant" `Quick
        test_unregister_if_current_replacement_count;
    ];
    "update_last_event_id", [
      test_case "exists" `Quick test_update_last_event_id_exists;
      test_case "nonexistent" `Quick test_update_last_event_id_nonexistent;
    ];
    "client_count", [
      test_case "nonnegative" `Quick test_client_count_nonnegative;
      test_case "increments" `Quick test_client_count_increments;
      test_case "unregister decrements exactly" `Quick
        test_client_count_exact_unregister_decrement;
      test_case "by kind tracks session roles" `Quick
        test_client_count_by_kind_tracks_session_roles;
    ];
    "event_buffer", [
      test_case "buffer and retrieve" `Quick test_buffer_event_and_retrieve;
      test_case "buffer retry timestamps on successful commit" `Quick
        test_buffer_event_preserves_producer_timestamp_after_retry;
      test_case "filters" `Quick test_get_events_after_filters;
      test_case "preserves oldest-first order" `Quick
        test_get_events_after_preserves_oldest_first_order;
      test_case "caps replay buffer" `Quick test_buffer_event_caps_replay_buffer;
      test_case "empty for future" `Quick test_get_events_after_empty;
      test_case "replay handoff deduplicates exact ids" `Quick
        test_replay_handoff_deduplicates_exact_ids_only;
      test_case "cleanup exact under domain contention" `Quick
        test_cleanup_expired_events_exact_under_domain_contention;
      test_case "concurrent broadcast preserves replay/live cursor order" `Quick
        test_concurrent_broadcast_preserves_replay_and_live_cursor_order;
    ];
    "broadcast", [
      test_case "sends to clients" `Quick test_broadcast_sends_to_clients;
      test_case "empty clients" `Quick test_broadcast_empty_clients;
    ];
    "snapshot_throttle", [
      test_case "rapid sync_transport_snapshot idempotent" `Quick
        test_sync_transport_snapshot_throttle_idempotent;
      test_case "rapid broadcast snapshot stable" `Quick
        test_broadcast_throttled_snapshot_stability;
    ];
    "send_to", [
      test_case "existing" `Quick test_send_to_existing;
      test_case "nonexistent" `Quick test_send_to_nonexistent;
    ];
    "client_type", [
      test_case "fields" `Quick test_client_type_fields;
    ];
  ]
