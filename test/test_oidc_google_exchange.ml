(* The exchange of a login with Google, with the transport answered here: the
   discovery document, the token request, the JWKS and its cache, and the
   checks of the ID token. The ID tokens and JWKS documents are the fixed
   vectors of test/oidc_id_token_vectors.ml (issuer Google, audience
   test-client.apps.example, subject user-1, nonce nonce-1). No network. *)

module V = Oidc_id_token_vectors
module X = Oidc_google_exchange
module T = Oidc_login_transaction

(* 2026-10-28T00:00:00Z, the instant the vectors treat as now. *)
let now =
  match Ptime.of_float_s 1793145600. with
  | Some instant -> instant
  | None -> failwith "the fixed instant is representable"
;;

let client =
  match
    Login_client.make
      ~client_id:"test-client.apps.example"
      ~client_secret:"secret-1"
      ~redirect_uri:"https://masc.example/auth/oidc/callback"
  with
  | Ok client -> client
  | Error error -> failwith (Login_client.error_to_string error)
;;

let discovery_document =
  {|{"issuer":"https://accounts.google.com","authorization_endpoint":"https://accounts.example/auth","token_endpoint":"https://oauth.example/token","jwks_uri":"https://keys.example/certs"}|}
;;

let taken ?(nonce = "nonce-1") () =
  { T.held = { T.nonce }; code_verifier = "verifier-1"; invite = None; return_to = T.Local_path.root; replaces = None }
;;

let answer ?(status = 200) ?(headers = []) body = Ok { Login_transport.status; headers; body }

(* The keys of [V.jwks_both] whose kid is [kid]. *)
let jwks_with_only kid =
  match Yojson.Safe.from_string V.jwks_both with
  | `Assoc [ ("keys", `List keys) ] ->
    Yojson.Safe.to_string
      (`Assoc
          [ ( "keys"
            , `List
                (List.filter
                   (fun key -> Yojson.Safe.Util.(to_string_option (member "kid" key)) = Some kid)
                   keys) )
          ])
  | _ -> Alcotest.fail "the JWKS vector changed shape"
;;

(* A transport that answers by URL and counts the GETs of each. *)
type google =
  { mutable discovery : (Login_transport.response, string) result
  ; mutable jwks : (Login_transport.response, string) result
  ; mutable token : (Login_transport.response, string) result
  ; mutable gets : string list
  ; mutable posts : (string * (string * string) list * string) list
  }

let google () =
  { discovery = answer discovery_document
  ; jwks = answer V.jwks_both
  ; token = answer (Printf.sprintf {|{"id_token":"%s","access_token":"a"}|} V.token_valid_key_1)
  ; gets = []
  ; posts = []
  }
;;

(* Google's discovery document and JWKS need no header, so the exchange
   sends none. *)
let get g : Login_transport.get =
  fun ~url ~headers ->
  Alcotest.(check (list (pair string string))) "no headers" [] headers;
  g.gets <- url :: g.gets;
  if String.equal url Oidc_google.discovery_url
  then g.discovery
  else if String.equal url "https://keys.example/certs"
  then g.jwks
  else Error ("no such URL: " ^ url)
;;

let post g : Login_transport.post =
  fun ~url ~headers ~body ->
  g.posts <- (url, headers, body) :: g.posts;
  if String.equal url "https://oauth.example/token" then g.token else Error ("no such URL: " ^ url)
;;

let gets_of g url = List.length (List.filter (String.equal url) g.gets)

let run ?(cache = X.cache ()) ?(now_ms = 0) ?(taken = taken ()) g =
  X.identity ~get:(get g) ~post:(post g) cache ~now ~now_ms client ~code:"code/1+2" taken
;;

let outcome = function
  | Ok identity -> "ok " ^ Authz_external_identity.to_string identity
  | Error error -> X.error_to_string error
;;

let a_code_becomes_the_identity_it_names () =
  let g = google () in
  Alcotest.(check string) "the identity" "ok google:user-1" (outcome (run g));
  match g.posts with
  | [ (url, headers, body) ] ->
    Alcotest.(check string) "the token endpoint of the document" "https://oauth.example/token" url;
    Alcotest.(check (option string))
      "a form"
      (Some "application/x-www-form-urlencoded")
      (List.assoc_opt "content-type" headers);
    Alcotest.(check string)
      "the form, every byte outside the unreserved set encoded"
      "grant_type=authorization_code&code=code%2F1%2B2&client_id=test-client.apps.example&client_secret=secret-1&redirect_uri=https%3A%2F%2Fmasc.example%2Fauth%2Foidc%2Fcallback&code_verifier=verifier-1"
      body
  | _ -> Alcotest.fail "one token request was expected"
;;

let the_authorization_url_asks_for_this_login () =
  let store = T.create ~capacity:1 in
  match T.start store ~now_ms:0 T.Google ~invite:None ~return_to:T.Local_path.root ~replaces:None with
  | Error T.Full -> Alcotest.fail "full"
  | Ok started ->
    (match X.endpoints ~get:(get (google ())) (X.cache ()) ~now_ms:0 with
     | Error error -> Alcotest.failf "no endpoints: %s" (X.error_to_string error)
     | Ok endpoints ->
       Alcotest.(check string)
         "the URL"
         (Printf.sprintf
            "https://accounts.example/auth?response_type=code&client_id=test-client.apps.example&redirect_uri=https%%3A%%2F%%2Fmasc.example%%2Fauth%%2Foidc%%2Fcallback&scope=openid&state=%s&nonce=%s&code_challenge=%s&code_challenge_method=S256"
            started.state
            started.held.nonce
            started.code_challenge)
         (X.authorization_url endpoints client started))
;;

let documents_are_kept_as_long_as_cache_control_says () =
  let g = google () in
  g.discovery <- answer ~headers:[ "Cache-Control", "public, max-age=60" ] discovery_document;
  g.jwks <- answer ~headers:[ "cache-control", "max-age=30" ] V.jwks_both;
  let cache = X.cache () in
  ignore (run ~cache ~now_ms:0 g);
  ignore (run ~cache ~now_ms:29_999 g);
  Alcotest.(check int) "the document once" 1 (gets_of g Oidc_google.discovery_url);
  Alcotest.(check int) "the keys once" 1 (gets_of g "https://keys.example/certs");
  ignore (run ~cache ~now_ms:30_000 g);
  Alcotest.(check int) "the keys again when stale" 2 (gets_of g "https://keys.example/certs");
  Alcotest.(check int) "the document still kept" 1 (gets_of g Oidc_google.discovery_url);
  ignore (run ~cache ~now_ms:60_000 g);
  Alcotest.(check int) "the document again when stale" 2 (gets_of g Oidc_google.discovery_url)
;;

let documents_without_a_lifetime_are_read_each_time () =
  let g = google () in
  g.discovery <- answer ~headers:[ "Cache-Control", "no-store" ] discovery_document;
  let cache = X.cache () in
  ignore (run ~cache g);
  ignore (run ~cache g);
  Alcotest.(check int) "no-store" 2 (gets_of g Oidc_google.discovery_url);
  Alcotest.(check int) "no header" 2 (gets_of g "https://keys.example/certs")
;;

let rotated_keys_are_read_once_more () =
  let g = google () in
  g.jwks <- answer ~headers:[ "Cache-Control", "max-age=3600" ] (jwks_with_only "test-key-2");
  let cache = X.cache () in
  Alcotest.(check string)
    "the token's key is not in the first JWKS"
    "the ID token is refused: unknown_key_id"
    (outcome (run ~cache g));
  Alcotest.(check int) "read in this call, not read again" 1 (gets_of g "https://keys.example/certs");
  g.jwks <- answer ~headers:[ "Cache-Control", "max-age=3600" ] V.jwks_both;
  Alcotest.(check string) "the cached JWKS lacks the key" "ok google:user-1" (outcome (run ~cache g));
  Alcotest.(check int) "so it is read once more" 2 (gets_of g "https://keys.example/certs");
  Alcotest.(check string) "and kept" "ok google:user-1" (outcome (run ~cache g));
  Alcotest.(check int) "no third read" 2 (gets_of g "https://keys.example/certs")
;;

let other_signature_failures_do_not_read_the_keys_again () =
  let g = google () in
  g.jwks <- answer ~headers:[ "Cache-Control", "max-age=3600" ] V.jwks_both;
  g.token <- answer (Printf.sprintf {|{"id_token":"%s"}|} V.token_expired);
  let cache = X.cache () in
  ignore (run ~cache g);
  ignore (run ~cache g);
  Alcotest.(check int) "an expired token with cached keys" 1 (gets_of g "https://keys.example/certs")
;;

let error_name = function
  | Ok _ -> "ok"
  | Error (X.Discovery_unavailable _) -> "discovery unavailable"
  | Error (X.Discovery_malformed member) -> "discovery malformed " ^ member
  | Error (X.Token_unavailable _) -> "token unavailable"
  | Error (X.Token_refused { status; error }) ->
    Printf.sprintf "token refused %d %s" status (Option.value ~default:"-" error)
  | Error X.Token_answer_malformed -> "token answer malformed"
  | Error (X.Keys_unavailable _) -> "keys unavailable"
  | Error (X.Signature_refused Oidc_id_token_signature.Expired) -> "signature expired"
  | Error (X.Signature_refused _) -> "signature other"
  | Error (X.Claims_refused Oidc_google.Nonce_differs) -> "claims nonce"
  | Error (X.Claims_refused _) -> "claims other"
;;

let with_discovery body =
  let g = google () in
  g.discovery <- answer body;
  error_name (run g)
;;

let with_token result =
  let g = google () in
  g.token <- result;
  error_name (run g)
;;

let failures_are_named () =
  let https = {|"authorization_endpoint":"https://a.example/auth","token_endpoint":"https://a.example/token","jwks_uri":"https://a.example/certs"|} in
  List.iter
    (fun (label, expected, actual) -> Alcotest.(check string) label expected actual)
    [ ( "the document cannot be reached"
      , "discovery unavailable"
      , (let g = google () in
         g.discovery <- Error "refused";
         error_name (run g)) )
    ; ( "the document is a 500"
      , "discovery unavailable"
      , (let g = google () in
         g.discovery <- answer ~status:500 discovery_document;
         error_name (run g)) )
    ; "the document is too long", "discovery unavailable", with_discovery (String.make (Login_transport.max_answer_bytes + 1) ' ')
    ; "the document is not JSON", "discovery malformed JSON object", with_discovery "<html>"
    ; "the document is a list", "discovery malformed JSON object", with_discovery "[]"
    ; ( "another issuer"
      , "discovery malformed issuer"
      , with_discovery ({|{"issuer":"https://login.example",|} ^ https ^ "}") )
    ; "no issuer", "discovery malformed issuer", with_discovery ("{" ^ https ^ "}")
    ; ( "a plain http token endpoint"
      , "discovery malformed token_endpoint"
      , with_discovery
          {|{"issuer":"accounts.google.com","authorization_endpoint":"https://a.example/auth","token_endpoint":"http://a.example/token","jwks_uri":"https://a.example/certs"}|}
      )
    ; ( "an authorization endpoint with a query"
      , "discovery malformed authorization_endpoint"
      , with_discovery
          {|{"issuer":"accounts.google.com","authorization_endpoint":"https://a.example/auth?x=1","token_endpoint":"https://a.example/token","jwks_uri":"https://a.example/certs"}|}
      )
    ; ( "no jwks_uri"
      , "discovery malformed jwks_uri"
      , with_discovery
          {|{"issuer":"accounts.google.com","authorization_endpoint":"https://a.example/auth","token_endpoint":"https://a.example/token"}|}
      )
    ; "the token endpoint cannot be reached", "token unavailable", with_token (Error "reset")
    ; ( "Google refuses the code"
      , "token refused 400 invalid_grant"
      , with_token (answer ~status:400 {|{"error":"invalid_grant","error_description":"Bad Request"}|}) )
    ; "a refusal that is not JSON", "token refused 502 -", with_token (answer ~status:502 "<html>")
    ; "no id_token", "token answer malformed", with_token (answer {|{"access_token":"a"}|})
    ; "an id_token number", "token answer malformed", with_token (answer {|{"id_token":1}|})
    ; "an answer that is not JSON", "token answer malformed", with_token (answer "id_token=x")
    ; ( "an id_token too long"
      , "token answer malformed"
      , with_token (answer (Printf.sprintf {|{"id_token":"%s"}|} (String.make (Login_transport.max_answer_bytes + 1) 'a'))) )
    ; ( "the keys cannot be read"
      , "keys unavailable"
      , (let g = google () in
         g.jwks <- answer ~status:503 "";
         error_name (run g)) )
    ; ( "an expired token"
      , "signature expired"
      , with_token (answer (Printf.sprintf {|{"id_token":"%s"}|} V.token_expired)) )
    ; ( "a token of another login"
      , "claims nonce"
      , error_name (run ~taken:(taken ~nonce:"nonce-2" ()) (google ())) )
    ]
;;

let cache_lifetimes_are_read_by_grammar () =
  List.iter
    (fun (label, headers, expected) ->
      Alcotest.(check (option int)) label expected (X.cache_lifetime_ms headers))
    [ "Google's", [ "Cache-Control", "public, max-age=19414, must-revalidate, no-transform" ], Some 19_414_000
    ; "upper case", [ "CACHE-CONTROL", "MAX-AGE=10" ], Some 10_000
    ; "zero", [ "cache-control", "max-age=0" ], Some 0
    ; "no header", [], None
    ; "no max-age", [ "cache-control", "public" ], None
    ; "no-store", [ "cache-control", "no-store, max-age=60" ], None
    ; "no-cache", [ "cache-control", "max-age=60, no-cache" ], None
    ; "not digits", [ "cache-control", "max-age=abc" ], None
    ; "negative", [ "cache-control", "max-age=-1" ], None
    ; "quoted", [ "cache-control", {|max-age="60"|} ], None
    ; "a fraction", [ "cache-control", "max-age=1.5" ], None
    ; "s-maxage is not max-age", [ "cache-control", "s-maxage=60" ], None
    ]
;;

let errors_are_told_apart () =
  let texts =
    List.map
      X.error_to_string
      [ X.Discovery_unavailable "x"
      ; X.Discovery_malformed "x"
      ; X.Token_unavailable "x"
      ; X.Token_refused { status = 400; error = None }
      ; X.Token_answer_malformed
      ; X.Keys_unavailable "x"
      ; X.Signature_refused Oidc_id_token_signature.Expired
      ; X.Claims_refused Oidc_google.Nonce_differs
      ]
  in
  Alcotest.(check int) "each error has its own text" 8 (List.length (List.sort_uniq String.compare texts));
  Alcotest.(check bool)
    "the secret is in no text"
    false
    (List.exists
       (fun text ->
         let rec has i = i + 8 <= String.length text && (String.equal (String.sub text i 8) "secret-1" || has (i + 1)) in
         has 0)
       texts)
;;

let a_loopback_client_returns_to_this_computer () =
  let made ?(client_id = "Iv1.preview") ?(client_secret = "secret-1") ?(path = "/auth/github/callback") port =
    match Login_client.loopback ~client_id ~client_secret ~port ~path with
    | Ok client -> Ok (Login_client.redirect_uri client)
    | Error error -> Error (Login_client.loopback_error_to_string error)
  in
  let refused error = Error (Login_client.loopback_error_to_string error) in
  let rows =
    [ "made", made 8940, Ok "http://127.0.0.1:8940/auth/github/callback"
    ; "lowest port", made 1, Ok "http://127.0.0.1:1/auth/github/callback"
    ; "highest port", made 65535, Ok "http://127.0.0.1:65535/auth/github/callback"
    ; "port 0", made 0, refused Login_client.Port_out_of_range
    ; "port 65536", made 65536, refused Login_client.Port_out_of_range
    ; "no client ID", made ~client_id:"" 8940, refused Login_client.Loopback_client_id_empty
    ; "no secret", made ~client_secret:"" 8940, refused Login_client.Loopback_client_secret_empty
    ; "empty path", made ~path:"" 8940, refused Login_client.Path_not_plain
    ; "relative path", made ~path:"auth" 8940, refused Login_client.Path_not_plain
    ; "a host in the path", made ~path:"@evil.example/" 8940, refused Login_client.Path_not_plain
    ; "a query", made ~path:"/cb?next=1" 8940, refused Login_client.Path_not_plain
    ; "a fragment", made ~path:"/cb#here" 8940, refused Login_client.Path_not_plain
    ]
  in
  List.iter
    (fun (label, got, expected) ->
       Alcotest.(check (result string string)) label expected got)
    rows
;;

let a_client_that_cannot_work_is_not_made () =
  let made ?(client_id = "test-client.apps.example") ?(client_secret = "secret-1") redirect_uri =
    match Login_client.make ~client_id ~client_secret ~redirect_uri with
    | Ok _ -> None
    | Error error -> Some error
  in
  let callback = "https://masc.example/auth/oidc/callback" in
  Alcotest.(check bool) "made" true (made callback = None);
  Alcotest.(check bool) "no client ID" true (made ~client_id:"" callback = Some Login_client.Client_id_empty);
  Alcotest.(check bool)
    "no secret"
    true
    (made ~client_secret:"" callback = Some Login_client.Client_secret_empty);
  List.iter
    (fun redirect_uri ->
       Alcotest.(check bool)
         ("refused " ^ redirect_uri)
         true
         (made redirect_uri = Some Login_client.Redirect_uri_not_https))
    [ "http://masc.example/auth/oidc/callback"
    ; "http://127.0.0.1:8940/auth/github/callback"
    ; "https:///auth/oidc/callback"
    ; "/auth/oidc/callback"
    ; "https://masc.example/auth/oidc/callback#here"
    ; "https://masc.example/auth/oidc/callback?next=1"
    ]
;;

let () =
  Alcotest.run
    "oidc_google_exchange"
    [ ( "exchange"
      , [ Alcotest.test_case "a code becomes an identity" `Quick a_code_becomes_the_identity_it_names
        ; Alcotest.test_case "the authorization URL" `Quick the_authorization_url_asks_for_this_login
        ; Alcotest.test_case "kept by Cache-Control" `Quick documents_are_kept_as_long_as_cache_control_says
        ; Alcotest.test_case "no lifetime" `Quick documents_without_a_lifetime_are_read_each_time
        ; Alcotest.test_case "rotated keys" `Quick rotated_keys_are_read_once_more
        ; Alcotest.test_case "other failures" `Quick other_signature_failures_do_not_read_the_keys_again
        ; Alcotest.test_case "failures" `Quick failures_are_named
        ; Alcotest.test_case "cache lifetimes" `Quick cache_lifetimes_are_read_by_grammar
        ; Alcotest.test_case "texts" `Quick errors_are_told_apart
        ; Alcotest.test_case "client" `Quick a_client_that_cannot_work_is_not_made
        ; Alcotest.test_case "loopback client" `Quick a_loopback_client_returns_to_this_computer
        ] )
    ]
;;
