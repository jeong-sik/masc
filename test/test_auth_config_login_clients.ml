(* The [google] and [github] members of the auth configuration (plans C2a-5
   and C2b-3): how each is read and written back. Every case runs for both
   members, and one case holds both at once. *)

module D = Masc_domain

type member =
  { name : string
  ; read : D.auth_config -> D.login_client option
  }

let google = { name = "google"; read = (fun cfg -> cfg.D.google) }
let github = { name = "github"; read = (fun cfg -> cfg.D.github) }

let client_json ~client_id ~redirect_uri ~client_secret_env =
  `Assoc
    [ "client_id", `String client_id
    ; "redirect_uri", `String redirect_uri
    ; "client_secret_env", `String client_secret_env
    ]
;;

let client =
  client_json
    ~client_id:"test-client.apps.example"
    ~redirect_uri:"https://masc.example/auth/callback"
    ~client_secret_env:"MASC_CLIENT_SECRET"
;;

let with_member member value = `Assoc [ "enabled", `Bool true; member.name, value ]

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

let refused member label json =
  match decode json with
  | Ok _ -> Alcotest.failf "%s %s: decoded" member.name label
  | Error message ->
    Alcotest.(check bool)
      (Printf.sprintf "%s %s: names the field" member.name label)
      true
      (String_util.contains_substring message (Printf.sprintf "%S" member.name))
;;

let absent member () =
  match decode (`Assoc [ "enabled", `Bool true ]) with
  | Error message -> Alcotest.fail message
  | Ok cfg ->
    Alcotest.(check bool) "no member, no client" true (member.read cfg = None);
    (match D.auth_config_to_yojson cfg with
     | `Assoc fields ->
       Alcotest.(check bool) "not written" false (List.mem_assoc member.name fields)
     | _ -> Alcotest.fail "the encoder wrote something that is not an object")
;;

let read_and_written_back member () =
  match decode (with_member member client) with
  | Error message -> Alcotest.fail message
  | Ok cfg ->
    Alcotest.(check bool)
      "the three values"
      true
      (member.read cfg
       = Some
           { D.client_id = "test-client.apps.example"
           ; redirect_uri = "https://masc.example/auth/callback"
           ; client_secret_env = "MASC_CLIENT_SECRET"
           });
    (* [save_auth_config] writes the record back, so a rewrite such as
       [masc auth enable] keeps the client. *)
    (match decode (D.auth_config_to_yojson { cfg with D.require_token = false }) with
     | Error message -> Alcotest.fail message
     | Ok back -> Alcotest.(check bool) "kept by a rewrite" true (member.read back = member.read cfg))
;;

let shape_refused member () =
  refused member "null" (with_member member `Null);
  refused member "a string" (with_member member (`String "test-client.apps.example"));
  refused member "an unknown field" (with_member member (client_and "client_secret" (`String "s")));
  refused member "a duplicate field" (with_member member (client_and "client_id" (`String "other")));
  List.iter
    (fun field ->
       refused member (field ^ " missing") (with_member member (client_without field));
       refused member (field ^ " empty") (with_member member (client_with field (`String "")));
       refused member (field ^ " a number") (with_member member (client_with field (`Int 1))))
    [ "client_id"; "redirect_uri"; "client_secret_env" ]
;;

let variable_names member () =
  let accepts name =
    match decode (with_member member (client_with "client_secret_env" (`String name))) with
    | Ok cfg ->
      Option.map (fun (client : D.login_client) -> client.client_secret_env) (member.read cfg) = Some name
    | Error _ -> false
  in
  List.iter
    (fun name -> Alcotest.(check bool) ("accepts " ^ name) true (accepts name))
    [ "MASC_GOOGLE_CLIENT_SECRET"; "_secret"; "a"; "S3CRET_2" ];
  List.iter
    (fun name -> Alcotest.(check bool) ("refuses " ^ String.escaped name) false (accepts name))
    [ "2SECRET"; "MASC-SECRET"; "MASC SECRET"; "$MASC"; "MASC=x"; "M\xc3\x84SC" ]
;;

(* Each member keeps its own client: one is never read as the other, and a
   rewrite keeps both. *)
let both_members () =
  let json =
    `Assoc
      [ "enabled", `Bool true
      ; ( "google"
        , client_json
            ~client_id:"g.apps.example"
            ~redirect_uri:"https://masc.example/auth/oidc/callback"
            ~client_secret_env:"MASC_GOOGLE_CLIENT_SECRET" )
      ; ( "github"
        , client_json
            ~client_id:"Iv1.github"
            ~redirect_uri:"https://masc.example/auth/github/callback"
            ~client_secret_env:"MASC_GITHUB_CLIENT_SECRET" )
      ]
  in
  match decode json with
  | Error message -> Alcotest.fail message
  | Ok cfg ->
    let id member cfg = Option.map (fun (client : D.login_client) -> client.client_id) (member.read cfg) in
    Alcotest.(check (option string)) "google" (Some "g.apps.example") (id google cfg);
    Alcotest.(check (option string)) "github" (Some "Iv1.github") (id github cfg);
    (match decode (D.auth_config_to_yojson cfg) with
     | Error message -> Alcotest.fail message
     | Ok back ->
       Alcotest.(check bool) "google kept" true (back.D.google = cfg.D.google);
       Alcotest.(check bool) "github kept" true (back.D.github = cfg.D.github))
;;

let cases member =
  ( member.name
  , [ Alcotest.test_case "absent" `Quick (absent member)
    ; Alcotest.test_case "read and written back" `Quick (read_and_written_back member)
    ; Alcotest.test_case "shape refused" `Quick (shape_refused member)
    ; Alcotest.test_case "variable names" `Quick (variable_names member)
    ] )
;;

let () =
  Alcotest.run
    "auth_config_login_clients"
    [ cases google; cases github; "both", [ Alcotest.test_case "both members" `Quick both_members ] ]
;;
