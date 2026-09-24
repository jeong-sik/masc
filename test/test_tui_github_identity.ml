(* The Keeper GitHub tab rows, drawn from payloads in the shape
   Keeper_github_identity.observation_to_yojson builds. *)

let reading ?(authenticated = Some (`Bool true)) ?(login = `String "pangyo-preachers")
    ?(scopes = `List [ `String "repo"; `String "workflow" ]) () =
  `Assoc
    ((match authenticated with Some value -> [ "authenticated", value ] | None -> [])
     @ [ "login", login; "scopes", scopes; "error", `Null ])

let payload ~stored ~effective =
  `Assoc
    [ "ok", `Bool true
    ; "keeper", `String "code-reviewer"
    ; "hostname", `String "github.com"
    ; "config_dir", `String "/keepers/code-reviewer/github-cli"
    ; "projected_token_env_names", `List []
    ; "stored", stored
    ; "effective", effective
    ; "effective_probe_scope", `String "host_process_credential_only"
    ; "checked_at_unix", `Float 0.
    ]

let rows json = Masc_tui_github_identity.view_lines ~sanitize:Fun.id json

let identity_rows json =
  List.filter
    (fun row ->
      String.starts_with ~prefix:"  stored" row
      || String.starts_with ~prefix:"  effective" row)
    (rows json)

(* On a plain login the two readings agree, and the tab drew the same
   sentence twice under two labels. Agreement is one row carrying both. *)
let test_agreeing_readings_share_one_row () =
  Alcotest.(check (list string))
    "one row, both labels"
    [ "  stored and effective (this host): signed in as pangyo-preachers \xc2\xb7 scopes: repo, workflow" ]
    (identity_rows (payload ~stored:(reading ()) ~effective:(reading ())))

(* The second row exists to show a difference, so a difference keeps it. *)
let test_differing_readings_take_a_row_each () =
  Alcotest.(check (list string))
    "two rows"
    [ "  stored: signed in as pangyo-preachers \xc2\xb7 scopes: repo, workflow"
    ; "  effective (this host): signed in as pangyo-preachers \xc2\xb7 scopes: repo"
    ]
    (identity_rows
       (payload ~stored:(reading ())
          ~effective:(reading ~scopes:(`List [ `String "repo" ]) ())))

(* A server that leaves "authenticated" out has not said no. Drawing it as
   "not signed in" sends the operator to sign in a Keeper that already is. *)
let test_a_missing_sign_in_is_unreported_not_refused () =
  let missing = reading ~authenticated:None () in
  let refused = reading ~authenticated:(Some (`Bool false)) () in
  Alcotest.(check (list string))
    "missing and refused read differently"
    [ "  stored: sign-in not reported"; "  effective (this host): not signed in" ]
    (identity_rows (payload ~stored:missing ~effective:refused))

(* A payload without a hostname, such as an error envelope, is drawn whole
   rather than as an empty tab. *)
let test_an_unknown_shape_is_drawn_whole () =
  let envelope = `Assoc [ "ok", `Bool false; "error", `String "keeper not found" ] in
  Alcotest.(check (list string))
    "pretty-printed payload"
    (String.split_on_char '\n' (Yojson.Safe.pretty_to_string envelope))
    (rows envelope)

let () =
  Alcotest.run "tui_github_identity"
    [ ( "rows"
      , [ Alcotest.test_case "agreeing readings share one row" `Quick
            test_agreeing_readings_share_one_row
        ; Alcotest.test_case "differing readings take a row each" `Quick
            test_differing_readings_take_a_row_each
        ; Alcotest.test_case "a missing sign-in is unreported, not refused" `Quick
            test_a_missing_sign_in_is_unreported_not_refused
        ; Alcotest.test_case "an unknown shape is drawn whole" `Quick
            test_an_unknown_shape_is_drawn_whole
        ] )
    ]
