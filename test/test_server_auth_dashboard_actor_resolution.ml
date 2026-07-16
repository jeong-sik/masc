(** Dashboard actor attribution keeps endpoint authorization separate while
    refusing to reinterpret a rejected bearer token as an anonymous hint. *)

open Alcotest

let with_temp_base_path f =
  let path = Filename.temp_file "masc-dashboard-actor-" "" in
  Unix.unlink path;
  Unix.mkdir path 0o700;
  Fun.protect
    ~finally:(fun () ->
      let rec remove path =
        match (Unix.lstat path).Unix.st_kind with
        | Unix.S_DIR ->
            Array.iter
              (fun entry -> remove (Filename.concat path entry))
              (Sys.readdir path);
            Unix.rmdir path
        | _ -> Unix.unlink path
      in
      remove path)
    (fun () -> f path)

let request ?token ~actor () =
  let headers =
    ("x-masc-agent", actor)
    :: (match token with
        | None -> []
        | Some token -> [ ("authorization", "Bearer " ^ token) ])
  in
  Httpun.Request.create
    ~headers:(Httpun.Headers.of_list headers)
    `GET
    "/api/v1/dashboard/briefing"

let resolve ~base_path request =
  Eio_main.run @@ fun _env ->
  Server_auth.dashboard_actor_resolution_for_request ~base_path request

let project ~base_path request =
  Eio_main.run @@ fun _env ->
  Server_auth.dashboard_actor_for_request ~base_path request

let loopback_request_authority () =
  match Server_request_authority.of_host_port ~host:"127.0.0.1" ~port:8935 with
  | Ok authority -> authority
  | Error `Malformed -> fail "failed to construct loopback request authority"

let test_anonymous_public_read_preserves_hint () =
  with_temp_base_path @@ fun base_path ->
  let request = request ~actor:"public-reader" () in
  (match resolve ~base_path request with
   | Server_auth.Anonymous_actor_hint (Some actor) ->
       check string "anonymous hint" "public-reader" actor
   | _ -> fail "expected Anonymous_actor_hint");
  check (option string) "public projection" (Some "public-reader")
    (project ~base_path request)

let test_rejected_credential_cannot_supply_actor_hint () =
  with_temp_base_path @@ fun base_path ->
  let request = request ~token:"stale-token" ~actor:"forged-actor" () in
  (match resolve ~base_path request with
   | Server_auth.Rejected_credential
       (Masc.Auth_error_kind.Outcome_error
          { err_kind = Masc.Auth_error_kind.Token_mismatch
          ; actor_hint = Some actor_hint
          ; _
          }) ->
       check string "hint retained only as diagnostic" "forged-actor" actor_hint
   | _ -> fail "expected typed token-mismatch rejection");
  check (option string) "rejected credential has no actor" None
    (project ~base_path request);
  (match
     Server_auth.authorize_tool_request_with_actor
       ~base_path
       ~tool_name:"masc_broadcast"
       ~request_authority:(loopback_request_authority ())
       request
   with
   | Error (Masc_domain.Auth (Masc_domain.Auth_error.InvalidToken _)) -> ()
   | Error err ->
       failf "unexpected endpoint auth error: %s"
         (Masc_domain.masc_error_to_string err)
   | Ok actor -> failf "endpoint auth unexpectedly admitted %s" actor)

let test_malformed_credential_cannot_become_anonymous () =
  with_temp_base_path @@ fun base_path ->
  Masc.Auth.save_auth_config
    base_path
    { Masc_domain.default_auth_config with enabled = true; require_token = false };
  let request =
    Httpun.Request.create
      ~headers:
        (Httpun.Headers.of_list
           [ ("authorization", "Basic malformed")
           ; ("x-masc-agent", "forged-actor")
           ])
      `GET
      "/api/v1/dashboard/briefing"
  in
  (match resolve ~base_path request with
   | Server_auth.Rejected_credential
       (Masc.Auth_error_kind.Outcome_error
          { err_kind = Masc.Auth_error_kind.Unauthorized
          ; actor_hint = Some actor_hint
          ; _
          }) ->
       check string "hint retained only as diagnostic" "forged-actor" actor_hint
   | _ -> fail "expected typed malformed-credential rejection");
  check (option string) "malformed credential has no actor" None
    (project ~base_path request);
  (match Server_auth.authorize_read_request ~base_path request with
   | Error (Masc_domain.Auth (Masc_domain.Auth_error.Unauthorized _)) -> ()
   | Error err ->
       failf "unexpected read auth error: %s"
         (Masc_domain.masc_error_to_string err)
   | Ok () -> fail "malformed credential admitted to read authorization");
  (match Server_auth.verify_mcp_auth ~base_path request with
   | Error _ -> ()
   | Ok _ -> fail "malformed credential admitted to optional MCP authorization");
  (match
     Server_auth.authorize_tool_request_with_actor
       ~base_path
       ~tool_name:"masc_broadcast"
       ~request_authority:(loopback_request_authority ())
       request
   with
   | Error (Masc_domain.Auth (Masc_domain.Auth_error.Unauthorized _)) -> ()
   | Error err ->
       failf "unexpected endpoint auth error: %s"
         (Masc_domain.masc_error_to_string err)
   | Ok actor -> failf "malformed credential admitted as %s" actor)

let observer_request ?authorization ?internal_token ?query_token () =
  let target =
    match query_token with
    | None -> "/mcp?sse_kind=observer"
    | Some token -> "/mcp?sse_kind=observer&token=" ^ token
  in
  let headers =
    []
    |> (fun headers ->
         match authorization with
         | None -> headers
         | Some value -> ("authorization", value) :: headers)
    |> fun headers ->
    match internal_token with
    | None -> headers
    | Some value -> ("x-masc-internal-token", value) :: headers
  in
  Httpun.Request.create ~headers:(Httpun.Headers.of_list headers) `GET target

let expect_observer_rejected ~base_path request message =
  match Server_auth.verify_mcp_observer_stream_auth ~base_path request with
  | Error _ -> ()
  | Ok _ -> fail message

let expect_observer_admitted ~base_path request message =
  match Server_auth.verify_mcp_observer_stream_auth ~base_path request with
  | Ok _ -> ()
  | Error err -> failf "%s: %s" message err

let test_credential_source_precedence_and_observer_query_state () =
  with_temp_base_path @@ fun base_path ->
  Masc.Auth.save_auth_config
    base_path
    { Masc_domain.default_auth_config with enabled = true; require_token = false };
  let save_token agent_name raw_token =
    match
      Masc.Auth.save_raw_token_credential
        base_path
        ~agent_name
        ~role:Masc_domain.Worker
        ~raw_token
    with
    | Ok _ -> ()
    | Error err -> fail (Masc_domain.masc_error_to_string err)
  in
  save_token "header-owner" "header-token";
  save_token "query-owner" "query-token";
  let internal_only = observer_request ~internal_token:" internal-token " () in
  check
    (option string)
    "internal token trimmed"
    (Some "internal-token")
    (Server_auth.auth_token_from_request internal_only);
  let blank_internal = observer_request ~internal_token:"   " () in
  check
    (option string)
    "blank internal is not parsed"
    None
    (Server_auth.auth_token_from_request blank_internal);
  check bool "blank internal remains explicit" true
    (Server_auth.request_carries_auth_credential blank_internal);
  let internal_after_malformed_authorization =
    observer_request
      ~authorization:"Basic malformed"
      ~internal_token:"internal-token"
      ()
  in
  check
    (option string)
    "supported internal header retains precedence fallback"
    (Some "internal-token")
    (Server_auth.auth_token_from_request internal_after_malformed_authorization);
  expect_observer_rejected
    ~base_path
    (observer_request
       ~authorization:"Basic malformed"
       ~query_token:"query-token"
       ())
    "malformed header must not fall back to a valid query credential";
  expect_observer_admitted
    ~base_path
    (observer_request
       ~authorization:"Bearer header-token"
       ~query_token:""
       ())
    "valid header must take precedence over malformed query credential";
  expect_observer_admitted
    ~base_path
    (observer_request ~query_token:"query-token" ())
    "valid observer query credential should be admitted";
  expect_observer_rejected
    ~base_path
    (observer_request ~query_token:"" ())
    "empty observer query credential must not become anonymous"

let test_authenticated_owner_overrides_request_hint () =
  with_temp_base_path @@ fun base_path ->
  let token = "owner-token" in
  (match
     Masc.Auth.save_raw_token_credential
       base_path
       ~agent_name:"credential-owner"
       ~role:Masc_domain.Worker
       ~raw_token:token
   with
   | Ok _ -> ()
   | Error err -> fail (Masc_domain.masc_error_to_string err));
  let request = request ~token ~actor:"forged-actor" () in
  (match resolve ~base_path request with
   | Server_auth.Authenticated_actor actor ->
       check string "credential owner" "credential-owner" actor
   | _ -> fail "expected Authenticated_actor");
  check (option string) "authenticated projection" (Some "credential-owner")
    (project ~base_path request)

let () =
  run "server_auth_dashboard_actor_resolution"
    [ ( "resolution"
      , [ test_case "anonymous public hint is preserved" `Quick
            test_anonymous_public_read_preserves_hint
        ; test_case "rejected credential fails closed" `Quick
            test_rejected_credential_cannot_supply_actor_hint
        ; test_case "malformed credential fails closed" `Quick
            test_malformed_credential_cannot_become_anonymous
        ; test_case "credential precedence and observer query state" `Quick
            test_credential_source_precedence_and_observer_query_state
        ; test_case "authenticated owner is canonical" `Quick
            test_authenticated_owner_overrides_request_hint
        ] )
    ]
