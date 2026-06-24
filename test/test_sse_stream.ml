(** Tests for per-session Eio.Stream broadcast in Sse module.

    Verifies that [broadcast] pushes events into per-client streams
    and that [pop]/[try_pop] drain them correctly.  All tests run
    inside [Eio_main.run] to exercise the stream path (not the
    direct-push fallback). *)

open Masc

let reset () = ignore (Sse.close_all_clients ())

let _dummy_push _s = ()

let jsonrpc_notification method_name =
  `Assoc [ ("jsonrpc", `String "2.0"); ("method", `String method_name) ]

let register_exn ~auth ?kind session_id ~last_event_id =
  (* Pre-create the MCP session so registration validates an existing
     session rather than auto-bootstrapping one (security/sse-auth-validation). *)
  let (_ : Session.McpSessionStore.mcp_session) =
    Session.McpSessionStore.get_or_create ~id:session_id ()
  in
  match Sse.register ?kind ~auth session_id ~last_event_id with
  | Ok result -> result
  | Error e ->
      Alcotest.fail
        (Printf.sprintf "Sse.register failed: %s"
           (Sse.registration_error_to_string e))

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
  ignore (register_exn ~auth "s-st-1" ~last_event_id:0);
  ignore (register_exn ~auth "s-st-2" ~last_event_id:0);
  Sse.send_to "s-st-1" (jsonrpc_notification "notifications/test");
  let got1 = Sse.try_pop "s-st-1" in
  let got2 = Sse.try_pop "s-st-2" in
  Alcotest.(check bool) "target got event" true (got1 <> None);
  Alcotest.(check bool) "other did not" true (got2 = None);
  Sse.unregister "s-st-1";
  Sse.unregister "s-st-2"

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

let test_broadcast_skips_already_seen ~auth () =
  reset ();
  (* Register with a high last_event_id so events are skipped *)
  ignore (register_exn ~auth ~kind:Observer "s-skip" ~last_event_id:999_999_999);
  Sse.broadcast (`Assoc [("skip", `Bool true)]);
  let ev = Sse.try_pop "s-skip" in
  Alcotest.(check bool) "skipped (already seen)" true (ev = None);
  Sse.unregister "s-skip"

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

let test_broadcast_to_agent_streams_only ~auth () =
  reset ();
  ignore (register_exn ~auth ~kind:Observer "s-obs2" ~last_event_id:0);
  ignore (register_exn ~auth ~kind:Agent_stream "s-workspace2" ~last_event_id:0);
  Sse.broadcast_to Agent_streams (jsonrpc_notification "notifications/test");
  let got_obs = Sse.try_pop "s-obs2" in
  let got_workspace = Sse.try_pop "s-workspace2" in
  Alcotest.(check bool) "observer did not get event" true (got_obs = None);
  Alcotest.(check bool) "agent_stream got event" true (got_workspace <> None);
  Sse.unregister "s-obs2";
  Sse.unregister "s-workspace2"

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
  let original_buffer = Atomic.get Sse.event_buffer in
  Fun.protect
    ~finally:(fun () ->
      Atomic.set Sse.event_buffer original_buffer;
      Sse.unregister "s-presence";
      Sse.unregister "s-observer")
    (fun () ->
      Atomic.set Sse.event_buffer [];
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
      Alcotest.(check (list string)) "presence not replay buffered" []
        (Sse.get_events_after before_id))

let test_non_jsonrpc_broadcast_does_not_reach_agent_streams ~auth () =
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
    (List.length (Sse.get_events_after_for_kind Observer before_id));
  Alcotest.(check (list string))
    "agent_stream replay skips non-JSON-RPC"
    []
    (Sse.get_events_after_for_kind Agent_stream before_id);
  Sse.unregister "s-nonjson-obs";
  Sse.unregister "s-nonjson-workspace"

let test_register_defaults_to_agent_stream ~auth () =
  reset ();
  (* Register without explicit kind *)
  ignore (register_exn ~auth "s-default" ~last_event_id:0);
  (* Should be Agent_stream: receives Agent_streams-targeted broadcast *)
  Sse.broadcast_to Agent_streams (jsonrpc_notification "notifications/test");
  let got = Sse.try_pop "s-default" in
  Alcotest.(check bool) "default kind is Agent_stream" true (got <> None);
  (* Should not receive Observers-targeted broadcast *)
  Sse.broadcast_to Observers (`Assoc [("observer_only", `Bool true)]);
  let got2 = Sse.try_pop "s-default" in
  Alcotest.(check bool) "default does not receive Observers" true (got2 = None);
  Sse.unregister "s-default"

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
          ( "try_pop",
            [
              Alcotest.test_case "nonexistent session" `Quick test_try_pop_empty;
              Alcotest.test_case "empty stream" `Quick (test_try_pop_no_events ~auth);
            ] );
          ( "broadcast_stream",
            [
              Alcotest.test_case "broadcast popable" `Quick (test_broadcast_popable ~auth);
              Alcotest.test_case "multiple clients" `Quick (test_broadcast_multiple_clients_streams ~auth);
              Alcotest.test_case "skips already seen" `Quick (test_broadcast_skips_already_seen ~auth);
              Alcotest.test_case "event contains data" `Quick (test_broadcast_event_contains_data ~auth);
            ] );
          ( "send_to_stream",
            [
              Alcotest.test_case "send_to popable" `Quick (test_send_to_popable ~auth);
            ] );
          ( "pop_blocking",
            [
              Alcotest.test_case "blocks then receives" `Quick (test_pop_blocks_then_receives ~auth);
            ] );
          ( "broadcast_to_targeting",
            [
              Alcotest.test_case "observers only" `Quick (test_broadcast_to_observers_only ~auth);
              Alcotest.test_case "agent_streams only" `Quick (test_broadcast_to_agent_streams_only ~auth);
              Alcotest.test_case "all targets" `Quick (test_broadcast_to_all ~auth);
              Alcotest.test_case "broadcast = broadcast_to All" `Quick (test_broadcast_equals_broadcast_to_all ~auth);
              Alcotest.test_case "broadcast All excludes presence" `Quick (test_broadcast_all_excludes_presence_sessions ~auth);
              Alcotest.test_case "presence live-only" `Quick (test_broadcast_presence_is_live_only ~auth);
              Alcotest.test_case "non-JSON-RPC skips agent_streams" `Quick
                (test_non_jsonrpc_broadcast_does_not_reach_agent_streams ~auth);
              Alcotest.test_case "default kind is Agent_stream" `Quick (test_register_defaults_to_agent_stream ~auth);
            ] );
        ])
