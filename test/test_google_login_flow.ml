(* A Google login from its start to the admission, with Google played here.
   This Google reads the nonce and the S256 challenge from the authorization
   URL, signs the ID token with an RSA key made for this run, and checks the
   verifier at its token endpoint, so a login only gets through when the flow
   carries each value to the right place. Each case bootstraps an
   installation in a temporary directory and writes the first Admin
   invitation, as test_authz_login does. No network. *)

open Authz_types
open Authz_records
module B = Authz_bootstrap
module E = Authz_invite_event
module Flow = Google_login_flow
module Login = Authz_login
module T = Oidc_login_transaction
module X = Oidc_google_exchange
module Z = Authz_zone

let start_ms = 1_700_000_000_000
let client_id = "test-client.apps.example"
let redirect_uri = "https://masc.example/auth/oidc/callback"
let client_secret = "secret-1"
let secret_variable = "MASC_GOOGLE_CLIENT_SECRET"
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
  ; client : X.Client.t
  ; log_path : string
  }

let now t () = instant_of_ms !(t.google.clock)

let with_installation ?(capacity = 8) f =
  Eio_main.run (fun _env ->
    let root = Filename.temp_dir "google-login-flow-" "" in
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
          let invitation =
            E.Issued
              { invite_id = get_ok (Invite_id.of_string "invite-admin")
              ; token_digest = E.Token_digest.of_token admin_token
              ; expires_at_ms = start_ms + admin_invitation_lifetime_ms
              ; role = E.Admin
              }
          in
          (match
             Z.commit
               zone
               { Z.author = Author.Local_operator; kind = Authz_record.Kind.Invite; body = get_ok (E.to_body invitation) }
           with
           | Ok (_ : Z.committed) -> ()
           | Error error -> Alcotest.failf "invitation refused: %s" (Z.error_to_string error));
          let client =
            match
              Flow.client
                ~getenv:(fun name -> if String.equal name secret_variable then Some client_secret else None)
                ~client_id
                ~redirect_uri
                ~client_secret_env:secret_variable
            with
            | Ok client -> client
            | Error error -> Alcotest.fail (Flow.client_error_to_string error)
          in
          f
            { zone
            ; google =
                { clock; discovery_up = ref true; grants = Hashtbl.create 4; issued = ref 0; token_requests = ref 0 }
            ; transactions = T.create ~capacity
            ; cache = X.cache ()
            ; client
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

let start ?(invite = None) t ~return_to =
  Flow.start ~get:(get t.google) t.cache t.transactions t.client ~now:(now t) ~invite ~return_to
;;

let started ?invite t ~return_to =
  match start ?invite t ~return_to with
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
let login ?invite t ~sub ~return_to =
  let started = started ?invite t ~return_to in
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
      match login ~invite:admin_invite t ~sub:"google-sub-1" ~return_to:(path "/keepers?tab=board") with
      | Ok { Flow.outcome = Login.Admitted { user_id; role = E.Admin; previously_deleted = false }; return_to }
        ->
        Alcotest.(check string) "back where it started" "/keepers?tab=board" (T.Local_path.to_string return_to);
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
    Flow.client ~getenv ~client_id ~redirect_uri ~client_secret_env:secret_variable
  in
  (match made (fun _ -> None) redirect_uri with
   | Error (Flow.Secret_variable_unset name) -> Alcotest.(check string) "names the variable" secret_variable name
   | Error error -> Alcotest.fail (Flow.client_error_to_string error)
   | Ok _ -> Alcotest.fail "made without a secret");
  (match made (fun _ -> Some "") redirect_uri with
   | Error (Flow.Client_refused X.Client.Client_secret_empty) -> ()
   | Error error -> Alcotest.fail (Flow.client_error_to_string error)
   | Ok _ -> Alcotest.fail "made with an empty secret");
  (match made (fun _ -> Some client_secret) "http://masc.example/auth/oidc/callback" with
   | Error (Flow.Client_refused X.Client.Redirect_uri_not_https) -> ()
   | Error error -> Alcotest.fail (Flow.client_error_to_string error)
   | Ok _ -> Alcotest.fail "made with an http redirect");
  match made (fun name -> if String.equal name secret_variable then Some client_secret else None) redirect_uri with
  | Ok client -> Alcotest.(check string) "redirect" redirect_uri (X.Client.redirect_uri client)
  | Error error -> Alcotest.fail (Flow.client_error_to_string error)
;;

let () =
  Alcotest.run
    "google_login_flow"
    [ ( "flow"
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
