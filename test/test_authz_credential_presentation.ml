(* Checks which credential a request presents in multi-account mode: one of
   each kind, none, several, and the ones that do not read. No files, clock,
   or network. *)

module P = Authz_credential_presentation

let secret = String.make 64 'a'
let none = { P.authorization = []; internal_token = []; session_cookies = []; query_credential = false }
let bearer token = { none with P.authorization = [ "Bearer " ^ token ] }

let reads_as () =
  List.iter
    (fun (name, request, expected) -> Alcotest.(check string) name expected (P.to_string (P.read request)))
    [ "nothing", none, "no credential"
    ; "a PAT", bearer ("mpat_pat-1." ^ secret), "a scoped PAT"
    ; "a Service credential", bearer ("msvc_cred-1." ^ secret), "a Service credential"
    ; "the scheme in any case", { none with P.authorization = [ "bEARER mpat_pat-1." ^ secret ] }, "a scoped PAT"
    ; "blanks around the token", { none with P.authorization = [ "Bearer  mpat_pat-1." ^ secret ^ " " ] }, "a scoped PAT"
    ; "an OAuth access token", bearer ("mat_" ^ secret), "an MCP OAuth token"
    ; "a workspace secret", bearer secret, "a legacy bearer"
    ; "an OAuth refresh token", bearer ("mrt_family." ^ secret), "a legacy bearer"
    ; "the internal token header", { none with P.internal_token = [ secret ] }, "a legacy bearer"
    ; ( "a Service credential in the internal header"
      , { none with P.internal_token = [ "msvc_cred-1." ^ secret ] }
      , "a legacy bearer" )
    ; "a session cookie", { none with P.session_cookies = [ "session-1." ^ secret ] }, "a browser session"
    ; "a query credential", { none with P.query_credential = true }, "a query credential"
    ; "a broken PAT", bearer "mpat_pat-1.short", P.unreadable_to_string P.Malformed_pat
    ; "a broken Service credential", bearer "msvc_", P.unreadable_to_string P.Malformed_service_credential
    ; "Basic", { none with P.authorization = [ "Basic dXNlcjpwdw==" ] }, P.unreadable_to_string P.Not_a_bearer
    ; "Bearer and no token", { none with P.authorization = [ "Bearer   " ] }, P.unreadable_to_string P.Not_a_bearer
    ; "a bad cookie", { none with P.session_cookies = [ "session-1" ] }, P.unreadable_to_string P.Not_a_session_cookie
    (* No silent winner (design 5.2). *)
    ; ( "a cookie and a bearer"
      , { (bearer ("mpat_pat-1." ^ secret)) with P.session_cookies = [ "session-1." ^ secret ] }
      , "several credentials" )
    ; ( "a bearer and the internal header"
      , { (bearer ("msvc_cred-1." ^ secret)) with P.internal_token = [ secret ] }
      , "several credentials" )
    ; ( "two Authorization fields"
      , { none with P.authorization = [ "Bearer mpat_pat-1." ^ secret; "Bearer mpat_pat-1." ^ secret ] }
      , "several credentials" )
    ; ( "two session cookies"
      , { none with P.session_cookies = [ "session-1." ^ secret; "session-2." ^ secret ] }
      , "several credentials" )
    ; ( "a bearer and a query credential"
      , { (bearer ("mpat_pat-1." ^ secret)) with P.query_credential = true }
      , "several credentials" )
    ; ( "a broken bearer beside a cookie"
      , { none with P.authorization = [ "Basic x" ]; session_cookies = [ "session-1." ^ secret ] }
      , "several credentials" )
    ]
;;

let () =
  Alcotest.run
    "authz_credential_presentation"
    [ ( "read"
      , [ Alcotest.test_case "what a request reads as" `Quick reads_as
        ] )
    ]
;;
