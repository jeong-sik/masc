(** The three operator-decision routes record the authenticated caller.

    task-1662: [POST /api/v1/keepers/ask-answer] recorded the request
    body's own [actor_id] as the responder, so the answering client could
    write any name into the durable log; [POST /api/v1/keepers/tool-approval]
    and [POST /api/v1/keepers/turn/interrupt] resolved the caller identity
    with [with_tool_auth] and threw it away, so the decision carried no
    attribution at all. The routes now use [with_tool_actor_auth] (#37327
    shape) and the handler records the token's principal. These tests drive
    the real dashboard router over HTTP with a bearer token whose body lies
    about who it is, and assert the record carries the token owner. *)

open Alcotest
open Masc

module Mcp_server = Masc.Mcp_server
module Http_server_eio = Masc.Http_server_eio
module U = Yojson.Safe.Util

(* Shadow the ambient [Masc] namespace so the test reads like its reference
   test (test_keeper_ask_store.ml) while keeping the explicit re-exports for
   the server modules that [open Masc] does not cover. [Keeper_ask] and
   friends come from [masc.keeper_runtime]; the continuation channel lives
   in the same library and is reached unqualified through it. *)
module Keeper_ask = Masc.Keeper_ask
module Keeper_ask_store = Masc.Keeper_ask_store

let temp_dir_counter = ref 0

let with_temp_dir f =
  incr temp_dir_counter;
  let base =
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "decision-actor-%d-%06d" (Unix.getpid ()) !temp_dir_counter)
  in
  Unix.mkdir base 0o755;
  Fun.protect
    ~finally:(fun () ->
      let rec rm_rf path =
        if Sys.file_exists path then
          if Sys.is_directory path then (
            Sys.readdir path
            |> Array.iter (fun name -> rm_rf (Filename.concat path name));
            Unix.rmdir path
          ) else Sys.remove path
      in
      rm_rf base)
    (fun () -> f base)

let loopback_request_authority () =
  match Server_request_authority.of_host_port ~host:"127.0.0.1" ~port:8936 with
  | Ok authority -> authority
  | Error `Malformed -> Alcotest.fail "failed to construct loopback request authority"

let create_token_exn base_path ~agent_name ~role =
  match Auth.create_token base_path ~agent_name ~role with
  | Ok token_info -> token_info
  | Error msg ->
    Alcotest.failf "create_token failed: %s" (Masc_domain.masc_error_to_string msg)

let make_keeper_meta name =
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc
        [ ("name", `String name)
        ; ("trace_id", `String ("trace-" ^ name))
        ])
  with
  | Ok meta -> meta
  | Error err -> Alcotest.fail ("meta_of_json failed: " ^ err)

(* Drive the real dashboard router with a POST carrying a bearer token and a
   JSON body, then return the raw HTTP response. *)
let dispatch_post ~sw ~clock ~state ~token ~path ~body =
  Server_request_authority.with_current (loopback_request_authority ()) (fun () ->
    let router =
      Server_routes_http_routes_dashboard.add_routes
        ~sw
        ~clock
        (Http_server_eio.Router.create ())
    in
    Server_auth.publish_server_state state;
    let response_buf = Buffer.create 1024 in
    let conn =
      Httpun.Server_connection.create (fun reqd ->
        Http_server_eio.Router.dispatch router (Httpun.Reqd.request reqd) reqd)
    in
    let request_str =
      Printf.sprintf
        "POST %s HTTP/1.1\r\n\
         Host: 127.0.0.1:8936\r\n\
         Origin: http://127.0.0.1:8936\r\n\
         Authorization: Bearer %s\r\n\
         Content-Type: application/json\r\n\
         Content-Length: %d\r\n\
         \r\n\
         %s"
        path token (String.length body) body
    in
    let bytes =
      Bigstringaf.of_string ~off:0 ~len:(String.length request_str) request_str
    in
    ignore
      (Httpun.Server_connection.read_eof
         conn
         bytes
         ~off:0
         ~len:(Bigstringaf.length bytes));
    let rec flush () =
      match Httpun.Server_connection.next_write_operation conn with
      | `Write iovecs ->
        let written =
          List.fold_left
            (fun total (iov : Bigstringaf.t Httpun.IOVec.t) ->
               Buffer.add_string
                 response_buf
                 (Bigstringaf.substring iov.buffer ~off:iov.off ~len:iov.len);
               total + iov.len)
            0
            iovecs
        in
        Httpun.Server_connection.report_write_result conn (`Ok written);
        flush ()
      | `Yield | `Close _ -> ()
    in
    flush ();
    Server_auth.clear_server_state ();
    Buffer.contents response_buf)

let status_of_response response =
  match String.split_on_char ' ' response with
  | _ :: status :: _ -> int_of_string status
  | _ -> Alcotest.failf "could not parse response status: %S" response

let body_of_response response =
  match String.index response '\r' with
  | exception Not_found -> Alcotest.failf "response has no header break: %S" response
  | first_break ->
    (* Split off the header block on the blank line, then take the rest. *)
    let header_and_body = String.sub response first_break (String.length response - first_break) in
    match Astring.String.cut ~sep:"\r\n\r\n" header_and_body with
    | Some (_, body) -> body
    | None -> Alcotest.failf "response has no body separator: %S" response

let latest_seq () =
  match Log.Ring.recent ~limit:1 () with
  | entry :: _ -> entry.Log.Ring.seq
  | [] -> 0

let keeper_entries_since seq =
  Log.Ring.recent
    ~limit:1000
    ~since_seq:seq
    ~module_filter:"Keeper"
    ~order:`Oldest_first
    ()

let with_actor_test_setup f =
  with_temp_dir (fun base_path ->
    let auth_config =
      { Masc_domain.default_auth_config with enabled = true; require_token = true }
    in
    Auth.save_auth_config base_path auth_config;
    let token, _cred =
      create_token_exn base_path ~agent_name:"probe-operator" ~role:Masc_domain.Admin
    in
    let state = Mcp_server.For_testing.create_state ~base_path in
    let keeper = "decision-canary" in
    ignore
      (Masc.Keeper_registry.For_testing.register ~base_path keeper
         (make_keeper_meta keeper));
    Fun.protect
      ~finally:(fun () ->
        Masc.Keeper_registry.For_testing.unregister ~base_path keeper)
      (fun () ->
         Eio_main.run (fun env ->
           let clock = Eio.Stdenv.clock env in
           Eio.Switch.run (fun sw ->
             f ~sw ~clock ~base_path ~state ~token ~keeper))))

(* An ask exists to answer, so the success path — not merely a refusal — is
   what gets its responder checked. *)
let record_one_question ~base_path ~keeper =
  let continuation =
    match Keeper_continuation_channel.dashboard ~thread_id:"thread-actor-1" with
    | Ok c -> c
    | Error e -> Alcotest.fail ("continuation: " ^ e)
  in
  let choice =
    match Keeper_ask.choice ~choice_id:"a" ~label:"Go" () with
    | Ok c -> c
    | Error e -> Alcotest.fail (Keeper_ask.invalid_choice_to_string e)
  in
  let question =
    match
      Keeper_ask.question ~question_id:"q1" ~header:"Route"
        ~prompt:"Which way?" ~choices:[ choice ] ~mode:Keeper_ask.Single
        ~free_text:Keeper_ask.Choices_only
    with
    | Ok q -> q
    | Error e -> Alcotest.fail (Keeper_ask.invalid_question_to_string e)
  in
  let ask =
    match
      Keeper_ask.ask ~ask_id:"ask-actor-1" ~keeper_name:keeper
        ~questions:[ question ] ~context:"actor attribution probe" ~continuation
        ~asked_at:1000.0 ()
    with
    | Ok a -> a
    | Error e -> Alcotest.fail (Keeper_ask.invalid_ask_to_string e)
  in
  (match Keeper_ask_store.record_ask ~base_path ask with
   | Ok () -> ()
   | Error e -> Alcotest.fail ("record_ask: " ^ e))

let test_ask_answer_records_the_token_owner ~sw ~clock ~base_path ~state ~token ~keeper =
  record_one_question ~base_path ~keeper;
  let before_seq = latest_seq () in
  (* The body claims a different actor. The record must carry the token
     owner instead — a self-reported identity is exactly what task-1662
     removes from the trust path. *)
  let body =
    {|{"name":"decision-canary","ask_id":"ask-actor-1","actor_id":"spoofed-name","answers":[{"question_id":"q1","response":{"kind":"chose","choice_ids":["a"]}}]}|}
  in
  let response =
    dispatch_post ~sw ~clock ~state ~token ~path:"/api/v1/keepers/ask-answer" ~body
  in
  check int "ask-answer POST succeeds" 200 (status_of_response response);
  let json =
    Yojson.Safe.from_string (body_of_response response)
  in
  check string "the response echoes the token owner as actor" "probe-operator"
    (U.member "actor" json |> U.to_string);
  (* The durable row, folded fresh off disk, names the token owner. *)
  (match Keeper_ask_store.settled ~base_path ~keeper_name:keeper ~ask_id:"ask-actor-1" with
   | Some (Keeper_ask.Answered_by { responder; _ }) ->
     check (option string) "the recorded responder is the token owner"
       (Some "probe-operator") responder.Keeper_ask.actor_id
   | other ->
     Alcotest.failf "expected an answered resolution, got %s"
       (match other with
        | Some _ -> "a non-answered resolution"
        | None -> "none"));
  let entries = keeper_entries_since before_seq in
  check bool "the ask-answer log line carries the token owner" true
    (List.exists
       (fun (entry : Log.Ring.entry) ->
          Astring.String.is_infix ~affix:"keeper_ask_answer" entry.message
          && Astring.String.is_infix ~affix:"actor=probe-operator" entry.message)
       entries);
  check bool "no log line repeats the spoofed name" true
    (not
       (List.exists
          (fun (entry : Log.Ring.entry) ->
             Astring.String.is_infix ~affix:"spoofed-name" entry.message)
          entries))

let test_tool_approval_stamps_the_token_owner ~sw ~clock ~base_path:_ ~state ~token ~keeper:_ =
  let before_seq = latest_seq () in
  let body =
    {|{"name":"decision-canary","tool_call_id":"call-actor-1","decision":"approve"}|}
  in
  let response =
    dispatch_post ~sw ~clock ~state ~token ~path:"/api/v1/keepers/tool-approval" ~body
  in
  check int "tool-approval POST succeeds" 200 (status_of_response response);
  let json =
    Yojson.Safe.from_string (body_of_response response)
  in
  check string "the response echoes the token owner as actor" "probe-operator"
    (U.member "actor" json |> U.to_string);
  let entries = keeper_entries_since before_seq in
  check bool "the tool-approval log line carries the token owner" true
    (List.exists
       (fun (entry : Log.Ring.entry) ->
          Astring.String.is_infix ~affix:"keeper_tool_approval" entry.message
          && Astring.String.is_infix ~affix:"actor=probe-operator" entry.message)
       entries)

let test_interrupt_stamps_the_token_owner ~sw ~clock ~base_path:_ ~state ~token ~keeper =
  let body = Printf.sprintf {|{"name":%S}|} keeper in
  let response =
    dispatch_post ~sw ~clock ~state ~token ~path:"/api/v1/keepers/turn/interrupt" ~body
  in
  check int "turn-interrupt POST succeeds" 200 (status_of_response response);
  let json =
    Yojson.Safe.from_string (body_of_response response)
  in
  check bool "no turn was in flight" false
    (U.member "signalled" json |> U.to_bool);
  check string "the response echoes the token owner as actor" "probe-operator"
    (U.member "actor" json |> U.to_string)

(* A turn is in flight, so the route takes its success arm: the cancelled
   turn's response carries the actor like the two refusal arms do. The turn
   runs in its own sub-switch so failing it does not cancel the test fiber
   (the shape test_keeper_turn_interrupt.ml uses). *)
let test_cancelled_turn_response_carries_the_actor ~sw ~clock ~base_path ~state ~token ~keeper =
  Masc.Keeper_registry.mark_turn_started ~base_path
    ~wake:Masc.Keeper_registry.Proactive_tick keeper;
  let registered, set_registered = Eio.Promise.create () in
  Eio.Fiber.fork ~sw (fun () ->
    try
      Eio.Switch.run (fun turn_sw ->
        Masc.Keeper_registry.set_turn_switch ~base_path keeper (Some turn_sw);
        Eio.Promise.resolve set_registered ();
        Eio.Time.sleep clock 10.0)
    with
    | Masc.Keeper_registry.Operator_interrupt -> ()
    | Eio.Cancel.Cancelled _ -> ());
  Eio.Promise.await registered;
  let body = Printf.sprintf {|{"name":%S}|} keeper in
  let response =
    dispatch_post ~sw ~clock ~state ~token ~path:"/api/v1/keepers/turn/interrupt" ~body
  in
  check int "turn-interrupt POST succeeds" 200 (status_of_response response);
  let json = Yojson.Safe.from_string (body_of_response response) in
  check bool "the in-flight turn was signalled" true
    (U.member "signalled" json |> U.to_bool);
  check string "the response echoes the token owner as actor" "probe-operator"
    (U.member "actor" json |> U.to_string)

let () =
  run "keeper_decision_actor_log"
    [ ( "decision actor"
      , [ test_case "ask-answer records the token owner, not the body's claim" `Quick
            (fun () ->
               with_actor_test_setup test_ask_answer_records_the_token_owner)
        ; test_case "tool-approval stamps the token owner" `Quick
            (fun () -> with_actor_test_setup test_tool_approval_stamps_the_token_owner)
        ; test_case "turn-interrupt stamps the token owner" `Quick
            (fun () -> with_actor_test_setup test_interrupt_stamps_the_token_owner)
        ; test_case "a cancelled turn's response carries the actor" `Quick
            (fun () ->
               with_actor_test_setup test_cancelled_turn_response_carries_the_actor)
        ] )
    ]
