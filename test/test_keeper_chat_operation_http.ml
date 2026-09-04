open Alcotest
open Masc

module Api = Server_dashboard_http_keeper_chat_operations

let test_dashboard_worker_permissions () =
  check bool
    "operation list reads use read-state authority"
    true
    (Api.get_permission (Api.Operation_list { keeper_name = "alpha" })
     = Masc_domain.CanReadState);
  check bool
    "exact operation reads use read-state authority"
    true
    (Api.get_permission
       (Api.Operation_exact { keeper_name = "alpha"; raw_operation_id = "kmsg-1" })
     = Masc_domain.CanReadState);
  (* The journal carries reasoning in full: same data as /raw-trace, same
     gate. A Worker token that reads operations must not read events. *)
  check bool
    "chat events read requires admin authority"
    true
    (Api.get_permission (Api.Chat_events { keeper_name = "alpha" })
     = Masc_domain.CanAdmin);
  check bool
    "worker cannot read chat events"
    false
    (Masc_domain.has_permission
       Masc_domain.Worker
       (Api.get_permission (Api.Chat_events { keeper_name = "alpha" })));
  check bool
    "queued mutations use chat broadcast authority"
    true
    (Api.mutation_permission = Masc_domain.CanBroadcast)
;;

let test_exact_routes () =
  (match Api.get_route "/api/v1/keepers/alpha/chat/operations" with
   | Some (Api.Operation_list { keeper_name }) ->
     check string "list keeper" "alpha" keeper_name
   | Some _ | None -> fail "operation list route did not match");
  (match Api.get_route "/api/v1/keepers/alpha/chat/operations/kmsg-1" with
   | Some (Api.Operation_exact { keeper_name; raw_operation_id }) ->
     check string "exact keeper" "alpha" keeper_name;
     check string "exact operation" "kmsg-1" raw_operation_id
   | Some _ | None -> fail "exact operation route did not match");
  (match Api.get_route "/api/v1/keepers/alpha/chat/events" with
   | Some (Api.Chat_events { keeper_name }) ->
     check string "events keeper" "alpha" keeper_name
   | Some _ | None -> fail "chat events route did not match");
  List.iter
    (fun (action, expected) ->
       match
         Api.mutation_route
           ("/api/v1/keepers/alpha/chat/operations/kmsg-1/" ^ action)
       with
       | Some { Api.mutation; _ } ->
         check bool "mutation kind" true (mutation = expected)
       | None -> fail ("mutation route did not match: " ^ action))
    [ "edit", Api.Edit; "move-to-end", Api.Move_to_end; "cancel", Api.Cancel ]
;;

let test_unknown_routes_do_not_match () =
  List.iter
    (fun path ->
       check bool
         ("unknown route rejected: " ^ path)
         true
         (Option.is_none (Api.get_route path)
          && Option.is_none (Api.mutation_route path)))
    [ "/api/v1/keepers/alpha/chat/operations/kmsg-1/retry"
    ; "/api/v1/keepers/alpha/chat/tasks/kmsg-1"
    ; "/api/v1/keepers/alpha/chat/events/kmsg-1"
    ; "/api/v1/keepers/chat/events"
    ]
;;

module E = Keeper_chat_events
module L = Keeper_chat_event_log

(* Seven journaled entries, seq 0..6, ts strictly increasing. *)
let journal : L.journaled_event list =
  [ E.Run_started { run_id = "run-events"; thread_id = "keeper:alpha" }
  ; E.Text_message_start { message_id = "msg-events"; role = E.Assistant }
  ; E.Text_delta "one "
  ; E.Agent_core_thinking_delta { index = 0; delta = "private reasoning" }
  ; E.Text_delta "two"
  ; E.Text_message_end
  ; E.Run_finished { run_id = "run-events" }
  ]
  |> List.mapi (fun seq event ->
    { L.seq; ts = 1_762_300_000.0 +. (float_of_int seq *. 0.5); event })
;;

let page ~since_seq ~limit =
  Api.chat_events_page ~operation_id:"kmsg-events" ~since_seq ~limit journal
;;

let field name = function
  | `Assoc fields ->
    (match List.assoc_opt name fields with
     | Some value -> value
     | None -> fail ("missing field " ^ name))
  | _ -> fail "body is not an object"
;;

let seqs body =
  match field "events" body with
  | `List events ->
    List.map
      (fun event ->
         match field "seq" event with
         | `Int seq -> seq
         | _ -> fail "event seq is not an int")
      events
  | _ -> fail "events is not a list"
;;

let int_field name body =
  match field name body with
  | `Int value -> value
  | _ -> fail (name ^ " is not an int")
;;

let bool_field name body =
  match field name body with
  | `Bool value -> value
  | _ -> fail (name ^ " is not a bool")
;;

let test_chat_events_page_walks_by_seq () =
  let first = page ~since_seq:(-1) ~limit:3 in
  check string
    "schema"
    "masc.keeper_chat_events.v2"
    (match field "schema" first with `String s -> s | _ -> "");
  check string
    "operation id"
    "kmsg-events"
    (match field "operation_id" first with `String s -> s | _ -> "");
  check (list int) "first page seqs" [ 0; 1; 2 ] (seqs first);
  check bool "first page has more" true (bool_field "has_more" first);
  check int "cursor is the last seq served" 2 (int_field "next_since_seq" first);
  let second = page ~since_seq:(int_field "next_since_seq" first) ~limit:3 in
  check (list int) "second page continues without gap or repeat" [ 3; 4; 5 ] (seqs second);
  check bool "second page has more" true (bool_field "has_more" second);
  let third = page ~since_seq:(int_field "next_since_seq" second) ~limit:3 in
  check (list int) "third page is the tail" [ 6 ] (seqs third);
  check bool "tail has no more" false (bool_field "has_more" third);
  check int "tail cursor" 6 (int_field "next_since_seq" third);
  let empty = page ~since_seq:6 ~limit:3 in
  check (list int) "past the end is empty" [] (seqs empty);
  check bool "empty page has no more" false (bool_field "has_more" empty);
  check int
    "an empty page hands the caller's cursor back unchanged"
    6
    (int_field "next_since_seq" empty)
;;

(* The response is the journal as written: each element is the stage-1
   envelope, reasoning delta included -- which is why the route is CanAdmin. *)
let test_chat_events_are_the_journal_lines () =
  let body = page ~since_seq:(-1) ~limit:Api.chat_events_default_limit in
  (match field "events" body with
   | `List events ->
     check int "every entry served" (List.length journal) (List.length events);
     List.iter2
       (fun served (entry : L.journaled_event) ->
          check bool
            (Printf.sprintf "seq %d served exactly as journaled" entry.seq)
            true
            (Yojson.Safe.equal served (L.journaled_event_to_json entry)))
       events
       journal
   | _ -> fail "events is not a list");
  (match field "events" body with
   | `List events ->
     let thinking =
       List.find_opt (fun event -> int_field "seq" event = 3) events
       |> Option.map (fun event -> field "delta" (field "event" event))
     in
     check bool
       "the reasoning delta is served verbatim"
       true
       (match thinking with
        | Some (`String delta) -> String.equal delta "private reasoning"
        | Some _ | None -> false)
   | _ -> fail "events is not a list");
  check bool
    "limit ceiling is above the default"
    true
    (Api.chat_events_max_limit > Api.chat_events_default_limit)
;;

let test_mutation_bodies_are_closed () =
  let input =
    `Assoc
      [ "schema", `String "masc.keeper_chat_operation.input.v1"
      ; "message", `String "edited"
      ; "user_blocks", `List []
      ; "turn_instructions", `Null
      ; "surface_context", `Null
      ; "attachments", `List []
      ]
  in
  let body = `Assoc [ "input", input ] |> Yojson.Safe.to_string in
  (match Api.For_testing.parse_mutation_body Api.Edit body with
   | Ok (Some observed) when Yojson.Safe.equal input observed -> ()
   | Ok _ -> fail "edit input projection changed"
   | Error code -> fail ("valid edit rejected: " ^ code));
  List.iter
    (fun body ->
       match Api.For_testing.parse_mutation_body Api.Edit body with
       | Error "invalid_input" -> ()
       | Error code -> fail ("wrong edit error: " ^ code)
       | Ok _ -> fail ("invalid edit body accepted: " ^ body))
    [ {|{"input":{"message":"edited"},"obsolete_authority":"old"}|}
    ; {|{"input":{"message":"edited"}}|}
    ; {|{"input":{},"input":{}}|}
    ; {|{"message":"flattened body"}|}
    ];
  List.iter
    (fun mutation ->
       (match Api.For_testing.parse_mutation_body mutation "{}" with
        | Ok None -> ()
        | Ok (Some _) -> fail "empty mutation unexpectedly returned input"
        | Error code -> fail ("empty mutation rejected: " ^ code));
       List.iter
         (fun body ->
            match Api.For_testing.parse_mutation_body mutation body with
            | Error "invalid_input" -> ()
            | Error code -> fail ("wrong closed mutation error: " ^ code)
            | Ok _ -> fail ("unknown mutation field accepted: " ^ body))
         [ {|{"obsolete_authority":"old"}|}; {|{"input":null}|} ])
    [ Api.Move_to_end; Api.Cancel ]
;;

let () =
  run
    "keeper chat operation http"
    [ ( "routes"
      , [ test_case
            "dashboard Worker permissions"
            `Quick
            test_dashboard_worker_permissions
        ; test_case "exact operation routes" `Quick test_exact_routes
        ; test_case "unknown routes do not match" `Quick test_unknown_routes_do_not_match
        ; test_case "mutation bodies are closed" `Quick test_mutation_bodies_are_closed
        ] )
    ; ( "chat events"
      , [ test_case "page walks by seq" `Quick test_chat_events_page_walks_by_seq
        ; test_case
            "events are the journal lines"
            `Quick
            test_chat_events_are_the_journal_lines
        ] )
    ]
;;
