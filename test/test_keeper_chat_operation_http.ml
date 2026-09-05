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

let page ?(redact_json = Fun.id) ~since_seq ~limit () =
  Api.chat_events_page ~operation_id:"kmsg-events" ~since_seq ~limit ~redact_json journal
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
  let first = page ~since_seq:(-1) ~limit:3 () in
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
  let second = page ~since_seq:(int_field "next_since_seq" first) ~limit:3 () in
  check (list int) "second page continues without gap or repeat" [ 3; 4; 5 ] (seqs second);
  check bool "second page has more" true (bool_field "has_more" second);
  let third = page ~since_seq:(int_field "next_since_seq" second) ~limit:3 () in
  check (list int) "third page is the tail" [ 6 ] (seqs third);
  check bool "tail has no more" false (bool_field "has_more" third);
  check int "tail cursor" 6 (int_field "next_since_seq" third);
  let empty = page ~since_seq:6 ~limit:3 () in
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
  let body = page ~since_seq:(-1) ~limit:Keeper_chat_event_log.page_default_limit () in
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
    (Keeper_chat_event_log.page_max_limit > Keeper_chat_event_log.page_default_limit)
;;

(* The served lines pass through the caller's redaction; the journal line
   itself is untouched. *)
let rec mask_private = function
  | `String text when Astring.String.is_infix ~affix:"private" text -> `String "[REDACTED]"
  | `Assoc fields -> `Assoc (List.map (fun (key, value) -> key, mask_private value) fields)
  | `List values -> `List (List.map mask_private values)
  | (`String _ | `Int _ | `Float _ | `Bool _ | `Null | `Intlit _) as scalar -> scalar
;;

let test_chat_events_are_redacted_per_line () =
  let body =
    page ~redact_json:mask_private ~since_seq:(-1) ~limit:Keeper_chat_event_log.page_default_limit ()
  in
  match field "events" body with
  | `List events ->
    let served =
      List.find_opt (fun event -> int_field "seq" event = 3) events
      |> Option.map (fun event -> field "delta" (field "event" event))
    in
    check bool
      "the reasoning delta is served redacted"
      true
      (match served with
       | Some (`String delta) -> String.equal delta "[REDACTED]"
       | Some _ | None -> false);
    check bool
      "redaction is at serving, not in the journal line"
      true
      (Yojson.Safe.to_string (L.journaled_event_to_json (List.nth journal 3))
       |> Astring.String.is_infix ~affix:"private reasoning")
  | _ -> fail "events is not a list"
;;

let test_missing_journal_is_classified_by_the_row () =
  let classify = Api.classify_missing_journal in
  check bool "no row is an unknown operation" true (classify None = Api.Unknown_operation);
  check bool
    "a queued row has nothing journaled yet"
    true
    (classify (Some Keeper_owner.Chat_operation.Queued) = Api.Nothing_journaled_yet);
  check bool
    "a running row has nothing journaled yet"
    true
    (classify (Some (Keeper_owner.Chat_operation.Running { started_at = 1.0 }))
     = Api.Nothing_journaled_yet);
  check bool
    "a succeeded row means the journal was pruned"
    true
    (classify
       (Some
          (Keeper_owner.Chat_operation.Succeeded
             { completed_at = 2.0; outcome_ref = "outcome-1" }))
     = Api.Journal_pruned);
  check bool
    "a cancelled row means the journal was pruned"
    true
    (classify (Some (Keeper_owner.Chat_operation.Cancelled { completed_at = 2.0 }))
     = Api.Journal_pruned)
;;

(* F3 from the adversarial review: pin the permission through the same
   authorizer the router runs, not only the table. Worker holds CanReadState,
   which reads operations; the events log is CanAdmin. *)
let temp_base prefix =
  let path =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "%s-%d-%d" prefix (Unix.getpid ()) (Random.bits ()))
  in
  Unix.mkdir path 0o700;
  path
;;

let rec rm_rf path =
  if Sys.file_exists path
  then
    if Sys.is_directory path
    then begin
      Sys.readdir path |> Array.iter (fun name -> rm_rf (Filename.concat path name));
      Unix.rmdir path
    end
    else Sys.remove path
;;

let test_chat_events_route_needs_admin_through_the_authorizer () =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_path = temp_base "keeper-chat-events-auth" in
  Eio.Switch.run
  @@ fun sw ->
  Eio.Switch.on_release sw (fun () -> rm_rf base_path);
  let config = Workspace_core.default_config base_path in
  ignore (Workspace_core.init config ~agent_name:(Some "test"));
  Auth.save_auth_config
    base_path
    { Masc_domain.default_auth_config with enabled = true; require_token = true };
  let token ~agent_name ~role =
    match Auth.create_token base_path ~agent_name ~role with
    | Ok (token, _) -> token
    | Error error -> fail (Masc_domain.masc_error_to_string error)
  in
  let worker = token ~agent_name:"worker" ~role:Masc_domain.Worker in
  let admin = token ~agent_name:"admin" ~role:Masc_domain.Admin in
  let path = "/api/v1/keepers/alpha/chat/events" in
  let permission =
    match Api.get_route path with
    | Some route -> Api.get_permission route
    | None -> fail "events route did not resolve"
  in
  let authorize request =
    Server_auth.authorize_token_bound_permission_request ~base_path ~permission request
  in
  let bearer token =
    Httpun.Request.create
      ~headers:(Httpun.Headers.of_list [ "authorization", "Bearer " ^ token ])
      `GET
      path
  in
  (match authorize (Httpun.Request.create `GET path) with
   | Error error ->
     check bool
       "anonymous is unauthorized"
       true
       (Server_auth.http_status_of_auth_error error = `Unauthorized)
   | Ok actor -> fail ("anonymous resolved actor " ^ actor));
  (match authorize (bearer worker) with
   | Error error ->
     check bool
       "Worker is forbidden"
       true
       (Server_auth.http_status_of_auth_error error = `Forbidden)
   | Ok actor -> fail ("Worker resolved actor " ^ actor));
  check (result string string)
    "Admin reads the events log"
    (Ok "admin")
    (authorize (bearer admin) |> Result.map_error Masc_domain.masc_error_to_string)
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
        ; test_case
            "events are redacted per line"
            `Quick
            test_chat_events_are_redacted_per_line
        ; test_case
            "missing journal is classified by the row"
            `Quick
            test_missing_journal_is_classified_by_the_row
        ; test_case
            "route needs admin through the authorizer"
            `Quick
            test_chat_events_route_needs_admin_through_the_authorizer
        ] )
    ]
;;
