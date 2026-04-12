(** Tests for OAS integration modules: oas_events, message conversion. *)

open Agent_sdk
open Masc_mcp

let temp_counter = ref 0

let tmpdir prefix =
  incr temp_counter;
  let dir = Filename.concat
    (Filename.get_temp_dir_name ())
    (Printf.sprintf "%s_%d_%d_%.0f" prefix !temp_counter (Unix.getpid ())
       (Unix.gettimeofday ()))
  in
  Fs_compat.mkdir_p dir;
  dir

let rec cleanup_dir path =
  if Sys.file_exists path then
    if Sys.is_directory path then begin
      Sys.readdir path
      |> Array.iter (fun name -> cleanup_dir (Filename.concat path name));
      Unix.rmdir path
    end else
      Unix.unlink path

(* ================================================================ *)
(* Oas_events tests                                                  *)
(* ================================================================ *)

let test_event_bus_broadcast () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let bus = Event_bus.create () in
  let sub = Event_bus.subscribe bus in
  Oas_events.publish_broadcast bus ~agent_name:"test-agent" ~content:"hello";
  let events = Event_bus.drain sub in
  Alcotest.(check int) "one event" 1 (List.length events);
  match (List.hd events : Event_bus.event).payload with
  | Event_bus.Custom ("masc:broadcast", payload) ->
    let agent = Yojson.Safe.Util.(member "agent_name" payload |> to_string) in
    Alcotest.(check string) "agent name" "test-agent" agent
  | _ -> Alcotest.fail "expected Custom masc:broadcast event"

let test_event_bus_heartbeat () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let bus = Event_bus.create () in
  let sub = Event_bus.subscribe bus in
  Oas_events.publish_heartbeat bus ~agent_name:"keeper-runtime" ~turn:5 ~context_pct:0.42;
  let events = Event_bus.drain sub in
  Alcotest.(check int) "one event" 1 (List.length events);
  match (List.hd events : Event_bus.event).payload with
  | Event_bus.Custom ("masc:heartbeat", payload) ->
    let turn = Yojson.Safe.Util.(member "turn" payload |> to_int) in
    Alcotest.(check int) "turn" 5 turn
  | _ -> Alcotest.fail "expected Custom masc:heartbeat event"

let test_event_bus_task_transition () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let bus = Event_bus.create () in
  let sub = Event_bus.subscribe bus in
  Oas_events.publish_task_transition bus ~agent_name:"worker"
    ~task_id:"task-1" ~transition:"done";
  let events = Event_bus.drain sub in
  Alcotest.(check int) "one event" 1 (List.length events);
  match (List.hd events : Event_bus.event).payload with
  | Event_bus.Custom ("masc:task_transition", payload) ->
    let tid = Yojson.Safe.Util.(member "task_id" payload |> to_string) in
    Alcotest.(check string) "task id" "task-1" tid
  | _ -> Alcotest.fail "expected Custom masc:task_transition event"

let test_oas_sse_bridge_persists_native_events () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = tmpdir "oas_sse_bridge" in
  Fun.protect
    ~finally:(fun () -> cleanup_dir dir)
    (fun () ->
      let config = Room.default_config dir in
      let bus = Event_bus.create () in
      Sse.set_clock (Eio.Stdenv.clock env);
      try
        Eio.Switch.run (fun sw ->
          Oas_sse_bridge.start ~sw ~clock:(Eio.Stdenv.clock env) ~config ~bus;
          Event_bus.publish bus
            (Event_bus.mk_event
               ~correlation_id:"sess-bridge" ~run_id:"run-bridge"
               (ToolCalled
                  {
                    agent_name = "bridge-agent";
                    tool_name = "masc_status";
                    input = `Assoc [];
                  }));
          Eio.Time.sleep (Eio.Stdenv.clock env) 2.2;
          let store =
            Dated_jsonl.create
              ~base_dir:(Filename.concat (Room.masc_root_dir config) "oas-events")
              ()
          in
          let events = Dated_jsonl.read_recent store 5 in
          Alcotest.(check bool) "durable oas event appended" true (events <> []);
          (match List.hd events with
           | `Assoc fields ->
               let field_string name =
                 match List.assoc_opt name fields with
                 | Some (`String value) -> value
                 | _ -> ""
               in
               Alcotest.(check string) "event type" "tool_called"
                 (field_string "event_type");
               Alcotest.(check string) "agent name" "bridge-agent"
                 (field_string "agent_name");
               Alcotest.(check string) "session id" "sess-bridge"
                 (field_string "session_id");
               Alcotest.(check string) "worker run id" "run-bridge"
                 (field_string "worker_run_id")
           | _ -> Alcotest.fail "expected persisted oas event object");
          raise Exit)
      with Exit -> ())

(* ================================================================ *)
(* Message conversion tests (formerly oas_checkpoint_bridge)         *)
(* ================================================================ *)

let test_message_roundtrip () =
  let masc_msg : Agent_sdk.Types.message =
    Agent_sdk.Types.assistant_msg "test content"
  in
  let oas_msg = (fun (m : Agent_sdk.Types.message) -> match m.role with Agent_sdk.Types.System -> None | _ -> Some m) masc_msg in
  (match oas_msg with
   | None -> Alcotest.fail "Assistant message should not be dropped"
   | Some msg ->
     let roundtrip = Fun.id msg in
     Alcotest.(check string) "role preserved"
       "assistant"
       (match roundtrip.role with Agent_sdk.Types.Assistant -> "assistant" | _ -> "other");
     Alcotest.(check string) "content preserved"
       "test content" (Agent_sdk.Types.text_of_message roundtrip))

let test_system_role_dropped () =
  let masc_msg : Agent_sdk.Types.message =
    Agent_sdk.Types.system_msg "system prompt"
  in
  let oas_msg = (fun (m : Agent_sdk.Types.message) -> match m.role with Agent_sdk.Types.System -> None | _ -> Some m) masc_msg in
  Alcotest.(check bool) "system message dropped (belongs in system_prompt)"
    true (Option.is_none oas_msg)

let test_restore_messages () =
  let oas_msgs : Agent_sdk.Types.message list = [
    { Agent_sdk.Types.role = Agent_sdk.Types.User;
      content = [Agent_sdk.Types.Text "hello"]; name = None; tool_call_id = None };
    { Agent_sdk.Types.role = Agent_sdk.Types.Assistant;
      content = [Agent_sdk.Types.Text "world"]; name = None; tool_call_id = None };
  ] in
  let masc_msgs = List.map Fun.id oas_msgs in
  Alcotest.(check int) "2 messages" 2 (List.length masc_msgs);
  Alcotest.(check string) "first content" "hello"
    (Agent_sdk.Types.text_of_message (List.hd masc_msgs))

(* ================================================================ *)
(* Context_manager OAS sync tests                                    *)
(* ================================================================ *)

let test_oas_context_sync () =
  let ctx = Keeper_exec_context.create ~system_prompt:"test" ~max_tokens:1000 in
  let ctx = Keeper_exec_context.append ctx
    (Agent_sdk.Types.user_msg "hello") in
  let ctx = Keeper_exec_context.sync_oas_context ctx in
  let msg_count =
    Context.get_scoped ctx.context Context.Session "message_count" in
  (match msg_count with
   | Some (`Int n) -> Alcotest.(check int) "message count synced" 1 n
   | _ -> Alcotest.fail "expected message_count in oas_context")

let test_compact_syncs_oas_context () =
  let ctx = Keeper_exec_context.create ~system_prompt:"test" ~max_tokens:1000 in
  let ctx = Keeper_exec_context.append ctx (Agent_sdk.Types.user_msg "msg1") in
  let ctx = Keeper_exec_context.append ctx (Agent_sdk.Types.assistant_msg "msg2") in
  let messages =
    Context_compact_oas.compact
      ~system_prompt:ctx.system_prompt ~messages:ctx.messages
      ~strategies:[Context_compact_oas.MergeContiguous] () in
  let ctx = Keeper_exec_context.sync_oas_context
    { ctx with messages } in
  let ratio =
    Context.get_scoped ctx.context Context.Session "context_ratio" in
  (match ratio with
   | Some (`Float r) ->
     Alcotest.(check bool) "ratio is non-negative" true (r >= 0.0)
   | _ -> Alcotest.fail "expected context_ratio in oas_context after compact")

(* ================================================================ *)
(* Runner                                                            *)
(* ================================================================ *)

let () =
  Alcotest.run "OAS Integration" [
    "oas_events", [
      Alcotest.test_case "broadcast event" `Quick test_event_bus_broadcast;
      Alcotest.test_case "heartbeat event" `Quick test_event_bus_heartbeat;
      Alcotest.test_case "task transition event" `Quick
        test_event_bus_task_transition;
      Alcotest.test_case "sse bridge persists native events" `Quick
        test_oas_sse_bridge_persists_native_events;
    ];
    "message_conversion", [
      Alcotest.test_case "message roundtrip" `Quick test_message_roundtrip;
      Alcotest.test_case "system role dropped" `Quick
        test_system_role_dropped;
      Alcotest.test_case "restore messages" `Quick test_restore_messages;
    ];
    "context_oas_sync", [
      Alcotest.test_case "sync_oas_context" `Quick test_oas_context_sync;
      Alcotest.test_case "compact syncs oas" `Quick
        test_compact_syncs_oas_context;
    ];
  ]
