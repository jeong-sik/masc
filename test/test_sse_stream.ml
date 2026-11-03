(** Tests for per-session Eio.Stream broadcast in Sse module.

    Verifies that [broadcast] pushes events into per-client streams
    and that [pop]/[try_pop] drain them correctly.  All tests run
    inside [Eio_main.run] to exercise the stream path (not the
    direct-push fallback). *)

open Masc

module U = Yojson.Safe.Util

let reset () = ignore (Sse.close_all_clients ())

let _dummy_push _s = ()

let jsonrpc_notification method_name =
  `Assoc [ ("jsonrpc", `String "2.0"); ("method", `String method_name) ]

let test_data_payload_of_frame () =
  Alcotest.(check (result string reject))
    "optional space and CRLF"
    (Ok "first\nsecond")
    (Sse.data_payload_of_frame "id: 7\r\ndata:first\r\ndata: second\r\n\r\n");
  Alcotest.(check bool)
    "bare JSON rejected"
    true
    (match Sse.data_payload_of_frame "{\"type\":\"event\"}" with
     | Error Sse.Missing_data_payload -> true
     | Ok _ -> false)

let test_format_event_preserves_multiline_data () =
  match Sse.data_payload_of_frame (Sse.format_event ~id:7 "first\nsecond") with
  | Ok payload -> Alcotest.(check string) "multiline data payload" "first\nsecond" payload
  | Error Sse.Missing_data_payload ->
      Alcotest.fail "format_event emitted a frame without a data field"

let register_exn ~auth ?kind ?on_disconnect ?observer_instance_id session_id ~last_event_id =
  (* Pre-create the MCP session so registration validates an existing
     session rather than auto-bootstrapping one (security/sse-auth-validation). *)
  let (_ : Session.McpSessionStore.mcp_session) =
    Session.McpSessionStore.get_or_create ~id:session_id ()
  in
  match Sse.register ?kind ?on_disconnect ?observer_instance_id ~auth session_id ~last_event_id with
  | Ok result -> result
  | Error e ->
      Alcotest.fail
        (Printf.sprintf "Sse.register failed: %s"
           (Sse.registration_error_to_string e))

(* Both old mailboxes overflow in one broadcast. Removing the first wakes its
   transport, which reconnects the second session before its old failure is
   handled. That old failure must not remove the new client. *)
let test_failed_broadcast_keeps_reconnected_successor ~auth () =
  reset ();
  let successor_session = "overflow-race-a" in
  let first_session = "overflow-race-z" in
  let reconnected = ref false in
  Fun.protect
    ~finally:(fun () -> List.iter Sse.unregister [first_session; successor_session])
    (fun () ->
      ignore (register_exn ~auth ~kind:Observer successor_session ~last_event_id:0);
      ignore (register_exn ~auth ~kind:Observer first_session ~last_event_id:0
        ~on_disconnect:(fun () ->
          ignore (register_exn ~auth ~kind:Observer successor_session ~last_event_id:0);
          reconnected := true));
      (* The configured stream capacity is clamped to at most 1024. *)
      for _ = 0 to 1024 do
        if not !reconnected then Sse.broadcast_to Observers (`Assoc ["type", `String "fill"])
      done;
      Alcotest.(check bool) "old transport reconnected its peer" true !reconnected;
      Alcotest.(check bool) "the replacement remains registered" true (Sse.exists successor_session);
      Sse.broadcast_to Observers (`Assoc ["type", `String "after-reconnect"]);
      Alcotest.(check bool) "the replacement receives later events" true
        (Option.is_some (Sse.try_pop successor_session)))
;;

(* ============================================================
   pop / try_pop
   ============================================================ *)

let test_try_pop_empty () =
  reset ();
  let result = Sse.try_pop "nonexistent" in
  Alcotest.(check bool) "None for missing session" true (result = None)

let test_try_pop_no_events ~auth () =
  reset ();
  ignore (register_exn ~auth "s-pop-empty" ~last_event_id:0);
  let result = Sse.try_pop "s-pop-empty" in
  Alcotest.(check bool) "None when stream empty" true (result = None);
  Sse.unregister "s-pop-empty"

let test_broadcast_popable ~auth () =
  reset ();
  ignore (register_exn ~auth ~kind:Observer "s-pop-bc" ~last_event_id:0);
  Sse.broadcast (`Assoc [("key", `String "val")]);
  let ev = Sse.try_pop "s-pop-bc" in
  Alcotest.(check bool) "got event from stream" true (ev <> None);
  (* Verify no more events queued *)
  let ev2 = Sse.try_pop "s-pop-bc" in
  Alcotest.(check bool) "no more events" true (ev2 = None);
  Sse.unregister "s-pop-bc"

let test_broadcast_multiple_clients_streams ~auth () =
  reset ();
  ignore (register_exn ~auth ~kind:Observer "s-mc-1" ~last_event_id:0);
  ignore (register_exn ~auth ~kind:Observer "s-mc-2" ~last_event_id:0);
  ignore (register_exn ~auth ~kind:Observer "s-mc-3" ~last_event_id:0);
  Sse.broadcast (`Assoc [("multi", `Bool true)]);
  let got1 = Sse.try_pop "s-mc-1" in
  let got2 = Sse.try_pop "s-mc-2" in
  let got3 = Sse.try_pop "s-mc-3" in
  Alcotest.(check bool) "client 1 got event" true (got1 <> None);
  Alcotest.(check bool) "client 2 got event" true (got2 <> None);
  Alcotest.(check bool) "client 3 got event" true (got3 <> None);
  Sse.unregister "s-mc-1";
  Sse.unregister "s-mc-2";
  Sse.unregister "s-mc-3"

let test_send_to_popable ~auth () =
  reset ();
  let original_buffer = Sse.event_buffer_events_for_test () in
  Fun.protect
    ~finally:(fun () ->
      Sse.unregister "s-st-1";
      Sse.unregister "s-st-2";
      Sse.set_event_buffer_for_test original_buffer)
    (fun () ->
      Sse.set_event_buffer_for_test [];
      ignore (register_exn ~auth "s-st-1" ~last_event_id:0);
      ignore (register_exn ~auth "s-st-2" ~last_event_id:0);
      let before_id = Sse.current_id () in
      Sse.send_to "s-st-1" (jsonrpc_notification "notifications/test");
      let got1 = Sse.try_pop "s-st-1" in
      let got2 = Sse.try_pop "s-st-2" in
      Alcotest.(check bool) "target got event" true (got1 <> None);
      Alcotest.(check bool) "other did not" true (got2 = None);
      Alcotest.(check int) "target replays targeted event" 1
        (List.length
           ((Sse.replay_after_for_session ~session_id:"s-st-1"
              ~kind:Agent_stream before_id).Sse.deliveries));
      Alcotest.(check int) "other session cannot replay targeted event" 0
        (List.length
           ((Sse.replay_after_for_session ~session_id:"s-st-2"
              ~kind:Agent_stream before_id).Sse.deliveries));
      Alcotest.(check int) "observer cannot replay targeted event" 0
        (List.length
           ((Sse.replay_after_for_session ~session_id:"s-st-1"
              ~kind:Observer before_id).Sse.deliveries)))

(* The replay filter reads the delivery's parsed payload rather than parsing
   the frame text again. Both must reach the same verdict: a JSON-RPC
   broadcast replays into an Agent_stream session, anything else does not. *)
let test_agent_stream_replay_filters_non_jsonrpc ~auth () =
  reset ();
  let original_buffer = Sse.event_buffer_events_for_test () in
  Fun.protect
    ~finally:(fun () ->
      Sse.unregister "s-replay-filter";
      Sse.set_event_buffer_for_test original_buffer)
    (fun () ->
      Sse.set_event_buffer_for_test [];
      ignore (register_exn ~auth ~kind:Agent_stream "s-replay-filter" ~last_event_id:0);
      let before_id = Sse.current_id () in
      Sse.broadcast (jsonrpc_notification "notifications/replay_test");
      Sse.broadcast (`Assoc [ ("type", `String "activity"); ("detail", `String "not jsonrpc") ]);
      let replayed =
        (Sse.replay_after_for_session ~session_id:"s-replay-filter"
          ~kind:Agent_stream before_id).Sse.deliveries
      in
      Alcotest.(check int) "only the jsonrpc broadcast replays" 1 (List.length replayed);
      Alcotest.(check int) "an observer replays both" 2
        (List.length
           ((Sse.replay_after_for_session ~session_id:"s-replay-filter"
              ~kind:Observer before_id).Sse.deliveries)))

let test_pop_blocks_then_receives ~auth () =
  reset ();
  ignore (register_exn ~auth ~kind:Observer "s-block" ~last_event_id:0);
  (* pop in a sub-fiber, broadcast from main fiber *)
  Eio.Fiber.both
    (fun () ->
      let ev = Sse.pop "s-block" in
      Alcotest.(check bool) "pop returned Some" true (ev <> None))
    (fun () ->
      (* Small yield so the pop fiber starts waiting *)
      Eio.Fiber.yield ();
      Sse.broadcast (`Assoc [("wakeup", `Bool true)]));
  Sse.unregister "s-block"

(* After a restart the counter starts again at 0 while the MCP session is
   restored, so a reconnecting client can carry a cursor far above it. A new
   event always gets an id above any cursor this process handed out, so such
   a cursor cannot mean "already seen"; the client still receives it. *)
let test_a_cursor_from_an_earlier_process_does_not_hold_back_events ~auth () =
  reset ();
  ignore (register_exn ~auth ~kind:Observer "s-earlier-process" ~last_event_id:999_999_999);
  Sse.broadcast (`Assoc [("after_restart", `Bool true)]);
  let ev = Sse.try_pop "s-earlier-process" in
  Alcotest.(check bool) "the new event arrives" true (ev <> None);
  Sse.unregister "s-earlier-process"

let test_broadcast_event_contains_data ~auth () =
  reset ();
  ignore (register_exn ~auth ~kind:Observer "s-data" ~last_event_id:0);
  Sse.broadcast (`Assoc [("payload", `Int 42)]);
  match Sse.try_pop "s-data" with
  | None -> Alcotest.fail "expected an event"
  | Some ev ->
    (* SSE format: "id: N\nevent: message\ndata: {...}\n\n" *)
    Alcotest.(check bool) "contains data:" true
      (String.length ev > 0 &&
       let has_data = ref false in
       String.split_on_char '\n' ev
       |> List.iter (fun line ->
         if String.length line >= 5 && String.sub line 0 5 = "data:" then
           has_data := true);
       !has_data);
    Sse.unregister "s-data"

(* ============================================================
   broadcast_to targeting (session_kind separation)
   ============================================================ *)

let test_broadcast_to_observers_only ~auth () =
  reset ();
  ignore (register_exn ~auth ~kind:Observer "s-obs" ~last_event_id:0);
  ignore (register_exn ~auth ~kind:Agent_stream "s-workspace" ~last_event_id:0);
  Sse.broadcast_to Observers (`Assoc [("target", `String "observers")]);
  let got_obs = Sse.try_pop "s-obs" in
  let got_workspace = Sse.try_pop "s-workspace" in
  Alcotest.(check bool) "observer got event" true (got_obs <> None);
  Alcotest.(check bool) "agent_stream did not" true (got_workspace = None);
  Sse.unregister "s-obs";
  Sse.unregister "s-workspace"

let test_broadcast_to_all ~auth () =
  reset ();
  ignore (register_exn ~auth ~kind:Observer "s-all-obs" ~last_event_id:0);
  ignore (register_exn ~auth ~kind:Agent_stream "s-all-workspace" ~last_event_id:0);
  Sse.broadcast_to All (jsonrpc_notification "notifications/test");
  let got_obs = Sse.try_pop "s-all-obs" in
  let got_workspace = Sse.try_pop "s-all-workspace" in
  Alcotest.(check bool) "observer got event" true (got_obs <> None);
  Alcotest.(check bool) "agent_stream got event" true (got_workspace <> None);
  Sse.unregister "s-all-obs";
  Sse.unregister "s-all-workspace"

let test_broadcast_equals_broadcast_to_all ~auth () =
  reset ();
  ignore (register_exn ~auth ~kind:Observer "s-eq-obs" ~last_event_id:0);
  ignore (register_exn ~auth ~kind:Agent_stream "s-eq-workspace" ~last_event_id:0);
  (* broadcast (no target) should reach everyone, same as broadcast_to All *)
  Sse.broadcast (jsonrpc_notification "notifications/test");
  let got_obs = Sse.try_pop "s-eq-obs" in
  let got_workspace = Sse.try_pop "s-eq-workspace" in
  Alcotest.(check bool) "observer got broadcast" true (got_obs <> None);
  Alcotest.(check bool) "agent_stream got broadcast" true (got_workspace <> None);
  Sse.unregister "s-eq-obs";
  Sse.unregister "s-eq-workspace"

let test_broadcast_all_excludes_presence_sessions ~auth () =
  reset ();
  ignore (register_exn ~auth ~kind:Presence "s-all-presence" ~last_event_id:0);
  ignore (register_exn ~auth ~kind:Observer "s-all-observer-only" ~last_event_id:0);
  Sse.broadcast (`Assoc [("durable", `Bool true)]);
  let got_presence = Sse.try_pop "s-all-presence" in
  let got_observer = Sse.try_pop "s-all-observer-only" in
  Alcotest.(check bool) "presence did not get durable all" true
    (got_presence = None);
  Alcotest.(check bool) "observer got durable all" true (got_observer <> None);
  Sse.unregister "s-all-presence";
  Sse.unregister "s-all-observer-only"

let test_broadcast_presence_is_live_only ~auth () =
  reset ();
  let original_buffer = Sse.event_buffer_events_for_test () in
  Fun.protect
    ~finally:(fun () ->
      Sse.set_event_buffer_for_test original_buffer;
      Sse.unregister "s-presence";
      Sse.unregister "s-observer")
    (fun () ->
      Sse.set_event_buffer_for_test [];
      ignore (register_exn ~auth ~kind:Presence "s-presence" ~last_event_id:0);
      ignore (register_exn ~auth ~kind:Observer "s-observer" ~last_event_id:0);
      let before_id = Sse.current_id () in
      Sse.broadcast_presence (`Assoc [("type", `String "keeper_heartbeat")]);
      let got_presence = Sse.try_pop "s-presence" in
      let got_observer = Sse.try_pop "s-observer" in
      Alcotest.(check bool) "presence got event" true (got_presence <> None);
      Alcotest.(check bool) "observer did not get presence" true
        (got_observer = None);
      (match got_presence with
       | Some event ->
           Alcotest.(check bool) "presence event type" true
             (List.exists
                (String.equal "event: presence")
                (String.split_on_char '\n' event))
       | None -> Alcotest.fail "expected presence event");
      Alcotest.(check int) "presence not replay buffered" 0
        (List.length (Sse.get_events_after_for_test before_id)))

(* [broadcast_is_unobservable] short-circuits a presence broadcast before it
   allocates an event id, so [current_id] is what says whether the skip fired.
   The two cases are opposite failures: skipping with a presence session
   registered loses a delivery and shows up only as "presence went quiet",
   while never skipping means the fanout mutex keeps paying for a broadcast
   nobody can read. *)
let test_presence_broadcast_skipped_without_a_presence_session ~auth () =
  reset ();
  Fun.protect
    ~finally:(fun () -> Sse.unregister "s-skip-observer")
    (fun () ->
      ignore (register_exn ~auth ~kind:Observer "s-skip-observer" ~last_event_id:0);
      let before_id = Sse.current_id () in
      Sse.broadcast_presence (`Assoc [("type", `String "keeper_heartbeat")]);
      Alcotest.(check int) "no event id consumed" before_id (Sse.current_id ());
      Alcotest.(check bool) "observer got nothing" true
        (Sse.try_pop "s-skip-observer" = None))

let test_presence_broadcast_not_skipped_with_a_presence_session ~auth () =
  reset ();
  Fun.protect
    ~finally:(fun () ->
      Sse.unregister "s-noskip-presence";
      Sse.unregister "s-noskip-observer")
    (fun () ->
      ignore (register_exn ~auth ~kind:Presence "s-noskip-presence" ~last_event_id:0);
      ignore (register_exn ~auth ~kind:Observer "s-noskip-observer" ~last_event_id:0);
      let before_id = Sse.current_id () in
      Sse.broadcast_presence (`Assoc [("type", `String "keeper_heartbeat")]);
      Alcotest.(check bool) "event id advanced" true (Sse.current_id () > before_id);
      Alcotest.(check bool) "presence session got the event" true
        (Sse.try_pop "s-noskip-presence" <> None);
      Alcotest.(check bool) "observer still excluded" true
        (Sse.try_pop "s-noskip-observer" = None))

let test_non_jsonrpc_broadcast_does_not_reach_agent_stream_sessions ~auth () =
  reset ();
  let before_id = Sse.current_id () in
  ignore (register_exn ~auth ~kind:Observer "s-nonjson-obs" ~last_event_id:0);
  ignore (register_exn ~auth ~kind:Agent_stream "s-nonjson-workspace" ~last_event_id:0);
  Sse.broadcast (`Assoc [("type", `String "keeper_tool_call")]);
  let got_obs = Sse.try_pop "s-nonjson-obs" in
  let got_workspace = Sse.try_pop "s-nonjson-workspace" in
  Alcotest.(check bool) "observer got dashboard event" true (got_obs <> None);
  Alcotest.(check bool) "agent_stream skipped non-JSON-RPC" true
    (got_workspace = None);
  Alcotest.(check int) "observer replay keeps dashboard event" 1
    (List.length
       ((Sse.replay_after_for_session ~session_id:"s-nonjson-obs"
          ~kind:Observer before_id).Sse.deliveries));
  Alcotest.(check int)
    "agent_stream replay skips non-JSON-RPC"
    0
    (List.length
       ((Sse.replay_after_for_session ~session_id:"s-nonjson-workspace"
          ~kind:Agent_stream before_id).Sse.deliveries));
  Sse.unregister "s-nonjson-obs";
  Sse.unregister "s-nonjson-workspace"

let test_register_defaults_to_agent_stream ~auth () =
  reset ();
  (* Register without explicit kind *)
  ignore (register_exn ~auth "s-default" ~last_event_id:0);
  Alcotest.(check int) "default kind is Agent_stream" 1
    (Sse.client_count_by_kind Agent_stream);
  Alcotest.(check int) "default kind is not Observer" 0
    (Sse.client_count_by_kind Observer);
  (* Should not receive Observers-targeted broadcast *)
  Sse.broadcast_to Observers (`Assoc [("observer_only", `Bool true)]);
  let got2 = Sse.try_pop "s-default" in
  Alcotest.(check bool) "default does not receive Observers" true (got2 = None);
  Sse.unregister "s-default"

let test_idle_session_is_not_hot ~auth () =
  reset ();
  ignore (register_exn ~auth ~kind:Observer "s-idle-hot-probe" ~last_event_id:0);
  Fun.protect
    ~finally:(fun () -> Sse.unregister "s-idle-hot-probe")
    (fun () ->
      Sse.sync_transport_snapshot ();
      let hot_sessions =
        Transport_metrics.transport_health_json ()
        |> U.member "sse"
        |> U.member "hot_sessions"
        |> U.to_list
      in
      Alcotest.(check int) "idle sessions are not hot" 0 (List.length hot_sessions))

let queue_snapshot () =
  Transport_metrics.transport_health_json () |> U.member "sse"

let check_queue ~label ~max_depth ~hot_count =
  let sse = queue_snapshot () in
  Alcotest.(check int) (label ^ " max depth") max_depth
    (sse |> U.member "queue_max_depth" |> U.to_int);
  Alcotest.(check int) (label ^ " hot count") hot_count
    (sse |> U.member "hot_sessions" |> U.to_list |> List.length)

let test_queue_metrics_follow_delivery ~auth () =
  reset ();
  let _, stream, _ =
    register_exn ~auth ~kind:Observer "queue-metrics-drain" ~last_event_id:0 in
  Fun.protect ~finally:(fun () -> Sse.unregister "queue-metrics-drain") (fun () ->
    Sse.broadcast_to Observers (`Assoc ["type", `String "queued"]);
    check_queue ~label:"enqueued" ~max_depth:1 ~hot_count:1;
    Alcotest.(check bool) "nonblocking take received the event" true
      (Option.is_some (Sse.take_delivery_nonblocking stream));
    check_queue ~label:"after nonblocking take" ~max_depth:0 ~hot_count:0;
    Sse.broadcast_to Observers (`Assoc ["type", `String "queued again"]);
    ignore (Sse.take_delivery stream);
    check_queue ~label:"after blocking take" ~max_depth:0 ~hot_count:0)

let test_retired_stream_cannot_change_successor_metrics ~auth () =
  reset ();
  let session_id = "queue-metrics-reconnect" in
  let old_id, old_stream, _ =
    register_exn ~auth ~kind:Observer session_id ~last_event_id:0 in
  Fun.protect ~finally:(fun () -> Sse.unregister session_id) (fun () ->
    Sse.broadcast_to Observers (`Assoc ["type", `String "old"]);
    let new_id, new_stream, _ =
      register_exn ~auth ~kind:Observer session_id ~last_event_id:0 in
    Alcotest.(check bool) "replacement has a new owner" true (old_id <> new_id);
    Sse.broadcast_to Observers (`Assoc ["type", `String "new"]);
    check_queue ~label:"successor queued" ~max_depth:1 ~hot_count:1;
    ignore (Sse.take_delivery old_stream);
    check_queue ~label:"after retired stream drains" ~max_depth:1 ~hot_count:1;
    ignore (Sse.take_delivery new_stream);
    check_queue ~label:"after successor drains" ~max_depth:0 ~hot_count:0)

let test_concurrent_enqueue_and_drain_metrics ~auth () =
  reset ();
  let session_id = "queue-metrics-domains" in
  let _, stream, _ =
    register_exn ~auth ~kind:Observer session_id ~last_event_id:0 in
  let produced = Atomic.make 0 and acknowledged = Atomic.make 0 in
  let stop = Atomic.make false and failure = Atomic.make None in
  let worker = Domain.spawn (fun () ->
    try
      for n = 1 to 200 do
        if not (Atomic.get stop) then begin
          Sse.broadcast_to Observers (`Assoc ["type", `String "domain-race"]);
          Atomic.set produced n;
          while Atomic.get acknowledged < n && not (Atomic.get stop) do
            Domain.cpu_relax ()
          done
        end
      done
    with exn -> Atomic.set failure (Some exn)) in
  Fun.protect
    ~finally:(fun () -> Atomic.set stop true; Domain.join worker; Sse.unregister session_id)
    (fun () ->
      let deadline = Unix.gettimeofday () +. 30.0 in
      let check_worker () =
        (match Atomic.get failure with None -> () | Some exn -> raise exn);
        if Unix.gettimeofday () > deadline then Alcotest.fail "domain race timed out";
        Domain.cpu_relax () in
      for n = 1 to 200 do
        let rec take () =
          match Sse.take_delivery_nonblocking stream with
          | Some _ -> ()
          | None -> check_worker (); take () in
        take ();
        while Atomic.get produced < n do check_worker () done;
        check_queue ~label:"concurrent drain" ~max_depth:0 ~hot_count:0;
        Atomic.set acknowledged n
      done)

let test_observer_instance_authority ~auth () =
  reset ();
  let original_buffer = Sse.event_buffer_events_for_test () in
  let base = auth.Sse.config in
  let foreign_base = Filename.concat base "observer-scope-foreign" in
  Fs_compat.mkdir_p (Filename.concat foreign_base Common.masc_dirname);
  let foreign_auth = Masc_test_deps.make_sse_auth foreign_base "scope-agent" in
  let authority = Sse.runtime_authority_exn ~base_path:base in
  let foreign_authority = Sse.runtime_authority_exn ~base_path:foreign_base in
  let sessions = ["scope-old"; "scope-current"; "scope-unbound"; "scope-foreign"; "scope-agent"] in
  Fun.protect
    ~finally:(fun () -> List.iter Sse.unregister sessions; Sse.set_event_buffer_for_test original_buffer)
    (fun () ->
      Sse.set_event_buffer_for_test [];
      ignore (register_exn ~auth ~kind:Observer ~observer_instance_id:"old" "scope-old" ~last_event_id:0);
      ignore (register_exn ~auth ~kind:Observer ~observer_instance_id:"current" "scope-current" ~last_event_id:0);
      ignore (register_exn ~auth ~kind:Observer "scope-unbound" ~last_event_id:0);
      ignore (register_exn ~auth:foreign_auth ~kind:Observer ~observer_instance_id:"old"
                "scope-foreign" ~last_event_id:0);
      ignore (register_exn ~auth ~kind:Agent_stream ~observer_instance_id:"old"
                "scope-agent" ~last_event_id:0);
      let before = Sse.current_id () in
      let scope = Sse.observer_scope ~runtime_authority:authority ~instance_id:"old" in
      Sse.broadcast_to (Sse.Scoped_runtime_observers scope) (`Assoc ["type", `String "scope-change"]);
      let received id = Option.is_some (Sse.try_pop id) in
      Alcotest.(check (list bool)) "only the exact instance receives the live event"
        [true; false; false; false; false] (List.map received sessions);
      let replay ?runtime_authority ?observer_instance_id () =
        (Sse.replay_after_for_session ?runtime_authority ?observer_instance_id
           ~session_id:"scope-replay" ~kind:Observer before).deliveries in
      Alcotest.(check int) "matching instance can replay" 1
        (List.length (replay ~runtime_authority:authority ~observer_instance_id:"old" ()));
      Alcotest.(check int) "replacement instance cannot replay" 0
        (List.length (replay ~runtime_authority:authority ~observer_instance_id:"current" ()));
      Alcotest.(check int) "unbound instance cannot replay" 0
        (List.length (replay ~runtime_authority:authority ()));
      Alcotest.(check int) "instance without workspace authority cannot replay" 0
        (List.length (replay ~observer_instance_id:"old" ()));
      Alcotest.(check int) "another workspace cannot replay" 0
        (List.length (replay ~runtime_authority:foreign_authority ~observer_instance_id:"old" ()));
      Alcotest.(check int) "agent streams cannot replay Observer events" 0
        (List.length (Sse.replay_after_for_session ~runtime_authority:authority
          ~observer_instance_id:"old" ~session_id:"scope-agent" ~kind:Agent_stream before).deliveries);
      Sse.broadcast_to (Sse.Runtime_observers authority) (`Assoc ["type", `String "workspace-change"]);
      Alcotest.(check (list bool)) "workspace-only events still reach matching observers"
        [true; true; true; false; false] (List.map received sessions))
;;

let test_waiting_inventory_observer_authority ~auth () =
  reset ();
  let base_a = auth.Sse.config in
  let base_b = Filename.concat base_a "waiting-inventory-beta" in
  Fs_compat.mkdir_p (Filename.concat base_b Common.masc_dirname);
  let auth_b = Masc_test_deps.make_sse_auth base_b "waiting-inventory-agent" in
  let authority_a = Sse.runtime_authority_exn ~base_path:base_a in
  let authority_b = Sse.runtime_authority_exn ~base_path:base_b in
  let before = Sse.current_id () in
  ignore (register_exn ~auth ~kind:Sse.Observer "waiting-observer-a" ~last_event_id:before);
  ignore (register_exn ~auth:auth_b ~kind:Sse.Observer "waiting-observer-b" ~last_event_id:before);
  Fun.protect
    ~finally:(fun () -> List.iter Sse.unregister [ "waiting-observer-a"; "waiting-observer-b" ])
    (fun () ->
      Keeper_waiting_inventory_broadcast.changed ~base_path:base_a
        ~keeper_name:"alpha" ~source:Event_queue;
      Alcotest.(check bool) "matching observer receives the event" true
        (Option.is_some (Sse.try_pop "waiting-observer-a"));
      Alcotest.(check bool) "other workspace receives no event" true
        (Option.is_none (Sse.try_pop "waiting-observer-b"));
      let replay authority session_id =
        (Sse.replay_after_for_session ~runtime_authority:authority
          ~session_id ~kind:Sse.Observer before).deliveries in
      Alcotest.(check int) "matching observer can replay" 1
        (List.length (replay authority_a "waiting-observer-a"));
      Alcotest.(check int) "other observer cannot replay" 0
        (List.length (replay authority_b "waiting-observer-b"));
      Alcotest.(check int) "unbound observer cannot replay" 0
        (List.length
          (Sse.replay_after_for_session ~session_id:"waiting-unbound"
             ~kind:Sse.Observer before).deliveries))
;;

let test_keeper_composite_authority ~auth () =
  reset ();
  let original_buffer = Sse.event_buffer_events_for_test () in
  let base_a = auth.Sse.config in
  let base_b = Filename.concat base_a "composite-beta" in
  Fs_compat.mkdir_p (Filename.concat base_b Common.masc_dirname);
  let auth_b = Masc_test_deps.make_sse_auth base_b "composite-agent" in
  let authority_a = Sse.runtime_authority_exn ~base_path:base_a in
  let authority_b = Sse.runtime_authority_exn ~base_path:base_b in
  let meta =
    match Masc_test_deps.meta_of_json_fixture
      (`Assoc [ "name", `String "alpha"; "trace_id", `String "trace-alpha" ]) with
    | Ok meta -> meta
    | Error error -> Alcotest.fail error in
  ignore (Keeper_registry.register_offline ~base_path:base_a "alpha" meta);
  ignore (Keeper_registry.register_offline ~base_path:base_b "alpha" meta);
  let before = Sse.current_id () in
  let sessions = [ "composite-observer-a"; "composite-observer-b";
                   "composite-presence-a"; "composite-presence-b" ] in
  let subscribers = [ "composite-external-a"; "composite-external-b";
                      "composite-external-unscoped" ] in
  let external_a = ref [] and external_b = ref [] and unscoped = ref [] in
  Fun.protect
    ~finally:(fun () ->
      List.iter Sse.unsubscribe_external subscribers;
      List.iter Sse.unregister sessions;
      Keeper_registry.For_testing.unregister ~base_path:base_a "alpha";
      Keeper_registry.For_testing.unregister ~base_path:base_b "alpha";
      Sse.set_event_buffer_for_test original_buffer)
    (fun () ->
      Sse.set_event_buffer_for_test [];
      ignore (register_exn ~auth ~kind:Observer "composite-observer-a" ~last_event_id:before);
      ignore (register_exn ~auth:auth_b ~kind:Observer "composite-observer-b" ~last_event_id:before);
      ignore (register_exn ~auth ~kind:Presence "composite-presence-a" ~last_event_id:before);
      ignore (register_exn ~auth:auth_b ~kind:Presence "composite-presence-b" ~last_event_id:before);
      Sse.subscribe_external ~runtime_authority:authority_a ~id:"composite-external-a"
        ~callback:(fun event -> external_a := event :: !external_a) ();
      Sse.subscribe_external ~runtime_authority:authority_b ~id:"composite-external-b"
        ~callback:(fun event -> external_b := event :: !external_b) ();
      Sse.subscribe_external ~id:"composite-external-unscoped"
        ~callback:(fun event -> unscoped := event :: !unscoped) ();
      let start base_path =
        Keeper_registry.mark_turn_started
          ~observation_token:(Keeper_turn_observation_token.fresh ())
          ~base_path ~wake:Keeper_registry.Proactive_tick "alpha" in
      let check_composite session ~presence =
        let frame = match Sse.try_pop session with
          | Some frame -> frame
          | None -> Alcotest.failf "%s received no event" session in
        let payload = match Sse.data_payload_of_frame frame with
          | Ok data -> Yojson.Safe.from_string data
          | Error Sse.Missing_data_payload -> Alcotest.failf "%s has no payload" session in
        Alcotest.(check bool) (session ^ " event type") true
          (U.member "type" payload = `String "keeper_composite_changed");
        Alcotest.(check bool) (session ^ " keeper") true
          (U.member "name" payload = `String "alpha");
        Alcotest.(check bool) (session ^ " presence framing") presence
          (List.exists (String.equal "event: presence") (String.split_on_char '\n' frame)) in
      start (Filename.concat base_a Common.masc_dirname);
      check_composite "composite-observer-a" ~presence:false;
      check_composite "composite-presence-a" ~presence:true;
      Alcotest.(check bool) "B observer excludes A" true
        (Option.is_none (Sse.try_pop "composite-observer-b"));
      Alcotest.(check bool) "B presence excludes A" true
        (Option.is_none (Sse.try_pop "composite-presence-b"));
      Alcotest.(check int) "A external receives the durable event once" 1 (List.length !external_a);
      Alcotest.(check int) "B external excludes A" 0 (List.length !external_b);
      Alcotest.(check int) "unscoped external excludes A" 0 (List.length !unscoped);
      start base_b;
      check_composite "composite-observer-b" ~presence:false;
      check_composite "composite-presence-b" ~presence:true;
      Alcotest.(check bool) "A observer excludes B" true
        (Option.is_none (Sse.try_pop "composite-observer-a"));
      Alcotest.(check bool) "A presence excludes B" true
        (Option.is_none (Sse.try_pop "composite-presence-a"));
      Alcotest.(check int) "B external receives the durable event once" 1 (List.length !external_b);
      Alcotest.(check int) "A external excludes B" 1 (List.length !external_a);
      Alcotest.(check int) "unscoped external excludes both" 0 (List.length !unscoped);
      let replay authority kind =
        (Sse.replay_after_for_session ~runtime_authority:authority
          ~session_id:"composite-replay" ~kind before).deliveries in
      Alcotest.(check int) "A observer replays only A" 1 (List.length (replay authority_a Observer));
      Alcotest.(check int) "B observer replays only B" 1 (List.length (replay authority_b Observer));
      Alcotest.(check int) "presence events are not replayed" 0 (List.length (replay authority_a Presence));
      Alcotest.(check int) "only durable events are buffered" 2
        (List.length (Sse.get_events_after_for_test before));
      Alcotest.(check int) "unbound observer cannot replay" 0
        (List.length (Sse.replay_after_for_session ~session_id:"composite-unbound"
          ~kind:Observer before).deliveries);
      Sse.unregister "composite-presence-a";
      let last_id = Sse.current_id () in
      Sse.broadcast_presence_to_runtime authority_a (`Assoc [ "type", `String "probe" ]);
      Alcotest.(check int) "foreign presence alone does not make A observable" last_id
        (Sse.current_id ());
      Alcotest.(check bool) "foreign presence receives no A probe" true
        (Option.is_none (Sse.try_pop "composite-presence-b"));
      Alcotest.(check bool) "generic broadcast cannot make scoped presence durable" true
        (match Sse.broadcast_to (Sse.Runtime_presence authority_a) (`Assoc []) with
         | () -> false
         | exception Invalid_argument _ -> true))
;;

let test_runtime_observer_authority ~auth () =
  reset ();
  let base_a = auth.Sse.config in
  let base_b = Filename.concat base_a "runtime-beta" in
  Fs_compat.mkdir_p (Filename.concat base_b Common.masc_dirname);
  let auth_b = Masc_test_deps.make_sse_auth base_b "sse-same-agent" in
  let authority_a = Sse.runtime_authority_exn ~base_path:base_a in
  let authority_b = Sse.runtime_authority_exn ~base_path:base_b in
  Alcotest.(check bool) "canonical .masc spelling uses the same runtime authority" true
    (Sse.equal_runtime_authority authority_a
      (Sse.runtime_authority_exn ~base_path:(Filename.concat base_a Common.masc_dirname)));
  let first_id = Sse.current_id () in
  ignore (register_exn ~auth ~kind:Sse.Observer "runtime-observer-a" ~last_event_id:first_id);
  ignore (register_exn ~auth:auth_b ~kind:Sse.Observer "runtime-observer-b" ~last_event_id:first_id);
  let external_a = ref [] and external_b = ref [] and unscoped = ref [] in
  Sse.subscribe_external ~runtime_authority:authority_a ~id:"runtime-external-a"
    ~callback:(fun event -> external_a := event :: !external_a) ();
  Sse.subscribe_external ~runtime_authority:authority_b ~id:"runtime-external-b"
    ~callback:(fun event -> external_b := event :: !external_b) ();
  Sse.subscribe_external ~id:"runtime-external-unscoped"
    ~callback:(fun event -> unscoped := event :: !unscoped) ();
  Fun.protect ~finally:(fun () ->
    List.iter Sse.unsubscribe_external ["runtime-external-a";"runtime-external-b";"runtime-external-unscoped"];
    List.iter Sse.unregister ["runtime-observer-a";"runtime-observer-b"]) (fun () ->
    let publish base_path text =
      let event = Ag_ui.make_event ~thread_id:"keeper:alpha" ~delta:(Some text)
          Ag_ui.Text_message_content in
      Keeper_chat_broadcast.operation_event ~base_path ~keeper_name:"alpha"
        ~operation_id:"op-X" ~seq:(Some 1) ~event in
    publish base_a "ROOT_A_BODY";
    Alcotest.(check bool) "same-root live SSE receives the operation" true
      (Option.is_some (Sse.try_pop "runtime-observer-a"));
    Alcotest.(check bool) "other-root TUI cannot be sent an invalid journal reference" true
      (Option.is_none (Sse.try_pop "runtime-observer-b"));
    Alcotest.(check int) "same-root external receives body" 1 (List.length !external_a);
    Alcotest.(check int) "other-root external receives no body" 0 (List.length !external_b);
    Alcotest.(check int) "unbound external receives no scoped body" 0 (List.length !unscoped);
    publish base_b "ROOT_B_BODY";
    Alcotest.(check bool) "same keeper/id in B is independent" true
      (Option.is_some (Sse.try_pop "runtime-observer-b"));
    Alcotest.(check bool) "B cannot leak back into A" true
      (Option.is_none (Sse.try_pop "runtime-observer-a"));
    let replay authority id = (Sse.replay_after_for_session ~runtime_authority:authority
      ~session_id:id ~kind:Sse.Observer first_id).deliveries in
    Alcotest.(check int) "A replay contains only A" 1 (List.length (replay authority_a "runtime-observer-a"));
    Alcotest.(check int) "B replay contains only B" 1 (List.length (replay authority_b "runtime-observer-b"));
    Alcotest.(check int) "unbound replay receives no scoped body" 0
      (List.length (Sse.replay_after_for_session ~session_id:"unbound" ~kind:Sse.Observer first_id).deliveries);
    let turn_ref = Ids.Turn_ref.make ~trace_id:"same-turn" ~absolute_turn:1 in
    let autonomous = Keeper_autonomous_stream.create ~base_path:base_a ~keeper_name:"alpha" ~turn_ref in
    Keeper_autonomous_stream.finish autonomous (Completed {reply="done";turn_outcome=Keeper_turn_outcome.Visible_reply});
    Alcotest.(check bool) "autonomous notices reach their runtime" true
      (List.length !external_a > 1);
    Alcotest.(check int) "autonomous notices cannot cross roots" 1 (List.length !external_b);
    Alcotest.(check bool) "autonomous notices do not reach foreign SSE" true
      (Option.is_none (Sse.try_pop "runtime-observer-b"));
    Alcotest.(check int) "autonomous notices do not enter foreign replay" 1
      (List.length (replay authority_b "runtime-observer-b"));
    Alcotest.(check int) "unbound callbacks stay outside runtime traffic" 0 (List.length !unscoped))
;;

let () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let workspace = Masc_test_deps.setup_test_workspace () in
  let auth = Masc_test_deps.make_sse_auth workspace "sse-stream-agent" in
  Fun.protect
    ~finally:(fun () -> Masc_test_deps.cleanup_test_workspace workspace)
    (fun () ->
      Alcotest.run "sse-stream"
        [
          ( "frame_parser",
            [
              Alcotest.test_case "data payload" `Quick
                test_data_payload_of_frame;
              Alcotest.test_case "multiline data framing" `Quick
                test_format_event_preserves_multiline_data;
            ] );
          ( "try_pop",
            [
              Alcotest.test_case "nonexistent session" `Quick test_try_pop_empty;
              Alcotest.test_case "empty stream" `Quick (test_try_pop_no_events ~auth);
            ] );
          ( "broadcast_stream",
            [
              Alcotest.test_case "broadcast popable" `Quick (test_broadcast_popable ~auth);
              Alcotest.test_case "multiple clients" `Quick (test_broadcast_multiple_clients_streams ~auth);
              Alcotest.test_case "a cursor from an earlier process does not hold back events" `Quick
                (test_a_cursor_from_an_earlier_process_does_not_hold_back_events ~auth);
              Alcotest.test_case "event contains data" `Quick (test_broadcast_event_contains_data ~auth);
              Alcotest.test_case "stale failure leaves a reconnected client" `Quick
                (test_failed_broadcast_keeps_reconnected_successor ~auth);
            ] );
          ( "send_to_stream",
            [
              Alcotest.test_case "send_to popable" `Quick (test_send_to_popable ~auth);
              Alcotest.test_case "agent_stream replay filters non-jsonrpc" `Quick
                (test_agent_stream_replay_filters_non_jsonrpc ~auth);
            ] );
          ( "pop_blocking",
            [
              Alcotest.test_case "blocks then receives" `Quick (test_pop_blocks_then_receives ~auth);
            ] );
          ( "broadcast_to_targeting",
            [
              Alcotest.test_case "observer instance live and replay authority" `Quick
                (test_observer_instance_authority ~auth);
              Alcotest.test_case "runtime authority live, replay and external" `Quick
                (test_runtime_observer_authority ~auth);
              Alcotest.test_case "waiting inventory authority live and replay" `Quick
                (test_waiting_inventory_observer_authority ~auth);
              Alcotest.test_case "keeper composite authority live and replay" `Quick
                (test_keeper_composite_authority ~auth);
              Alcotest.test_case "observers only" `Quick (test_broadcast_to_observers_only ~auth);
              Alcotest.test_case "all targets" `Quick (test_broadcast_to_all ~auth);
              Alcotest.test_case "broadcast = broadcast_to All" `Quick (test_broadcast_equals_broadcast_to_all ~auth);
              Alcotest.test_case "broadcast All excludes presence" `Quick (test_broadcast_all_excludes_presence_sessions ~auth);
              Alcotest.test_case "presence live-only" `Quick (test_broadcast_presence_is_live_only ~auth);
              Alcotest.test_case "presence broadcast skipped with no presence session" `Quick
                (test_presence_broadcast_skipped_without_a_presence_session ~auth);
              Alcotest.test_case "presence broadcast delivered with a presence session" `Quick
                (test_presence_broadcast_not_skipped_with_a_presence_session ~auth);
              Alcotest.test_case "non-JSON-RPC skips agent_stream sessions" `Quick
                (test_non_jsonrpc_broadcast_does_not_reach_agent_stream_sessions ~auth);
              Alcotest.test_case "default kind is Agent_stream" `Quick (test_register_defaults_to_agent_stream ~auth);
            ] );
          ( "transport_snapshot",
            [
              Alcotest.test_case "idle session is not hot" `Quick
                (test_idle_session_is_not_hot ~auth);
              Alcotest.test_case "queue metrics follow delivery" `Quick
                (test_queue_metrics_follow_delivery ~auth);
              Alcotest.test_case "retired stream cannot alter successor metrics" `Quick
                (test_retired_stream_cannot_change_successor_metrics ~auth);
              Alcotest.test_case "concurrent enqueue and drain metrics" `Quick
                (test_concurrent_enqueue_and_drain_metrics ~auth);
            ] );
        ])
