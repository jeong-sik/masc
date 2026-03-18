(** Tests for OAS integration modules: oas_events, message conversion. *)

open Agent_sdk
open Masc_mcp

(* ================================================================ *)
(* Oas_events tests                                                  *)
(* ================================================================ *)

let test_event_bus_broadcast () =
  Eio_main.run @@ fun _env ->
  let bus = Event_bus.create () in
  let sub = Event_bus.subscribe bus in
  Oas_events.publish_broadcast bus ~agent_name:"test-agent" ~content:"hello";
  let events = Event_bus.drain sub in
  Alcotest.(check int) "one event" 1 (List.length events);
  match List.hd events with
  | Event_bus.Custom ("masc:broadcast", payload) ->
    let agent = Yojson.Safe.Util.(member "agent_name" payload |> to_string) in
    Alcotest.(check string) "agent name" "test-agent" agent
  | _ -> Alcotest.fail "expected Custom masc:broadcast event"

let test_event_bus_heartbeat () =
  Eio_main.run @@ fun _env ->
  let bus = Event_bus.create () in
  let sub = Event_bus.subscribe bus in
  Oas_events.publish_heartbeat bus ~agent_name:"perpetual" ~turn:5 ~context_pct:0.42;
  let events = Event_bus.drain sub in
  Alcotest.(check int) "one event" 1 (List.length events);
  match List.hd events with
  | Event_bus.Custom ("masc:heartbeat", payload) ->
    let turn = Yojson.Safe.Util.(member "turn" payload |> to_int) in
    Alcotest.(check int) "turn" 5 turn
  | _ -> Alcotest.fail "expected Custom masc:heartbeat event"

let test_event_bus_task_transition () =
  Eio_main.run @@ fun _env ->
  let bus = Event_bus.create () in
  let sub = Event_bus.subscribe bus in
  Oas_events.publish_task_transition bus ~agent_name:"worker"
    ~task_id:"task-1" ~transition:"done";
  let events = Event_bus.drain sub in
  Alcotest.(check int) "one event" 1 (List.length events);
  match List.hd events with
  | Event_bus.Custom ("masc:task_transition", payload) ->
    let tid = Yojson.Safe.Util.(member "task_id" payload |> to_string) in
    Alcotest.(check string) "task id" "task-1" tid
  | _ -> Alcotest.fail "expected Custom masc:task_transition event"

(* ================================================================ *)
(* Message conversion tests (formerly oas_checkpoint_bridge)         *)
(* ================================================================ *)

let test_message_roundtrip () =
  let masc_msg : Llm_client.message =
    Llm_client.assistant_msg "test content"
  in
  let oas_msg = Llm_client.to_oas_message masc_msg in
  (match oas_msg with
   | None -> Alcotest.fail "Assistant message should not be dropped"
   | Some msg ->
     let roundtrip = Llm_client.of_oas_message msg in
     Alcotest.(check string) "role preserved"
       "assistant"
       (match roundtrip.role with Llm_client.Assistant -> "assistant" | _ -> "other");
     Alcotest.(check string) "content preserved"
       "test content" (Llm_client.text_of_message roundtrip))

let test_system_role_dropped () =
  let masc_msg : Llm_client.message =
    Llm_client.system_msg "system prompt"
  in
  let oas_msg = Llm_client.to_oas_message masc_msg in
  Alcotest.(check bool) "system message dropped (belongs in system_prompt)"
    true (Option.is_none oas_msg)

let test_restore_messages () =
  let oas_msgs : Agent_sdk.Types.message list = [
    { Agent_sdk.Types.role = Agent_sdk.Types.User;
      content = [Agent_sdk.Types.Text "hello"] };
    { Agent_sdk.Types.role = Agent_sdk.Types.Assistant;
      content = [Agent_sdk.Types.Text "world"] };
  ] in
  let masc_msgs = List.map Llm_client.of_oas_message oas_msgs in
  Alcotest.(check int) "2 messages" 2 (List.length masc_msgs);
  Alcotest.(check string) "first content" "hello"
    (Llm_client.text_of_message (List.hd masc_msgs))

(* ================================================================ *)
(* Context_manager OAS sync tests                                    *)
(* ================================================================ *)

let test_oas_context_sync () =
  let ctx = Context_manager.create ~system_prompt:"test" ~max_tokens:1000 in
  let ctx = Context_manager.append ctx
    (Llm_client.user_msg "hello") in
  let ctx = Context_manager.sync_oas_context ctx in
  let msg_count =
    Context.get_scoped ctx.oas_context Context.Session "message_count" in
  (match msg_count with
   | Some (`Int n) -> Alcotest.(check int) "message count synced" 1 n
   | _ -> Alcotest.fail "expected message_count in oas_context")

let test_compact_syncs_oas_context () =
  let ctx = Context_manager.create ~system_prompt:"test" ~max_tokens:1000 in
  let ctx = Context_manager.append ctx (Llm_client.user_msg "msg1") in
  let ctx = Context_manager.append ctx (Llm_client.assistant_msg "msg2") in
  let ctx = Context_manager.compact ctx [Context_manager.MergeContiguous] in
  let ratio =
    Context.get_scoped ctx.oas_context Context.Session "context_ratio" in
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
