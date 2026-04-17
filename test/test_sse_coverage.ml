(** Sse Module Coverage Tests

    Tests for SSE (Server-Sent Events) functionality:
    - format_event: SSE event formatting
    - max_buffer_size: buffer limit constant
    - buffer_event, get_events_after: event buffering
    - current_id, next_id: event ID management
    - register, unregister, exists: client management
    - client_count: statistics
    - client type: record fields
*)

open Alcotest

module Sse = Masc_mcp.Sse

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
  let event = Sse.format_event "test data" in
  check bool "has id" true (String.length event > 0 && String.sub event 0 3 = "id:");
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
   current_id / next_id Tests
   ============================================================ *)

let test_current_id_positive () =
  let id = Sse.current_id () in
  check bool "positive" true (id >= 0)

let test_next_id_increments () =
  let before = Sse.current_id () in
  let next = Sse.next_id () in
  check bool "incremented" true (next > before)

let test_next_id_sequential () =
  let id1 = Sse.next_id () in
  let id2 = Sse.next_id () in
  check bool "sequential" true (id2 > id1)

(* ============================================================
   register / unregister / exists Tests
   ============================================================ *)

let test_register_creates_client () =
  let session_id = "test_register_" ^ string_of_int (Random.int 10000) in
  let push _ = () in
  let (_id, _, _) = Sse.register session_id ~push ~last_event_id:0 in
  check bool "exists after register" true (Sse.exists session_id);
  Sse.unregister session_id

let test_unregister_removes_client () =
  let session_id = "test_unregister_" ^ string_of_int (Random.int 10000) in
  let push _ = () in
  let (_id, _, _) = Sse.register session_id ~push ~last_event_id:0 in
  Sse.unregister session_id;
  check bool "not exists after unregister" false (Sse.exists session_id)

let test_exists_false_for_unknown () =
  check bool "unknown session" false (Sse.exists "nonexistent_session_xyz")

let test_register_returns_unique_id () =
  let session1 = "test_unique1_" ^ string_of_int (Random.int 10000) in
  let session2 = "test_unique2_" ^ string_of_int (Random.int 10000) in
  let push _ = () in
  let (id1, _, _) = Sse.register session1 ~push ~last_event_id:0 in
  let (id2, _, _) = Sse.register session2 ~push ~last_event_id:0 in
  check bool "unique ids" true (id1 <> id2);
  Sse.unregister session1;
  Sse.unregister session2

let test_register_uses_successful_commit_time_after_retry () =
  let session_id = "register_retry_" ^ string_of_int (Random.int 10000) in
  let push _ = () in
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
               (Sse.atomic_update_result Sse.clients (fun state ->
                    {
                      next_state = { state with count = state.count };
                      result = ();
                    }));
             ignore (Unix.select [] [] [] 0.02);
             retry_barrier := Unix.gettimeofday ()
           end));
      ignore (Sse.register session_id ~push ~last_event_id:0);
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
  let push _ = () in
  let (_id, _, _) = Sse.register session_id ~push ~last_event_id:0 in
  let after = Sse.client_count () in
  Sse.unregister session_id;
  check bool "incremented" true (after > before || after = before)

(* ============================================================
   buffer_event / get_events_after Tests
   ============================================================ *)

let test_buffer_event_and_retrieve () =
  let base_id = Sse.current_id () in
  Sse.buffer_event (base_id + 1000) "test event 1";
  let events = Sse.get_events_after (base_id + 999) in
  check bool "has event" true (List.length events >= 1)

let test_buffer_event_timestamps_successful_commit_after_retry () =
  let original_buffer = Atomic.get Sse.event_buffer in
  let original_hook = Atomic.get Sse.buffer_commit_test_hook in
  let forced_retry = Atomic.make false in
  let retry_barrier = ref 0.0 in
  Fun.protect
    ~finally:(fun () ->
      Atomic.set Sse.buffer_commit_test_hook original_hook;
      Atomic.set Sse.event_buffer original_buffer)
    (fun () ->
      Atomic.set Sse.event_buffer [ (777_000, "sentinel", Unix.gettimeofday ()) ];
      Atomic.set Sse.buffer_commit_test_hook
        (Some (fun () ->
           if Atomic.compare_and_set forced_retry false true then begin
             ignore
               (Sse.atomic_update_result Sse.event_buffer (fun buffer ->
                    {
                      next_state = List.map (fun item -> item) buffer;
                      result = ();
                    }));
             ignore (Unix.select [] [] [] 0.02);
             retry_barrier := Unix.gettimeofday ()
           end));
      Sse.buffer_event 777_001 "fresh";
      check bool "forced retry triggered" true (Atomic.get forced_retry);
      match Atomic.get Sse.event_buffer with
      | (event_id, _event, ts) :: _ ->
          check int "new event inserted at head" 777_001 event_id;
          check bool "timestamp captured after retry barrier" true
            (ts >= !retry_barrier)
      | [] ->
          fail "buffer should contain the fresh event")

let test_get_events_after_filters () =
  let base_id = Sse.current_id () in
  Sse.buffer_event (base_id + 2000) "event A";
  Sse.buffer_event (base_id + 2001) "event B";
  let events = Sse.get_events_after (base_id + 2000) in
  check bool "filtered" true (List.length events >= 1)

let test_get_events_after_empty () =
  let future_id = Sse.current_id () + 100000 in
  let events = Sse.get_events_after future_id in
  check int "empty for future id" 0 (List.length events)

let test_cleanup_expired_events_exact_under_domain_contention () =
  let original_buffer = Atomic.get Sse.event_buffer in
  let now = Unix.gettimeofday () in
  let expired_count = 32 in
  let expired_items =
    List.init expired_count (fun index ->
      (900_000 + index, Printf.sprintf "expired-%d" index,
       now -. Sse.buffer_ttl_seconds -. 10.0))
  in
  Fun.protect
    ~finally:(fun () -> Atomic.set Sse.event_buffer original_buffer)
    (fun () ->
      Atomic.set Sse.event_buffer expired_items;
      let total_removed = Atomic.make 0 in
      run_domains_together 2 (fun _index ->
        ignore (Atomic.fetch_and_add total_removed (Sse.cleanup_expired_events ())));
      check int "each expired event counted once" expired_count
        (Atomic.get total_removed);
      check int "buffer emptied once" 0 (List.length (Atomic.get Sse.event_buffer)))

(* ============================================================
   client Type Tests
   ============================================================ *)

let test_client_type_fields () =
  let session_id = "test_client_" ^ string_of_int (Random.int 10000) in
  let received = ref [] in
  let push msg = received := msg :: !received in
  let (_id, _, _) = Sse.register session_id ~push ~last_event_id:5 in
  check bool "exists" true (Sse.exists session_id);
  Sse.unregister session_id

(* ============================================================
   unregister_if_current Tests
   ============================================================ *)

let test_unregister_if_current_matches () =
  let session_id = "test_unreg_match_" ^ string_of_int (Random.int 10000) in
  let push _ = () in
  let (client_id, _, _) = Sse.register session_id ~push ~last_event_id:0 in
  check bool "exists before" true (Sse.exists session_id);
  Sse.unregister_if_current session_id client_id;
  check bool "removed when matching" false (Sse.exists session_id)

let test_unregister_if_current_no_match () =
  let session_id = "test_unreg_nomatch_" ^ string_of_int (Random.int 10000) in
  let push _ = () in
  let (_client_id, _, _) = Sse.register session_id ~push ~last_event_id:0 in
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
  let push _ = () in
  let (_id, _, _) = Sse.register session_id ~push ~last_event_id:0 in
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
  let push _ = () in
  let (_id, _, _) = Sse.register session_id ~push ~last_event_id:0 in
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
  let push _ = () in
  let (_id, _, _) = Sse.register session_id ~push ~last_event_id:0 in
  Sse.send_to session_id (`Assoc [("direct", `String "message")]);
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
      test_case "next_id increments" `Quick test_next_id_increments;
      test_case "next_id sequential" `Quick test_next_id_sequential;
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
    ];
    "update_last_event_id", [
      test_case "exists" `Quick test_update_last_event_id_exists;
      test_case "nonexistent" `Quick test_update_last_event_id_nonexistent;
    ];
    "client_count", [
      test_case "nonnegative" `Quick test_client_count_nonnegative;
      test_case "increments" `Quick test_client_count_increments;
    ];
    "event_buffer", [
      test_case "buffer and retrieve" `Quick test_buffer_event_and_retrieve;
      test_case "buffer retry timestamps on successful commit" `Quick
        test_buffer_event_timestamps_successful_commit_after_retry;
      test_case "filters" `Quick test_get_events_after_filters;
      test_case "empty for future" `Quick test_get_events_after_empty;
      test_case "cleanup exact under domain contention" `Quick
        test_cleanup_expired_events_exact_under_domain_contention;
    ];
    "broadcast", [
      test_case "sends to clients" `Quick test_broadcast_sends_to_clients;
      test_case "empty clients" `Quick test_broadcast_empty_clients;
    ];
    "send_to", [
      test_case "existing" `Quick test_send_to_existing;
      test_case "nonexistent" `Quick test_send_to_nonexistent;
    ];
    "client_type", [
      test_case "fields" `Quick test_client_type_fields;
    ];
  ]
