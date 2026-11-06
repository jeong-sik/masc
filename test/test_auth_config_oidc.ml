(* The [oidc] member of the auth configuration (plan C2a-5): how it is read
   and written back. *)

module D = Masc_domain

let client =
  `Assoc
    [ "client_id", `String "test-client.apps.example"
    ; "redirect_uri", `String "https://masc.example/auth/oidc/callback"
    ; "client_secret_env", `String "MASC_GOOGLE_CLIENT_SECRET"
    ]
;;

let with_oidc value = `Assoc [ "enabled", `Bool true; "oidc", value ]

let client_with field value =
  match client with
  | `Assoc fields ->
    `Assoc (List.map (fun (name, old) -> name, if name = field then value else old) fields)
;;

let client_without field =
  match client with
  | `Assoc fields -> `Assoc (List.filter (fun (name, _) -> name <> field) fields)
;;

let client_and field value =
  match client with
  | `Assoc fields -> `Assoc (fields @ [ field, value ])
;;

let decode json = D.auth_config_of_yojson json

let refused label json =
  match decode json with
  | Ok _ -> Alcotest.failf "%s: decoded" label
  | Error message ->
    Alcotest.(check bool)
      (label ^ ": names the oidc field")
      true
      (String_util.contains_substring message "\"oidc\"")
;;

let absent () =
  match decode (`Assoc [ "enabled", `Bool true ]) with
  | Error message -> Alcotest.fail message
  | Ok cfg ->
    Alcotest.(check bool) "no member, no client" true (cfg.D.oidc = None);
    (match D.auth_config_to_yojson cfg with
     | `Assoc fields ->
       Alcotest.(check bool) "not written" false (List.mem_assoc "oidc" fields)
     | _ -> Alcotest.fail "the encoder wrote something that is not an object")
;;

let read_and_written_back () =
  match decode (with_oidc client) with
  | Error message -> Alcotest.fail message
  | Ok cfg ->
    Alcotest.(check bool)
      "the three values"
      true
      (cfg.D.oidc
       = Some
           { D.client_id = "test-client.apps.example"
           ; redirect_uri = "https://masc.example/auth/oidc/callback"
           ; client_secret_env = "MASC_GOOGLE_CLIENT_SECRET"
           });
    (* [save_auth_config] writes the record back, so a rewrite such as
       [masc auth enable] keeps the client. *)
    (match decode (D.auth_config_to_yojson { cfg with D.require_token = false }) with
     | Error message -> Alcotest.fail message
     | Ok back -> Alcotest.(check bool) "kept by a rewrite" true (back.D.oidc = cfg.D.oidc))
;;

let shape_refused () =
  refused "null" (with_oidc `Null);
  refused "a string" (with_oidc (`String "test-client.apps.example"));
  refused "an unknown field" (with_oidc (client_and "client_secret" (`String "s")));
  refused "a duplicate field" (with_oidc (client_and "client_id" (`String "other")));
  List.iter
    (fun field ->
       refused (field ^ " missing") (with_oidc (client_without field));
       refused (field ^ " empty") (with_oidc (client_with field (`String "")));
       refused (field ^ " a number") (with_oidc (client_with field (`Int 1))))
    [ "client_id"; "redirect_uri"; "client_secret_env" ]
;;

let variable_names () =
  let accepts name =
    match decode (with_oidc (client_with "client_secret_env" (`String name))) with
    | Ok cfg ->
      Option.map (fun (oidc : D.oidc_config) -> oidc.client_secret_env) cfg.D.oidc = Some name
    | Error _ -> false
  in
  List.iter
    (fun name -> Alcotest.(check bool) ("accepts " ^ name) true (accepts name))
    [ "MASC_GOOGLE_CLIENT_SECRET"; "_secret"; "a"; "S3CRET_2" ];
  List.iter
    (fun name -> Alcotest.(check bool) ("refuses " ^ String.escaped name) false (accepts name))
    [ "2SECRET"; "MASC-SECRET"; "MASC SECRET"; "$MASC"; "MASC=x"; "M\xc3\x84SC" ]
;;

let () =
  Alcotest.run
    "auth_config_oidc"
    [ ( "oidc"
      , [ Alcotest.test_case "absent" `Quick absent
        ; Alcotest.test_case "read and written back" `Quick read_and_written_back
        ; Alcotest.test_case "shape refused" `Quick shape_refused
        ; Alcotest.test_case "variable names" `Quick variable_names
        ] )
    ]
;;
