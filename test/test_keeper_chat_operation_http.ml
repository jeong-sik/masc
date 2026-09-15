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

(* The journal as the store holds it: one encoded row per line. *)
let rows_of entries =
  String.concat "" (List.map (fun entry -> L.journaled_event_to_string entry ^ "\n") entries)
;;

let rows = rows_of journal
let journal_file = "kmsg-events.jsonl"

let served_page ?(start = L.From_first_row) ~since_seq ~limit rows =
  match L.page_of_rows ~path:journal_file ~since_seq ~start ~limit rows with
  | Ok page -> page
  | Error failure -> fail ("page refused: " ^ L.page_failure_to_string failure)
;;

let page ?(redact_json = Fun.id) ?start ~since_seq ~limit () =
  Api.chat_events_page
    ~operation_id:"kmsg-events"
    ~since_seq
    ~redact_json
    (served_page ?start ~since_seq ~limit rows)
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
  let first = page ~since_seq:L.Whole_turn ~limit:3 () in
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
  let second = page ~since_seq:(L.After_seq (int_field "next_since_seq" first)) ~limit:3 () in
  check (list int) "second page continues without gap or repeat" [ 3; 4; 5 ] (seqs second);
  check bool "second page has more" true (bool_field "has_more" second);
  let third = page ~since_seq:(L.After_seq (int_field "next_since_seq" second)) ~limit:3 () in
  check (list int) "third page is the tail" [ 6 ] (seqs third);
  check bool "tail has no more" false (bool_field "has_more" third);
  check int "tail cursor" 6 (int_field "next_since_seq" third);
  let empty = page ~since_seq:(L.After_seq 6) ~limit:3 () in
  check (list int) "past the end is empty" [] (seqs empty);
  check bool "empty page has no more" false (bool_field "has_more" empty);
  check int
    "an empty page hands the caller's cursor back unchanged"
    6
    (int_field "next_since_seq" empty);
  let nothing = page ~since_seq:L.Whole_turn ~limit:3 () in
  check (list int) "a whole-turn page starts at seq 0" [ 0; 1; 2 ] (seqs nothing);
  (* An empty page for the whole journal has no seq to hand back, and a
     response field cannot be absent the way the request's was: it is null,
     which a client reads as the whole journal again. *)
  check bool
    "an empty whole-journal page hands back null"
    true
    (field
       "next_since_seq"
       (Api.chat_events_page
          ~operation_id:"kmsg-events"
          ~since_seq:L.Whole_turn
          ~redact_json:Fun.id
          (L.empty_page L.From_first_row))
     = `Null);
  check int
    "an empty page from the first row hands back offset 0"
    0
    (int_field
       "next_since_offset"
       (Api.chat_events_page
          ~operation_id:"kmsg-events"
          ~since_seq:L.Whole_turn
          ~redact_json:Fun.id
          (L.empty_page L.From_first_row)))
;;

(* The pages a client reads by feeding both cursors back are the journal
   filtered past the position it started from: no row twice, none missing,
   and each page starts where the page before ended in the bytes. *)
let test_chat_events_page_walks_by_offset () =
  let seqs_of entries = List.map (fun (entry : L.journaled_event) -> entry.seq) entries in
  let walk ~since_seq =
    let rec next ~since_seq ~start acc =
      let body = page ~start ~since_seq ~limit:3 () in
      let acc = List.rev_append (seqs body) acc in
      let next_since_seq =
        match field "next_since_seq" body with
        | `Int seq -> L.After_seq seq
        | `Null -> L.Whole_turn
        | _ -> fail "next_since_seq is neither an int nor null"
      in
      let start = L.From_offset (int_field "next_since_offset" body) in
      if bool_field "has_more" body
      then next ~since_seq:next_since_seq ~start acc
      else List.rev acc
    in
    next ~since_seq ~start:L.From_first_row []
  in
  check (list int)
    "a walk from the whole journal serves every row once"
    (seqs_of journal)
    (walk ~since_seq:L.Whole_turn);
  check (list int)
    "a walk from a held seq serves the rows past it once"
    (seqs_of (List.filter (fun (entry : L.journaled_event) -> entry.seq > 1) journal))
    (walk ~since_seq:(L.After_seq 1));
  let first = page ~since_seq:L.Whole_turn ~limit:3 () in
  check int
    "the first page ends in the bytes after its last row"
    (String.length (rows_of (List.filteri (fun index _ -> index < 3) journal)))
    (int_field "next_since_offset" first);
  let last = page ~since_seq:L.Whole_turn ~limit:L.page_max_limit () in
  check int
    "a page to the end hands back the end of the rows"
    (String.length rows)
    (int_field "next_since_offset" last);
  check bool
    "the wire spells the first row as an absent offset"
    true
    (L.page_start_of_wire None = Some L.From_first_row
     && L.page_start_of_wire (Some 0) = Some (L.From_offset 0)
     && Option.is_none (L.page_start_of_wire (Some (-1))))
;;

(* A page decodes the rows it serves and the one after, not the rest: a
   corrupt row further down fails only the page that reaches it. A cursor the
   rows cannot place is refused by its own name. *)
let test_chat_events_page_refuses_what_it_cannot_place () =
  let with_corrupt_tail = rows ^ "this complete row is not an envelope\n" in
  check (list int)
    "a page before the corrupt row is served"
    [ 0; 1; 2 ]
    (List.map
       (fun (entry : L.journaled_event) -> entry.seq)
       (served_page ~since_seq:L.Whole_turn ~limit:3 with_corrupt_tail).events);
  let refused ~since_seq ~start ~limit rows =
    match L.page_of_rows ~path:journal_file ~since_seq ~start ~limit rows with
    | Ok page ->
      failf "a page was served with %d events" (List.length page.L.events)
    | Error failure -> failure
  in
  check bool
    "the page that reaches the corrupt row is corrupt"
    true
    (match
       refused
         ~since_seq:(L.After_seq 5)
         ~start:(L.From_offset (String.length (rows_of (List.filteri (fun index _ -> index < 6) journal))))
         ~limit:3
         with_corrupt_tail
     with
     | L.Page_corrupt _ -> true
     | L.Page_offset_past_rows _ | L.Page_offset_inside_row _ | L.Page_cursor_mismatch _ ->
       false);
  check bool
    "an offset inside a row is refused"
    true
    (match refused ~since_seq:L.Whole_turn ~start:(L.From_offset 1) ~limit:3 rows with
     | L.Page_offset_inside_row 1 -> true
     | L.Page_offset_inside_row _ | L.Page_offset_past_rows _ | L.Page_cursor_mismatch _
     | L.Page_corrupt _ -> false);
  check bool
    "an offset past the rows is refused"
    true
    (match
       refused
         ~since_seq:L.Whole_turn
         ~start:(L.From_offset (String.length rows + 1))
         ~limit:3
         rows
     with
     | L.Page_offset_past_rows { offset; rows_end } ->
       offset = String.length rows + 1 && rows_end = String.length rows
     | L.Page_offset_inside_row _ | L.Page_cursor_mismatch _ | L.Page_corrupt _ -> false);
  let first = page ~since_seq:L.Whole_turn ~limit:3 () in
  check bool
    "an offset paired with a seq from a later page is refused"
    true
    (match
       refused
         ~since_seq:(L.After_seq 5)
         ~start:(L.From_offset (int_field "next_since_offset" first))
         ~limit:3
         rows
     with
     | L.Page_cursor_mismatch { since_seq; row_seq; _ } -> since_seq = 5 && row_seq = 3
     | L.Page_offset_past_rows _ | L.Page_offset_inside_row _ | L.Page_corrupt _ -> false)
;;

(* The response is the journal as written: each element is the stage-1
   envelope, reasoning delta included -- which is why the route is CanAdmin. *)
let test_chat_events_are_the_journal_lines () =
  let body = page ~since_seq:L.Whole_turn ~limit:Keeper_chat_event_log.page_default_limit () in
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
    page
      ~redact_json:mask_private
      ~since_seq:L.Whole_turn
      ~limit:Keeper_chat_event_log.page_default_limit
      ()
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
    "a succeeded row with no journal is a settled operation without one"
    true
    (classify
       (Some
          (Keeper_owner.Chat_operation.Succeeded
             { completed_at = 2.0; outcome_ref = "outcome-1" }))
     = Api.No_journal_for_settled_operation);
  check bool
    "a cancelled row with no journal is a settled operation without one"
    true
    (classify (Some (Keeper_owner.Chat_operation.Cancelled { completed_at = 2.0 }))
     = Api.No_journal_for_settled_operation);
  (* The server cannot tell a retention prune from an append that never
     created the file, so the message names the operation and its ended
     state and claims no cause. *)
  let message =
    Api.For_testing.no_journal_for_settled_operation_message ~operation_id:"kmsg-gone"
  in
  check bool
    "the message names the operation"
    true
    (Astring.String.is_infix ~affix:"kmsg-gone" message);
  List.iter
    (fun claim ->
       check bool
         ("the message does not claim a cause: " ^ claim)
         false
         (Astring.String.is_infix ~affix:claim message))
    [ "retention"; "aged"; "prune" ]
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
        ; test_case "page walks by offset" `Quick test_chat_events_page_walks_by_offset
        ; test_case
            "page refuses what it cannot place"
            `Quick
            test_chat_events_page_refuses_what_it_cannot_place
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
