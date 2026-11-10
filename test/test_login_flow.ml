(* Google and GitHub logins from their start to the admission, with both
   providers played here. This Google reads the nonce and the S256 challenge
   from the authorization URL, signs the ID token with an RSA key made for
   this run, and checks the verifier at its token endpoint. This GitHub reads
   the challenge, checks the verifier and the client at its token endpoint,
   and answers [GET /user] only for the token it issued. A login only gets
   through when the flow carries each value to the right place. Each case
   bootstraps an installation in a temporary directory and writes the first
   Admin invitation, as test_authz_login does. No network. *)

open Authz_types
open Authz_records
module B = Authz_bootstrap
module E = Authz_invite_event
module Flow = Google_login_flow
module Gh_flow = Github_login_flow
module Login = Authz_login
module T = Oidc_login_transaction
module X = Oidc_google_exchange
module Z = Authz_zone

let start_ms = 1_700_000_000_000
let client_id = "test-client.apps.example"
let redirect_uri = "https://masc.example/auth/oidc/callback"
let client_secret = "secret-1"
let secret_variable = "MASC_GOOGLE_CLIENT_SECRET"
let github_client_id = "Iv1.test-client"
let github_redirect_uri = "https://masc.example/auth/github/callback"
let github_client_secret = "github-secret-1"
let github_secret_variable = "MASC_GITHUB_CLIENT_SECRET"
let second_admin_token = String.make 64 'b'
let admin_token = String.make 64 'a'
let admin_invitation_lifetime_ms = 24 * 60 * 60 * 1000
let authorization_endpoint = "https://accounts.example/auth"
let token_endpoint = "https://oauth.example/token"
let jwks_uri = "https://keys.example/certs"

let get_ok = function
  | Ok value -> value
  | Error _ -> Alcotest.fail "fixture value rejected"
;;

let rec remove_tree path =
  match Unix.lstat path with
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()
  | { Unix.st_kind = Unix.S_DIR; _ } ->
    Array.iter (fun name -> remove_tree (Filename.concat path name)) (Sys.readdir path);
    Unix.rmdir path
  | { Unix.st_kind = Unix.S_REG | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO | Unix.S_SOCK; _ } ->
    Sys.remove path
;;

(* One key for the run: 2048-bit generation is slow, and every case can
   trust the same Google. *)
let key =
  lazy
    (Mirage_crypto_rng_unix.use_default ();
     Jose.Jwk.make_priv_rsa ~use:`Sig (Mirage_crypto_pk.Rsa.generate ~bits:2048 ()))
;;

let s256 verifier =
  Digestif.SHA256.(digest_string verifier |> to_raw_string)
  |> Base64.encode_string ~pad:false ~alphabet:Base64.uri_safe_alphabet
;;

(* What Google remembers between the authorization request and the token
   request. *)
type grant =
  { nonce : string
  ; challenge : string
  ; sub : string
  }

type google =
  { clock : int ref
  ; discovery_up : bool ref
  ; grants : (string, grant) Hashtbl.t
  ; issued : int ref
  ; token_requests : int ref
  }

let instant_of_ms ms =
  match Ptime.of_float_s (Float.of_int ms /. 1000.) with
  | Some instant -> instant
  | None -> Alcotest.fail "the clock left the range of Ptime"
;;

let answer ?(status = 200) body = Ok { Login_transport.status; headers = []; body }

let discovery_document =
  Yojson.Safe.to_string
    (`Assoc
        [ "issuer", `String "https://accounts.google.com"
        ; "authorization_endpoint", `String authorization_endpoint
        ; "token_endpoint", `String token_endpoint
        ; "jwks_uri", `String jwks_uri
        ])
;;

let get google ~url ~headers:_ =
  if String.equal url Oidc_google.discovery_url
  then if !(google.discovery_up) then answer discovery_document else answer ~status:503 ""
  else if String.equal url jwks_uri
  then
    answer
      (Yojson.Safe.to_string
         (`Assoc [ "keys", `List [ Jose.Jwk.to_pub_json (Jose.Jwk.pub_of_priv (Lazy.force key)) ] ]))
  else Alcotest.failf "a GET of %s" url
;;

let id_token google { nonce; sub; challenge = _ } =
  let now_s = !(google.clock) / 1000 in
  let claims =
    `Assoc
      [ "iss", `String "https://accounts.google.com"
      ; "aud", `String client_id
      ; "sub", `String sub
      ; "nonce", `String nonce
      ; "iat", `Int now_s
      ; "exp", `Int (now_s + 3600)
      ]
  in
  let key = Lazy.force key in
  match Jose.Jws.sign ~header:(Jose.Header.make_header ~typ:"JWT" key) ~payload:(Yojson.Safe.to_string claims) key with
  | Ok jws -> Jose.Jws.to_string jws
  | Error (`Msg message) -> Alcotest.fail message
;;

let refuse_grant () = answer ~status:400 {|{"error":"invalid_grant"}|}

(* The token endpoint: a code is spent by its first request, and the verifier
   must be the one whose S256 the authorization request carried. *)
let post google ~url ~headers:_ ~body =
  if not (String.equal url token_endpoint) then Alcotest.failf "a POST to %s" url;
  incr google.token_requests;
  let form = Uri.query_of_encoded body in
  let field name = Option.bind (List.assoc_opt name form) (function [ value ] -> Some value | _ -> None) in
  let code = Option.value (field "code") ~default:"" in
  match Hashtbl.find_opt google.grants code with
  | None -> refuse_grant ()
  | Some grant ->
    Hashtbl.remove google.grants code;
    let verified =
      field "grant_type" = Some "authorization_code"
      && field "client_id" = Some client_id
      && field "client_secret" = Some client_secret
      && field "redirect_uri" = Some redirect_uri
      && Option.map s256 (field "code_verifier") = Some grant.challenge
    in
    if verified
    then answer (Yojson.Safe.to_string (`Assoc [ "id_token", `String (id_token google grant) ]))
    else refuse_grant ()
;;

(* What GitHub remembers: the challenge and the person of each code, and the
   person of each token it issued. *)
type github_grant =
  { github_challenge : string
  ; user_id : int
  }

type github =
  { github_grants : (string, github_grant) Hashtbl.t
  ; tokens : (string, int) Hashtbl.t
  ; github_issued : int ref
  ; github_token_requests : int ref
  }

let header name headers =
  List.find_map
    (fun (key, value) ->
       if String.equal (String.lowercase_ascii key) (String.lowercase_ascii name) then Some value else None)
    headers
;;

(* GitHub answers a refused code with status 200 and an [error] member. *)
let github_post github ~url ~headers:_ ~body =
  if not (String.equal url Github_oauth.token_url) then Alcotest.failf "a POST to %s" url;
  incr github.github_token_requests;
  let form = Uri.query_of_encoded body in
  let field name = Option.bind (List.assoc_opt name form) (function [ value ] -> Some value | _ -> None) in
  let refused = answer {|{"error":"bad_verification_code"}|} in
  let code = Option.value (field "code") ~default:"" in
  match Hashtbl.find_opt github.github_grants code with
  | None -> refused
  | Some grant ->
    Hashtbl.remove github.github_grants code;
    let verified =
      field "client_id" = Some github_client_id
      && field "client_secret" = Some github_client_secret
      && field "redirect_uri" = Some github_redirect_uri
      && Option.map s256 (field "code_verifier") = Some grant.github_challenge
    in
    if verified
    then (
      let token = Printf.sprintf "gho_%d" (Hashtbl.length github.tokens + 1) in
      Hashtbl.replace github.tokens token grant.user_id;
      answer (Yojson.Safe.to_string (`Assoc [ "access_token", `String token; "token_type", `String "bearer" ])))
    else refused
;;

let github_get github ~url ~headers =
  if not (String.equal url Github_oauth.user_url) then Alcotest.failf "a GET of %s" url;
  let bearer = header "Authorization" headers in
  match
    Hashtbl.fold
      (fun token user_id found -> if bearer = Some ("Bearer " ^ token) then Some user_id else found)
      github.tokens
      None
  with
  | Some user_id -> answer (Printf.sprintf {|{"login":"someone","id":%d}|} user_id)
  | None -> answer ~status:401 {|{"message":"Bad credentials"}|}
;;

(* The person signs in at GitHub as [user_id]: GitHub reads the authorization
   request and sends the browser back with a code and the state. *)
let sign_in_at_github github ~user_id authorization_url =
  let uri = Uri.of_string authorization_url in
  let param name =
    match Uri.get_query_param uri name with
    | Some value -> value
    | None -> Alcotest.failf "the authorization URL has no %s" name
  in
  Alcotest.(check string) "endpoint" Github_oauth.authorize_url (Uri.to_string (Uri.with_query uri []));
  Alcotest.(check string) "client" github_client_id (param "client_id");
  Alcotest.(check string) "redirect" github_redirect_uri (param "redirect_uri");
  Alcotest.(check string) "S256" "S256" (param "code_challenge_method");
  Alcotest.(check (option string)) "no scope" None (Uri.get_query_param uri "scope");
  incr github.github_issued;
  let code = Printf.sprintf "github-code-%d" !(github.github_issued) in
  Hashtbl.replace github.github_grants code { github_challenge = param "code_challenge"; user_id };
  code, param "state"
;;

(* The person signs in at Google as [sub]: Google reads the authorization
   request and sends the browser back with a code and the state. *)
let sign_in_at_google google ~sub authorization_url =
  let uri = Uri.of_string authorization_url in
  let param name =
    match Uri.get_query_param uri name with
    | Some value -> value
    | None -> Alcotest.failf "the authorization URL has no %s" name
  in
  Alcotest.(check string) "endpoint" authorization_endpoint (Uri.to_string (Uri.with_query uri []));
  Alcotest.(check string) "client" client_id (param "client_id");
  Alcotest.(check string) "redirect" redirect_uri (param "redirect_uri");
  Alcotest.(check string) "code flow" "code" (param "response_type");
  Alcotest.(check string) "S256" "S256" (param "code_challenge_method");
  incr google.issued;
  let code = Printf.sprintf "code-%d" !(google.issued) in
  Hashtbl.replace google.grants code { nonce = param "nonce"; challenge = param "code_challenge"; sub };
  code, param "state"
;;

type installation =
  { zone : Z.t
  ; google : google
  ; transactions : T.t
  ; cache : X.cache
  ; client : Login_client.t
  ; github : github
  ; github_client : Login_client.t
  ; log_path : string
  }

let now t () = instant_of_ms !(t.google.clock)

let issue_invitation zone ~invite_id ~token ~role =
  let invitation =
    E.Issued
      { invite_id = get_ok (Invite_id.of_string invite_id)
      ; token_digest = E.Token_digest.of_token token
      ; expires_at_ms = start_ms + admin_invitation_lifetime_ms
      ; role
      }
  in
  match
    Z.commit
      zone
      { Z.author = Author.Local_operator; kind = Authz_record.Kind.Invite; body = get_ok (E.to_body invitation) }
  with
  | Ok (_ : Z.committed) -> ()
  | Error error -> Alcotest.failf "invitation refused: %s" (Z.error_detail error)
;;

let client_of ~client_id ~redirect_uri ~variable ~secret =
  match
    Login_client.of_environment
      ~getenv:(fun name -> if String.equal name variable then Some secret else None)
      ~client_id
      ~redirect_uri
      ~client_secret_env:variable
  with
  | Ok client -> client
  | Error error -> Alcotest.fail (Login_client.environment_error_to_string error)
;;

let with_installation ?(capacity = 8) f =
  Eio_main.run (fun _env ->
    let root = Filename.temp_dir "login-flow-" "" in
    Fun.protect
      ~finally:(fun () -> remove_tree root)
      (fun () ->
        let base = Filename.concat root "base" in
        Unix.mkdir base 0o700;
        let store = Filename.concat (Filename.concat root "store") "external.jsonl" in
        let clock = ref start_ms in
        let now_ms () = !clock in
        (match
           B.fresh_bootstrap
             { B.base_path = base
             ; config_dir = Some (Filename.concat root "config")
             ; external_store = store
             ; workspace_id = get_ok (Workspace_id.of_string "workspace-1")
             ; now_ms
             }
         with
         | Ok (_ : B.completed) -> ()
         | Error error -> Alcotest.failf "bootstrap refused: %s" (B.error_to_string error));
        let log_path = Authz_log.path_of_base_path ~base_path:base in
        match Z.open_at_start ~now_ms ~log_path ~store_path:store with
        | Error error -> Alcotest.failf "zone not opened: %s" (Z.open_error_to_string error)
        | Ok zone ->
          issue_invitation zone ~invite_id:"invite-admin" ~token:admin_token ~role:E.Admin;
          let client = client_of ~client_id ~redirect_uri ~variable:secret_variable ~secret:client_secret in
          let github_client =
            client_of
              ~client_id:github_client_id
              ~redirect_uri:github_redirect_uri
              ~variable:github_secret_variable
              ~secret:github_client_secret
          in
          f
            { zone
            ; google =
                { clock; discovery_up = ref true; grants = Hashtbl.create 4; issued = ref 0; token_requests = ref 0 }
            ; transactions = T.create ~capacity
            ; cache = X.cache ()
            ; client
            ; github =
                { github_grants = Hashtbl.create 4
                ; tokens = Hashtbl.create 4
                ; github_issued = ref 0
                ; github_token_requests = ref 0
                }
            ; github_client
            ; log_path
            }))
;;

let next_seq t = Authz_record.next_seq (Z.snapshot t.zone).head

let admin_invite =
  match T.Invite_token.of_form admin_token with
  | Some token -> Some token
  | None -> Alcotest.fail "the fixture token is not a token"
;;

let path text =
  match T.Local_path.of_string text with
  | Some path -> path
  | None -> Alcotest.failf "%S is not a local path" text
;;

let session_of text =
  match Session_id.of_string text with
  | Ok session_id -> session_id
  | Error (_ : Authz_id.error) -> Alcotest.failf "%S is not a session id" text
;;

let start ?(invite = None) ?(replaces = None) t ~return_to =
  Flow.start ~get:(get t.google) t.cache t.transactions t.client ~now:(now t) ~invite ~return_to ~replaces
;;

let started ?invite ?replaces t ~return_to =
  match start ?invite ?replaces t ~return_to with
  | Ok started -> started
  | Error error -> Alcotest.fail (Flow.start_error_to_string error)
;;

(* Ids from a counter, so two admissions in one case draw different ones. *)
let drawing () =
  let drawn = ref 0 in
  fun () ->
    incr drawn;
    Printf.sprintf "%032x" !drawn
;;

let callback t id ~state answer =
  Flow.callback
    ~get:(get t.google)
    ~post:(post t.google)
    t.cache
    t.transactions
    t.zone
    t.client
    ~now:(now t)
    ~draw:(drawing ())
    id
    ~state
    answer
;;

(* The whole way: start, Google, callback. *)
let login ?invite ?replaces t ~sub ~return_to =
  let started = started ?invite ?replaces t ~return_to in
  let code, state = sign_in_at_google t.google ~sub started.authorization_url in
  callback t started.Flow.id ~state (Flow.Code code)
;;

let refusal_of label = function
  | Ok (_ : Flow.completed) -> Alcotest.failf "%s: completed" label
  | Error error -> error
;;

let an_invited_person_joins_and_signs_in_later () =
  with_installation (fun t ->
    let joined =
      match
        login
          ~invite:admin_invite
          ~replaces:(Some (session_of "session-1"))
          t
          ~sub:"google-sub-1"
          ~return_to:(path "/keepers?tab=board")
      with
      | Ok
          { Flow.outcome = Login.Admitted { user_id; role = E.Admin; previously_deleted = false }
          ; return_to
          ; replaces
          } ->
        Alcotest.(check string) "back where it started" "/keepers?tab=board" (T.Local_path.to_string return_to);
        Alcotest.(check (option string))
          "the session of the browser that started"
          (Some "session-1")
          (Option.map Session_id.to_string replaces);
        user_id
      | Ok _ -> Alcotest.fail "not admitted as the invited Admin"
      | Error error -> Alcotest.fail (Flow.callback_error_to_string error)
    in
    match login t ~sub:"google-sub-1" ~return_to:T.Local_path.root with
    | Ok { Flow.outcome = Login.Signed_in user_id; _ } ->
      Alcotest.(check string) "the same principal" (User_id.to_string joined) (User_id.to_string user_id)
    | Ok _ -> Alcotest.fail "admitted twice"
    | Error error -> Alcotest.fail (Flow.callback_error_to_string error))
;;

let a_person_without_an_invitation_writes_nothing () =
  with_installation (fun t ->
    let before = next_seq t in
    (match refusal_of "uninvited" (login t ~sub:"google-sub-2" ~return_to:T.Local_path.root) with
     | Flow.Login_refused Login.Not_invited -> ()
     | error -> Alcotest.fail (Flow.callback_error_to_string error));
    Alcotest.(check int) "nothing written" before (next_seq t))
;;

let a_transaction_is_taken_once () =
  with_installation (fun t ->
    let first = started ~invite:admin_invite t ~return_to:T.Local_path.root in
    let code, state = sign_in_at_google t.google ~sub:"google-sub-1" first.authorization_url in
    ignore (refusal_of "wrong state" (callback t first.id ~state:(state ^ "0") (Flow.Code code)));
    (match refusal_of "after the wrong state" (callback t first.id ~state (Flow.Code code)) with
     | Flow.Transaction_refused T.Unknown -> ()
     | error -> Alcotest.fail (Flow.callback_error_to_string error));
    Alcotest.(check int) "Google never asked" 0 !(t.google.token_requests);
    let second = started ~invite:admin_invite t ~return_to:T.Local_path.root in
    let code, state = sign_in_at_google t.google ~sub:"google-sub-1" second.authorization_url in
    (match callback t second.id ~state (Flow.Code code) with
     | Ok (_ : Flow.completed) -> ()
     | Error error -> Alcotest.fail (Flow.callback_error_to_string error));
    (match refusal_of "replayed" (callback t second.id ~state (Flow.Code code)) with
     | Flow.Transaction_refused T.Unknown -> ()
     | error -> Alcotest.fail (Flow.callback_error_to_string error));
    Alcotest.(check int) "one token request" 1 !(t.google.token_requests))
;;

let a_refusal_at_google_spends_the_transaction () =
  with_installation (fun t ->
    let login = started ~invite:admin_invite t ~return_to:T.Local_path.root in
    let _code, state = sign_in_at_google t.google ~sub:"google-sub-1" login.authorization_url in
    (match refusal_of "refused" (callback t login.id ~state Flow.Refused) with
     | Flow.Refused_at_google -> ()
     | error -> Alcotest.fail (Flow.callback_error_to_string error));
    Alcotest.(check int) "no transaction left" 0 (T.live t.transactions ~now_ms:!(t.google.clock));
    Alcotest.(check int) "Google never asked" 0 !(t.google.token_requests))
;;

let a_late_callback_is_expired () =
  with_installation (fun t ->
    let login = started ~invite:admin_invite t ~return_to:T.Local_path.root in
    let code, state = sign_in_at_google t.google ~sub:"google-sub-1" login.authorization_url in
    t.google.clock := !(t.google.clock) + T.lifetime_ms;
    match refusal_of "late" (callback t login.id ~state (Flow.Code code)) with
    | Flow.Transaction_refused T.Expired -> ()
    | error -> Alcotest.fail (Flow.callback_error_to_string error))
;;

let a_start_that_fails_at_google_holds_nothing () =
  with_installation ~capacity:1 (fun t ->
    t.google.discovery_up := false;
    (match start ~invite:admin_invite t ~return_to:T.Local_path.root with
     | Error (Flow.Google_unavailable (X.Discovery_unavailable _)) -> ()
     | Error error -> Alcotest.fail (Flow.start_error_to_string error)
     | Ok _ -> Alcotest.fail "started without Google");
    Alcotest.(check int) "no transaction held" 0 (T.live t.transactions ~now_ms:!(t.google.clock));
    t.google.discovery_up := true;
    ignore (started t ~return_to:T.Local_path.root);
    match start t ~return_to:T.Local_path.root with
    | Error Flow.Transactions_full -> ()
    | Error error -> Alcotest.fail (Flow.start_error_to_string error)
    | Ok _ -> Alcotest.fail "started past the capacity")
;;

let a_token_for_another_login_is_refused () =
  with_installation (fun t ->
    let first = started ~invite:admin_invite t ~return_to:T.Local_path.root in
    let second = started ~invite:admin_invite t ~return_to:T.Local_path.root in
    let code, _ = sign_in_at_google t.google ~sub:"google-sub-1" first.authorization_url in
    let _, state = sign_in_at_google t.google ~sub:"google-sub-1" second.authorization_url in
    (* The code of the first login comes back with the second transaction:
       its verifier is not the one the code was issued for. *)
    match refusal_of "crossed" (callback t second.id ~state (Flow.Code code)) with
    | Flow.Exchange_failed (X.Token_refused { status = 400; _ }) -> ()
    | error -> Alcotest.fail (Flow.callback_error_to_string error))
;;

let the_client_needs_its_secret () =
  let made getenv redirect_uri =
    Login_client.of_environment ~getenv ~client_id ~redirect_uri ~client_secret_env:secret_variable
  in
  (match made (fun _ -> None) redirect_uri with
   | Error (Login_client.Secret_variable_unset name) -> Alcotest.(check string) "names the variable" secret_variable name
   | Error error -> Alcotest.fail (Login_client.environment_error_to_string error)
   | Ok _ -> Alcotest.fail "made without a secret");
  (match made (fun _ -> Some "") redirect_uri with
   | Error (Login_client.Client_refused Login_client.Client_secret_empty) -> ()
   | Error error -> Alcotest.fail (Login_client.environment_error_to_string error)
   | Ok _ -> Alcotest.fail "made with an empty secret");
  (match made (fun _ -> Some client_secret) "http://masc.example/auth/oidc/callback" with
   | Error (Login_client.Client_refused Login_client.Redirect_uri_not_https) -> ()
   | Error error -> Alcotest.fail (Login_client.environment_error_to_string error)
   | Ok _ -> Alcotest.fail "made with an http redirect");
  match made (fun name -> if String.equal name secret_variable then Some client_secret else None) redirect_uri with
  | Ok client -> Alcotest.(check string) "redirect" redirect_uri (Login_client.redirect_uri client)
  | Error error -> Alcotest.fail (Login_client.environment_error_to_string error)
;;

let invite_of token =
  match T.Invite_token.of_form token with
  | Some token -> Some token
  | None -> Alcotest.fail "the fixture token is not a token"
;;

let github_started ?(invite = None) ?(replaces = None) t ~return_to =
  match Gh_flow.start t.transactions t.github_client ~now:(now t) ~invite ~return_to ~replaces with
  | Ok started -> started
  | Error T.Full -> Alcotest.fail "the store is full"
;;

let github_callback t id ~state answer =
  Gh_flow.callback
    ~get:(github_get t.github)
    ~post:(github_post t.github)
    t.transactions
    t.zone
    t.github_client
    ~now:(now t)
    ~draw:(drawing ())
    id
    ~state
    answer
;;

(* The whole way: start, GitHub, callback. *)
let github_login ?invite ?replaces t ~user_id ~return_to =
  let started = github_started ?invite ?replaces t ~return_to in
  let code, state = sign_in_at_github t.github ~user_id started.Gh_flow.authorization_url in
  github_callback t started.Gh_flow.id ~state (Gh_flow.Code code)
;;

let github_refusal_of label = function
  | Ok (_ : Gh_flow.completed) -> Alcotest.failf "%s: completed" label
  | Error error -> error
;;

let github_joined label = function
  | Ok { Gh_flow.outcome = Login.Admitted { user_id; _ }; _ } -> user_id
  | Ok _ -> Alcotest.failf "%s: not admitted" label
  | Error error -> Alcotest.failf "%s: %s" label (Gh_flow.callback_error_to_string error)
;;

let github_signed_in label = function
  | Ok { Gh_flow.outcome = Login.Signed_in user_id; _ } -> user_id
  | Ok _ -> Alcotest.failf "%s: admitted again" label
  | Error error -> Alcotest.failf "%s: %s" label (Gh_flow.callback_error_to_string error)
;;

let a_github_person_joins_and_signs_in_later () =
  with_installation (fun t ->
    let joined =
      match
        github_login
          ~invite:admin_invite
          ~replaces:(Some (session_of "session-2"))
          t
          ~user_id:583231
          ~return_to:(path "/keepers?tab=board")
      with
      | Ok
          { Gh_flow.outcome = Login.Admitted { user_id; role = E.Admin; previously_deleted = false }
          ; return_to
          ; replaces
          } ->
        Alcotest.(check string) "back where it started" "/keepers?tab=board" (T.Local_path.to_string return_to);
        Alcotest.(check (option string))
          "the session of the browser that started"
          (Some "session-2")
          (Option.map Session_id.to_string replaces);
        user_id
      | Ok _ -> Alcotest.fail "not admitted as the invited Admin"
      | Error error -> Alcotest.fail (Gh_flow.callback_error_to_string error)
    in
    let again = github_signed_in "again" (github_login t ~user_id:583231 ~return_to:T.Local_path.root) in
    Alcotest.(check string) "the same principal" (User_id.to_string joined) (User_id.to_string again))
;;

let a_github_person_without_an_invitation_writes_nothing () =
  with_installation (fun t ->
    let before = next_seq t in
    (match github_refusal_of "uninvited" (github_login t ~user_id:2 ~return_to:T.Local_path.root) with
     | Gh_flow.Login_refused Login.Not_invited -> ()
     | error -> Alcotest.fail (Gh_flow.callback_error_to_string error));
    Alcotest.(check int) "nothing written" before (next_seq t))
;;

let a_github_transaction_is_taken_once () =
  with_installation (fun t ->
    let login = github_started ~invite:admin_invite t ~return_to:T.Local_path.root in
    let code, state = sign_in_at_github t.github ~user_id:583231 login.authorization_url in
    ignore (github_refusal_of "wrong state" (github_callback t login.id ~state:(state ^ "0") (Gh_flow.Code code)));
    (match github_refusal_of "after the wrong state" (github_callback t login.id ~state (Gh_flow.Code code)) with
     | Gh_flow.Transaction_refused T.Unknown -> ()
     | error -> Alcotest.fail (Gh_flow.callback_error_to_string error));
    Alcotest.(check int) "GitHub never asked" 0 !(t.github.github_token_requests))
;;

let a_refusal_at_github_spends_the_transaction () =
  with_installation (fun t ->
    let login = github_started ~invite:admin_invite t ~return_to:T.Local_path.root in
    let _code, state = sign_in_at_github t.github ~user_id:583231 login.authorization_url in
    (match github_refusal_of "refused" (github_callback t login.id ~state Gh_flow.Refused) with
     | Gh_flow.Refused_at_github -> ()
     | error -> Alcotest.fail (Gh_flow.callback_error_to_string error));
    Alcotest.(check int) "no transaction left" 0 (T.live t.transactions ~now_ms:!(t.google.clock));
    Alcotest.(check int) "GitHub never asked" 0 !(t.github.github_token_requests))
;;

let a_late_github_callback_is_expired () =
  with_installation (fun t ->
    let login = github_started ~invite:admin_invite t ~return_to:T.Local_path.root in
    let code, state = sign_in_at_github t.github ~user_id:583231 login.authorization_url in
    t.google.clock := !(t.google.clock) + T.lifetime_ms;
    match github_refusal_of "late" (github_callback t login.id ~state (Gh_flow.Code code)) with
    | Gh_flow.Transaction_refused T.Expired -> ()
    | error -> Alcotest.fail (Gh_flow.callback_error_to_string error))
;;

(* The code of the first GitHub login comes back with the second
   transaction: its verifier is not the one the code was issued for. *)
let a_github_code_for_another_login_is_refused () =
  with_installation (fun t ->
    let first = github_started ~invite:admin_invite t ~return_to:T.Local_path.root in
    let second = github_started ~invite:admin_invite t ~return_to:T.Local_path.root in
    let code, _ = sign_in_at_github t.github ~user_id:583231 first.authorization_url in
    let _, state = sign_in_at_github t.github ~user_id:583231 second.authorization_url in
    match github_refusal_of "crossed" (github_callback t second.id ~state (Gh_flow.Code code)) with
    | Gh_flow.Exchange_failed (Github_oauth.Token_refused { status = 200; error = Some "bad_verification_code" }) ->
      Alcotest.(check int) "no token issued" 0 (Hashtbl.length t.github.tokens)
    | error -> Alcotest.fail (Gh_flow.callback_error_to_string error))
;;

(* A transaction is taken only by the callback of the flow that started it:
   the other one removes it and refuses. *)
let a_transaction_of_the_other_provider_is_refused () =
  with_installation (fun t ->
    let google = started ~invite:admin_invite t ~return_to:T.Local_path.root in
    let code, state = sign_in_at_google t.google ~sub:"google-sub-1" google.authorization_url in
    (match github_refusal_of "Google at GitHub" (github_callback t google.id ~state (Gh_flow.Code code)) with
     | Gh_flow.Transaction_refused T.Other_flow -> ()
     | error -> Alcotest.fail (Gh_flow.callback_error_to_string error));
    (match refusal_of "after the refusal" (callback t google.id ~state (Flow.Code code)) with
     | Flow.Transaction_refused T.Unknown -> ()
     | error -> Alcotest.fail (Flow.callback_error_to_string error));
    let github = github_started ~invite:admin_invite t ~return_to:T.Local_path.root in
    let code, state = sign_in_at_github t.github ~user_id:583231 github.authorization_url in
    (match refusal_of "GitHub at Google" (callback t github.id ~state (Flow.Code code)) with
     | Flow.Transaction_refused T.Other_flow -> ()
     | error -> Alcotest.fail (Flow.callback_error_to_string error));
    Alcotest.(check int) "neither provider asked" 0 (!(t.google.token_requests) + !(t.github.github_token_requests)))
;;

(* Design 5.1-5: an identity is one provider's. The same person who joined
   with Google and then with GitHub, each with an invitation, is two
   principals, and each login comes back to its own. *)
let the_same_person_at_google_and_github_is_two_principals () =
  with_installation (fun t ->
    (* The local operator invites only Admins, so the second invitation is
       one too. *)
    issue_invitation t.zone ~invite_id:"invite-admin-2" ~token:second_admin_token ~role:E.Admin;
    let at_google =
      match login ~invite:admin_invite t ~sub:"google-sub-1" ~return_to:T.Local_path.root with
      | Ok { Flow.outcome = Login.Admitted { user_id; _ }; _ } -> user_id
      | Ok _ -> Alcotest.fail "Google: not admitted"
      | Error error -> Alcotest.fail (Flow.callback_error_to_string error)
    in
    let at_github =
      github_joined
        "GitHub"
        (github_login ~invite:(invite_of second_admin_token) t ~user_id:583231 ~return_to:T.Local_path.root)
    in
    Alcotest.(check bool)
      "two principals"
      false
      (String.equal (User_id.to_string at_google) (User_id.to_string at_github));
    (match login t ~sub:"google-sub-1" ~return_to:T.Local_path.root with
     | Ok { Flow.outcome = Login.Signed_in user_id; _ } ->
       Alcotest.(check string) "Google comes back to its own" (User_id.to_string at_google) (User_id.to_string user_id)
     | Ok _ -> Alcotest.fail "Google: admitted again"
     | Error error -> Alcotest.fail (Flow.callback_error_to_string error));
    let again = github_signed_in "GitHub again" (github_login t ~user_id:583231 ~return_to:T.Local_path.root) in
    Alcotest.(check string) "GitHub comes back to its own" (User_id.to_string at_github) (User_id.to_string again))
;;

let () =
  Alcotest.run
    "login_flow"
    [ ( "github"
      , [ Alcotest.test_case "invited, then back" `Quick a_github_person_joins_and_signs_in_later
        ; Alcotest.test_case "not invited" `Quick a_github_person_without_an_invitation_writes_nothing
        ; Alcotest.test_case "taken once" `Quick a_github_transaction_is_taken_once
        ; Alcotest.test_case "refused at GitHub" `Quick a_refusal_at_github_spends_the_transaction
        ; Alcotest.test_case "late" `Quick a_late_github_callback_is_expired
        ; Alcotest.test_case "crossed logins" `Quick a_github_code_for_another_login_is_refused
        ] )
    ; ( "both"
      , [ Alcotest.test_case "the other provider's transaction" `Quick a_transaction_of_the_other_provider_is_refused
        ; Alcotest.test_case "two principals" `Quick the_same_person_at_google_and_github_is_two_principals
        ] )
    ; ( "google"
      , [ Alcotest.test_case "invited, then back" `Quick an_invited_person_joins_and_signs_in_later
        ; Alcotest.test_case "not invited" `Quick a_person_without_an_invitation_writes_nothing
        ; Alcotest.test_case "taken once" `Quick a_transaction_is_taken_once
        ; Alcotest.test_case "refused at Google" `Quick a_refusal_at_google_spends_the_transaction
        ; Alcotest.test_case "late" `Quick a_late_callback_is_expired
        ; Alcotest.test_case "start without Google" `Quick a_start_that_fails_at_google_holds_nothing
        ; Alcotest.test_case "crossed logins" `Quick a_token_for_another_login_is_refused
        ; Alcotest.test_case "client" `Quick the_client_needs_its_secret
        ] )
    ]
;;
