(* The exchange of a GitHub login, with GitHub played here: the token endpoint
   checks the form and the headers GitHub's documentation asks for, and the
   user endpoint checks the bearer token, the API version and the
   User-Agent. No network. *)

module G = Github_oauth
module T = Oidc_login_transaction

let client_id = "Iv1.test-client"
let client_secret = "secret-1"
let redirect_uri = "https://masc.example/auth/github/callback"
let access_token = "gho_token-1"
let verifier = "verifier-1"

let client =
  match Login_client.make ~client_id ~client_secret ~redirect_uri with
  | Ok client -> client
  | Error error -> failwith (Login_client.error_to_string error)
;;

let taken = { T.held = (); code_verifier = verifier; invite = None; return_to = T.Local_path.root; replaces = None }
let answer ?(status = 200) body = Ok { Login_transport.status; headers = []; body }

type github =
  { mutable token : (Login_transport.response, string) result
  ; mutable user : (Login_transport.response, string) result
  ; mutable token_requests : int
  ; mutable user_requests : int
  }

let github () =
  { token = answer (Printf.sprintf {|{"access_token":"%s","token_type":"bearer","scope":""}|} access_token)
  ; user = answer {|{"login":"octocat","id":583231,"email":null}|}
  ; token_requests = 0
  ; user_requests = 0
  }
;;

let header name headers =
  List.find_map
    (fun (key, value) ->
       if String.equal (String.lowercase_ascii key) (String.lowercase_ascii name) then Some value else None)
    headers
;;

let post g : Login_transport.post =
  fun ~url ~headers ~body ->
  Alcotest.(check string) "token URL" "https://github.com/login/oauth/access_token" url;
  Alcotest.(check (option string)) "JSON answer" (Some "application/json") (header "Accept" headers);
  Alcotest.(check (option string)) "user agent" (Some "masc") (header "User-Agent" headers);
  let form = Uri.query_of_encoded body in
  let field name = List.assoc_opt name form in
  Alcotest.(check (option (list string))) "code" (Some [ "code/1+2" ]) (field "code");
  Alcotest.(check (option (list string))) "client" (Some [ client_id ]) (field "client_id");
  Alcotest.(check (option (list string))) "secret" (Some [ client_secret ]) (field "client_secret");
  Alcotest.(check (option (list string))) "redirect" (Some [ redirect_uri ]) (field "redirect_uri");
  Alcotest.(check (option (list string))) "verifier" (Some [ verifier ]) (field "code_verifier");
  g.token_requests <- g.token_requests + 1;
  g.token
;;

let get g : Login_transport.get =
  fun ~url ~headers ->
  Alcotest.(check string) "user URL" "https://api.github.com/user" url;
  Alcotest.(check (option string)) "bearer" (Some ("Bearer " ^ access_token)) (header "Authorization" headers);
  Alcotest.(check (option string)) "media type" (Some "application/vnd.github+json") (header "Accept" headers);
  Alcotest.(check (option string)) "version" (Some "2026-03-10") (header "X-GitHub-Api-Version" headers);
  Alcotest.(check (option string)) "user agent" (Some "masc") (header "User-Agent" headers);
  g.user_requests <- g.user_requests + 1;
  g.user
;;

let run g = G.identity ~get:(get g) ~post:(post g) client ~code:"code/1+2" taken

let a_code_becomes_the_numeric_user_id () =
  let g = github () in
  match run g with
  | Ok identity -> Alcotest.(check string) "identity" "github:583231" (Authz_external_identity.to_string identity)
  | Error error -> Alcotest.fail (G.error_to_string error)
;;

let the_authorization_url_asks_for_this_login () =
  let key = T.create () in
  match T.start key ~now_ms:0 T.Github ~invite:None ~return_to:T.Local_path.root ~replaces:None with
  | Error T.Too_long -> Alcotest.fail "too long"
  | Ok started ->
    Alcotest.(check string)
      "the URL, with no scope"
      (Printf.sprintf
         "https://github.com/login/oauth/authorize?client_id=Iv1.test-client&redirect_uri=https%%3A%%2F%%2Fmasc.example%%2Fauth%%2Fgithub%%2Fcallback&state=%s&code_challenge=%s&code_challenge_method=S256"
         started.state
         started.code_challenge)
      (G.authorization_url client started)
;;

let error_name = function
  | Ok _ -> "ok"
  | Error (G.Token_unavailable _) -> "token unavailable"
  | Error (G.Token_refused { status; error }) ->
    Printf.sprintf "token refused %d %s" status (Option.value error ~default:"-")
  | Error (G.User_unavailable _) -> "user unavailable"
  | Error G.User_answer_malformed -> "user malformed"
  | Error (G.Identity_refused Authz_external_identity.Github_user_id_not_positive) -> "id not positive"
  | Error (G.Identity_refused Authz_external_identity.Github_user_id_too_large) -> "id too large"
  | Error
      (G.Identity_refused
         ( Authz_external_identity.Google_sub_empty
         | Authz_external_identity.Google_sub_too_long
         | Authz_external_identity.Google_sub_invalid_byte _ )) -> "google error"
;;

let with_token token =
  let g = github () in
  g.token <- token;
  g
;;

let with_user user =
  let g = github () in
  g.user <- user;
  g
;;

let refused_tokens_read_no_user () =
  List.iter
    (fun (label, expected, token) ->
       let g = with_token token in
       Alcotest.(check string) label expected (error_name (run g));
       Alcotest.(check int) (label ^ ": no user read") 0 g.user_requests)
    [ "an error with 200", "token refused 200 bad_verification_code", answer {|{"error":"bad_verification_code","error_description":"The code passed is incorrect or expired."}|}
    ; "an error with 400", "token refused 400 incorrect_client_credentials", answer ~status:400 {|{"error":"incorrect_client_credentials"}|}
    ; "a token with 400", "token refused 400 -", answer ~status:400 {|{"access_token":"gho_x"}|}
    ; "an empty token", "token refused 200 -", answer {|{"access_token":""}|}
    ; "a number for a token", "token refused 200 -", answer {|{"access_token":12}|}
    ; "not JSON", "token refused 200 -", answer "access_token=gho_x&token_type=bearer"
    ; "a list", "token refused 200 -", answer {|[{"access_token":"gho_x"}]|}
    ; "too long", "token unavailable", answer (String.make (Login_transport.max_answer_bytes + 1) ' ')
    ; "no answer", "token unavailable", Error "connection refused"
    ]
;;

let users_without_an_id_are_refused () =
  List.iter
    (fun (label, expected, user) ->
       Alcotest.(check string) label expected (error_name (run (with_user user))))
    [ "unauthorized", "user unavailable", answer ~status:401 {|{"message":"Bad credentials"}|}
    ; "no answer", "user unavailable", Error "timeout"
    ; "too long", "user unavailable", answer (String.make (Login_transport.max_answer_bytes + 1) ' ')
    ; "no id", "user malformed", answer {|{"login":"octocat"}|}
    ; "an id as a string", "user malformed", answer {|{"id":"583231"}|}
    ; "an id as a float", "user malformed", answer {|{"id":583231.0}|}
    ; "an id past every int", "user malformed", answer {|{"id":123456789012345678901234567890}|}
    ; "not JSON", "user malformed", answer "<html>"
    ; "a zero id", "id not positive", answer {|{"id":0}|}
    ; "an id past 2^53 - 1", "id too large", answer {|{"id":9007199254740992}|}
    ; "the largest id", "ok", answer {|{"id":9007199254740991}|}
    ]
;;

(* Every failure is printed without the secret and without the token. *)
let errors_name_neither_secret_nor_token () =
  let errors =
    [ G.Token_unavailable "connection refused"
    ; G.Token_refused { status = 400; error = Some "bad_verification_code" }
    ; G.Token_refused { status = 200; error = None }
    ; G.User_unavailable "HTTP 401"
    ; G.User_answer_malformed
    ; G.Identity_refused Authz_external_identity.Github_user_id_not_positive
    ]
  in
  let texts = List.map G.error_to_string errors in
  List.iter
    (fun text ->
       Alcotest.(check bool) ("no secret: " ^ text) false (String_util.contains_substring text client_secret);
       Alcotest.(check bool) ("no token: " ^ text) false (String_util.contains_substring text access_token))
    texts;
  Alcotest.(check int) "each error has its own text" (List.length texts) (List.length (List.sort_uniq String.compare texts))
;;

let () =
  Alcotest.run
    "github_oauth"
    [ ( "exchange"
      , [ Alcotest.test_case "a code becomes the user id" `Quick a_code_becomes_the_numeric_user_id
        ; Alcotest.test_case "the authorization URL" `Quick the_authorization_url_asks_for_this_login
        ; Alcotest.test_case "refused tokens" `Quick refused_tokens_read_no_user
        ; Alcotest.test_case "users without an id" `Quick users_without_an_id_are_refused
        ; Alcotest.test_case "texts" `Quick errors_name_neither_secret_nor_token
        ] )
    ]
;;
