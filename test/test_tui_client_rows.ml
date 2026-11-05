open Alcotest
module Types = Masc_tui_types

(* A Keeper's own session is filed under the Keeper's name, so the column
   repeated the name beside it -- twelve of fourteen rows on a live
   workspace -- while the row's type already said it was a Keeper. *)
let test_a_keepers_own_session_is_not_acting_for_anyone () =
  check (option string) "the row does not say the name twice" None
    (Types.client_acting_for ~name:"won-chik" ~keeper_name:(Some "won-chik"))

(* The reading the column exists for: a client bound to a Keeper's session
   under a name of its own. *)
let test_a_client_bound_to_a_keeper_names_it () =
  check (option string) "the keeper it stands in for" (Some "won-chik")
    (Types.client_acting_for ~name:"codex-mcp-client"
       ~keeper_name:(Some "won-chik"))

let test_a_client_bound_to_nobody_names_nobody () =
  check (option string) "no keeper to name" None
    (Types.client_acting_for ~name:"dashboard-admin" ~keeper_name:None)

let row ?keeper name : Masc.Tui_decode.client_row =
  { cr_name = name
  ; cr_agent_type = (match keeper with Some _ -> "client" | None -> "keeper")
  ; cr_keeper_name = (match keeper with Some k -> Some k | None -> Some name)
  ; cr_current_task = None
  ; cr_status = Masc.Tui_decode.Client_active
  ; cr_last_seen = Some "2026-09-23T05:06:41Z"
  ; cr_session_bound_at = Some "2026-09-23T04:00:00Z"
  ; cr_capabilities = []
  }

(* On a live workspace every row was a Keeper's own session, so the column
   drew nothing on fourteen rows while the clock at the end of each read
   "01:4…". *)
let test_a_listing_of_keepers_own_sessions_draws_no_column () =
  check bool "no row has a keeper to name" false
    (Types.clients_act_for_others
       [ row "won-chik"; row "polisher"; row "geek-scout" ])

let test_one_bound_client_brings_the_column_back () =
  check bool "the column has a reading to carry" true
    (Types.clients_act_for_others
       [ row "won-chik"; row ~keeper:"polisher" "codex-mcp-client" ])

(* A Keeper registry row comes with no session or observation time: the only
   times the server had for it were the time of the read, and the response
   sends those as null instead of dressing the read up as a fact. *)
let test_a_registry_row_reads_without_times () =
  let row times =
    `Assoc
      ([ "name", `String "won-chik"
       ; "agent_type", `String "keeper"
       ; "status", `String "active"
       ; "current_task", `Null
       ; "keeper_name", `String "won-chik"
       ; "capabilities", `List []
       ]
       @ times)
  in
  let snapshot ?(schema = "masc.dashboard.clients.v2") ?(failures = true) times =
    Masc.Tui_decode.decode_clients_snapshot
      (`Assoc
        ([ "schema", `String schema
         ; "generated_at", `String "2026-11-04T04:00:00Z"
         ; "observation_only", `Bool true
         ; "clients", `List [ row times ]
         ]
         @ (match failures with
            | true -> [ "read_failures", `List [] ]
            | false -> [])))
  in
  (match snapshot [ "session_bound_at", `Null; "last_seen", `Null ] with
   | Ok { Masc.Tui_decode.cls_clients = [ client ]; _ } ->
     check (option string) "no observation time" None client.cr_last_seen;
     check (option string) "no session time" None client.cr_session_bound_at
   | Ok _ | Error _ -> fail "a registry row without times was refused");
  (* A row that leaves the keys out entirely is a different shape, not a row
     without times, and the decoder rejects it. *)
  check bool "a row that leaves the fields out is still refused" true
    (Result.is_error (snapshot []));
  (* v2 is the contract the nullable fields and read_failures belong to; a
     v1 response matches neither and the name says which reader it wants. *)
  check bool "a v1 snapshot is refused" true
    (Result.is_error
       (snapshot ~schema:"masc.dashboard.clients.v1"
          [ "session_bound_at", `Null; "last_seen", `Null ]));
  (* An old server's response carries no read_failures key at all. *)
  check bool "a snapshot without read failures is refused" true
    (Result.is_error (snapshot ~failures:false
                         [ "session_bound_at", `String "2026-11-04T03:00:00Z"
                         ; "last_seen", `String "2026-11-04T03:30:00Z" ]));
  (* An agent record row keeps its own times under the same schema. *)
  (match snapshot
           [ "session_bound_at", `String "2026-11-04T03:00:00Z"
           ; "last_seen", `String "2026-11-04T03:30:00Z" ]
     with
   | Ok { Masc.Tui_decode.cls_clients = [ client ]; _ } ->
     check (option string) "an agent record keeps its observation time"
       (Some "2026-11-04T03:30:00Z") client.cr_last_seen
   | Ok _ | Error _ -> fail "an agent record row with times was refused")

(* The surface's owed read settles once its answer lands (RFC-0480
   §3.4), so launch_owed_clients does not read again on the next loop. *)
let snapshot ?(failures = []) () : Masc.Tui_decode.clients_snapshot =
  { Masc.Tui_decode.cls_observed_at = "2026-11-05T04:00:00Z"
  ; cls_clients = []
  ; cls_read_failures = failures
  }

let test_an_owed_read_that_answers_settles () =
  let state = Masc_tui_types.create_state ~workspace:"test" ~port:8935 ~refresh_interval:2.0 () in
  Masc_tui_types.owe_clients_read state;
  Masc_tui_types.begin_clients_read state;
  Masc_tui_types.settle_clients_read state ~now:0. (Ok (snapshot ()));
  (* Not due is what keeps launch_owed_clients from reading again. *)
  check bool "the settled read is not due again"
    false
    (Masc_tui_owed_read.due ~now:0. state.Masc_tui_types.clients_owed)

let test_an_answer_with_unread_rows_backs_off () =
  let state = Masc_tui_types.create_state ~workspace:"test" ~port:8935 ~refresh_interval:2.0 () in
  Masc_tui_types.owe_clients_read state;
  Masc_tui_types.begin_clients_read state;
  Masc_tui_types.settle_clients_read state ~now:0.
    (Ok (snapshot ~failures:[ "runtime agent roster: read failed" ] ()));
  check bool "a partial roster is not due at once"
    false
    (Masc_tui_owed_read.due ~now:0. state.Masc_tui_types.clients_owed);
  check bool "the retry is due after the backoff"
    true
    (Masc_tui_owed_read.due ~now:2. state.Masc_tui_types.clients_owed)

let () =
  run "tui client rows"
    [ ( "acting for"
      , [ test_case "a keeper's own session is not acting for anyone" `Quick
            test_a_keepers_own_session_is_not_acting_for_anyone
        ; test_case "a client bound to a keeper names it" `Quick
            test_a_client_bound_to_a_keeper_names_it
        ; test_case "a client bound to nobody names nobody" `Quick
            test_a_client_bound_to_nobody_names_nobody
        ] )
    ; ( "the column"
      , [ test_case "a listing of keepers' own sessions draws no column" `Quick
            test_a_listing_of_keepers_own_sessions_draws_no_column
        ; test_case "one bound client brings the column back" `Quick
            test_one_bound_client_brings_the_column_back
        ] )
    ; ( "times"
      , [ test_case "a registry row reads without times" `Quick
            test_a_registry_row_reads_without_times
        ] )
    ; ( "owed read"
      , [ test_case "an owed read that answers settles" `Quick
            test_an_owed_read_that_answers_settles
        ; test_case "an answer with unread rows backs off" `Quick
            test_an_answer_with_unread_rows_backs_off
        ] )
    ]
