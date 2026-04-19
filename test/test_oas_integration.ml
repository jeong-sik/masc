(** Tests for OAS integration modules: oas_events, message conversion. *)

module Masc_log = Log

open Agent_sdk
open Masc_mcp

let ctx_messages = Keeper_exec_context.messages_of_context
let ctx_system_prompt = Keeper_exec_context.system_prompt_of_context

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

let contains_substring s needle =
  let s_len = String.length s in
  let n_len = String.length needle in
  let rec loop i =
    if i + n_len > s_len then false
    else if String.sub s i n_len = needle then true
    else loop (i + 1)
  in
  if n_len = 0 then true else loop 0

let sse_data_json raw_event =
  let prefix = "data: " in
  let prefix_len = String.length prefix in
  raw_event
  |> String.split_on_char '\n'
  |> List.find_map (fun line ->
       if String.length line >= prefix_len
          && String.sub line 0 prefix_len = prefix
       then
         Some
           (Yojson.Safe.from_string
              (String.sub line prefix_len
                 (String.length line - prefix_len)))
       else
         None)
  |> Option.value ~default:`Null

let relay_test_config broken_root =
  let base = Coord.default_config (Filename.get_temp_dir_name ()) in
  { base with base_path = broken_root; workspace_path = broken_root }

(* ================================================================ *)
(* Oas_events tests                                                  *)
(* ================================================================ *)

let test_event_bus_broadcast () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let bus = Event_bus.create () in
  Masc_event_bus.set bus;
  let sub = Event_bus.subscribe bus in
  Oas_events.publish_broadcast bus ~agent_name:"test-agent" ~content:"hello";
  let events = Event_bus.drain sub in
  Alcotest.(check int) "one event" 1 (List.length events);
  match (List.hd events : Event_bus.event).payload with
  | Event_bus.Custom ("masc.broadcast", payload) ->
    let agent = Yojson.Safe.Util.(member "agent_name" payload |> to_string) in
    Alcotest.(check string) "agent name" "test-agent" agent
  | _ -> Alcotest.fail "expected Custom masc.broadcast event"

let test_event_bus_heartbeat () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let bus = Event_bus.create () in
  Masc_event_bus.set bus;
  let sub = Event_bus.subscribe bus in
  Oas_events.publish_heartbeat bus ~agent_name:"keeper-runtime" ~turn:5 ~context_pct:0.42;
  let events = Event_bus.drain sub in
  Alcotest.(check int) "one event" 1 (List.length events);
  match (List.hd events : Event_bus.event).payload with
  | Event_bus.Custom ("masc.heartbeat", payload) ->
    let turn = Yojson.Safe.Util.(member "turn" payload |> to_int) in
    Alcotest.(check int) "turn" 5 turn
  | _ -> Alcotest.fail "expected Custom masc.heartbeat event"

let test_event_bus_task_transition () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let bus = Event_bus.create () in
  Masc_event_bus.set bus;
  let sub = Event_bus.subscribe bus in
  Oas_events.publish_task_transition bus ~agent_name:"worker"
    ~task_id:"task-1" ~transition:"done";
  let events = Event_bus.drain sub in
  Alcotest.(check int) "one event" 1 (List.length events);
  match (List.hd events : Event_bus.event).payload with
  | Event_bus.Custom ("masc.task_transition", payload) ->
    let tid = Yojson.Safe.Util.(member "task_id" payload |> to_string) in
    Alcotest.(check string) "task id" "task-1" tid
  | _ -> Alcotest.fail "expected Custom masc.task_transition event"

let test_event_bus_keeper_lifecycle_includes_phase () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let bus = Event_bus.create () in
  Masc_event_bus.set bus;
  let sub = Event_bus.subscribe bus in
  Oas_events.publish_keeper_lifecycle bus
    ~event:(Masc_mcp.Keeper_lifecycle_events.Custom_event
              { verb = Masc_mcp.Keeper_lifecycle_events.Started;
                phase = Some Masc_mcp.Keeper_state_machine.Running })
    ~keeper_name:"keeper-a"
    ~detail:"supervised"
    ();
  let events = Event_bus.drain sub in
  Alcotest.(check int) "one event" 1 (List.length events);
  match (List.hd events : Event_bus.event).payload with
  | Event_bus.Custom ("masc.keeper.lifecycle", payload) ->
    let phase = Yojson.Safe.Util.(member "phase" payload |> to_string) in
    let event = Yojson.Safe.Util.(member "event" payload |> to_string) in
    Alcotest.(check string) "phase" "running" phase;
    Alcotest.(check string) "event" "started" event
  | _ -> Alcotest.fail "expected Custom masc.keeper:lifecycle event"

let test_keeper_snapshot_envelope_agent_name () =
  (* #7827: publish_keeper_snapshot stores the keeper's identity as
     [keeper_name] inside the Custom payload.  native_event_to_json must
     still populate the top-level envelope [agent_name] so that
     [.masc/oas-events/*.jsonl] consumers can filter/group by agent
     instead of silently dropping 9%+ of daily events. *)
  Eio_main.run @@ fun _env ->
  let bus = Event_bus.create () in
  Masc_event_bus.set bus;
  let sub = Event_bus.subscribe bus in
  Oas_events.publish_keeper_snapshot bus
    ~keeper_name:"sojin"
    ~generation:4
    ~context_ratio:0.25
    ~message_count:47;
  let events = Event_bus.drain sub in
  Alcotest.(check int) "one event" 1 (List.length events);
  match Oas_sse_bridge.native_event_to_json (List.hd events) with
  | None -> Alcotest.fail "expected native_event_to_json to emit"
  | Some (`Assoc fields) ->
    let field_string name =
      match List.assoc_opt name fields with
      | Some (`String value) -> value
      | Some `Null -> "<null>"
      | _ -> ""
    in
    Alcotest.(check string) "event_type"
      "masc:keeper:snapshot" (field_string "event_type");
    Alcotest.(check string) "envelope agent_name"
      "sojin" (field_string "agent_name")
  | Some _ -> Alcotest.fail "unexpected JSON shape"

let test_keeper_lifecycle_envelope_agent_name () =
  (* #7827 sibling: masc:keeper:lifecycle carries the same attribution
     through keeper_name. *)
  Eio_main.run @@ fun _env ->
  let bus = Event_bus.create () in
  Masc_event_bus.set bus;
  let sub = Event_bus.subscribe bus in
  Oas_events.publish_keeper_lifecycle bus
    ~event:(Masc_mcp.Keeper_lifecycle_events.Custom_event
              { verb = Masc_mcp.Keeper_lifecycle_events.Started;
                phase = Some Masc_mcp.Keeper_state_machine.Running })
    ~keeper_name:"masc-improver"
    ~detail:"supervised"
    ();
  let events = Event_bus.drain sub in
  Alcotest.(check int) "one event" 1 (List.length events);
  match Oas_sse_bridge.native_event_to_json (List.hd events) with
  | None -> Alcotest.fail "expected native_event_to_json to emit"
  | Some (`Assoc fields) ->
    let field_string name =
      match List.assoc_opt name fields with
      | Some (`String value) -> value
      | Some `Null -> "<null>"
      | _ -> ""
    in
    Alcotest.(check string) "envelope agent_name"
      "masc-improver" (field_string "agent_name")
  | Some _ -> Alcotest.fail "unexpected JSON shape"

let test_oas_sse_bridge_persists_native_events () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = tmpdir "oas_sse_bridge" in
  Fun.protect
    ~finally:(fun () -> cleanup_dir dir)
    (fun () ->
      let config = Coord.default_config dir in
      let bus = Event_bus.create () in
      Sse.set_clock (Eio.Stdenv.clock env);
      try
        Eio.Switch.run (fun sw ->
            Oas_sse_bridge.start_with_interval ~drain_interval_s:0.1
              ~sw ~clock:(Eio.Stdenv.clock env) ~config ~bus;
            Event_bus.publish bus
              (Event_bus.mk_event
                 ~correlation_id:"sess-bridge" ~run_id:"run-bridge"
                 (ToolCalled
                    {
                      agent_name = "bridge-agent";
                      tool_name = "masc_status";
                      input = `Assoc [];
                    }));
            Eio.Time.sleep (Eio.Stdenv.clock env) 0.6;
            let store =
              Dated_jsonl.create
                ~base_dir:(Filename.concat (Coord.masc_root_dir config) "oas-events")
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
                 Alcotest.(check string) "correlation id" "sess-bridge"
                   (field_string "correlation_id");
                 Alcotest.(check string) "run id" "run-bridge"
                   (field_string "run_id")
             | _ -> Alcotest.fail "expected persisted oas event object");
            raise Exit)
      with Exit -> ())

let test_oas_sse_bridge_broadcasts_lifecycle_to_observers () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = tmpdir "oas_sse_bridge_observer" in
  Fun.protect
    ~finally:(fun () ->
      ignore (Masc_mcp.Sse.close_all_clients ());
      cleanup_dir dir)
    (fun () ->
      let config = Coord.default_config dir in
      let bus = Event_bus.create () in
      Masc_event_bus.set bus;
      Masc_mcp.Sse.set_clock (Eio.Stdenv.clock env);
      try
        Eio.Switch.run (fun sw ->
            ignore (Masc_mcp.Sse.register ~kind:Masc_mcp.Sse.Observer
                      "observer-lifecycle" ~push:(fun _ -> ()) ~last_event_id:0);
            ignore (Masc_mcp.Sse.register ~kind:Masc_mcp.Sse.Coordinator
                      "coordinator-lifecycle" ~push:(fun _ -> ()) ~last_event_id:0);
            Oas_sse_bridge.start_with_interval ~drain_interval_s:0.1
              ~sw ~clock:(Eio.Stdenv.clock env) ~config ~bus;
            Oas_events.publish_keeper_lifecycle bus
              ~event:(Masc_mcp.Keeper_lifecycle_events.Custom_event
                        { verb = Masc_mcp.Keeper_lifecycle_events.Started;
                          phase = Some Masc_mcp.Keeper_state_machine.Running })
              ~keeper_name:"keeper-a"
              ~detail:"supervised"
              ();
            Eio.Time.sleep (Eio.Stdenv.clock env) 0.6;
            let observer_event = Masc_mcp.Sse.try_pop "observer-lifecycle" in
            let coordinator_event = Masc_mcp.Sse.try_pop "coordinator-lifecycle" in
            Alcotest.(check bool) "observer got oas lifecycle" true
              (observer_event <> None);
            Alcotest.(check bool) "coordinator got oas lifecycle" true
              (coordinator_event <> None);
            raise Exit)
      with Exit -> ())

let test_oas_sse_bridge_retries_append_failure_then_recovers () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = tmpdir "oas_sse_bridge_retry" in
  let broken_root = Filename.concat dir "broken-root" in
  Out_channel.with_open_text broken_root (fun oc -> output_string oc "blocked");
  Fun.protect
    ~finally:(fun () ->
      ignore (Masc_mcp.Sse.close_all_clients ());
      cleanup_dir dir)
    (fun () ->
      let config = relay_test_config broken_root in
      let bus = Event_bus.create () in
      Masc_mcp.Sse.set_clock (Eio.Stdenv.clock env);
      try
        Eio.Switch.run (fun sw ->
            ignore (Masc_mcp.Sse.register ~kind:Masc_mcp.Sse.Observer
                      "observer-retry" ~push:(fun _ -> ()) ~last_event_id:0);
            Oas_sse_bridge.start_with_interval ~drain_interval_s:0.1
              ~sw ~clock:(Eio.Stdenv.clock env) ~config ~bus;
            Event_bus.publish bus
              (Event_bus.mk_event
                 ~correlation_id:"sess-retry" ~run_id:"run-retry"
                 (ToolCalled
                    {
                      agent_name = "retry-agent";
                      tool_name = "keeper_status";
                      input = `Assoc [];
                    }));
            Eio.Time.sleep (Eio.Stdenv.clock env) 0.12;
            Sys.remove broken_root;
            Unix.mkdir broken_root 0o755;
            Eio.Time.sleep (Eio.Stdenv.clock env) 0.45;
            let store =
              Dated_jsonl.create
                ~base_dir:(Filename.concat (Coord.masc_root_dir config) "oas-events")
                ()
            in
            let events = Dated_jsonl.read_recent store 5 in
            Alcotest.(check bool) "event eventually persisted" true (events <> []);
            Alcotest.(check bool) "observer eventually sees recovered event" true
              (Masc_mcp.Sse.try_pop "observer-retry" <> None);
            raise Exit)
      with Exit -> ())

let test_oas_sse_bridge_drop_marker_on_exhausted_append_failure () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = tmpdir "oas_sse_bridge_drop" in
  let broken_root = Filename.concat dir "broken-root" in
  Out_channel.with_open_text broken_root (fun oc -> output_string oc "blocked");
  Fun.protect
    ~finally:(fun () ->
      ignore (Masc_mcp.Sse.close_all_clients ());
      cleanup_dir dir)
    (fun () ->
      let config = relay_test_config broken_root in
      let bus = Event_bus.create () in
      Masc_mcp.Sse.set_clock (Eio.Stdenv.clock env);
      try
        Eio.Switch.run (fun sw ->
            ignore (Masc_mcp.Sse.register ~kind:Masc_mcp.Sse.Observer
                      "observer-drop" ~push:(fun _ -> ()) ~last_event_id:0);
            Oas_sse_bridge.start_with_interval ~drain_interval_s:0.1
              ~sw ~clock:(Eio.Stdenv.clock env) ~config ~bus;
            Event_bus.publish bus
              (Event_bus.mk_event
                 ~correlation_id:"sess-drop" ~run_id:"run-drop"
                 (ToolCalled
                    {
                      agent_name = "drop-agent";
                      tool_name = "keeper_status";
                      input = `Assoc [];
                    }));
            Eio.Time.sleep (Eio.Stdenv.clock env) 0.8;
            let observer_event = Masc_mcp.Sse.try_pop "observer-drop" in
            Alcotest.(check bool) "drop marker broadcast" true
              (observer_event <> None);
            match observer_event with
            | None -> Alcotest.fail "expected relay drop marker"
            | Some raw_event ->
                let json = sse_data_json raw_event in
                let event_type =
                  Yojson.Safe.Util.(member "type" json |> to_string)
                in
                let failed_stage =
                  Yojson.Safe.Util.(member "failed_stage" json |> to_string)
                in
                Alcotest.(check string) "marker type" "oas:relay_dropped"
                  event_type;
                Alcotest.(check string) "failed stage" "append" failed_stage;
                raise Exit)
      with Exit -> ())

let test_oas_sse_bridge_broadcast_retry_does_not_duplicate_append () =
  let append_count = ref 0 in
  let broadcast_count = ref 0 in
  let pending =
    Oas_sse_bridge.For_testing.make_pending
      (`Assoc
         [
           ("type", `String "oas:tool_called");
           ("event_type", `String "tool_called");
           ("correlation_id", `String "sess-broadcast");
           ("run_id", `String "run-broadcast");
         ])
  in
  let first =
    Oas_sse_bridge.For_testing.deliver_pending_with
      ~append_json:(fun _json -> incr append_count)
      ~broadcast_json:(fun _json ->
        incr broadcast_count;
        if !broadcast_count = 1 then failwith "synthetic broadcast failure")
      pending
  in
  let pending_after_failure =
    match first with
    | Oas_sse_bridge.For_testing.Retryable_failure
        (pending, Oas_sse_bridge.For_testing.Broadcast, _) ->
        pending
    | Oas_sse_bridge.For_testing.Retryable_failure _ ->
        Alcotest.fail "expected broadcast-stage retryable failure"
    | Oas_sse_bridge.For_testing.Delivered ->
        Alcotest.fail "expected first delivery to fail on broadcast"
  in
  Alcotest.(check int) "append happens exactly once before retry" 1 !append_count;
  Alcotest.(check bool) "pending remembers durable append" true
    pending_after_failure.appended;
  let second =
    Oas_sse_bridge.For_testing.deliver_pending_with
      ~append_json:(fun _json -> incr append_count)
      ~broadcast_json:(fun _json -> incr broadcast_count)
      pending_after_failure
  in
  (match second with
   | Oas_sse_bridge.For_testing.Delivered -> ()
   | Oas_sse_bridge.For_testing.Retryable_failure _ ->
       Alcotest.fail "expected retry to deliver after broadcast recovery");
  Alcotest.(check int) "retry does not duplicate durable append" 1 !append_count;
  Alcotest.(check int) "broadcast retried once" 2 !broadcast_count

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
    (* Issue #8597 #1: ~system_prompt dropped from compact signature. *)
    Context_compact_oas.compact
      ~messages:(ctx_messages ctx)
      ~strategies:[Context_compact_oas.MergeContiguous] () in
  let ctx = Keeper_exec_context.sync_oas_context
    {
      ctx with
      checkpoint =
        { (Keeper_exec_context.checkpoint_of_context ctx) with messages };
    }
  in
  let ratio =
    Context.get_scoped ctx.context Context.Session "context_ratio" in
  (match ratio with
   | Some (`Float r) ->
     Alcotest.(check bool) "ratio is non-negative" true (r >= 0.0)
   | _ -> Alcotest.fail "expected context_ratio in oas_context after compact")

(* ================================================================ *)
let test_agent_completed_includes_usage () =
  let open Agent_sdk in
  let usage : Types.api_usage =
    {
      input_tokens = 500;
      output_tokens = 150;
      cache_creation_input_tokens = 0;
      cache_read_input_tokens = 0;
      cost_usd = Some 0.003;
    }
  in
  let resp : Types.api_response =
    {
      id = "msg-test";
      model = "test-model";
      stop_reason = EndTurn;
      content = [];
      usage = Some usage;
      telemetry = None;
    }
  in
  let evt =
    Event_bus.mk_event ~correlation_id:"sess-usage" ~run_id:"run-usage"
      (AgentCompleted
         {
           agent_name = "usage-agent";
           task_id = "task-usage";
           result = Ok resp;
           elapsed = 1.5;
         })
  in
  match Oas_sse_bridge.native_event_to_json evt with
  | None -> Alcotest.fail "expected Some for AgentCompleted"
  | Some (`Assoc fields) ->
      let payload_fields =
        match List.assoc_opt "payload" fields with
        | Some (`Assoc p) -> p
        | _ -> Alcotest.failf "expected payload assoc"
      in
      let int_field name =
        match List.assoc_opt name payload_fields with
        | Some (`Int v) -> v
        | _ -> -1
      in
      Alcotest.(check int) "input_tokens" 500 (int_field "input_tokens");
      Alcotest.(check int) "output_tokens" 150 (int_field "output_tokens");
      (match List.assoc_opt "cost_usd" payload_fields with
       | Some (`Float f) ->
           Alcotest.(check (float 0.001)) "cost_usd" 0.003 f
       | _ -> Alcotest.fail "expected cost_usd float");
      Alcotest.(check string) "event_type" "agent_completed"
        (match List.assoc_opt "event_type" fields with
         | Some (`String s) -> s
         | _ -> "")
  | Some _ -> Alcotest.fail "expected assoc"

let test_agent_completed_no_usage_on_error () =
  let open Agent_sdk in
  let evt =
    Event_bus.mk_event
      (AgentCompleted
         {
           agent_name = "err-agent";
           task_id = "task-err";
           result = Error (Error.Internal "test failure");
           elapsed = 0.5;
         })
  in
  match Oas_sse_bridge.native_event_to_json evt with
  | None -> Alcotest.fail "expected Some for AgentCompleted error"
  | Some (`Assoc fields) ->
      let payload_fields =
        match List.assoc_opt "payload" fields with
        | Some (`Assoc p) -> p
        | Some _ -> Alcotest.fail "expected payload assoc"
        | None -> Alcotest.fail "expected payload field"
      in
      Alcotest.(check bool) "no input_tokens on error" true
        (Option.is_none (List.assoc_opt "input_tokens" payload_fields))
  | Some _ -> Alcotest.fail "expected assoc"

let test_oas_log_bridge_turn_completed_summary () =
  Oas_log_bridge.install ();
  let before_seq =
    match Masc_log.Ring.recent ~module_filter:"oas:agent" ~limit:1 () with
    | [] -> None
    | entry :: _ -> Some entry.seq
  in
  let logger = Agent_sdk.Log.create ~module_name:"agent" () in
  Agent_sdk.Log.info logger "turn completed"
    [
      Agent_sdk.Log.I ("turn", 72);
      Agent_sdk.Log.I ("max_turns", 120);
      Agent_sdk.Log.F ("turn_duration_sec", 1.25);
      Agent_sdk.Log.S ("model", "glm-5-turbo");
      Agent_sdk.Log.S ("stop", "end_turn");
    ];
  let entries =
    Masc_log.Ring.recent ~module_filter:"oas:agent" ?since_seq:before_seq
      ~order:`Oldest_first ()
  in
  match List.rev entries with
  | [] -> Alcotest.fail "expected bridged oas:agent log entry"
  | entry :: _ ->
      Alcotest.(check bool) "message includes turn" true
        (contains_substring entry.message "turn=72");
      Alcotest.(check bool) "message includes model" true
        (contains_substring entry.message "model=glm-5-turbo");
      Alcotest.(check bool) "message includes stop" true
        (contains_substring entry.message "stop=end_turn");
      (match entry.details with
       | `Assoc fields ->
           Alcotest.(check bool) "details preserve turn" true
             (List.mem_assoc "turn" fields)
       | _ -> Alcotest.fail "expected structured details")

let test_oas_sse_bridge_logs_turn_completed_with_agent_name () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = tmpdir "oas_turn_log" in
  Fun.protect
    ~finally:(fun () -> cleanup_dir dir)
    (fun () ->
      let config = Coord.default_config dir in
      let bus = Event_bus.create () in
      let before_seq =
        match Masc_log.Ring.recent ~module_filter:"oas:event" ~limit:1 () with
        | [] -> None
        | entry :: _ -> Some entry.seq
      in
      Sse.set_clock (Eio.Stdenv.clock env);
      try
        Eio.Switch.run (fun sw ->
          Oas_sse_bridge.start ~sw ~clock:(Eio.Stdenv.clock env) ~config ~bus;
          Event_bus.publish bus
            (Event_bus.mk_event
               ~correlation_id:"sess-turn" ~run_id:"run-turn"
               (TurnCompleted { agent_name = "bridge-agent"; turn = 72 }));
          Eio.Time.sleep (Eio.Stdenv.clock env) 2.2;
          let entries =
            Masc_log.Ring.recent ~module_filter:"oas:event" ?since_seq:before_seq
              ~order:`Oldest_first ()
          in
          let entry =
            match
              List.find_opt
                (fun (entry : Masc_log.Ring.entry) ->
                  contains_substring entry.message
                    "turn completed agent=bridge-agent turn=72")
                entries
            with
            | Some entry -> entry
            | None -> Alcotest.fail "expected oas:event turn completed log"
          in
          (match entry.details with
           | `Assoc fields ->
               let event_type =
                 match List.assoc_opt "event_type" fields with
                 | Some (`String value) -> value
                 | _ -> ""
               in
               let agent_name =
                 match List.assoc_opt "agent_name" fields with
                 | Some (`String value) -> value
                 | _ -> ""
               in
               let turn =
                 match List.assoc_opt "turn" fields with
                 | Some (`Int value) -> value
                 | _ -> -1
               in
               Alcotest.(check string) "event type" "turn_completed" event_type;
               Alcotest.(check string) "agent name" "bridge-agent" agent_name;
               Alcotest.(check int) "turn" 72 turn
           | _ -> Alcotest.fail "expected structured oas:event details");
          raise Exit)
      with Exit -> ())

let test_oas_sse_bridge_logs_tool_completed_with_agent_name () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = tmpdir "oas_tool_log" in
  Fun.protect
    ~finally:(fun () -> cleanup_dir dir)
    (fun () ->
      let config = Coord.default_config dir in
      let bus = Event_bus.create () in
      let before_seq =
        match Masc_log.Ring.recent ~module_filter:"oas:event" ~limit:1 () with
        | [] -> None
        | entry :: _ -> Some entry.seq
      in
      Sse.set_clock (Eio.Stdenv.clock env);
      try
        Eio.Switch.run (fun sw ->
          Oas_sse_bridge.start ~sw ~clock:(Eio.Stdenv.clock env) ~config ~bus;
          Event_bus.publish bus
            (Event_bus.mk_event
               ~correlation_id:"sess-tool" ~run_id:"run-tool"
               (ToolCompleted
                  {
                    agent_name = "bridge-agent";
                    tool_name = "masc_board_list";
                    output = Ok { Agent_sdk.Types.content = "ok" };
                  }));
          Eio.Time.sleep (Eio.Stdenv.clock env) 2.2;
          let entries =
            Masc_log.Ring.recent ~module_filter:"oas:event" ?since_seq:before_seq
              ~order:`Oldest_first ()
          in
          let entry =
            match
              List.find_opt
                (fun (entry : Masc_log.Ring.entry) ->
                  contains_substring entry.message
                    "tool completed agent=bridge-agent tool_name=masc_board_list")
                entries
            with
            | Some entry -> entry
            | None -> Alcotest.fail "expected oas:event tool completed log"
          in
          (match entry.details with
           | `Assoc fields ->
               let event_type =
                 match List.assoc_opt "event_type" fields with
                 | Some (`String value) -> value
                 | _ -> ""
               in
               let tool_name =
                 match List.assoc_opt "tool_name" fields with
                 | Some (`String value) -> value
                 | _ -> ""
               in
               Alcotest.(check string) "event type" "tool_completed" event_type;
               Alcotest.(check string) "tool name" "masc_board_list" tool_name
           | _ -> Alcotest.fail "expected structured oas:event details");
          raise Exit)
      with Exit -> ())

(* Runner                                                            *)
(* ================================================================ *)

let () =
  Alcotest.run "OAS Integration" [
    "oas_events", [
      Alcotest.test_case "broadcast event" `Quick test_event_bus_broadcast;
      Alcotest.test_case "heartbeat event" `Quick test_event_bus_heartbeat;
      Alcotest.test_case "task transition event" `Quick
        test_event_bus_task_transition;
      Alcotest.test_case "keeper lifecycle includes phase" `Quick
        test_event_bus_keeper_lifecycle_includes_phase;
      Alcotest.test_case "keeper snapshot envelope carries agent_name (#7827)" `Quick
        test_keeper_snapshot_envelope_agent_name;
      Alcotest.test_case "keeper lifecycle envelope carries agent_name (#7827)" `Quick
        test_keeper_lifecycle_envelope_agent_name;
      Alcotest.test_case "sse bridge persists native events" `Quick
        test_oas_sse_bridge_persists_native_events;
      Alcotest.test_case "sse bridge sends lifecycle to observers" `Quick
        test_oas_sse_bridge_broadcasts_lifecycle_to_observers;
      Alcotest.test_case "sse bridge retries append failure then recovers" `Quick
        test_oas_sse_bridge_retries_append_failure_then_recovers;
      Alcotest.test_case "sse bridge emits drop marker on exhausted append failure" `Quick
        test_oas_sse_bridge_drop_marker_on_exhausted_append_failure;
      Alcotest.test_case "sse bridge retry avoids duplicate append after broadcast failure" `Quick
        test_oas_sse_bridge_broadcast_retry_does_not_duplicate_append;
      Alcotest.test_case "agent_completed includes usage" `Quick
        test_agent_completed_includes_usage;
      Alcotest.test_case "agent_completed no usage on error" `Quick
        test_agent_completed_no_usage_on_error;
      Alcotest.test_case "oas log bridge adds turn completed summary" `Quick
        test_oas_log_bridge_turn_completed_summary;
      Alcotest.test_case "sse bridge logs turn completed with agent name" `Quick
        test_oas_sse_bridge_logs_turn_completed_with_agent_name;
      Alcotest.test_case "sse bridge logs tool completed with agent name" `Quick
        test_oas_sse_bridge_logs_tool_completed_with_agent_name;
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
