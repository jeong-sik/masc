(* The login routes against the writer zone on real files, with a Google and
   a GitHub that the test plays: a browser starts a login, signs in at the
   provider, comes back to the callback, reads its session, and signs out.
   Each case bootstraps a fresh installation in a temporary directory and
   issues one Admin invitation. No network.

   The providers are the ones of test_login_flow: Google signs an ID token
   with a key of the run, and GitHub answers a code with a token and the
   token with a user. *)

open Authz_types
open Authz_records
module B = Authz_bootstrap
module Bs = Authz_browser_session
module E = Authz_invite_event
module Q = Authz_browser_request
module R = Login_routes
module T = Oidc_login_transaction
module X = Oidc_google_exchange
module Z = Authz_zone

let start_ms = 1_700_000_000_000
let client_id = "test-client.apps.example"
let redirect_uri = "https://masc.example/auth/oidc/callback"
let client_secret = "secret-1"
let github_client_id = "Iv1.test-client"
let github_redirect_uri = "https://masc.example/auth/github/callback"
let github_client_secret = "github-secret-1"
let admin_token = String.make 64 'a'
let invitation_lifetime_ms = 24 * 60 * 60 * 1000
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

(* ---- the providers ---- *)

let key =
  lazy
    (Mirage_crypto_rng_unix.use_default ();
     Jose.Jwk.make_priv_rsa ~use:`Sig (Mirage_crypto_pk.Rsa.generate ~bits:2048 ()))
;;

let s256 verifier =
  Digestif.SHA256.(digest_string verifier |> to_raw_string)
  |> Base64.encode_string ~pad:false ~alphabet:Base64.uri_safe_alphabet
;;

type grant =
  { nonce : string
  ; challenge : string
  ; sub : string
  }

type github_grant =
  { github_challenge : string
  ; user_id : int
  }

type providers =
  { clock : int ref
  ; discovery_up : bool ref
  ; grants : (string, grant) Hashtbl.t
  ; github_grants : (string, github_grant) Hashtbl.t
  ; tokens : (string, int) Hashtbl.t
  ; issued : int ref
  }

let answer ?(status = 200) body = Ok { Login_transport.status; headers = []; body }

let form_field body name =
  Option.bind (List.assoc_opt name (Uri.query_of_encoded body)) (function
    | [ value ] -> Some value
    | [] | _ :: _ :: _ -> None)
;;

let id_token p { nonce; sub; challenge = _ } =
  let now_s = !(p.clock) / 1000 in
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

let get p ~url ~headers =
  if String.equal url Oidc_google.discovery_url
  then
    if !(p.discovery_up)
    then
      answer
        (Yojson.Safe.to_string
           (`Assoc
               [ "issuer", `String "https://accounts.google.com"
               ; "authorization_endpoint", `String authorization_endpoint
               ; "token_endpoint", `String token_endpoint
               ; "jwks_uri", `String jwks_uri
               ]))
    else answer ~status:503 ""
  else if String.equal url jwks_uri
  then
    answer
      (Yojson.Safe.to_string
         (`Assoc [ "keys", `List [ Jose.Jwk.to_pub_json (Jose.Jwk.pub_of_priv (Lazy.force key)) ] ]))
  else if String.equal url Github_oauth.user_url
  then (
    let bearer =
      List.find_map
        (fun (name, value) ->
          if String.equal (String.lowercase_ascii name) "authorization" then Some value else None)
        headers
    in
    match
      Hashtbl.fold
        (fun token user_id found -> if bearer = Some ("Bearer " ^ token) then Some user_id else found)
        p.tokens
        None
    with
    | Some user_id -> answer (Printf.sprintf {|{"login":"someone","id":%d}|} user_id)
    | None -> answer ~status:401 {|{"message":"Bad credentials"}|})
  else Alcotest.failf "a GET of %s" url
;;

(* A code is spent by its first request, and the verifier must be the one
   whose S256 the authorization request carried. GitHub answers a refused
   code with status 200 and an [error] member. *)
let post p ~url ~headers:_ ~body =
  let field = form_field body in
  let code = Option.value (field "code") ~default:"" in
  if String.equal url token_endpoint
  then (
    match Hashtbl.find_opt p.grants code with
    | Some grant
      when field "client_secret" = Some client_secret
           && Option.map s256 (field "code_verifier") = Some grant.challenge ->
      Hashtbl.remove p.grants code;
      answer (Yojson.Safe.to_string (`Assoc [ "id_token", `String (id_token p grant) ]))
    | Some _ | None -> answer ~status:400 {|{"error":"invalid_grant"}|})
  else if String.equal url Github_oauth.token_url
  then (
    match Hashtbl.find_opt p.github_grants code with
    | Some grant
      when field "client_secret" = Some github_client_secret
           && Option.map s256 (field "code_verifier") = Some grant.github_challenge ->
      Hashtbl.remove p.github_grants code;
      let token = Printf.sprintf "gho_%d" (Hashtbl.length p.tokens + 1) in
      Hashtbl.replace p.tokens token grant.user_id;
      answer (Yojson.Safe.to_string (`Assoc [ "access_token", `String token; "token_type", `String "bearer" ]))
    | Some _ | None -> answer {|{"error":"bad_verification_code"}|})
  else Alcotest.failf "a POST to %s" url
;;

let param uri name =
  match Uri.get_query_param uri name with
  | Some value -> value
  | None -> Alcotest.failf "the authorization URL has no %s" name
;;

(* The person signs in at Google as [sub], or at GitHub as [user_id], and the
   provider sends the browser back with a code and the state. *)
let sign_in_at_google p ~sub authorization_url =
  let uri = Uri.of_string authorization_url in
  incr p.issued;
  let code = Printf.sprintf "code-%d" !(p.issued) in
  Hashtbl.replace p.grants code { nonce = param uri "nonce"; challenge = param uri "code_challenge"; sub };
  code, param uri "state"
;;

let sign_in_at_github p ~user_id authorization_url =
  let uri = Uri.of_string authorization_url in
  incr p.issued;
  let code = Printf.sprintf "github-code-%d" !(p.issued) in
  Hashtbl.replace p.github_grants code { github_challenge = param uri "code_challenge"; user_id };
  code, param uri "state"
;;

(* ---- the installation ---- *)

type installation =
  { routes : R.t
  ; zone : Z.t
  ; providers : providers
  }

let instant_of_ms ms =
  match Ptime.of_float_s (Float.of_int ms /. 1000.) with
  | Some instant -> instant
  | None -> Alcotest.fail "the clock left the range of Ptime"
;;

let client_of ~client_id ~redirect_uri ~secret =
  match Login_client.make ~client_id ~client_secret:secret ~redirect_uri with
  | Ok client -> client
  | Error error -> Alcotest.fail (Login_client.error_to_string error)
;;

let with_installation f =
  Eio_main.run (fun _env ->
    let root = Filename.temp_dir "login-routes-" "" in
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
          (match
             Z.commit
               zone
               { Z.author = Author.Local_operator
               ; kind = Authz_record.Kind.Invite
               ; body =
                   get_ok
                     (E.to_body
                        (E.Issued
                           { invite_id = get_ok (Invite_id.of_string "invite-admin")
                           ; token_digest = E.Token_digest.of_token admin_token
                           ; expires_at_ms = start_ms + invitation_lifetime_ms
                           ; role = E.Admin
                           }))
               }
           with
           | Ok (_ : Z.committed) -> ()
           | Error error -> Alcotest.failf "invitation refused: %s" (Z.error_detail error));
          let providers =
            { clock
            ; discovery_up = ref true
            ; grants = Hashtbl.create 4
            ; github_grants = Hashtbl.create 4
            ; tokens = Hashtbl.create 4
            ; issued = ref 0
            }
          in
          let fresh = ref 0 in
          let routes =
            { R.zone
            ; transactions = T.create ()
            ; google =
                Some { R.client = client_of ~client_id ~redirect_uri ~secret:client_secret; cache = X.cache () }
            ; github =
                Some
                  (client_of
                     ~client_id:github_client_id
                     ~redirect_uri:github_redirect_uri
                     ~secret:github_client_secret)
            ; get = get providers
            ; post = post providers
            ; now = (fun () -> instant_of_ms !clock)
            ; draw =
                (fun () ->
                  incr fresh;
                  Printf.sprintf "%064x" !fresh)
            }
          in
          f { routes; zone; providers }))
;;

(* ---- a browser ---- *)

type browser =
  { mutable session : string option
  ; mutable transaction : string option
  }

let browser () = { session = None; transaction = None }
let headers name (answer : R.answer) = List.filter_map (fun (key, value) -> if String.equal key name then Some value else None) answer.headers

(* The value a [set-cookie] gives the cookie [name]: [Some ""] for a clear. *)
let cookie_set ~name answer =
  let prefix = name ^ "=" in
  List.find_map
    (fun header ->
      if String.starts_with ~prefix header
      then (
        let rest = String.sub header (String.length prefix) (String.length header - String.length prefix) in
        Some (List.hd (String.split_on_char ';' rest)))
      else None)
    (headers "set-cookie" answer)
;;

let keep_cookies browser answer =
  let keep name current =
    match cookie_set ~name answer with
    | None -> current
    | Some "" -> None
    | Some value -> Some value
  in
  browser.session <- keep Q.session_cookie browser.session;
  browser.transaction <- keep Q.transaction_cookie browser.transaction
;;

let code (answer : R.answer) = R.status_code answer.status

let cookies_of browser =
  match browser.session with
  | None -> Q.No_cookie
  | Some value -> Q.One_cookie value
;;

let start ?(origin = Q.Same_origin) ?(fields = []) t browser provider =
  let answer = R.start t.routes provider ~origin ~session_cookie:(cookies_of browser) ~fields in
  keep_cookies browser answer;
  answer
;;

let callback t browser provider query =
  let answer = R.callback t.routes provider ~transaction_cookie:browser.transaction ~query in
  keep_cookies browser answer;
  answer
;;

let location answer =
  match headers "location" answer with
  | [ url ] -> url
  | [] | _ :: _ :: _ -> Alcotest.failf "a %d with no single location" (code answer)
;;

let invited = [ "invite", admin_token ]

(* Starts, signs in at the provider, and comes back. *)
let sign_in ?(fields = []) t browser provider ~who =
  let started = start ~fields t browser provider in
  Alcotest.(check int) "the start sends the browser to the provider" 303 (code started);
  let given, state =
    match provider with
    | R.Google -> sign_in_at_google t.providers ~sub:(Printf.sprintf "google-sub-%d" who) (location started)
    | R.Github -> sign_in_at_github t.providers ~user_id:who (location started)
  in
  callback t browser provider [ "state", state; "code", given ]
;;

let request ?(method_ = Q.Unsafe) ?(origin = Q.Same_origin) ?csrf ?(bearer = false) browser =
  { Q.method_; session_cookie = cookies_of browser; bearer; query_credential = false; origin; csrf }
;;

let read_session ?origin t browser = R.session t.routes (request ~method_:Q.Safe ?origin browser)

let member name (answer : R.answer) =
  match Yojson.Safe.from_string answer.body with
  | `Assoc fields -> List.assoc_opt name fields
  | _ -> Alcotest.failf "the answer %S is not a JSON object" answer.body
;;

let string_member name answer =
  match member name answer with
  | Some (`String value) -> value
  | _ -> Alcotest.failf "no string %s in %S" name answer.R.body
;;

let cookie_of value =
  match Bs.Cookie.of_value value with
  | Some cookie -> cookie
  | None -> Alcotest.failf "the cookie value %S is not a session" value
;;

let session_id_of value = Bs.Cookie.session_id (cookie_of value)
let forged value = Session_id.to_string (session_id_of value) ^ "." ^ String.make 64 '0'

let session_status t value =
  match Authz_session_state.find (Z.snapshot t.zone).state.sessions (session_id_of value) with
  | None -> "none"
  | Some { Authz_session_state.status = Authz_session_state.Open; _ } -> "open"
  | Some { Authz_session_state.status = Authz_session_state.Revoked; _ } -> "signed out"
  | Some { Authz_session_state.status = Authz_session_state.Replaced by; _ } ->
    "replaced by " ^ Session_id.to_string by
;;

let current_session browser =
  match browser.session with
  | Some value -> value
  | None -> Alcotest.fail "the browser holds no session"
;;

let contains ~sub text =
  let n = String.length sub in
  let rec go i = i + n <= String.length text && (String.equal (String.sub text i n) sub || go (i + 1)) in
  go 0
;;

let clears_the_transaction answer =
  Alcotest.(check (option string)) "the transaction cookie is cleared" (Some "") (cookie_set ~name:Q.transaction_cookie answer)
;;

(* The value of a source ['nonce-<value>'] when the value is one
   [Account_page.Nonce.draw] gives: hex digits, never empty. *)
let drawn_nonce source =
  let prefix = "nonce-" in
  if String.starts_with ~prefix source
  then (
    let value = String.sub source (String.length prefix) (String.length source - String.length prefix) in
    if value <> "" && String.for_all (function '0' .. '9' | 'a' .. 'f' -> true | _ -> false) value
    then Some value
    else None)
  else None
;;

(* The page a person's sign-in ends on runs the one script of the page, and
   every other page the routes write runs nothing. *)
type page =
  | Refused
  | Completed

(* A page of the routes applies the sheet of its frame and runs at most the
   script of a completed sign-in: its policy names nothing but the nonce that
   the sheet and that script carry, and the limits that every page has. The
   sheet is not empty; what it says is not read here. *)
let page_nonce label page (answer : R.answer) =
  match headers "content-security-policy" answer with
  | [ policy ] ->
    let nonce =
      match page, String.split_on_char '\'' policy with
      | ( Refused
        , [ "default-src "
          ; "none"
          ; "; style-src "
          ; style
          ; "; base-uri "
          ; "none"
          ; "; form-action "
          ; "none"
          ; "; frame-ancestors "
          ; "none"
          ; ""
          ] ) -> drawn_nonce style
      | ( Completed
        , [ "default-src "
          ; "none"
          ; "; script-src "
          ; script
          ; "; style-src "
          ; style
          ; "; base-uri "
          ; "none"
          ; "; form-action "
          ; "none"
          ; "; frame-ancestors "
          ; "none"
          ; ""
          ] )
        when String.equal script style -> drawn_nonce style
      | (Refused | Completed), _ -> None
    in
    (match nonce with
     | None -> Alcotest.failf "%s: a page under the policy %S" label policy
     | Some nonce ->
       let sheet = Printf.sprintf {|<style nonce="%s">|} nonce in
       Alcotest.(check bool)
         (label ^ ": a sheet is under the nonce of the policy")
         true
         (contains ~sub:sheet answer.body && not (contains ~sub:(sheet ^ "</style>") answer.body));
       (match page with
        | Refused -> Alcotest.(check bool) (label ^ ": no script") false (contains ~sub:"<script" answer.body)
        | Completed ->
          Alcotest.(check bool)
            (label ^ ": the script is under the nonce of the policy")
            true
            (contains ~sub:(Printf.sprintf {|<script nonce="%s">|} nonce) answer.body));
       nonce)
  | [] | _ :: _ :: _ -> Alcotest.failf "%s: no single policy" label
;;

let applies_only_its_sheet label answer = page_nonce label Refused answer

(* The draw of the routes gives ids, and a page draws its own nonce, so a
   draw whose value would end the source and add a directive leaves the
   policy of a page as it is. *)
let not_a_nonce () = "0'; script-src 'unsafe-inline"

(* No two answers share a nonce: each is drawn for its answer. *)
let each_drawn_once label nonces =
  Alcotest.(check int)
    (label ^ ": no nonce is used twice")
    (List.length nonces)
    (List.length (List.sort_uniq String.compare nonces))
;;

(* ---- the cases ---- *)

let a_google_sign_in_gives_a_session_until_the_sign_out () =
  with_installation (fun t ->
    let b = browser () in
    let started = start ~fields:(("return_to", "/keepers?tab=board") :: invited) t b R.Google in
    Alcotest.(check int) "a 303" 303 (code started);
    Alcotest.(check bool)
      "to Google"
      true
      (String.starts_with ~prefix:authorization_endpoint (location started));
    Alcotest.(check bool) "with a transaction" true (Option.is_some b.transaction);
    Alcotest.(check (list string)) "not cached" [ "no-store" ] (headers "cache-control" started);
    let code_, state = sign_in_at_google t.providers ~sub:"google-sub-1" (location started) in
    let back = callback t b R.Google [ "state", state; "code", code_; "scope", "openid" ] in
    Alcotest.(check int) "a 200 page" 200 (code back);
    clears_the_transaction back;
    let value = current_session b in
    Alcotest.(check string) "the session is open" "open" (session_status t value);
    Alcotest.(check bool) "the page goes back where it started" true (contains ~sub:{|href="/keepers?tab=board"|} back.body);
    Alcotest.(check (list string)) "no referrer" [ "no-referrer" ] (headers "referrer-policy" back);
    let (_ : string) = page_nonce "the completed sign-in" Completed back in
    Alcotest.(check bool) "the page holds no secret" false (contains ~sub:value back.body);
    let read = read_session t b in
    Alcotest.(check int) "the session reads" 200 (code read);
    let csrf = string_member "csrf_token" read in
    Alcotest.(check string) "its CSRF token" (Bs.csrf_token (cookie_of value)) csrf;
    (match member "expires_at_ms" read with
     | Some (`Int at) -> Alcotest.(check int) "7 days from the sign-in" (start_ms + Authz_session_state.lifetime_ms) at
     | _ -> Alcotest.fail "no expiry");
    let out = R.logout t.routes (request ~csrf b) in
    keep_cookies b out;
    Alcotest.(check int) "a 204" 204 (code out);
    Alcotest.(check (option string)) "the cookie is cleared" None b.session;
    Alcotest.(check string) "the session is signed out" "signed out" (session_status t value);
    Alcotest.(check int) "a second sign-out has no session" 401 (code (R.logout t.routes (request ~csrf b)));
    b.session <- Some value;
    let again = read_session t b in
    Alcotest.(check int) "the old cookie does not act" 401 (code again);
    Alcotest.(check string) "and says why" (Bs.refusal_to_string Bs.Ended) (string_member "error" again))
;;

let a_new_sign_in_ends_the_session_of_the_browser () =
  with_installation (fun t ->
    let b = browser () in
    Alcotest.(check int) "joins at GitHub" 200 (code (sign_in ~fields:invited t b R.Github ~who:583231));
    let first = current_session b in
    Alcotest.(check int) "signs in again" 200 (code (sign_in t b R.Github ~who:583231));
    let second = current_session b in
    Alcotest.(check bool) "a new session" false (String.equal first second);
    Alcotest.(check string)
      "the old one ended in the same record"
      ("replaced by " ^ Session_id.to_string (session_id_of second))
      (session_status t first);
    Alcotest.(check string) "the new one is open" "open" (session_status t second);
    b.session <- Some first;
    Alcotest.(check int) "the old cookie does not act" 401 (code (read_session t b));
    (* A session that the start named and that ends before the callback, in
       another tab, is not ended again: the sign-in still completes. *)
    b.session <- Some second;
    let started = start t b R.Github in
    let other_tab = { b with transaction = None } in
    let csrf = string_member "csrf_token" (read_session t other_tab) in
    Alcotest.(check int) "signed out in another tab" 204 (code (R.logout t.routes (request ~csrf other_tab)));
    let given, state = sign_in_at_github t.providers ~user_id:583231 (location started) in
    Alcotest.(check int)
      "the sign-in completes"
      200
      (code (callback t b R.Github [ "state", state; "code", given ]));
    let third = current_session b in
    Alcotest.(check string) "the other tab's sign-out stays" "signed out" (session_status t second);
    Alcotest.(check string) "the new session is open" "open" (session_status t third);
    (* A cookie that does not act names no session to end. *)
    let second = third in
    b.session <- Some (forged second);
    Alcotest.(check int) "a sign-in over a forged cookie" 200 (code (sign_in t b R.Github ~who:583231));
    Alcotest.(check string) "leaves the real session open" "open" (session_status t second))
;;

(* More starts than any store of logins in flight held (16, issue #51394). *)
let starts_in_a_row = 64

let a_start_that_is_refused () =
  with_installation (fun t ->
    let nonces = ref [] in
    let refused label ?(origin = Q.Same_origin) ?(routes = t.routes) ?(fields = []) provider expected =
      let answer = R.start routes provider ~origin ~session_cookie:Q.No_cookie ~fields in
      Alcotest.(check int) label expected (code answer);
      Alcotest.(check (list string)) (label ^ ": no cookie") [] (headers "set-cookie" answer);
      nonces := applies_only_its_sheet label answer :: !nonces;
      Alcotest.(check bool) (label ^ ": no token in the page") false (contains ~sub:admin_token answer.body)
    in
    refused "from another origin" ~origin:Q.Other_origin ~fields:invited R.Google 403;
    refused "with no origin" ~origin:Q.No_origin R.Github 403;
    refused "an unknown field" ~fields:[ "next", "/" ] R.Google 400;
    refused "a field twice" ~fields:[ "return_to", "/"; "return_to", "/keepers" ] R.Github 400;
    refused "an invitation that is not a token" ~fields:[ "invite", "token" ] R.Google 400;
    refused "a path to another host" ~fields:[ "return_to", "//evil.example/" ] R.Github 400;
    refused "a URL" ~fields:[ "return_to", "https://evil.example/" ] R.Google 400;
    refused "Google not set up" ~routes:{ t.routes with R.google = None } R.Google 404;
    refused "GitHub not set up" ~routes:{ t.routes with R.github = None } R.Github 404;
    refused "a draw that is no nonce" ~origin:Q.Other_origin ~routes:{ t.routes with R.draw = not_a_nonce } R.Google 403;
    List.iter
      (fun provider ->
        let answer =
          R.start t.routes provider ~origin:Q.Same_origin ~session_cookie:Q.Several_cookies ~fields:[]
        in
        Alcotest.(check int) "several session cookies" 401 (code answer);
        Alcotest.(check (list string)) "several session cookies: no cookie" [] (headers "set-cookie" answer);
        nonces := applies_only_its_sheet "several session cookies" answer :: !nonces)
      [ R.Google; R.Github ];
    t.providers.discovery_up := false;
    refused "Google does not answer" R.Google 502;
    t.providers.discovery_up := true;
    (* The server holds nothing of a login under way, so one start does not
       wait for another. A return path that does not fit in the cookie is
       refused as the request it is. *)
    for _ = 1 to starts_in_a_row do
      Alcotest.(check int) "a start after a start" 303 (code (start t (browser ()) R.Github))
    done;
    let too_long = [ "return_to", "/" ^ String.make T.max_sealed_length 'a' ] in
    refused "a return path longer than a cookie (Google)" ~fields:too_long R.Google 400;
    refused "a return path longer than a cookie (GitHub)" ~fields:too_long R.Github 400;
    each_drawn_once "a start that is refused" !nonces)
;;

let a_callback_that_is_refused () =
  with_installation (fun t ->
    let nonces = ref [] in
    let check label answer expected =
      Alcotest.(check int) label expected (code answer);
      clears_the_transaction answer;
      nonces := applies_only_its_sheet label answer :: !nonces;
      List.iter
        (fun secret -> Alcotest.(check bool) (label ^ ": nothing private in the page") false (contains ~sub:secret answer.body))
        [ admin_token; client_secret; github_client_secret ]
    in
    let fresh_start provider =
      let b = browser () in
      let started = start ~fields:invited t b provider in
      b, location started
    in
    check "no transaction" (callback t (browser ()) R.Google [ "state", "s"; "code", "c" ]) 401;
    check
      "a transaction cookie that is not one"
      (R.callback t.routes R.Github ~transaction_cookie:(Some "abc") ~query:[ "state", "s"; "code", "c" ])
      401;
    check
      "a draw that is no nonce"
      (R.callback
         { t.routes with R.draw = not_a_nonce }
         R.Google
         ~transaction_cookie:None
         ~query:[ "state", "s"; "code", "c" ])
      401;
    let b, (_ : string) = fresh_start R.Google in
    check "no state" (callback t b R.Google [ "code", "c" ]) 400;
    let b, url = fresh_start R.Google in
    check
      "a code and an error"
      (callback t b R.Google [ "state", param (Uri.of_string url) "state"; "code", "c"; "error", "x" ])
      400;
    let b, url = fresh_start R.Github in
    check "the person declined" (callback t b R.Github [ "state", param (Uri.of_string url) "state"; "error", "access_denied" ]) 401;
    let b, url = fresh_start R.Google in
    let code_, _ = sign_in_at_google t.providers ~sub:"google-sub-1" url in
    check "another state" (callback t b R.Google [ "state", "other"; "code", code_ ]) 401;
    let b, url = fresh_start R.Google in
    let code_, state = sign_in_at_google t.providers ~sub:"google-sub-1" url in
    check "a Google transaction at the GitHub callback" (callback t b R.Github [ "state", state; "code", code_ ]) 401;
    let b, url = fresh_start R.Github in
    check
      "a code GitHub did not give"
      (callback t b R.Github [ "state", param (Uri.of_string url) "state"; "code", "github-code-0" ])
      401;
    check "no invitation" (sign_in t (browser ()) R.Google ~who:7) 403;
    let first, first_url = fresh_start R.Google in
    let second, second_url = fresh_start R.Google in
    let code_, state = sign_in_at_google t.providers ~sub:"google-sub-1" first_url in
    Alcotest.(check int) "the first joins" 200 (code (callback t first R.Google [ "state", state; "code", code_ ]));
    let code_, state = sign_in_at_google t.providers ~sub:"google-sub-2" second_url in
    check "the invitation is spent" (callback t second R.Google [ "state", state; "code", code_ ]) 409;
    Alcotest.(check (option string)) "no session for the second" None second.session;
    each_drawn_once "a callback that is refused" !nonces)
;;

let a_sign_out_or_a_read_that_is_refused () =
  with_installation (fun t ->
    let b = browser () in
    Alcotest.(check int) "joins" 200 (code (sign_in ~fields:invited t b R.Google ~who:1));
    let value = current_session b in
    let csrf = string_member "csrf_token" (read_session t b) in
    let refused label answer expected ~clears =
      Alcotest.(check int) label expected (code answer);
      Alcotest.(check (option string))
        (label ^ ": the cookie")
        (if clears then Some "" else None)
        (cookie_set ~name:Q.session_cookie answer);
      Alcotest.(check string) (label ^ ": still open") "open" (session_status t value)
    in
    refused "a sign-out from another origin" (R.logout t.routes (request ~origin:Q.Other_origin ~csrf b)) 403 ~clears:false;
    refused "a sign-out with no token" (R.logout t.routes (request b)) 403 ~clears:false;
    refused "a sign-out with another token" (R.logout t.routes (request ~csrf:(String.make 64 'f') b)) 403 ~clears:false;
    refused "a sign-out beside a bearer" (R.logout t.routes (request ~csrf ~bearer:true b)) 401 ~clears:false;
    let twice = { (request ~csrf b) with Q.session_cookie = Q.session_cookies_of_values [ value; value ] } in
    refused "a sign-out with the cookie twice" (R.logout t.routes twice) 401 ~clears:false;
    refused
      "a read with the cookie twice"
      (R.session t.routes { twice with Q.method_ = Q.Safe; csrf = None })
      401
      ~clears:false;
    refused "a read from another origin" (read_session ~origin:Q.Other_origin t b) 403 ~clears:false;
    (* The token of the forged cookie passes the CSRF check, so the session
       check is the one that refuses. *)
    let forged_value = forged value in
    let forged_browser = { b with session = Some forged_value } in
    refused
      "a sign-out with a forged cookie"
      (R.logout t.routes (request ~csrf:(Bs.csrf_token (cookie_of forged_value)) forged_browser))
      401
      ~clears:true;
    t.providers.clock := !(t.providers.clock) + Authz_session_state.lifetime_ms;
    let late = read_session t b in
    Alcotest.(check int) "7 days later" 401 (code late);
    Alcotest.(check string) "it has expired" (Bs.refusal_to_string Bs.Expired) (string_member "error" late))
;;

let the_page_escapes_its_path () =
  with_installation (fun t ->
    let b = browser () in
    let back = sign_in ~fields:(("return_to", "/board?a=1&b='x'") :: invited) t b R.Github ~who:9 in
    Alcotest.(check int) "signed in" 200 (code back);
    Alcotest.(check bool) "escaped" true (contains ~sub:{|href="/board?a=1&amp;b=&#39;x&#39;"|} back.body);
    Alcotest.(check bool) "not raw" false (contains ~sub:"b='x'" back.body))
;;

let () =
  Alcotest.run
    "login_routes"
    [ ( "sign-in"
      , [ Alcotest.test_case "Google, then sign out" `Quick a_google_sign_in_gives_a_session_until_the_sign_out
        ; Alcotest.test_case "a new sign-in" `Quick a_new_sign_in_ends_the_session_of_the_browser
        ; Alcotest.test_case "the page escapes its path" `Quick the_page_escapes_its_path
        ] )
    ; ( "refused"
      , [ Alcotest.test_case "start" `Quick a_start_that_is_refused
        ; Alcotest.test_case "callback" `Quick a_callback_that_is_refused
        ; Alcotest.test_case "sign-out and read" `Quick a_sign_out_or_a_read_that_is_refused
        ] )
    ]
;;
