(** Coverage tests for Tool_notifications — MCP tool handlers for
    in-turn event polling (notification_count, check, consume).

    Requires Eio runtime because Session.with_lock uses Eio.Mutex.

    Covered: dispatch routing, get_int helper, count/check/consume
    handlers, limit boundary, empty queue, queue mutation (consume). *)

module Tool_notifications = Masc_mcp.Tool_notifications
module Tool_args = Masc_mcp.Tool_args
module Session = Masc_mcp.Session

(* ============================================================
   Test Helpers
   ============================================================ *)

(** Build a registry and pre-populate a session with messages. *)
let make_registry_with_messages agent msgs =
  let registry = Session.create () in
  ignore (Session.register registry ~agent_name:agent);
  (* Inject messages directly into the queue *)
  Session.with_lock registry (fun () ->
    match Hashtbl.find_opt registry.sessions agent with
    | Some session -> session.message_queue <- msgs
    | None -> failwith "session not registered"
  );
  registry

(** Extract JSON portion from tool response body.
    Format: "summary text\n---\n{json}" — parse everything after "---\n". *)
let extract_json body =
  match String.split_on_char '-' body with
  | _ ->
    (* Find "---\n" separator and parse JSON after it *)
    let sep = "\n---\n" in
    let sep_len = String.length sep in
    let body_len = String.length body in
    let rec find_sep i =
      if i > body_len - sep_len then
        (* No separator found — try parsing the whole body as JSON (backward compat) *)
        Yojson.Safe.from_string body
      else if String.sub body i sep_len = sep then
        Yojson.Safe.from_string (String.sub body (i + sep_len) (body_len - i - sep_len))
      else find_sep (i + 1)
    in
    find_sep 0

let json_member key body =
  Yojson.Safe.Util.member key (extract_json body)

let json_to_int json = Yojson.Safe.Util.to_int json
(* ============================================================
   get_int tests
   ============================================================ *)

let test_get_int_present () =
  let args = `Assoc [("limit", `Int 5)] in
  Alcotest.(check int) "extracts int" 5
    (Tool_args.get_int args "limit" 10)

let test_get_int_missing () =
  let args = `Assoc [] in
  Alcotest.(check int) "returns default" 10
    (Tool_args.get_int args "limit" 10)

let test_get_int_wrong_type () =
  let args = `Assoc [("limit", `String "five")] in
  Alcotest.(check int) "returns default on wrong type" 10
    (Tool_args.get_int args "limit" 10)

let test_get_int_non_assoc () =
  let args = `Null in
  Alcotest.(check int) "returns default on non-assoc" 10
    (Tool_args.get_int args "limit" 10)

(* ============================================================
   Dispatch routing tests
   ============================================================ *)

let test_dispatch_unknown () =
  let registry = Session.create () in
  let result = Tool_notifications.dispatch registry ~agent_name:"test" ~name:"unknown_tool" (`Assoc []) in
  Alcotest.(check bool) "unknown returns None" true (result = None)

let test_dispatch_routes_count () =
  let registry = Session.create () in
  ignore (Session.register registry ~agent_name:"test");
  let result = Tool_notifications.dispatch registry ~agent_name:"test" ~name:"masc_notification_count" (`Assoc []) in
  Alcotest.(check bool) "count routes" true (result <> None)

let test_dispatch_routes_check () =
  let registry = Session.create () in
  ignore (Session.register registry ~agent_name:"test");
  let result = Tool_notifications.dispatch registry ~agent_name:"test" ~name:"masc_check_notifications" (`Assoc []) in
  Alcotest.(check bool) "check routes" true (result <> None)

let test_dispatch_routes_consume () =
  let registry = Session.create () in
  ignore (Session.register registry ~agent_name:"test");
  let result = Tool_notifications.dispatch registry ~agent_name:"test" ~name:"masc_consume_notifications" (`Assoc []) in
  Alcotest.(check bool) "consume routes" true (result <> None)

(* ============================================================
   handle_notification_count tests
   ============================================================ *)

let test_count_empty_queue () =
  let registry = Session.create () in
  ignore (Session.register registry ~agent_name:"test");
  let (ok, body) = Tool_notifications.handle_notification_count registry ~agent_name:"test" in
  Alcotest.(check bool) "success" true ok;
  Alcotest.(check int) "count=0" 0
    (json_member "count" body |> json_to_int)

let test_count_with_messages () =
  let msgs = [`String "m1"; `String "m2"; `String "m3"] in
  let registry = make_registry_with_messages "agent1" msgs in
  let (ok, body) = Tool_notifications.handle_notification_count registry ~agent_name:"agent1" in
  Alcotest.(check bool) "success" true ok;
  Alcotest.(check int) "count=3" 3
    (json_member "count" body |> json_to_int)

let test_count_unknown_agent () =
  let registry = Session.create () in
  let (ok, body) = Tool_notifications.handle_notification_count registry ~agent_name:"nobody" in
  Alcotest.(check bool) "success even for unknown" true ok;
  Alcotest.(check int) "count=0 for unknown" 0
    (json_member "count" body |> json_to_int)

(* ============================================================
   handle_check_notifications tests
   ============================================================ *)

let test_check_empty () =
  let registry = Session.create () in
  ignore (Session.register registry ~agent_name:"test");
  let (ok, body) = Tool_notifications.handle_check_notifications registry ~agent_name:"test" (`Assoc []) in
  Alcotest.(check bool) "success" true ok;
  let json = extract_json body in
  Alcotest.(check int) "count=0" 0
    (Yojson.Safe.Util.member "count" json |> Yojson.Safe.Util.to_int);
  Alcotest.(check int) "notifications empty" 0
    (Yojson.Safe.Util.member "notifications" json |> Yojson.Safe.Util.to_list |> List.length)

let test_check_with_limit () =
  let msgs = [`String "a"; `String "b"; `String "c"; `String "d"; `String "e"] in
  let registry = make_registry_with_messages "test" msgs in
  let (ok, body) = Tool_notifications.handle_check_notifications registry ~agent_name:"test" (`Assoc [("limit", `Int 3)]) in
  Alcotest.(check bool) "success" true ok;
  let json = extract_json body in
  Alcotest.(check int) "returns 3" 3
    (Yojson.Safe.Util.member "count" json |> Yojson.Safe.Util.to_int)

let test_check_default_limit () =
  (* Default limit is 10, with 5 messages should return all 5 *)
  let msgs = List.init 5 (fun i -> `String (string_of_int i)) in
  let registry = make_registry_with_messages "test" msgs in
  let (ok, body) = Tool_notifications.handle_check_notifications registry ~agent_name:"test" (`Assoc []) in
  Alcotest.(check bool) "success" true ok;
  let json = extract_json body in
  Alcotest.(check int) "returns all 5" 5
    (Yojson.Safe.Util.member "count" json |> Yojson.Safe.Util.to_int)

let test_check_does_not_consume () =
  let msgs = [`String "x"; `String "y"] in
  let registry = make_registry_with_messages "test" msgs in
  (* Check twice — queue should remain unchanged *)
  ignore (Tool_notifications.handle_check_notifications registry ~agent_name:"test" (`Assoc []));
  let (_, body) = Tool_notifications.handle_check_notifications registry ~agent_name:"test" (`Assoc []) in
  let json = extract_json body in
  Alcotest.(check int) "still 2 after double check" 2
    (Yojson.Safe.Util.member "count" json |> Yojson.Safe.Util.to_int)

let test_check_negative_limit () =
  let msgs = [`String "a"] in
  let registry = make_registry_with_messages "test" msgs in
  let (ok, body) = Tool_notifications.handle_check_notifications registry ~agent_name:"test" (`Assoc [("limit", `Int (-5))]) in
  Alcotest.(check bool) "success" true ok;
  let json = extract_json body in
  Alcotest.(check int) "negative limit → 0 results" 0
    (Yojson.Safe.Util.member "count" json |> Yojson.Safe.Util.to_int)

(* ============================================================
   handle_consume_notifications tests
   ============================================================ *)

let test_consume_empty () =
  let registry = Session.create () in
  ignore (Session.register registry ~agent_name:"test");
  let (ok, body) = Tool_notifications.handle_consume_notifications registry ~agent_name:"test" (`Assoc []) in
  Alcotest.(check bool) "success" true ok;
  let json = extract_json body in
  Alcotest.(check int) "consumed=0" 0
    (Yojson.Safe.Util.member "consumed" json |> Yojson.Safe.Util.to_int);
  Alcotest.(check int) "remaining=0" 0
    (Yojson.Safe.Util.member "remaining" json |> Yojson.Safe.Util.to_int)

let test_consume_partial () =
  let msgs = [`String "a"; `String "b"; `String "c"; `String "d"] in
  let registry = make_registry_with_messages "test" msgs in
  let (ok, body) = Tool_notifications.handle_consume_notifications registry ~agent_name:"test" (`Assoc [("limit", `Int 2)]) in
  Alcotest.(check bool) "success" true ok;
  let json = extract_json body in
  Alcotest.(check int) "consumed=2" 2
    (Yojson.Safe.Util.member "consumed" json |> Yojson.Safe.Util.to_int);
  Alcotest.(check int) "remaining=2" 2
    (Yojson.Safe.Util.member "remaining" json |> Yojson.Safe.Util.to_int)

let test_consume_removes_from_queue () =
  let msgs = [`String "a"; `String "b"; `String "c"] in
  let registry = make_registry_with_messages "test" msgs in
  ignore (Tool_notifications.handle_consume_notifications registry ~agent_name:"test" (`Assoc [("limit", `Int 2)]));
  (* Count should now be 1 *)
  let (_, body) = Tool_notifications.handle_notification_count registry ~agent_name:"test" in
  Alcotest.(check int) "1 left after consuming 2 of 3" 1
    (json_member "count" body |> json_to_int)

let test_consume_all () =
  let msgs = [`String "x"; `String "y"] in
  let registry = make_registry_with_messages "test" msgs in
  let (ok, body) = Tool_notifications.handle_consume_notifications registry ~agent_name:"test" (`Assoc [("limit", `Int 100)]) in
  Alcotest.(check bool) "success" true ok;
  let json = extract_json body in
  Alcotest.(check int) "consumed=2" 2
    (Yojson.Safe.Util.member "consumed" json |> Yojson.Safe.Util.to_int);
  Alcotest.(check int) "remaining=0" 0
    (Yojson.Safe.Util.member "remaining" json |> Yojson.Safe.Util.to_int)

let test_consume_unknown_agent () =
  let registry = Session.create () in
  let (ok, body) = Tool_notifications.handle_consume_notifications registry ~agent_name:"nobody" (`Assoc []) in
  Alcotest.(check bool) "success even for unknown" true ok;
  let json = extract_json body in
  Alcotest.(check int) "consumed=0" 0
    (Yojson.Safe.Util.member "consumed" json |> Yojson.Safe.Util.to_int)

(* ============================================================
   schemas tests
   ============================================================ *)

let test_schemas_count () =
  Alcotest.(check int) "3 schemas" 3
    (List.length Tool_notifications.schemas)

let test_schemas_names () =
  let names = List.map (fun (s : Types.tool_schema) -> s.name) Tool_notifications.schemas in
  Alcotest.(check bool) "has notification_count" true
    (List.mem "masc_notification_count" names);
  Alcotest.(check bool) "has check_notifications" true
    (List.mem "masc_check_notifications" names);
  Alcotest.(check bool) "has consume_notifications" true
    (List.mem "masc_consume_notifications" names)

(* ============================================================
   Test runner
   ============================================================ *)

let () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Alcotest.run "Tool_notifications coverage" [
    ("get_int", [
      Alcotest.test_case "present" `Quick test_get_int_present;
      Alcotest.test_case "missing" `Quick test_get_int_missing;
      Alcotest.test_case "wrong type" `Quick test_get_int_wrong_type;
      Alcotest.test_case "non-assoc" `Quick test_get_int_non_assoc;
    ]);
    ("dispatch", [
      Alcotest.test_case "unknown" `Quick test_dispatch_unknown;
      Alcotest.test_case "routes count" `Quick test_dispatch_routes_count;
      Alcotest.test_case "routes check" `Quick test_dispatch_routes_check;
      Alcotest.test_case "routes consume" `Quick test_dispatch_routes_consume;
    ]);
    ("notification_count", [
      Alcotest.test_case "empty queue" `Quick test_count_empty_queue;
      Alcotest.test_case "with messages" `Quick test_count_with_messages;
      Alcotest.test_case "unknown agent" `Quick test_count_unknown_agent;
    ]);
    ("check_notifications", [
      Alcotest.test_case "empty" `Quick test_check_empty;
      Alcotest.test_case "with limit" `Quick test_check_with_limit;
      Alcotest.test_case "default limit" `Quick test_check_default_limit;
      Alcotest.test_case "non-destructive" `Quick test_check_does_not_consume;
      Alcotest.test_case "negative limit" `Quick test_check_negative_limit;
    ]);
    ("consume_notifications", [
      Alcotest.test_case "empty" `Quick test_consume_empty;
      Alcotest.test_case "partial" `Quick test_consume_partial;
      Alcotest.test_case "removes from queue" `Quick test_consume_removes_from_queue;
      Alcotest.test_case "consume all" `Quick test_consume_all;
      Alcotest.test_case "unknown agent" `Quick test_consume_unknown_agent;
    ]);
    ("schemas", [
      Alcotest.test_case "count" `Quick test_schemas_count;
      Alcotest.test_case "names" `Quick test_schemas_names;
    ]);
  ]
