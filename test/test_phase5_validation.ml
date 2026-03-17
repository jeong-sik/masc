(** Test Phase 5: Swarm envelope validation + Keeper chat AG-UI bridge *)

open Masc_mcp

let passed = ref 0
let failed = ref 0

let test name fn =
  try fn (); incr passed; Printf.printf "  PASS  %s\n%!" name
  with e -> incr failed; Printf.printf "  FAIL  %s: %s\n%!" name (Printexc.to_string e)

(* ══════════════════════════════════════════════════════════════
   #991 — Swarm envelope validation
   ══════════════════════════════════════════════════════════════ *)

let () = test "envelope round-trip" (fun () ->
  let env : Message_schema.swarm_envelope = {
    sender = "claude";
    timestamp = 1700000000.0;
    sequence = 42;
    channel = "broadcast";
    message = Message_schema.TaskUpdate {
      task_id = "task-1"; status = "done"; payload = None };
  } in
  match Message_schema.roundtrip_envelope env with
  | Ok env2 ->
      assert (env2.sender = "claude");
      assert (env2.sequence = 42);
      assert (env2.channel = "broadcast");
      assert (Message_schema.message_type_string env2.message = "task_update")
  | Error e -> failwith e
)

let () = test "envelope rejects empty sender" (fun () ->
  let json = `Assoc [
    ("sender", `String "");
    ("timestamp", `Float 1.0);
    ("sequence", `Int 0);
    ("channel", `String "broadcast");
    ("message", `Assoc [("type", `String "freeform"); ("text", `String "hi")]);
  ] in
  match Message_schema.envelope_of_json json with
  | Error msg -> assert (String.length msg > 0)
  | Ok _ -> failwith "expected error for empty sender"
)

let () = test "envelope rejects negative sequence" (fun () ->
  let json = `Assoc [
    ("sender", `String "agent");
    ("timestamp", `Float 1.0);
    ("sequence", `Int (-1));
    ("channel", `String "broadcast");
    ("message", `Assoc [("type", `String "freeform"); ("text", `String "hi")]);
  ] in
  match Message_schema.envelope_of_json json with
  | Error _ -> ()
  | Ok _ -> failwith "expected error for negative sequence"
)

let () = test "envelope rejects missing message" (fun () ->
  let json = `Assoc [
    ("sender", `String "agent");
    ("timestamp", `Float 1.0);
    ("sequence", `Int 0);
    ("channel", `String "broadcast");
  ] in
  match Message_schema.envelope_of_json json with
  | Error msg -> assert (String.length msg > 0)
  | Ok _ -> failwith "expected error for missing message"
)

let () = test "envelope strict mode rejects invalid" (fun () ->
  match Message_schema.validate_envelope ~mode:Strict "{\"bad\": true}" with
  | Error _ -> ()
  | Ok _ -> failwith "expected strict rejection"
)

let () = test "envelope permissive mode wraps invalid" (fun () ->
  match Message_schema.validate_envelope ~mode:Permissive "{\"bad\": true}" with
  | Ok env ->
      assert (env.sender = "unknown");
      assert (env.channel = "freeform")
  | Error _ -> failwith "expected permissive acceptance"
)

let () = test "envelope all message types" (fun () ->
  let messages = [
    Message_schema.TaskUpdate { task_id = "t1"; status = "pending"; payload = None };
    Message_schema.StatusReport { agent = "a"; progress = 0.5; details = "half" };
    Message_schema.Request { target = "b"; action = "ping"; params = `Null };
    Message_schema.Response { request_id = "r1"; success = true; result = `Int 42 };
    Message_schema.Freeform "hello";
  ] in
  List.iter (fun msg ->
    let env : Message_schema.swarm_envelope = {
      sender = "test"; timestamp = 1.0; sequence = 0;
      channel = "test"; message = msg;
    } in
    match Message_schema.roundtrip_envelope env with
    | Ok _ -> ()
    | Error e -> failwith (Printf.sprintf "roundtrip failed for %s: %s"
        (Message_schema.message_type_string msg) e)
  ) messages
)

(* ══════════════════════════════════════════════════════════════
   #897 — Keeper chat AG-UI bridge
   ══════════════════════════════════════════════════════════════ *)

let () = test "keeper session creates unique IDs" (fun () ->
  let s1 = Keeper_chat_ag_ui.make_session ~keeper_name:"dreamer" in
  let s2 = Keeper_chat_ag_ui.make_session ~keeper_name:"dreamer" in
  assert (s1.run_id <> s2.run_id);
  assert (s1.thread_id = s2.thread_id)  (* same keeper = same thread *)
)

let () = test "events_for_response has correct sequence" (fun () ->
  let session = Keeper_chat_ag_ui.make_session ~keeper_name:"sangsu" in
  let events = Keeper_chat_ag_ui.events_for_response session ~response:"hello world" in
  (* Sequence: RUN_STARTED, TEXT_START, TEXT_CONTENT*, TEXT_END, RUN_FINISHED *)
  assert (List.length events >= 5);
  let types = List.map (fun (e : Ag_ui.event) -> e.event_type) events in
  assert (List.hd types = Ag_ui.Run_started);
  assert (List.nth types 1 = Ag_ui.Text_message_start);
  let last = List.nth types (List.length types - 1) in
  assert (last = Ag_ui.Run_finished);
  let second_last = List.nth types (List.length types - 2) in
  assert (second_last = Ag_ui.Text_message_end)
)

let () = test "events_for_response chunks long text" (fun () ->
  let session = Keeper_chat_ag_ui.make_session ~keeper_name:"luna" in
  (* 200 chars → ceil(200/64) = 4 chunks *)
  let long_text = String.make 200 'x' in
  let events = Keeper_chat_ag_ui.events_for_response session ~response:long_text in
  let content_events = List.filter (fun (e : Ag_ui.event) ->
    e.event_type = Ag_ui.Text_message_content
  ) events in
  assert (List.length content_events >= 3);
  (* Verify deltas concatenate to original *)
  let reconstructed = String.concat "" (List.filter_map (fun (e : Ag_ui.event) ->
    e.delta
  ) content_events) in
  assert (reconstructed = long_text)
)

let () = test "sse_for_response produces valid SSE" (fun () ->
  let session = Keeper_chat_ag_ui.make_session ~keeper_name:"miso" in
  let sse = Keeper_chat_ag_ui.sse_for_response session ~response:"test" in
  (* Each event should be "data: {...}\n\n" *)
  assert (String.length sse > 0);
  let lines = String.split_on_char '\n' sse in
  let data_lines = List.filter (fun l ->
    String.length l > 5 && String.sub l 0 5 = "data:"
  ) lines in
  assert (List.length data_lines >= 5)
)

let () = test "sse_for_error produces RUN_ERROR event" (fun () ->
  let session = Keeper_chat_ag_ui.make_session ~keeper_name:"err" in
  let sse = Keeper_chat_ag_ui.sse_for_error session ~error:"timeout" in
  assert (String.length sse > 0);
  (* Should contain RUN_ERROR *)
  let has_error = try
    ignore (Str.search_forward (Str.regexp_string "RUN_ERROR") sse 0); true
  with Not_found -> false in
  assert has_error
)

(* ── Summary ──────────────────────────────────── *)

let () =
  Printf.printf "\nPhase 5 tests: %d passed, %d failed\n%!" !passed !failed;
  if !failed > 0 then exit 1
