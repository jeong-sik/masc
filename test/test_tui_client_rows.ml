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

(* A Keeper registry row comes with no session or observation time, since
   the only ones the server had were the time of the read. *)
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
  let snapshot times =
    Masc.Tui_decode.decode_clients_snapshot
      (`Assoc
        [ "schema", `String "masc.dashboard.clients.v1"
        ; "generated_at", `String "2026-11-04T04:00:00Z"
        ; "observation_only", `Bool true
        ; "clients", `List [ row times ]
        ])
  in
  (match snapshot [ "session_bound_at", `Null; "last_seen", `Null ] with
   | Ok { cls_clients = [ client ]; _ } ->
     check (option string) "no observation time" None client.cr_last_seen;
     check (option string) "no session time" None client.cr_session_bound_at
   | Ok _ | Error _ -> fail "a registry row without times was refused");
  check bool "a row that leaves the fields out is still refused" true
    (Result.is_error (snapshot []))

let () =
  run "tui client rows"
    [ ( "times"
      , [ test_case "a registry row reads without times" `Quick
            test_a_registry_row_reads_without_times ] )
    ; ( "acting for"
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
    ]
