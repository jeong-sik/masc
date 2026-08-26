(** Recording an app an operator made themselves.

    Slack, GitHub and Figma publish no registration endpoint that answers a
    stranger, so the only road in is a client the operator made. This is
    that road, and what it must not do is as load-bearing as what it does:
    the secret goes to disk and never back out. *)

module Store = Keeper_oauth_client_store
module Oauth = Server_keeper_oauth

let check = Alcotest.check

let base_path () =
  let path =
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "masc-own-app-%d-%d" (Unix.getpid ()) (Random.int 1_000_000))
  in
  Unix.mkdir path 0o700;
  path

let provider_or_fail id =
  match Keeper_oauth_declarations.find id with
  | Some (Keeper_oauth_declarations.Declared provider) -> provider
  | Some (Keeper_oauth_declarations.Unreadable { problem; _ }) ->
    Alcotest.failf "the %s declaration does not read: %s" id problem
  | None -> Alcotest.failf "no provider is declared as %s" id

let member json key =
  match json with
  | `Assoc pairs -> List.assoc_opt key pairs
  | _ -> Alcotest.fail "the answer is not an object"

let set ?(scopes = "") base_path ~client_secret =
  match
    Oauth.set_client ~base_path ~provider_id:"slack" ~client_id:"an-app"
      ~client_secret ~scopes
  with
  | Ok payload -> payload
  | Error message -> Alcotest.failf "set_client failed: %s" message

let test_the_secret_never_comes_back () =
  (* A screen needs to know whether one is on file. It has no use for the
     value, and an answer that carried it would put a credential in every
     log and proxy between here and the browser. *)
  let base_path = base_path () in
  let payload = set base_path ~client_secret:(Some "s3cret") in
  check Alcotest.bool "it says one is on file" true
    (member payload "has_client_secret" = Some (`Bool true));
  let rendered = Yojson.Safe.to_string payload in
  check Alcotest.bool "and the value is nowhere in the answer" false
    (Str.string_match (Str.regexp ".*s3cret") rendered 0)

let test_what_was_set_is_what_start_would_use () =
  let base_path = base_path () in
  let _ = set base_path ~client_secret:(Some "s3cret") in
  let dir =
    Filename.concat (Filename.concat base_path ".masc") "identity"
  in
  match Store.load ~dir ~provider:(provider_or_fail "slack") with
  | Ok (Some credentials) ->
    check Alcotest.string "the id" "an-app" credentials.Store.client_id;
    check
      (Alcotest.option Alcotest.string)
      "the secret" (Some "s3cret") credentials.Store.client_secret
  | Ok None -> Alcotest.fail "nothing was written"
  | Error message -> Alcotest.failf "reading back failed: %s" message

let test_an_app_without_a_secret_is_allowed () =
  (* Some providers issue one without. Absent has to stay absent: an empty
     client_secret on the exchange is refused by a server that issued none. *)
  let base_path = base_path () in
  let payload = set base_path ~client_secret:None in
  check Alcotest.bool "it says none is on file" true
    (member payload "has_client_secret" = Some (`Bool false))

let test_a_blank_secret_is_the_same_as_none () =
  (* Clearing the field is saying "this app has none", not "leave what is
     there". Writing an empty string would put one on file that no server
     will accept. *)
  let base_path = base_path () in
  let payload = set base_path ~client_secret:(Some "   ") in
  check Alcotest.bool "still none on file" true
    (member payload "has_client_secret" = Some (`Bool false))

let test_a_blank_client_id_is_refused () =
  let base_path = base_path () in
  match
    Oauth.set_client ~base_path ~provider_id:"slack" ~client_id:"  "
      ~client_secret:None ~scopes:""
  with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "a blank client id was written"

let test_an_undeclared_provider_is_refused () =
  (* The id names a directory. A provider nobody declared has no directory
     to name, and inventing one would leave a client nothing ever reads. *)
  let base_path = base_path () in
  match
    Oauth.set_client ~base_path ~provider_id:"not-a-provider"
      ~client_id:"an-app" ~client_secret:None ~scopes:""
  with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "a client was written for a provider nobody declared"

let test_the_listing_says_whether_an_app_is_on_file () =
  let base_path = base_path () in
  let has id json =
    match json with
    | `List rows ->
      List.exists
        (function
          | `Assoc pairs ->
            List.assoc_opt "id" pairs = Some (`String id)
            && List.assoc_opt "has_client" pairs = Some (`Bool true)
          | _ -> false)
        rows
    | _ -> Alcotest.fail "the listing is not a list"
  in
  check Alcotest.bool "nothing on file to begin with" false
    (has "slack" (Oauth.declarations_json ~base_path));
  let _ = set base_path ~client_secret:None in
  check Alcotest.bool "and it says so once there is" true
    (has "slack" (Oauth.declarations_json ~base_path));
  check Alcotest.bool "without claiming it for another provider" false
    (has "figma" (Oauth.declarations_json ~base_path))

let test_one_google_app_answers_for_all_of_them () =
  (* Google publishes eight MCP resources behind one accounts.google.com,
     and one Cloud project's app serves them all. Keyed by provider id, an
     operator would type the same client id and secret eight times and send
     the secret over the wire eight times to say one thing. *)
  let base_path = base_path () in
  match
    Oauth.set_client ~base_path ~provider_id:"googlesheets"
      ~client_id:"one-cloud-project" ~client_secret:(Some "s3cret") ~scopes:""
  with
  | Error message -> Alcotest.failf "set_client failed: %s" message
  | Ok _ ->
    let dir = Filename.concat (Filename.concat base_path ".masc") "identity" in
    let seen id =
      match Store.load ~dir ~provider:(provider_or_fail id) with
      | Ok (Some credentials) -> Some credentials.Store.client_id
      | Ok None -> None
      | Error message -> Alcotest.failf "reading %s back failed: %s" id message
    in
    List.iter
      (fun id ->
        check
          (Alcotest.option Alcotest.string)
          (id ^ " reads the same app")
          (Some "one-cloud-project") (seen id))
      [ "gmail"; "googledrive"; "googlecalendar"; "googlecontacts" ];
    (* And no further than the group: a provider behind another
       authorization server has nothing on file. *)
    check
      (Alcotest.option Alcotest.string)
      "slack is untouched" None (seen "slack")

let test_recorded_scopes_are_what_gets_asked_for () =
  (* An app an operator brought is the authority on what it may be granted.
     Asking for a scope it does not declare is refused, and adding that scope
     means reinstalling an app other people may depend on -- so what they
     recorded here has to be what the authorize call carries. *)
  let base_path = base_path () in
  let payload =
    set ~scopes:"channels:read  chat:write " base_path ~client_secret:None
  in
  check Alcotest.bool "split and trimmed, blanks dropped" true
    (member payload "scopes"
     = Some (`List [ `String "channels:read"; `String "chat:write" ]));
  let dir = Filename.concat (Filename.concat base_path ".masc") "identity" in
  match Store.load ~dir ~provider:(provider_or_fail "slack") with
  | Ok (Some credentials) ->
    check
      (Alcotest.list Alcotest.string)
      "and they come back" [ "channels:read"; "chat:write" ]
      credentials.Store.scopes
  | Ok None -> Alcotest.fail "nothing was written"
  | Error message -> Alcotest.failf "reading back failed: %s" message

let test_no_scopes_means_ask_for_what_the_service_publishes () =
  (* Empty is not "ask for nothing" -- it is the absence of an override, and
     a client this install registered can be granted whatever the resource
     offers. *)
  let base_path = base_path () in
  let payload = set base_path ~client_secret:None in
  check Alcotest.bool "nothing recorded" true
    (member payload "scopes" = Some (`List []))

let () =
  Alcotest.run "server_keeper_oauth_client"
    [ ( "recording an operator's own app",
        [ Alcotest.test_case "the secret never comes back" `Quick
            test_the_secret_never_comes_back;
          Alcotest.test_case "what was set is what start would use" `Quick
            test_what_was_set_is_what_start_would_use;
          Alcotest.test_case "an app without a secret is allowed" `Quick
            test_an_app_without_a_secret_is_allowed;
          Alcotest.test_case "a blank secret is the same as none" `Quick
            test_a_blank_secret_is_the_same_as_none;
          Alcotest.test_case "a blank client id is refused" `Quick
            test_a_blank_client_id_is_refused;
          Alcotest.test_case "an undeclared provider is refused" `Quick
            test_an_undeclared_provider_is_refused;
          Alcotest.test_case "the listing says whether an app is on file"
            `Quick test_the_listing_says_whether_an_app_is_on_file;
          Alcotest.test_case "one Google app answers for all of them" `Quick
            test_one_google_app_answers_for_all_of_them;
          Alcotest.test_case "recorded scopes are what gets asked for" `Quick
            test_recorded_scopes_are_what_gets_asked_for;
          Alcotest.test_case "no scopes means what the service publishes"
            `Quick test_no_scopes_means_ask_for_what_the_service_publishes;
        ] );
    ]
