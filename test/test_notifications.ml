(** test_notifications.ml — Notification harness unit tests

    Tests Tool_notifications dispatch handlers (count, check, consume)
    and Subscriptions bridge wiring.

    Requires Eio runtime: Session.with_lock uses Eio.Mutex.use_rw.
*)

open Alcotest

module Session = Masc_mcp.Session
module Tool_notifications = Masc_mcp.Tool_notifications
module Subscriptions = Masc_mcp.Subscriptions
module Encryption = Masc_mcp.Encryption

let () = Encryption.initialize ()

(* ── Helpers ─────────────────────────────────── *)

let make_event typ =
  `Assoc [
    ("type", `String typ);
    ("timestamp", `Float 1000.0);
  ]

let inject_events registry ~agent_name events =
  Session.with_lock registry (fun () ->
    match Hashtbl.find_opt registry.sessions agent_name with
    | Some session ->
        session.message_queue <- session.message_queue @ events
    | None -> ()
  )

let queue_length registry ~agent_name =
  Session.with_lock registry (fun () ->
    match Hashtbl.find_opt registry.sessions agent_name with
    | Some session -> List.length session.message_queue
    | None -> 0
  )

(** Extract JSON from response body that may have "summary\n---\n{json}" format *)
let extract_json body =
  match String.split_on_char '-' body with
  | _ ->
    (* Find the first '{' and parse from there *)
    let len = String.length body in
    let rec find_brace i =
      if i >= len then body
      else if body.[i] = '{' then String.sub body i (len - i)
      else find_brace (i + 1)
    in
    Yojson.Safe.from_string (find_brace 0)

(* Run a test function inside Eio runtime *)
let with_eio f () =
  Eio_main.run @@ fun _env -> f ()

(* ── Tests ───────────────────────────────────── *)

(* dispatch returns None for unknown tool *)
let test_dispatch_unknown () =
  let registry = Session.create () in
  let result = Tool_notifications.dispatch registry
    ~agent_name:"agent-a" ~name:"masc_unknown_tool" (`Assoc []) in
  check (option (pair bool string)) "unknown tool returns None"
    None result

(* notification_count: empty queue *)
let test_count_empty () =
  let registry = Session.create () in
  ignore (Session.register registry ~agent_name:"agent-a");
  let result = Tool_notifications.dispatch registry
    ~agent_name:"agent-a" ~name:"masc_notification_count" (`Assoc []) in
  match result with
  | Some (true, body) ->
      check bool "contains count 0" true
        (String.length body > 0);
      let json = extract_json body in
      let count = Yojson.Safe.Util.(json |> member "count" |> to_int) in
      check int "count is 0" 0 count
  | _ -> fail "expected Some (true, _)"

(* notification_count: with events *)
let test_count_with_events () =
  let registry = Session.create () in
  ignore (Session.register registry ~agent_name:"agent-b");
  let events = [make_event "masc/task_claimed"; make_event "masc/task_done"] in
  inject_events registry ~agent_name:"agent-b" events;
  let result = Tool_notifications.dispatch registry
    ~agent_name:"agent-b" ~name:"masc_notification_count" (`Assoc []) in
  match result with
  | Some (true, body) ->
      let json = extract_json body in
      let count = Yojson.Safe.Util.(json |> member "count" |> to_int) in
      check int "count is 2" 2 count
  | _ -> fail "expected Some (true, _)"

(* notification_count: unregistered agent *)
let test_count_unregistered () =
  let registry = Session.create () in
  let result = Tool_notifications.dispatch registry
    ~agent_name:"ghost" ~name:"masc_notification_count" (`Assoc []) in
  match result with
  | Some (true, body) ->
      let json = extract_json body in
      let count = Yojson.Safe.Util.(json |> member "count" |> to_int) in
      check int "unregistered agent count 0" 0 count
  | _ -> fail "expected Some (true, _)"

(* check_notifications: non-destructive peek *)
let test_check_peek () =
  let registry = Session.create () in
  ignore (Session.register registry ~agent_name:"agent-c");
  let events = [make_event "ev1"; make_event "ev2"; make_event "ev3"] in
  inject_events registry ~agent_name:"agent-c" events;
  (* First check — should return all 3 *)
  let result = Tool_notifications.dispatch registry
    ~agent_name:"agent-c" ~name:"masc_check_notifications"
    (`Assoc [("limit", `Int 10)]) in
  (match result with
   | Some (true, body) ->
       let json = extract_json body in
       let count = Yojson.Safe.Util.(json |> member "count" |> to_int) in
       check int "peek returns 3" 3 count
   | _ -> fail "expected Some (true, _)");
  (* Queue should still have 3 *)
  check int "queue unchanged after peek" 3
    (queue_length registry ~agent_name:"agent-c")

(* check_notifications: limit parameter *)
let test_check_with_limit () =
  let registry = Session.create () in
  ignore (Session.register registry ~agent_name:"agent-d");
  let events = [make_event "a"; make_event "b"; make_event "c"; make_event "d"] in
  inject_events registry ~agent_name:"agent-d" events;
  let result = Tool_notifications.dispatch registry
    ~agent_name:"agent-d" ~name:"masc_check_notifications"
    (`Assoc [("limit", `Int 2)]) in
  match result with
  | Some (true, body) ->
      let json = extract_json body in
      let count = Yojson.Safe.Util.(json |> member "count" |> to_int) in
      check int "limited to 2" 2 count;
      (* Queue still has all 4 *)
      check int "queue unchanged" 4
        (queue_length registry ~agent_name:"agent-d")
  | _ -> fail "expected Some (true, _)"

(* consume_notifications: destructive pop *)
let test_consume_basic () =
  let registry = Session.create () in
  ignore (Session.register registry ~agent_name:"agent-e");
  let events = [make_event "x"; make_event "y"; make_event "z"] in
  inject_events registry ~agent_name:"agent-e" events;
  let result = Tool_notifications.dispatch registry
    ~agent_name:"agent-e" ~name:"masc_consume_notifications"
    (`Assoc [("limit", `Int 2)]) in
  (match result with
   | Some (true, body) ->
       let json = extract_json body in
       let consumed = Yojson.Safe.Util.(json |> member "consumed" |> to_int) in
       let remaining = Yojson.Safe.Util.(json |> member "remaining" |> to_int) in
       check int "consumed 2" 2 consumed;
       check int "remaining 1" 1 remaining
   | _ -> fail "expected Some (true, _)");
  (* Queue should now have 1 *)
  check int "queue drained to 1" 1
    (queue_length registry ~agent_name:"agent-e")

(* consume_notifications: consume all *)
let test_consume_all () =
  let registry = Session.create () in
  ignore (Session.register registry ~agent_name:"agent-f");
  let events = [make_event "p"; make_event "q"] in
  inject_events registry ~agent_name:"agent-f" events;
  let result = Tool_notifications.dispatch registry
    ~agent_name:"agent-f" ~name:"masc_consume_notifications"
    (`Assoc [("limit", `Int 100)]) in
  (match result with
   | Some (true, body) ->
       let json = extract_json body in
       let consumed = Yojson.Safe.Util.(json |> member "consumed" |> to_int) in
       let remaining = Yojson.Safe.Util.(json |> member "remaining" |> to_int) in
       check int "consumed all 2" 2 consumed;
       check int "remaining 0" 0 remaining
   | _ -> fail "expected Some (true, _)");
  check int "queue empty" 0
    (queue_length registry ~agent_name:"agent-f")

(* consume_notifications: empty queue *)
let test_consume_empty () =
  let registry = Session.create () in
  ignore (Session.register registry ~agent_name:"agent-g");
  let result = Tool_notifications.dispatch registry
    ~agent_name:"agent-g" ~name:"masc_consume_notifications"
    (`Assoc [("limit", `Int 5)]) in
  match result with
  | Some (true, body) ->
      let json = extract_json body in
      let consumed = Yojson.Safe.Util.(json |> member "consumed" |> to_int) in
      check int "consumed 0 from empty" 0 consumed
  | _ -> fail "expected Some (true, _)"

(* Bridge: push_event_to_sessions distributes to all sessions *)
let test_bridge_push () =
  let registry = Session.create () in
  ignore (Session.register registry ~agent_name:"alice");
  ignore (Session.register registry ~agent_name:"bob");
  (* Wire the bridge *)
  Subscriptions.set_session_push_fn (fun event ->
    Session.push_notification_to_active_agents registry ~event
  );
  (* Push via bridge *)
  Subscriptions.push_event_to_sessions (make_event "masc/broadcast");
  (* Both agents should have the event *)
  check int "alice got 1" 1 (queue_length registry ~agent_name:"alice");
  check int "bob got 1" 1 (queue_length registry ~agent_name:"bob");
  (* Cleanup: reset bridge to avoid leaking into other tests *)
  Subscriptions.set_session_push_fn (fun _event -> 0)

(* Bridge: push with no bridge set does nothing *)
let test_bridge_not_set () =
  (* Reset bridge *)
  Subscriptions.set_session_push_fn (fun _event -> 0);
  (* This should not raise *)
  Subscriptions.push_event_to_sessions (make_event "masc/test");
  ()

(* consume_notifications: partial consume (5 events, limit=3) *)
let test_consume_partial () =
  let registry = Session.create () in
  ignore (Session.register registry ~agent_name:"agent-partial");
  let events = List.init 5 (fun i -> make_event (Printf.sprintf "ev%d" i)) in
  inject_events registry ~agent_name:"agent-partial" events;
  let result = Tool_notifications.dispatch registry
    ~agent_name:"agent-partial" ~name:"masc_consume_notifications"
    (`Assoc [("limit", `Int 3)]) in
  (match result with
   | Some (true, body) ->
       let json = extract_json body in
       let consumed = Yojson.Safe.Util.(json |> member "consumed" |> to_int) in
       let remaining = Yojson.Safe.Util.(json |> member "remaining" |> to_int) in
       check int "consumed 3" 3 consumed;
       check int "remaining 2" 2 remaining
   | _ -> fail "expected Some (true, _)");
  check int "queue has 2 left" 2
    (queue_length registry ~agent_name:"agent-partial")

(* consume_notifications: negative limit clamped to 0 *)
let test_consume_negative_limit () =
  let registry = Session.create () in
  ignore (Session.register registry ~agent_name:"agent-neg");
  let events = [make_event "a"; make_event "b"] in
  inject_events registry ~agent_name:"agent-neg" events;
  let result = Tool_notifications.dispatch registry
    ~agent_name:"agent-neg" ~name:"masc_consume_notifications"
    (`Assoc [("limit", `Int (-5))]) in
  (match result with
   | Some (true, body) ->
       let json = extract_json body in
       let consumed = Yojson.Safe.Util.(json |> member "consumed" |> to_int) in
       let remaining = Yojson.Safe.Util.(json |> member "remaining" |> to_int) in
       check int "consumed 0 with negative limit" 0 consumed;
       check int "remaining 2" 2 remaining
   | _ -> fail "expected Some (true, _)");
  (* Queue should be unchanged *)
  check int "queue unchanged" 2
    (queue_length registry ~agent_name:"agent-neg")

(* notification_count: response is valid JSON via Yojson *)
let test_count_yojson_format () =
  let registry = Session.create () in
  ignore (Session.register registry ~agent_name:"agent-json");
  let events = [make_event "ev1"] in
  inject_events registry ~agent_name:"agent-json" events;
  let result = Tool_notifications.dispatch registry
    ~agent_name:"agent-json" ~name:"masc_notification_count" (`Assoc []) in
  match result with
  | Some (true, body) ->
      (* Must parse as valid JSON *)
      let json = extract_json body in
      let count = Yojson.Safe.Util.(json |> member "count" |> to_int) in
      check int "count is 1" 1 count;
      (* Verify structure: must have "count" key *)
      (match json with
       | `Assoc fields ->
           check bool "has count key" true (List.mem_assoc "count" fields)
       | _ -> fail "expected JSON object")
  | _ -> fail "expected Some (true, _)"

(* Bridge: push_event_to_sessions with None registry logs warning *)
let test_bridge_none_warning () =
  (* Capture stderr output *)
  let (rd, wr) = Unix.pipe () in
  let old_stderr = Unix.dup Unix.stderr in
  Unix.dup2 wr Unix.stderr;
  Unix.close wr;
  (* Reset bridge to a fresh None state by setting a dummy, then we need
     to trigger the None path. Since set_session_push_fn always sets Some,
     we test the re-set warning instead. *)
  Subscriptions.set_session_push_fn (fun _event -> 0);
  (* Calling set again should trigger "already set" warning *)
  Subscriptions.set_session_push_fn (fun _event -> 0);
  (* Restore stderr and read captured output *)
  Unix.dup2 old_stderr Unix.stderr;
  Unix.close old_stderr;
  let buf = Buffer.create 256 in
  let bytes = Bytes.create 1024 in
  let n = Unix.read rd bytes 0 1024 in
  Unix.close rd;
  Buffer.add_subbytes buf bytes 0 n;
  let output = Buffer.contents buf in
  check bool "warning contains 'already set'"
    true (String.length output > 0 &&
          let pat = "already set" in
          let found = ref false in
          for i = 0 to String.length output - String.length pat do
            if String.sub output i (String.length pat) = pat then found := true
          done;
          !found)

(* ── Test runner ─────────────────────────────── *)

let () =
  run "Notification Harness" [
    "dispatch", [
      test_case "unknown tool returns None" `Quick (with_eio test_dispatch_unknown);
    ];
    "notification_count", [
      test_case "empty queue" `Quick (with_eio test_count_empty);
      test_case "with events" `Quick (with_eio test_count_with_events);
      test_case "unregistered agent" `Quick (with_eio test_count_unregistered);
    ];
    "check_notifications", [
      test_case "non-destructive peek" `Quick (with_eio test_check_peek);
      test_case "limit parameter" `Quick (with_eio test_check_with_limit);
    ];
    "consume_notifications", [
      test_case "destructive pop" `Quick (with_eio test_consume_basic);
      test_case "consume all" `Quick (with_eio test_consume_all);
      test_case "empty queue" `Quick (with_eio test_consume_empty);
      test_case "partial consume" `Quick (with_eio test_consume_partial);
      test_case "negative limit clamped" `Quick (with_eio test_consume_negative_limit);
    ];
    "notification_count_format", [
      test_case "valid JSON response" `Quick (with_eio test_count_yojson_format);
    ];
    "bridge", [
      test_case "push distributes to all" `Quick (with_eio test_bridge_push);
      test_case "no bridge set" `Quick (with_eio test_bridge_not_set);
      test_case "re-set warning" `Quick (with_eio test_bridge_none_warning);
    ];
  ]
