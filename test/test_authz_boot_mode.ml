(* The boot judgment of the account mode: every row of the table in design 5.1,
   reasons that come together, the settings that Multi_account refuses, and the
   account_mode member of config.json. No files, clock, or network. *)

module B = Authz_boot_mode
module H = Authz_high_water

let mode = Alcotest.testable (fun fmt m -> Format.pp_print_string fmt (B.mode_to_string m)) ( = )

let refusals =
  Alcotest.testable
    (fun fmt rs -> Format.pp_print_string fmt (String.concat "; " (List.map B.refusal_to_string rs)))
    ( = )
;;

let secure = B.Settings_read { enabled = true; require_token = true }
let some_hash = Option.get (Authz_record.Hash.of_hex (String.make 64 'a'))

(* The three values of the high-water column. A mismatch and a store that cannot
   be read are one cell of the table; a refusal over a store that cannot be read
   says so instead of calling it a rewind. *)
let absent = B.Judged H.Absent
let matches = B.Judged H.Matches
let mismatch = B.Judged (H.Mismatch (H.Commit_not_in_log some_hash, []))
let unreadable_store = B.Store_unreadable "install record corrupt"
let store_unreadable = B.External_store_unreadable "install record corrupt"

(* The table reads only that the last mode event is Off. The state rides along
   to the boot, which keeps its records read-only (row 4). *)
let off = B.Made_off Authz_state.empty

let input ?(settings = secure) ?(anonymous_mutations = false) requested log_mode high_water =
  { B.requested; log_mode; high_water; settings; anonymous_mutations }
;;

let su = B.Requested Masc_domain.Single_user
let ma = B.Requested Masc_domain.Multi_account

let expect_mode name expected i =
  match B.judge i with
  | Ok got -> Alcotest.check mode name expected got
  | Error (r, rs) ->
    Alcotest.failf "%s: refused: %s" name (String.concat "; " (List.map B.refusal_to_string (r :: rs)))
;;

let expect_refused name expected i =
  match B.judge i with
  | Ok got -> Alcotest.failf "%s: booted as %s" name (B.mode_to_string got)
  | Error (r, rs) -> Alcotest.check refusals name expected (r :: rs)
;;

let test_rows () =
  (* Row 1: the behavior without accounts. *)
  expect_mode "row 1, no member" B.Single_user (input B.Not_set B.No_mode_event absent);
  expect_mode "row 1, Single_user" B.Single_user (input su B.No_mode_event absent);
  (* Row 2: the store says something was answered, the log has no mode event. *)
  List.iter
    (fun hw -> expect_refused "row 2" [ B.Rewound_before_bootstrap ] (input su B.No_mode_event hw))
    [ matches; mismatch ];
  expect_refused "row 2, store unreadable" [ store_unreadable ] (input su B.No_mode_event unreadable_store);
  (* Row 3: lowering the config alone. *)
  List.iter
    (fun hw ->
       expect_refused "row 3" [ B.Downgraded_from_multi_account ] (input B.Not_set B.Made_multi_account hw))
    [ absent; matches; mismatch; unreadable_store ];
  (* Row 4: a single user after Off, with the state the log replayed to. *)
  List.iter
    (fun requested ->
       match B.judge (input requested off matches) with
       | Ok (B.Single_user_after_off state) ->
         Alcotest.(check bool) "row 4 hands on the state of the log" true (state == Authz_state.empty)
       | Ok got -> Alcotest.failf "row 4: booted as %s" (B.mode_to_string got)
       | Error (r, rs) ->
         Alcotest.failf "row 4: refused: %s" (String.concat "; " (List.map B.refusal_to_string (r :: rs))))
    [ B.Not_set; su ];
  (* Row 5: a request before activation. *)
  expect_mode "row 5" B.Activation_requested (input ma B.No_mode_event absent);
  (* Row 6: a rewind, not a new installation. *)
  List.iter
    (fun hw -> expect_refused "row 6" [ B.Rewound_before_bootstrap ] (input ma B.No_mode_event hw))
    [ matches; mismatch ];
  expect_refused "row 6, store unreadable" [ store_unreadable ] (input ma B.No_mode_event unreadable_store);
  (* Rows 7 and 8. *)
  expect_mode "row 7" B.Multi_account (input ma B.Made_multi_account matches);
  List.iter
    (fun hw -> expect_mode "row 8" B.Multi_account_uncertain (input ma B.Made_multi_account hw))
    [ absent; mismatch; unreadable_store ];
  (* Row 9: a reactivation without the recovery procedure. *)
  expect_refused "row 9" [ B.Reactivation_not_ready ] (input ma off matches);
  (* Row 10: Off with a store that does not match, whatever the config asks. *)
  List.iter
    (fun requested ->
       List.iter
         (fun hw -> expect_refused "row 10" [ B.Rewound_after_off ] (input requested off hw))
         [ absent; mismatch ];
       expect_refused "row 10, store unreadable" [ store_unreadable ] (input requested off unreadable_store))
    [ B.Not_set; su; ma ];
  (* Row 11: an unknown value, whatever the log and the store say. *)
  List.iter
    (fun (log, hw) ->
       expect_refused "row 11" [ B.Unknown_account_mode "null" ] (input (B.Unknown_value "null") log hw))
    [ B.No_mode_event, absent; B.Made_multi_account, matches; off, matches ];
  (* The rewind does not depend on the config, so it comes with the unknown value. *)
  expect_refused
    "row 11 over a rewind"
    [ B.Unknown_account_mode "null"; B.Rewound_before_bootstrap ]
    (input (B.Unknown_value "null") B.No_mode_event matches)
;;

let test_unreadable_log_refuses_every_config () =
  List.iter
    (fun requested ->
       expect_refused
         "unreadable log"
         [ B.Authorization_log_unreadable "line 3" ]
         (input requested (B.Log_unreadable "line 3") absent))
    [ B.Not_set; su; ma ]
;;

let test_every_reason_is_returned () =
  expect_refused
    "unknown value and unreadable log"
    [ B.Unknown_account_mode "1"; B.Authorization_log_unreadable "torn" ]
    (input (B.Unknown_value "1") (B.Log_unreadable "torn") absent);
  expect_refused
    "unknown value and Off rewound"
    [ B.Unknown_account_mode "\"multi_account\""; B.Rewound_after_off ]
    (input (B.Unknown_value "\"multi_account\"") off mismatch);
  expect_refused
    "rewind and every insecure setting"
    [ B.Rewound_before_bootstrap
    ; B.Auth_disabled_in_multi_account
    ; B.Token_not_required_in_multi_account
    ; B.Anonymous_mutations_in_multi_account
    ]
    (input
       ~settings:(B.Settings_read { enabled = false; require_token = false })
       ~anonymous_mutations:true
       ma
       B.No_mode_event
       matches)
;;

let test_multi_account_refuses_insecure_settings () =
  let ready = input ma B.Made_multi_account matches in
  expect_refused
    "auth disabled"
    [ B.Auth_disabled_in_multi_account ]
    { ready with settings = B.Settings_read { enabled = false; require_token = true } };
  expect_refused
    "token not required"
    [ B.Token_not_required_in_multi_account ]
    { ready with settings = B.Settings_read { enabled = true; require_token = false } };
  expect_refused
    "anonymous mutations"
    [ B.Anonymous_mutations_in_multi_account ]
    { ready with anonymous_mutations = true };
  expect_refused
    "settings that do not decode"
    [ B.Auth_settings_unreadable_in_multi_account "duplicate field" ]
    { ready with settings = B.Settings_unreadable "duplicate field" };
  (* Before activation too: only a bootstrap runs, and it runs on these settings. *)
  expect_refused
    "activation with auth disabled"
    [ B.Auth_disabled_in_multi_account ]
    (input ~settings:(B.Settings_read { enabled = false; require_token = true }) ma B.No_mode_event absent);
  expect_refused
    "activation with token not required"
    [ B.Token_not_required_in_multi_account ]
    (input ~settings:(B.Settings_read { enabled = true; require_token = false }) ma B.No_mode_event absent);
  expect_refused
    "activation with anonymous mutations"
    [ B.Anonymous_mutations_in_multi_account ]
    (input ~anonymous_mutations:true ma B.No_mode_event absent);
  (* An uncertain multi-account boot is a multi-account boot. *)
  expect_refused
    "uncertain with auth disabled"
    [ B.Auth_disabled_in_multi_account; B.Anonymous_mutations_in_multi_account ]
    (input
       ~settings:(B.Settings_read { enabled = false; require_token = true })
       ~anonymous_mutations:true
       ma
       B.Made_multi_account
       mismatch)
;;

let test_unknown_value_does_not_judge_settings () =
  (* The value is refused for itself; the settings of a mode nobody asked for
     are not reasons. *)
  expect_refused
    "unknown value"
    [ B.Unknown_account_mode "1" ]
    (input
       ~settings:(B.Settings_read { enabled = false; require_token = false })
       ~anonymous_mutations:true
       (B.Unknown_value "1")
       B.No_mode_event
       absent)
;;

let test_single_user_keeps_its_settings () =
  (* A single-user boot does not judge the other fields: a request that reads a
     broken config still gets 503, as before. *)
  expect_mode
    "unreadable settings"
    B.Single_user
    (input ~settings:(B.Settings_unreadable "not an object") ~anonymous_mutations:true su B.No_mode_event absent);
  expect_mode
    "auth disabled"
    B.Single_user
    (input ~settings:(B.Settings_read { enabled = false; require_token = false }) B.Not_set B.No_mode_event absent)
;;

(* A state with a mode event comes only from records, so Multi_account and
   Off are read from real logs in test_authz_boot_mode_read. *)
let test_mode_events () =
  Alcotest.(check bool) "no bootstrap" true (B.of_state Authz_state.empty = B.No_mode_event)
;;

(* The account_mode member of config.json. *)

let decode text = Masc_domain.auth_config_of_yojson (Yojson.Safe.from_string text)

let test_config_member_is_optional () =
  match decode {|{"enabled":true,"require_token":true}|} with
  | Error e -> Alcotest.fail e
  | Ok cfg ->
    Alcotest.(check bool) "absent member" true (cfg.account_mode = None);
    let json = Masc_domain.auth_config_to_yojson cfg in
    Alcotest.(check bool)
      "no member written back"
      false
      (match json with
       | `Assoc fields -> List.mem_assoc "account_mode" fields
       | _ -> true)
;;

let test_config_member_survives_a_rewrite () =
  (* enable_auth, disable_auth and prepare_login_auth rewrite the record with
     [{ cfg with ... }]; the member has to come back from the encoder. *)
  match decode {|{"enabled":true,"require_token":true,"account_mode":"Multi_account"}|} with
  | Error e -> Alcotest.fail e
  | Ok cfg ->
    let rewritten = { cfg with Masc_domain.enabled = false; require_token = true } in
    (match Masc_domain.auth_config_of_yojson (Masc_domain.auth_config_to_yojson rewritten) with
     | Error e -> Alcotest.fail e
     | Ok back ->
       Alcotest.(check bool) "Multi_account kept" true (back.account_mode = Some Masc_domain.Multi_account))
;;

let test_config_member_shapes () =
  List.iter
    (fun text ->
       match decode text with
       | Ok _ -> Alcotest.failf "accepted %s" text
       | Error _ -> ())
    [ {|{"account_mode":null}|}
    ; {|{"account_mode":1}|}
    ; {|{"account_mode":{"mode":"Multi_account"}}|}
    ; {|{"account_mode":"multi_account"}|}
    ; {|{"account_mode":"Single_user","account_mode":"Multi_account"}|}
    ];
  match decode {|{"account_mode":"Single_user"}|} with
  | Ok cfg -> Alcotest.(check bool) "Single_user" true (cfg.account_mode = Some Masc_domain.Single_user)
  | Error e -> Alcotest.fail e
;;

let () =
  Alcotest.run
    "authz_boot_mode"
    [ ( "table"
      , [ Alcotest.test_case "rows 1 to 11" `Quick test_rows
        ; Alcotest.test_case "unreadable log" `Quick test_unreadable_log_refuses_every_config
        ; Alcotest.test_case "every reason" `Quick test_every_reason_is_returned
        ; Alcotest.test_case "mode events" `Quick test_mode_events
        ] )
    ; ( "settings"
      , [ Alcotest.test_case "multi-account refuses" `Quick test_multi_account_refuses_insecure_settings
        ; Alcotest.test_case "single user unchanged" `Quick test_single_user_keeps_its_settings
        ; Alcotest.test_case "unknown value" `Quick test_unknown_value_does_not_judge_settings
        ] )
    ; ( "config member"
      , [ Alcotest.test_case "optional" `Quick test_config_member_is_optional
        ; Alcotest.test_case "survives a rewrite" `Quick test_config_member_survives_a_rewrite
        ; Alcotest.test_case "shapes" `Quick test_config_member_shapes
        ] )
    ]
;;
