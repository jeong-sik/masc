(* The login routes over the server's HTTP/1 router (plan C3-8c): a browser's
   requests go in as bytes to a router that holds the routes of
   Server_login_http over a zone on real files, and the bytes that come back
   are read as a browser reads them. The test plays GitHub through the
   transport functions of the routes, so nothing leaves the process. What the
   routes decide is tested in test_login_routes and test_login_allowlist_routes;
   this suite is about what reaches them and what they write. *)

open Authz_types
module B = Authz_bootstrap
module E = Authz_invite_event
module Http = Masc.Http_server_eio
module Q = Authz_browser_request
module R = Login_routes
module Z = Authz_zone

let start_ms = 1_700_000_000_000
let admin_token = String.make 64 'a'
let client_id = "Iv1.test-client"
let client_secret = "github-secret-1"
let redirect_uri = "https://masc.example/auth/github/callback"
let same_origin = "http://127.0.0.1:8935"

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

let fresh = ref 0

let draw () =
  incr fresh;
  Printf.sprintf "%064x" !fresh
;;

let contains ~sub text =
  let n = String.length sub in
  let rec at i = i + n <= String.length text && (String.equal (String.sub text i n) sub || at (i + 1)) in
  at 0
;;

(* The text before and after the first [on]. *)
let split_once ~on text =
  let n = String.length on in
  let rec find i =
    if i + n > String.length text
    then None
    else if String.equal (String.sub text i n) on
    then Some (String.sub text 0 i, String.sub text (i + n) (String.length text - i - n))
    else find (i + 1)
  in
  find 0
;;

(* What a page lets a person do about a GitHub login, read from the page as
   a browser parses it. *)
let login_of page = Account_page_reading.login ~start:"/auth/github/start" page

(* ---- GitHub, as the test plays it ---- *)

type github =
  { grants : (string, string * int) Hashtbl.t  (** A code: the S256 challenge and the user. *)
  ; tokens : (string, int) Hashtbl.t
  ; issued : int ref
  }

let answer ?(status = 200) body = Ok { Login_transport.status; headers = []; body }

let form_field body name =
  Option.bind (List.assoc_opt name (Uri.query_of_encoded body)) (function
    | [ value ] -> Some value
    | [] | _ :: _ :: _ -> None)
;;

let s256 verifier =
  Digestif.SHA256.(digest_string verifier |> to_raw_string)
  |> Base64.encode_string ~pad:false ~alphabet:Base64.uri_safe_alphabet
;;

let github_get g ~url ~headers =
  if not (String.equal url Github_oauth.user_url)
  then Alcotest.failf "a GET of %s" url
  else (
    let bearer =
      List.find_map
        (fun (name, value) ->
          if String.equal (String.lowercase_ascii name) "authorization" then Some value else None)
        headers
    in
    match
      Hashtbl.fold
        (fun token user_id found -> if bearer = Some ("Bearer " ^ token) then Some user_id else found)
        g.tokens
        None
    with
    | Some user_id -> answer (Printf.sprintf {|{"login":"someone","id":%d}|} user_id)
    | None -> answer ~status:401 {|{"message":"Bad credentials"}|})
;;

(* A code is spent by its first request, and the verifier must be the one whose
   S256 the authorization request carried. *)
let github_post g ~url ~headers:_ ~body =
  if not (String.equal url Github_oauth.token_url)
  then Alcotest.failf "a POST to %s" url
  else (
    let field = form_field body in
    let code = Option.value (field "code") ~default:"" in
    match Hashtbl.find_opt g.grants code with
    | Some (challenge, user_id)
      when field "client_secret" = Some client_secret
           && Option.map s256 (field "code_verifier") = Some challenge ->
      Hashtbl.remove g.grants code;
      let token = Printf.sprintf "gho_%d" (Hashtbl.length g.tokens + 1) in
      Hashtbl.replace g.tokens token user_id;
      answer (Yojson.Safe.to_string (`Assoc [ "access_token", `String token; "token_type", `String "bearer" ]))
    | Some _ | None -> answer {|{"error":"bad_verification_code"}|})
;;

(* ---- HTTP/1 over the router ---- *)

type reply =
  { status : int
  ; headers : (string * string) list  (** Lowercase names, in the order written. *)
  ; body : string
  }

let authority =
  match Server_request_authority.of_host_port ~host:"127.0.0.1" ~port:8935 with
  | Ok authority -> authority
  | Error `Malformed -> Alcotest.fail "no loopback authority"
;;

let parse raw =
  match split_once ~on:"\r\n\r\n" raw with
  | None -> Alcotest.failf "no HTTP answer in %S" raw
  | Some (head, body) ->
    (match List.map String.trim (String.split_on_char '\n' head) with
     | [] -> Alcotest.failf "no status line in %S" raw
     | status_line :: lines ->
       let status =
         match String.split_on_char ' ' status_line with
         | (_ : string) :: code :: (_ : string list) -> int_of_string code
         | [] | [ _ ] -> Alcotest.failf "the status line %S" status_line
       in
       let header line =
         match split_once ~on:": " line with
         | Some (name, value) -> String.lowercase_ascii name, value
         | None -> Alcotest.failf "the header line %S" line
       in
       { status; headers = List.map header lines; body })
;;

let exchange router ~meth ~path ~headers ~body =
  Server_request_authority.with_current authority (fun () ->
    let output = Buffer.create 1024 in
    let connection =
      Httpun.Server_connection.create (fun reqd -> Http.Router.dispatch router (Httpun.Reqd.request reqd) (Masc.Http_reqd.of_httpun reqd))
    in
    let lines = String.concat "" (List.map (fun (name, value) -> name ^ ": " ^ value ^ "\r\n") headers) in
    let raw =
      Printf.sprintf
        "%s %s HTTP/1.1\r\nHost: 127.0.0.1:8935\r\n%sContent-Length: %d\r\n\r\n%s"
        meth
        path
        lines
        (String.length body)
        body
    in
    let input = Bigstringaf.of_string ~off:0 ~len:(String.length raw) raw in
    let (_ : int) = Httpun.Server_connection.read_eof connection input ~off:0 ~len:(Bigstringaf.length input) in
    let rec drain () =
      match Httpun.Server_connection.next_write_operation connection with
      | `Write iovecs ->
        let written =
          List.fold_left
            (fun total (iov : Bigstringaf.t Httpun.IOVec.t) ->
              Buffer.add_string output (Bigstringaf.substring iov.buffer ~off:iov.off ~len:iov.len);
              total + iov.len)
            0
            iovecs
        in
        Httpun.Server_connection.report_write_result connection (`Ok written);
        drain ()
      | `Yield | `Close (_ : int) -> ()
    in
    drain ();
    parse (Buffer.contents output))
;;

(* ---- a browser ---- *)

type browser = { mutable cookies : (string * string) list }

let fresh_browser () = { cookies = [] }
let all name reply = List.filter_map (fun (key, value) -> if String.equal key name then Some value else None) reply.headers

let one name reply =
  match all name reply with
  | [ value ] -> value
  | values -> Alcotest.failf "%d values of %s in a %d" (List.length values) name reply.status
;;

let cookie_of line =
  let pair =
    match String.split_on_char ';' line with
    | first :: (_ : string list) -> first
    | [] -> line
  in
  match split_once ~on:"=" pair with
  | Some cookie -> cookie
  | None -> Alcotest.failf "a set-cookie with no value: %S" line
;;

let written_cookies reply = List.sort String.compare (List.map (fun line -> fst (cookie_of line)) (all "set-cookie" reply))

let keep browser reply =
  List.iter
    (fun line ->
      let name, value = cookie_of line in
      let others = List.remove_assoc name browser.cookies in
      browser.cookies <- (if String.equal value "" then others else (name, value) :: others))
    (all "set-cookie" reply)
;;

let send ?(headers = []) ?(body = "") browser router ~meth ~path =
  let cookie =
    match browser.cookies with
    | [] -> []
    | cookies -> [ "Cookie", String.concat "; " (List.map (fun (name, value) -> name ^ "=" ^ value) cookies) ]
  in
  let reply = exchange router ~meth ~path ~headers:(cookie @ headers) ~body in
  keep browser reply;
  reply
;;

let member name reply =
  match Yojson.Safe.from_string reply.body with
  | `Assoc fields -> List.assoc_opt name fields
  | _ -> Alcotest.failf "the answer %S is not a JSON object" reply.body
;;

(* The headers of a request that changes something. *)
let changing ?(origin = Some same_origin) ?csrf () =
  Option.to_list (Option.map (fun origin -> "Origin", origin) origin)
  @ Option.to_list (Option.map (fun token -> Q.csrf_header, token) csrf)
;;

(* ---- the installation ---- *)

type installation =
  { router : Http.Router.t
  ; routes : R.t
  ; github : github
  ; base : string
  ; env : Eio_unix.Stdenv.base
  }

let start_instant =
  match Ptime.of_float_s (Float.of_int start_ms /. 1000.) with
  | Some instant -> instant
  | None -> Alcotest.fail "the clock left the range of Ptime"
;;

let with_installation f =
  Eio_main.run (fun env ->
    let root = Filename.temp_dir "server-login-http-" "" in
    Fun.protect
      ~finally:(fun () -> remove_tree root)
      (fun () ->
        let base = Filename.concat root "base" in
        Unix.mkdir base 0o700;
        let store = Filename.concat (Filename.concat root "store") "external.jsonl" in
        let now_ms () = start_ms in
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
        match Z.open_at_start ~now_ms ~log_path:(Authz_log.path_of_base_path ~base_path:base) ~store_path:store with
        | Error error -> Alcotest.failf "zone not opened: %s" (Z.open_error_to_string error)
        | Ok zone ->
          (match
             Z.commit
               zone
               { Z.author = Authz_records.Author.Local_operator
               ; kind = Authz_record.Kind.Invite
               ; body =
                   get_ok
                     (E.to_body
                        (E.Issued
                           { invite_id = get_ok (Invite_id.of_string "invite-admin")
                           ; token_digest = E.Token_digest.of_token admin_token
                           ; expires_at_ms = start_ms + 3_600_000
                           ; role = E.Admin
                           }))
               }
           with
           | Ok (_ : Z.committed) -> ()
           | Error error -> Alcotest.failf "invitation refused: %s" (Z.error_detail error));
          let client =
            match Login_client.make ~client_id ~client_secret ~redirect_uri with
            | Ok client -> client
            | Error error -> Alcotest.fail (Login_client.error_to_string error)
          in
          let github = { grants = Hashtbl.create 4; tokens = Hashtbl.create 4; issued = ref 0 } in
          let routes =
            { R.zone
            ; transactions = Oidc_login_transaction.create ()
            ; google = None
            ; github = Some client
            ; get = github_get github
            ; post = github_post github
            ; now = (fun () -> start_instant)
            ; draw
            }
          in
          f
            { router = Server_login_http.add_routes routes (Http.Router.create ())
            ; routes
            ; github
            ; base
            ; env
            }))
;;

(* ---- a login, as a browser does it ---- *)

let start t ?(headers = [ "Origin", same_origin ]) browser fields =
  send
    browser
    t.router
    ~meth:"POST"
    ~path:"/auth/github/start"
    ~headers:(("Content-Type", "application/x-www-form-urlencoded") :: headers)
    ~body:(Login_transport.form fields)
;;

let param url name =
  match Uri.get_query_param (Uri.of_string url) name with
  | Some value -> value
  | None -> Alcotest.failf "the authorization URL %s has no %s" url name
;;

(* GitHub signs [user_id] in and sends the browser back with a code. *)
let sign_in ?(fields = []) t browser ~user_id =
  let started = start t browser fields in
  Alcotest.(check int) ("started: " ^ started.body) 303 started.status;
  let url = one "location" started in
  incr t.github.issued;
  let code = Printf.sprintf "github-code-%d" !(t.github.issued) in
  Hashtbl.replace t.github.grants code (param url "code_challenge", user_id);
  send
    browser
    t.router
    ~meth:"GET"
    ~path:("/auth/github/callback?" ^ Login_transport.form [ "state", param url "state"; "code", code ])
;;

let csrf_of t browser =
  let reply = send browser t.router ~meth:"GET" ~path:"/auth/session" in
  Alcotest.(check int) ("session read: " ^ reply.body) 200 reply.status;
  match member "csrf_token" reply with
  | Some (`String token) -> token
  | _ -> Alcotest.failf "no csrf_token in %S" reply.body
;;

let user_of t browser =
  let reply = send browser t.router ~meth:"GET" ~path:"/auth/session" in
  match member "user_id" reply with
  | Some (`String id) -> get_ok (User_id.of_string id)
  | _ -> Alcotest.failf "no user_id in %S" reply.body
;;

let registration_of reply =
  Alcotest.(check int) ("registered: " ^ reply.body) 200 reply.status;
  match member "registration_id" reply with
  | Some (`String id) -> id
  | _ -> Alcotest.failf "no registration_id in %S" reply.body
;;

let register t browser ~csrf body =
  send
    browser
    t.router
    ~meth:"POST"
    ~path:"/api/v1/auth/allowlist"
    ~headers:(("Content-Type", "application/json") :: changing ~csrf ())
    ~body
;;

(* ---- the cases ---- *)

let a_browser_signs_in_acts_and_signs_out () =
  with_installation (fun t ->
    let admin = fresh_browser () in
    let started = start t admin [ "invite", admin_token; "return_to", "/keepers" ] in
    Alcotest.(check (list string)) "the start writes the transaction" [ Q.transaction_cookie ] (written_cookies started);
    Alcotest.(check bool) "to GitHub" true (String.starts_with ~prefix:Github_oauth.authorize_url (one "location" started));
    let url = one "location" started in
    Hashtbl.replace t.github.grants "github-code-0" (param url "code_challenge", 583231);
    let back =
      send
        admin
        t.router
        ~meth:"GET"
        ~path:("/auth/github/callback?" ^ Login_transport.form [ "state", param url "state"; "code", "github-code-0" ])
    in
    Alcotest.(check int) ("signed in: " ^ back.body) 200 back.status;
    Alcotest.(check (list string))
      "the callback writes two cookies"
      (List.sort String.compare [ Q.session_cookie; Q.transaction_cookie ])
      (written_cookies back);
    Alcotest.(check (list string)) "the browser keeps the session" [ Q.session_cookie ] (List.map fst admin.cookies);
    Alcotest.(check bool) "the page moves on to return_to" true (contains ~sub:"/keepers" back.body);
    Alcotest.(check string) "the length is the body's" (string_of_int (String.length back.body)) (one "content-length" back);
    let csrf = csrf_of t admin in
    let (_ : string) = registration_of (register t admin ~csrf {|{"provider":"github","user_id":7}|}) in
    Alcotest.(check int) "the registered identity joins" 200 (sign_in t (fresh_browser ()) ~user_id:7).status;
    let other = registration_of (register t admin ~csrf {|{"provider":"github","user_id":8}|}) in
    let removed =
      send admin t.router ~meth:"DELETE" ~path:("/api/v1/auth/allowlist/" ^ other) ~headers:(changing ~csrf ())
    in
    Alcotest.(check int) ("removed: " ^ removed.body) 204 removed.status;
    Alcotest.(check int) "the removed identity does not join" 403 (sign_in t (fresh_browser ()) ~user_id:8).status;
    let old = { cookies = admin.cookies } in
    let out = send admin t.router ~meth:"POST" ~path:"/auth/logout" ~headers:(changing ~csrf ()) in
    Alcotest.(check int) ("signed out: " ^ out.body) 204 out.status;
    Alcotest.(check (list string)) "the cookie is cleared" [] (List.map fst admin.cookies);
    Alcotest.(check int)
      "the old cookie does not act"
      401
      (send old t.router ~meth:"GET" ~path:"/auth/session").status)
;;

(* What a who-am-I answer says, in one line. *)
let whoami_line (reply : reply) =
  let text name =
    match member name reply with
    | Some (`String value) -> value
    | Some (`Assoc fields) ->
      (match List.assoc_opt "kind" fields with
       | Some (`String kind) -> kind
       | _ -> Alcotest.failf "no kind in %S" reply.body)
    | _ -> Alcotest.failf "no %s in %S" name reply.body
  in
  match reply.status with
  | 200 -> Printf.sprintf "200 %s %s by %s" (text "role") (text "principal") (text "binding")
  | status -> Printf.sprintf "%d %s" status (text "error")
;;

let whoami router browser ?(headers = []) () =
  whoami_line (send browser router ~meth:"GET" ~path:"/api/v1/auth/whoami" ~headers)
;;

(* The localhost preview (plan, preview scope P3) as a browser uses it: the
   pages, a GitHub login from the invitation, who-am-I, and the sign-out. *)
(* A provider a person may connect and one they may not (plan L2a). *)
let declared_toml =
  {|[runtime]
default = "claude_code.claude-sonnet-5"

[providers.claude_code]
display-name = "Claude Code"
protocol = "claude-code"
command = "claude"
is-non-interactive = true

[providers.agy]
display-name = "Antigravity"
protocol = "antigravity-cli"
command = "agy"
is-non-interactive = true
timeout-s = 180.0

[providers.local]
display-name = "Local server"
protocol = "openai-compatible-http"
endpoint = "http://127.0.0.1:1"

[models."claude-sonnet-5"]
api-name = "claude-sonnet-5"
max-context = 1000000
tools-support = true
streaming = true

[claude_code."claude-sonnet-5"]
|}
;;

let the_preview_follows_a_login () =
  with_installation (fun t ->
    let router = Server_login_http.add_person_routes t.routes ~env:t.env ~base_path:t.base t.router in
    let admin = fresh_browser () in
    let home = send admin router ~meth:"GET" ~path:"/" in
    Alcotest.(check int) "the home page" 200 home.status;
    Alcotest.(check bool)
      "a form may go to GitHub"
      true
      (contains ~sub:"form-action 'self' https://github.com" (one "content-security-policy" home));
    (* The policy lets a browser apply one sheet, the one the page wrote under
       the nonce of that policy. Under another nonce the browser applies no
       style at all. *)
    (match split_once ~on:"style-src 'nonce-" (one "content-security-policy" home) with
     | None -> Alcotest.fail "the policy of the home page names no style sheet"
     | Some (_, rest) ->
       let nonce =
         match split_once ~on:"'" rest with
         | Some (nonce, _) -> nonce
         | None -> Alcotest.fail "the style source of the policy does not end"
       in
       Alcotest.(check bool)
         "the sheet of the page is under the nonce of its policy"
         true
         (contains ~sub:(Printf.sprintf {|<style nonce="%s">|} nonce) home.body));
    (* A browser sends "Origin: null" with a form POST from a no-referrer page. *)
    Alcotest.(check string) "the form posts with its origin" "same-origin" (one "referrer-policy" home);
    let invitation = send admin router ~meth:"GET" ~path:"/accounts/invite" in
    Alcotest.(check int) "the invitation page" 200 invitation.status;
    (* On each page a person can press the one submit button of the form that
       posts to the start route. *)
    Alcotest.check
      Account_page_reading.outcome
      "the home page starts a GitHub login"
      (Ok Account_page_reading.Open)
      (login_of home.body);
    Alcotest.check
      Account_page_reading.outcome
      "the invitation page starts one"
      (Ok Account_page_reading.Open)
      (login_of invitation.body);
    (* A server with no GitHub login client serves the same pages, and the
       button of the login cannot be pressed. *)
    (let no_github =
       Server_login_http.add_person_routes
         { t.routes with Login_routes.github = None }
         ~env:t.env
         ~base_path:t.base
         (Http.Router.create ())
     in
     List.iter
       (fun path ->
         let page = send (fresh_browser ()) no_github ~meth:"GET" ~path in
         Alcotest.(check int) ("with no GitHub client, " ^ path) 200 page.status;
         (* The same button, disabled, and the page says why: the button
            names its description, which is on the page and holds text. *)
         Alcotest.check
           Account_page_reading.outcome
           ("the login is closed and the page says why on " ^ path)
           (Ok Account_page_reading.Closed)
           (login_of page.body))
       [ "/"; "/accounts/invite" ]);
    Alcotest.(check string)
      "nobody yet"
      ("401 " ^ Masc.Auth_gate.reason_to_string Masc.Auth_gate.Credential_required)
      (whoami router admin ());
    let back = sign_in t admin ~user_id:583231 ~fields:[ "invite", admin_token; "return_to", "/" ] in
    Alcotest.(check int) ("signed in: " ^ back.body) 200 back.status;
    Alcotest.(check string) "the Admin" "200 admin human by session" (whoami router admin ());
    let owned = send admin router ~meth:"GET" ~path:Masc.Auth_preview.provider_accounts_path in
    Alcotest.(check (pair int string))
      "owns no subscription yet"
      (200, {|{"provider_accounts":[],"runtimes":[]}|})
      (owned.status, owned.body);
    (* Plan D1: what the subscription routes write once a login and a call
       of the account pass, the list shows. *)
    let user_id = user_of t admin in
    let account = get_ok (Provider_account_id.of_string "account-1") in
    (match Authz_provider_account.link t.routes.R.zone ~user_id ~provider_account_id:account with
     | Ok () -> ()
     | Error error -> Alcotest.fail (Authz_provider_account.error_to_string error));
    let runtime_id = get_ok (Runtime_id.of_string "account-1.claude-sonnet-5-5") in
    (match
       Authz_runtime.make
         t.routes.R.zone
         ~user_id
         ~provider_account_id:account
         ~runtime_id
         ~self_effects:Effect.(Set.of_list [ Invoke_model; Use_tool ])
         ~draw:(fun () -> "grant-1")
     with
     | Ok grant -> Alcotest.(check string) "the Self grant" "grant-1" (Grant_id.to_string grant)
     | Error error -> Alcotest.fail (Authz_runtime.error_detail error));
    let owned = send admin router ~meth:"GET" ~path:Masc.Auth_preview.provider_accounts_path in
    Alcotest.(check (pair int string))
      "owns the subscription and its Runtime"
      ( 200
      , {|{"provider_accounts":["account-1"],"runtimes":[{"runtime_id":"account-1.claude-sonnet-5-5","provider_account_id":"account-1"}]}|}
      )
      (owned.status, owned.body);
    (* Plan D1-5: the person makes a Keeper and gives it their Runtime. *)
    let csrf = csrf_of t admin in
    let keeper_post ?(csrf = Some csrf) path body =
      let reply =
        send
          admin
          router
          ~meth:"POST"
          ~path
          ~headers:(changing ?csrf () @ [ "Content-Type", "application/json" ])
          ~body
      in
      reply.status, reply.body
    in
    let keepers () =
      let reply = send admin router ~meth:"GET" ~path:Masc.Auth_preview_keeper.keepers_path in
      reply.status, reply.body
    in
    let made = Masc.Auth_preview_keeper.keepers_path in
    let assign = Masc.Auth_preview_keeper.assign_path in
    let check_reply label expected actual = Alcotest.(check (pair int string)) label expected actual in
    check_reply "owns no Keeper yet" (200, {|{"keepers":[]}|}) (keepers ());
    Alcotest.(check int)
      "a Keeper without the CSRF token stops at the gate"
      403
      (fst (keeper_post ~csrf:None made {|{"keeper_id":"keeper-1"}|}));
    check_reply
      "a name that is not a Keeper name"
      ( 400
      , {|{"error":"keeper_name must match [A-Za-z0-9._-]+ and must not be a reserved path component (. or ..)"}|}
      )
      (keeper_post made {|{"keeper_id":".."}|});
    check_reply
      "a Keeper"
      (200, {|{"keeper_id":"keeper-1","record":"made"}|})
      (keeper_post made {|{"keeper_id":"keeper-1"}|});
    check_reply
      "the same Keeper again"
      (200, {|{"keeper_id":"keeper-1","record":"existing"}|})
      (keeper_post made {|{"keeper_id":"keeper-1"}|});
    check_reply
      "a Runtime no one made"
      (404, {|{"error":"No Runtime of yours has this id."}|})
      (keeper_post assign {|{"keeper_id":"keeper-1","runtime_id":"account-2.claude-sonnet-5-5"}|});
    check_reply
      "its owner's Runtime"
      ( 200
      , {|{"keeper_id":"keeper-1","runtime_id":"account-1.claude-sonnet-5-5","record":"assigned"}|} )
      (keeper_post assign {|{"keeper_id":"keeper-1","runtime_id":"account-1.claude-sonnet-5-5"}|});
    check_reply
      "the Keeper on its Runtime"
      (200, {|{"keepers":[{"keeper_id":"keeper-1","runtime_id":"account-1.claude-sonnet-5-5"}]}|})
      (keepers ());
    (* Plan D2-8: a turn is judged as [Manage_own_keeper] with the person's
       namespace. A turn of a Keeper no one made gets past the gate and stops
       at the records, before any client starts. *)
    let turn = Masc.Auth_preview_keeper.turn_path in
    Alcotest.(check int)
      "a turn without the CSRF token stops at the gate"
      403
      (fst (keeper_post ~csrf:None turn {|{"keeper_id":"keeper-1","message":"hello"}|}));
    check_reply
      "a turn of a Keeper no one made"
      (404, {|{"error":"No Keeper of yours has this name.","code":"unknown_keeper"}|})
      (keeper_post turn {|{"keeper_id":"keeper-2","message":"hello"}|});
    Alcotest.(check int)
      "a connect without the CSRF token stops at the gate"
      403
      (send
         admin
         router
         ~meth:"POST"
         ~path:Masc.Auth_preview.connect_path
         ~headers:[ "Origin", same_origin; "Content-Type", "application/json" ]
         ~body:{|{"integration_id":"claude_code"}|})
        .status;
    Alcotest.(check string)
      "a session and a bearer"
      ("401 " ^ Masc.Auth_gate.reason_to_string Masc.Auth_gate.Several_credentials)
      (whoami router admin ~headers:[ "Authorization", "Bearer " ^ String.make 64 'f' ] ());
    (* Plan L2a: the integrations are read with the session. This workspace
       has no runtime.toml, so the server says it cannot read one. *)
    let integrations () =
      let reply = send admin router ~meth:"GET" ~path:Server_person_integrations.path in
      reply.status, reply.body
    in
    check_reply
      "a person reaches the integrations"
      (503, {|{"error":"The workspace configuration could not be read."}|})
      (integrations ());
    (* Once the workspace declares its providers, the route reads them: the
       Claude Code one, and not the Antigravity one, which the connect route
       refuses a person by the same rule. *)
    let config = Filename.concat (Common.masc_dir_from_base_path ~base_path:t.base) "config" in
    Fs_compat.mkdir_p config;
    Out_channel.with_open_bin
      (Filename.concat config Config_dir_resolver.runtime_toml_filename)
      (fun out -> output_string out declared_toml);
    check_reply
      "the integrations of the workspace"
      ( 200
      , {|{"integrations":[{"integration_id":"claude_code","display_name":"Claude Code","models":["claude-sonnet-5"],"calls":"allowed"}]}|}
      )
      (integrations ());
    let refused sentence = 400, Yojson.Safe.to_string (`Assoc [ "error", `String sentence ]) in
    check_reply
      "a connect of what a person may not connect"
      (refused
         "Antigravity is not connected in multi-account mode: its credential is a copy in the setup registry, \
          which has no owner.")
      (keeper_post Masc.Auth_preview.connect_path {|{"integration_id":"agy"}|});
    (* A client the server knows that the workspace does not declare: an
       account of it could not be used, so its login does not start. *)
    check_reply
      "a connect of a client the workspace does not declare"
      (refused
         "In multi-account mode a login is of a provider this workspace declares, and it declares none of \
          this id.")
      (keeper_post Masc.Auth_preview.connect_path {|{"integration_id":"codex"}|});
    check_reply
      "a connect of a declared server over HTTP"
      (refused "This connection needs its native account setup before web discovery.")
      (keeper_post Masc.Auth_preview.connect_path {|{"integration_id":"local"}|});
    let out = send admin router ~meth:"POST" ~path:"/auth/logout" ~headers:(changing ~csrf ()) in
    Alcotest.(check int) ("signed out: " ^ out.body) 204 out.status;
    Alcotest.(check string)
      "nobody again"
      ("401 " ^ Masc.Auth_gate.reason_to_string Masc.Auth_gate.Credential_required)
      (whoami router admin ());
    Alcotest.(check int)
      "and no subscriptions"
      401
      (send admin router ~meth:"GET" ~path:Masc.Auth_preview.provider_accounts_path).status;
    Alcotest.(check int)
      "and no integrations"
      401
      (send admin router ~meth:"GET" ~path:Server_person_integrations.path).status)
;;

(* A PAT through the routes a browser calls (plan C4-10): the person issues
   one with their session, it acts as them where a bearer is read, and once
   they revoke it, it does not. A bearer alone does not reach the PAT routes,
   so a PAT issues no other PAT. *)
let a_pat_acts_until_it_is_revoked () =
  with_installation (fun t ->
    let router = Server_login_http.add_person_routes t.routes ~env:t.env ~base_path:t.base t.router in
    let admin = fresh_browser () in
    Alcotest.(check int)
      "the Admin joins"
      200
      (sign_in t admin ~fields:[ "invite", admin_token ] ~user_id:583231).status;
    let csrf = csrf_of t admin in
    let issue browser headers =
      send
        browser
        router
        ~meth:"POST"
        ~path:"/api/v1/auth/pats"
        ~headers:(("Content-Type", "application/json") :: headers)
        ~body:
          {|{"scope":{"runtimes":"all","channels":["direct"],"allowed_effects":["read_state"]},"expires_at_ms":null}|}
    in
    let issued = issue admin (changing ~csrf ()) in
    Alcotest.(check int) ("issued: " ^ issued.body) 200 issued.status;
    let pat_id, token =
      match member "pat_id" issued, member "token" issued with
      | Some (`String pat_id), Some (`String token) -> pat_id, token
      | _ -> Alcotest.failf "no PAT in %S" issued.body
    in
    let listed = send admin router ~meth:"GET" ~path:"/api/v1/auth/pats" in
    Alcotest.(check int) ("listed: " ^ listed.body) 200 listed.status;
    Alcotest.(check (pair bool bool))
      "the list holds the PAT and not its token"
      (true, false)
      (contains ~sub:pat_id listed.body, contains ~sub:token listed.body);
    let bearer = [ "Authorization", "Bearer " ^ token ] in
    Alcotest.(check string)
      "the PAT acts as the Admin"
      "200 admin human by pat"
      (whoami router (fresh_browser ()) ~headers:bearer ());
    Alcotest.(check int)
      "a bearer alone issues no PAT"
      401
      (issue (fresh_browser ()) (bearer @ changing ())).status;
    let revoked =
      send admin router ~meth:"DELETE" ~path:("/api/v1/auth/pats/" ^ pat_id) ~headers:(changing ~csrf ())
    in
    Alcotest.(check int) ("revoked: " ^ revoked.body) 204 revoked.status;
    Alcotest.(check string)
      "the revoked PAT does not act"
      ("401 " ^ Masc.Auth_gate.reason_to_string (Masc.Auth_gate.Pat_refused Authz_pat.Ended))
      (whoami router (fresh_browser ()) ~headers:bearer ()))
;;

(* The MCP endpoint of a person (plan S1b-1a): an MCP client posts JSON-RPC
   messages with the person's PAT and gets one JSON answer for each. The
   endpoint judges the credential of every request, so it gives no session id,
   and a revoked PAT is refused on the next request. A browser session acts
   there under the rules of every route that changes something: the same
   origin and the CSRF token. *)
let mcp_headers = [ "Content-Type", "application/json"; "Accept", "application/json, text/event-stream" ]

let mcp ?(headers = []) browser router body =
  send browser router ~meth:"POST" ~path:Server_person_mcp.path ~headers:(mcp_headers @ headers) ~body
;;

let rpc ?(params = `Assoc []) ~id method_ =
  Yojson.Safe.to_string
    (`Assoc [ "jsonrpc", `String "2.0"; "id", `Int id; "method", `String method_; "params", params ])
;;

(* The member at [path] of the JSON answer, [`Null] where there is none. *)
let at path (reply : reply) =
  List.fold_left
    (fun json name ->
      match json with
      | `Assoc fields -> Option.value ~default:`Null (List.assoc_opt name fields)
      | _ -> `Null)
    (Yojson.Safe.from_string reply.body)
    path
;;

let error_code reply =
  match at [ "error"; "code" ] reply with
  | `Int code -> code
  | _ -> Alcotest.failf "no error code in %S" reply.body
;;

let wire = Masc.Mcp_error_code.to_wire_code

(* The text of a tool result, as the answer of the route it stands for. *)
let tool_text (reply : reply) =
  match at [ "result"; "content" ] reply with
  | `List [ `Assoc fields ] ->
    (match List.assoc_opt "text" fields with
     | Some (`String text) -> text
     | _ -> Alcotest.failf "no text in %S" reply.body)
  | _ -> Alcotest.failf "no content in %S" reply.body
;;

let call_whoami ?(arguments = `Assoc []) ~id () =
  rpc ~id "tools/call" ~params:(`Assoc [ "name", `String "masc_whoami"; "arguments", arguments ])
;;

let a_person_calls_mcp () =
  with_installation (fun t ->
    let router = Server_login_http.add_person_routes t.routes ~env:t.env ~base_path:t.base t.router in
    let admin = fresh_browser () in
    Alcotest.(check int)
      "the Admin joins"
      200
      (sign_in t admin ~fields:[ "invite", admin_token ] ~user_id:583231).status;
    let csrf = csrf_of t admin in
    let issued =
      send
        admin
        router
        ~meth:"POST"
        ~path:"/api/v1/auth/pats"
        ~headers:(("Content-Type", "application/json") :: changing ~csrf ())
        ~body:
          {|{"scope":{"runtimes":"all","channels":["direct"],"allowed_effects":["read_state"]},"expires_at_ms":null}|}
    in
    let pat_id, token =
      match member "pat_id" issued, member "token" issued with
      | Some (`String pat_id), Some (`String token) -> pat_id, token
      | _ -> Alcotest.failf "no PAT in %S" issued.body
    in
    let bearer = [ "Authorization", "Bearer " ^ token ] in
    let as_pat ?(headers = []) body = mcp ~headers:(bearer @ headers) (fresh_browser ()) router body in
    (* Who may send a message at all. *)
    Alcotest.(check string)
      "no credential"
      ("401 " ^ Masc.Auth_gate.reason_to_string Masc.Auth_gate.Credential_required)
      (whoami_line (mcp (fresh_browser ()) router (rpc ~id:1 "tools/list")));
    let legacy = [ "Authorization", "Bearer " ^ String.make 64 'f' ] in
    Alcotest.(check string)
      "a credential the who-am-I route refuses is refused in its words"
      (whoami router (fresh_browser ()) ~headers:legacy ())
      (whoami_line (mcp ~headers:legacy (fresh_browser ()) router (rpc ~id:1 "tools/list")));
    (* The handshake of a client that starts with initialize. *)
    let initialized =
      as_pat
        (rpc
           ~id:1
           "initialize"
           ~params:
             (`Assoc
                 [ "protocolVersion", `String "2025-06-18"
                 ; "capabilities", `Assoc []
                 ; "clientInfo", `Assoc [ "name", `String "test"; "version", `String "0" ]
                 ]))
    in
    Alcotest.(check int) ("initialize: " ^ initialized.body) 200 initialized.status;
    Alcotest.(check string)
      "tools and nothing else"
      {|{"tools":{"listChanged":false}}|}
      (Yojson.Safe.to_string (at [ "result"; "capabilities" ] initialized));
    Alcotest.(check (list string)) "no session id" [] (all "mcp-session-id" initialized);
    let notified = as_pat {|{"jsonrpc":"2.0","method":"notifications/initialized"}|} in
    Alcotest.(check (pair int string)) "a notification" (202, "") (notified.status, notified.body);
    (* The tools. *)
    let listed = as_pat (rpc ~id:2 "tools/list") in
    Alcotest.(check int) ("tools/list: " ^ listed.body) 200 listed.status;
    Alcotest.(check (list string))
      "the tools"
      [ "masc_whoami"
      ; "masc_my_runtimes"
      ; "masc_my_keepers"
      ; "masc_my_keeper_create"
      ; "masc_my_keeper_assign"
      ; "masc_my_keeper_turn"
      ; "masc_my_keeper_conversation_new"
      ; "masc_my_keeper_conversation"
      ]
      (match at [ "result"; "tools" ] listed with
       | `List tools ->
         List.map
           (function
             | `Assoc fields ->
               (match List.assoc_opt "name" fields with
                | Some (`String name) -> name
                | _ -> Alcotest.failf "a tool without a name in %S" listed.body)
             | _ -> Alcotest.failf "a tool that is no object in %S" listed.body)
           tools
       | _ -> Alcotest.failf "no tools in %S" listed.body);
    let called = as_pat (call_whoami ~id:3 ()) in
    Alcotest.(check int) ("tools/call: " ^ called.body) 200 called.status;
    Alcotest.(check string)
      "the tool acts as the person of the PAT"
      "200 admin human by pat"
      (whoami_line { status = 200; headers = []; body = tool_text called });
    Alcotest.(check string)
      "and the result is no error"
      "false"
      (Yojson.Safe.to_string (at [ "result"; "isError" ] called));
    let with_argument = as_pat (call_whoami ~id:4 ~arguments:(`Assoc [ "user", `String "someone" ]) ()) in
    Alcotest.(check (pair int string))
      ("an argument the tool does not take: " ^ with_argument.body)
      (200, "true")
      (with_argument.status, Yojson.Safe.to_string (at [ "result"; "isError" ] with_argument));
    Alcotest.(check int)
      "a tool the endpoint does not have"
      (wire Masc.Mcp_error_code.Invalid_params)
      (error_code (as_pat (rpc ~id:5 "tools/call" ~params:(`Assoc [ "name", `String "masc_keeper_up" ]))));
    let unknown = as_pat (rpc ~id:6 "resources/list") in
    Alcotest.(check (pair int int))
      "a method the endpoint does not have"
      (200, wire Masc.Mcp_error_code.Method_not_found)
      (unknown.status, error_code unknown);
    (* What is no message. *)
    List.iter
      (fun (label, body, code) ->
        let reply = as_pat body in
        Alcotest.(check (pair int int)) (label ^ ": " ^ reply.body) (400, wire code) (reply.status, error_code reply))
      [ "text that is not JSON", "{", Masc.Mcp_error_code.Parse_error
      ; "a batch", "[]", Masc.Mcp_error_code.Invalid_request
      ];
    let only_json =
      send
        (fresh_browser ())
        router
        ~meth:"POST"
        ~path:Server_person_mcp.path
        ~headers:([ "Content-Type", "application/json"; "Accept", "application/json" ] @ bearer)
        ~body:(rpc ~id:7 "tools/list")
    in
    Alcotest.(check (pair int int))
      ("an Accept without the event stream: " ^ only_json.body)
      (400, wire Masc.Mcp_error_code.Invalid_request)
      (only_json.status, error_code only_json);
    Alcotest.(check int)
      "a message over the bound"
      413
      (as_pat (String.make (Server_person_mcp.max_message_bytes + 1) ' ')).status;
    Alcotest.(check int)
      "the endpoint opens no stream"
      405
      (send (fresh_browser ()) router ~meth:"GET" ~path:Server_person_mcp.path ~headers:bearer).status;
    (* A revision that selects its protocol on every request. *)
    let revision = Mcp_transport_protocol.protocol_version_2026_07_28 in
    let stateless ?(revision = revision) ~id () =
      rpc
        ~id
        "tools/call"
        ~params:
          (`Assoc
              [ "name", `String "masc_whoami"
              ; ( "_meta"
                , `Assoc
                    [ Mcp_transport_protocol.protocol_version_meta_key, `String revision
                    ; Mcp_transport_protocol.client_capabilities_meta_key, `Assoc []
                    ] )
              ])
    in
    let routing ?(revision = revision) method_ =
      [ "MCP-Protocol-Version", revision; "Mcp-Method", method_; "Mcp-Name", "masc_whoami" ]
    in
    let per_request = as_pat ~headers:(routing "tools/call") (stateless ~id:8 ()) in
    Alcotest.(check int) ("a per-request revision: " ^ per_request.body) 200 per_request.status;
    Alcotest.(check (list string)) "names the revision back" [ revision ] (all "mcp-protocol-version" per_request);
    Alcotest.(check string)
      "and calls the tool"
      "200 admin human by pat"
      (whoami_line { status = 200; headers = []; body = tool_text per_request });
    let mismatched = as_pat ~headers:(routing "tools/list") (stateless ~id:9 ()) in
    Alcotest.(check (pair int int))
      ("a routing header that is not the method of the body: " ^ mismatched.body)
      (400, wire Masc.Mcp_error_code.Header_mismatch)
      (mismatched.status, error_code mismatched);
    let unsupported =
      as_pat
        ~headers:(routing ~revision:"1999-01-01" "tools/call")
        (stateless ~revision:"1999-01-01" ~id:10 ())
    in
    Alcotest.(check (pair int int))
      ("a revision the server does not have: " ^ unsupported.body)
      (400, wire Masc.Mcp_error_code.Unsupported_protocol_version)
      (unsupported.status, error_code unsupported);
    (* A browser session. *)
    let by_session = mcp ~headers:(changing ~csrf ()) admin router (call_whoami ~id:11 ()) in
    Alcotest.(check int) ("a session with the token: " ^ by_session.body) 200 by_session.status;
    Alcotest.(check string)
      "acts as the person of the session"
      "200 admin human by session"
      (whoami_line { status = 200; headers = []; body = tool_text by_session });
    Alcotest.(check string)
      "a session without the CSRF token"
      ("403 " ^ Masc.Auth_gate.reason_to_string (Masc.Auth_gate.Session_refused Q.Csrf_missing))
      (whoami_line (mcp ~headers:(changing ()) admin router (call_whoami ~id:12 ())));
    (* The PAT, once revoked. *)
    let revoked =
      send admin router ~meth:"DELETE" ~path:("/api/v1/auth/pats/" ^ pat_id) ~headers:(changing ~csrf ())
    in
    Alcotest.(check int) ("revoked: " ^ revoked.body) 204 revoked.status;
    Alcotest.(check string)
      "the revoked PAT sends no message"
      ("401 " ^ Masc.Auth_gate.reason_to_string (Masc.Auth_gate.Pat_refused Authz_pat.Ended))
      (whoami_line (as_pat (rpc ~id:13 "tools/list"))))
;;

(* The Runtime and Keeper tools of the MCP endpoint (plan S1b-1b, S1b-1c). Each tool
   is the route of the person's page under another name: the same judgment,
   the same function, the same words. A PAT whose scope lacks the effect of
   the route is refused by the tool, and a Keeper of another person is one
   that is not there. *)
let call_tool ?(arguments = `Assoc []) ~id name =
  rpc ~id "tools/call" ~params:(`Assoc [ "name", `String name; "arguments", arguments ])
;;

let error_json text = Yojson.Safe.to_string (`Assoc [ "error", `String text ])

(* The refusal of a route of a Keeper's turn or conversation, which names its
   case (issue #51747). *)
let route_error ~code text =
  Yojson.Safe.to_string (`Assoc [ "error", `String text; "code", `String code ])
;;

let a_person_keeps_keepers_over_mcp () =
  with_installation (fun t ->
    let router = Server_login_http.add_person_routes t.routes ~env:t.env ~base_path:t.base t.router in
    let admin = fresh_browser () in
    Alcotest.(check int)
      "the Admin joins"
      200
      (sign_in t admin ~fields:[ "invite", admin_token ] ~user_id:583231).status;
    let csrf = csrf_of t admin in
    let user_id = user_of t admin in
    let account = get_ok (Provider_account_id.of_string "account-1") in
    (match Authz_provider_account.link t.routes.R.zone ~user_id ~provider_account_id:account with
     | Ok () -> ()
     | Error error -> Alcotest.fail (Authz_provider_account.error_to_string error));
    (match
       Authz_runtime.make
         t.routes.R.zone
         ~user_id
         ~provider_account_id:account
         ~runtime_id:(get_ok (Runtime_id.of_string "account-1.claude-sonnet-5-5"))
         ~self_effects:Effect.(Set.of_list [ Invoke_model; Use_tool ])
         ~draw:(fun () -> "grant-1")
     with
     | Ok (_ : Grant_id.t) -> ()
     | Error error -> Alcotest.fail (Authz_runtime.error_detail error));
    (* A PAT of [browser]'s person whose scope allows [effects]. *)
    let pat browser ~csrf effects =
      let issued =
        send
          browser
          router
          ~meth:"POST"
          ~path:"/api/v1/auth/pats"
          ~headers:(("Content-Type", "application/json") :: changing ~csrf ())
          ~body:
            (Printf.sprintf
               {|{"scope":{"runtimes":"all","channels":["direct"],"allowed_effects":%s},"expires_at_ms":null}|}
               effects)
      in
      match member "token" issued with
      | Some (`String token) -> token
      | _ -> Alcotest.failf "no PAT in %S" issued.body
    in
    let reader = pat admin ~csrf {|["read_state"]|} in
    let owner = pat admin ~csrf {|["manage_own_keeper","manage_own_provider","read_state"]|} in
    (* Whether the result is an error, and its text. *)
    let result ?arguments token name =
      let reply =
        mcp ~headers:[ "Authorization", "Bearer " ^ token ] (fresh_browser ()) router (call_tool ?arguments ~id:1 name)
      in
      Alcotest.(check int) (name ^ ": " ^ reply.body) 200 reply.status;
      Yojson.Safe.to_string (at [ "result"; "isError" ] reply), tool_text reply
    in
    let check label expected actual = Alcotest.(check (pair string string)) label expected actual in
    let keeper name = `Assoc [ "keeper_id", `String name ] in
    check
      "a PAT without the Keeper effect lists no Keeper"
      ("true", error_json (Masc.Auth_gate.reason_to_string Masc.Auth_gate.Pat_scope_lacks_own_keeper))
      (result reader "masc_my_keepers");
    check
      "and makes none"
      ("true", error_json (Masc.Auth_gate.reason_to_string Masc.Auth_gate.Pat_scope_lacks_own_keeper))
      (result reader "masc_my_keeper_create" ~arguments:(keeper "keeper-1"));
    check
      "a PAT without the provider effect lists no Runtime"
      ("true", error_json (Masc.Auth_gate.reason_to_string Masc.Auth_gate.Pat_scope_lacks_own_provider))
      (result reader "masc_my_runtimes");
    check
      "the Runtimes of the person"
      ( "false"
      , {|{"provider_accounts":["account-1"],"runtimes":[{"runtime_id":"account-1.claude-sonnet-5-5","provider_account_id":"account-1"}]}|}
      )
      (result owner "masc_my_runtimes");
    check "no Keeper yet" ("false", {|{"keepers":[]}|}) (result owner "masc_my_keepers");
    Alcotest.(check string)
      "a Keeper without a name is refused by the definition of the tool"
      "true"
      (fst (result owner "masc_my_keeper_create"));
    check
      "a name that is not a Keeper name, in the words of the route"
      ( "true"
      , error_json
          "keeper_name must match [A-Za-z0-9._-]+ and must not be a reserved path component (. or ..)" )
      (result owner "masc_my_keeper_create" ~arguments:(keeper ".."));
    check
      "a Keeper"
      ("false", {|{"keeper_id":"keeper-1","record":"made"}|})
      (result owner "masc_my_keeper_create" ~arguments:(keeper "keeper-1"));
    check
      "the same Keeper again"
      ("false", {|{"keeper_id":"keeper-1","record":"existing"}|})
      (result owner "masc_my_keeper_create" ~arguments:(keeper "keeper-1"));
    check
      "a Runtime no one made"
      ("true", error_json "No Runtime of yours has this id.")
      (result
         owner
         "masc_my_keeper_assign"
         ~arguments:(`Assoc [ "keeper_id", `String "keeper-1"; "runtime_id", `String "account-2.claude-sonnet-5-5" ]));
    check
      "its owner's Runtime, with the arguments in the other order"
      ("false", {|{"keeper_id":"keeper-1","runtime_id":"account-1.claude-sonnet-5-5","record":"assigned"}|})
      (result
         owner
         "masc_my_keeper_assign"
         ~arguments:(`Assoc [ "runtime_id", `String "account-1.claude-sonnet-5-5"; "keeper_id", `String "keeper-1" ]));
    let listed = {|{"keepers":[{"keeper_id":"keeper-1","runtime_id":"account-1.claude-sonnet-5-5"}]}|} in
    check "the Keeper on its Runtime" ("false", listed) (result owner "masc_my_keepers");
    Alcotest.(check string)
      "the page of the person lists the same"
      listed
      (send admin router ~meth:"GET" ~path:Masc.Auth_preview_keeper.keepers_path).body;
    (* Another person. *)
    let (_ : string) = registration_of (register t admin ~csrf {|{"provider":"github","user_id":7}|}) in
    let other = fresh_browser () in
    Alcotest.(check int) "another person joins" 200 (sign_in t other ~user_id:7).status;
    let theirs = pat other ~csrf:(csrf_of t other) {|["manage_own_keeper","read_state"]|} in
    check "who owns no Keeper" ("false", {|{"keepers":[]}|}) (result theirs "masc_my_keepers");
    let give_the_first_runtime =
      `Assoc [ "keeper_id", `String "keeper-1"; "runtime_id", `String "account-1.claude-sonnet-5-5" ]
    in
    check
      "and gives the first person's Keeper no Runtime"
      ("true", error_json "No Keeper of yours has this name.")
      (result theirs "masc_my_keeper_assign" ~arguments:give_the_first_runtime);
    (* A Keeper name is a person's own (issue #51073). *)
    check
      "they make a Keeper of the same name"
      ("false", {|{"keeper_id":"keeper-1","record":"made"}|})
      (result theirs "masc_my_keeper_create" ~arguments:(keeper "keeper-1"));
    check
      "which is theirs, with no Runtime"
      ("false", {|{"keepers":[{"keeper_id":"keeper-1","runtime_id":null}]}|})
      (result theirs "masc_my_keepers");
    check
      "a Runtime of the first person is not theirs to give it"
      ("true", error_json "No Runtime of yours has this id.")
      (result theirs "masc_my_keeper_assign" ~arguments:give_the_first_runtime);
    check "the first person's Keeper is as it was" ("false", listed) (result owner "masc_my_keepers");
    (* Plan S1b-1c: one turn of a Keeper. The tool stops where the route
       stops, before any client starts. *)
    let turn name message = `Assoc [ "keeper_id", `String name; "message", `String message ] in
    check
      "a PAT without the Keeper effect asks no Keeper"
      ("true", error_json (Masc.Auth_gate.reason_to_string Masc.Auth_gate.Pat_scope_lacks_own_keeper))
      (result reader "masc_my_keeper_turn" ~arguments:(turn "keeper-1" "hello"));
    check
      "a turn of a Keeper no one made"
      ("true", route_error ~code:"unknown_keeper" "No Keeper of yours has this name.")
      (result owner "masc_my_keeper_turn" ~arguments:(turn "keeper-2" "hello"));
    check
      "a turn of their Keeper of that name does not run on the first person's Runtime"
      ( "true"
      , route_error ~code:"keeper_has_no_runtime" "The Keeper has no Runtime. Give it one of yours first."
      )
      (result theirs "masc_my_keeper_turn" ~arguments:(turn "keeper-1" "hello"));
    check
      "a blank message, in the words of the route"
      ("true", route_error ~code:"message_blank" "The message is blank.")
      (result owner "masc_my_keeper_turn" ~arguments:(turn "keeper-1" " "));
    Alcotest.(check string)
      "a turn without a message is refused by the definition of the tool"
      "true"
      (fst (result owner "masc_my_keeper_turn" ~arguments:(keeper "keeper-1")));
    (* Plan S1b-3: a new conversation of a Keeper. The tool stops where the
       route stops. *)
    check
      "a PAT without the Keeper effect starts no conversation"
      ("true", error_json (Masc.Auth_gate.reason_to_string Masc.Auth_gate.Pat_scope_lacks_own_keeper))
      (result reader "masc_my_keeper_conversation_new" ~arguments:(keeper "keeper-1"));
    check
      "a conversation of a Keeper no one made"
      ("true", route_error ~code:"unknown_keeper" "No Keeper of yours has this name.")
      (result owner "masc_my_keeper_conversation_new" ~arguments:(keeper "keeper-2"));
    check
      "a conversation of their Keeper of that name does not start on the first person's account"
      ( "true"
      , route_error ~code:"keeper_has_no_runtime" "The Keeper has no Runtime. Give it one of yours first."
      )
      (result theirs "masc_my_keeper_conversation_new" ~arguments:(keeper "keeper-1"));
    Alcotest.(check string)
      "a conversation without a Keeper is refused by the definition of the tool"
      "true"
      (fst (result owner "masc_my_keeper_conversation_new"));
    (* The read of a conversation. A token reads it with the Keeper effect
       and [read_state] together. The endpoint of the tools asks [read_state]
       of every message, so the token that lacks it is tried on the route. *)
    check
      "a PAT without the Keeper effect reads no conversation"
      ("true", error_json (Masc.Auth_gate.reason_to_string Masc.Auth_gate.Pat_scope_lacks_own_keeper))
      (result reader "masc_my_keeper_conversation" ~arguments:(keeper "keeper-1"));
    let keepers_only = pat admin ~csrf {|["manage_own_keeper"]|} in
    let by_route token path =
      (send (fresh_browser ()) router ~meth:"GET" ~path ~headers:[ "Authorization", "Bearer " ^ token ]).status
    in
    Alcotest.(check int)
      "a PAT that manages Keepers lists them on the route"
      200
      (by_route keepers_only Masc.Auth_preview_keeper.keepers_path);
    Alcotest.(check int)
      "and reads no conversation, as it reads no state"
      403
      (by_route keepers_only (Masc.Auth_preview_keeper.conversation_path ^ "?keeper_id=keeper-1"));
    Alcotest.(check int)
      "the PAT with both reads it on the route"
      200
      (by_route owner (Masc.Auth_preview_keeper.conversation_path ^ "?keeper_id=keeper-1"));
    (* A deletion is judged as a turn is: a token that reads state alone
       deletes nothing, and one that manages Keepers is told when no
       conversation of the person has the id. *)
    let delete_by_route token id =
      let reply =
        send
          (fresh_browser ())
          router
          ~meth:"DELETE"
          ~path:(Masc.Auth_preview_keeper.conversation_entry_prefix ^ id)
          ~headers:[ "Authorization", "Bearer " ^ token ]
      in
      reply.status, reply.body
    in
    Alcotest.(check int)
      "a PAT that reads state deletes no conversation"
      403
      (fst (delete_by_route reader "conversation-1"));
    Alcotest.(check (pair int string))
      "a PAT that manages Keepers is told no conversation of the person has the id"
      (404, route_error ~code:"unknown_conversation" "No conversation of yours has this id.")
      (delete_by_route owner "conversation-1");
    check
      "a Keeper with no turn yet has no conversation"
      ( "false"
      , {|{"keeper_id":"keeper-1","current_conversation_id":null,"conversations":[],"conversation_id":null,"turns":[]}|}
      )
      (result owner "masc_my_keeper_conversation" ~arguments:(keeper "keeper-1"));
    check
      "the conversation of a Keeper no one made"
      ("true", route_error ~code:"unknown_keeper" "No Keeper of yours has this name.")
      (result owner "masc_my_keeper_conversation" ~arguments:(keeper "keeper-2"));
    check
      "a conversation the Keeper does not have"
      ("true", route_error ~code:"unknown_conversation" "No conversation of this Keeper has this id.")
      (result
         owner
         "masc_my_keeper_conversation"
         ~arguments:(`Assoc [ "keeper_id", `String "keeper-1"; "conversation_id", `String "none" ]));
    check
      "an argument the definition of the tool does not have, before the route reads any"
      ( "true"
      , "Tool 'masc_my_keeper_conversation' received unsupported field(s): limit; accepted: keeper_id, \
         conversation_id" )
      (result
         owner
         "masc_my_keeper_conversation"
         ~arguments:(`Assoc [ "keeper_id", `String "keeper-1"; "limit", `String "1" ]));
    check
      "their Keeper of that name has no conversation of the first person's"
      ( "false"
      , {|{"keeper_id":"keeper-1","current_conversation_id":null,"conversations":[],"conversation_id":null,"turns":[]}|}
      )
      (result theirs "masc_my_keeper_conversation" ~arguments:(keeper "keeper-1")))
;;

(* Bytes another writer added to the log: the next commit finds the end moved
   and stops the log. From then on no route decides on the state the zone
   holds. A person who signed in before gets a 503 where they read or change
   anything of theirs, the answer names no path of the server, and the browser
   keeps its cookie for when the files are read again. *)
let a_stopped_zone_answers_no_person () =
  with_installation (fun t ->
    let router = Server_login_http.add_person_routes t.routes ~env:t.env ~base_path:t.base t.router in
    let admin = fresh_browser () in
    let back = sign_in t admin ~user_id:583231 ~fields:[ "invite", admin_token; "return_to", "/" ] in
    Alcotest.(check int) ("signed in: " ^ back.body) 200 back.status;
    Alcotest.(check string)
      "the Admin, while the zone can be trusted"
      "200 admin human by session"
      (whoami router admin ());
    let csrf = csrf_of t admin in
    let user_id = user_of t admin in
    Out_channel.with_open_gen
      [ Open_append; Open_binary ]
      0o600
      (Authz_log.path_of_base_path ~base_path:t.base)
      (fun channel -> Out_channel.output_string channel "{}\n");
    (match
       Authz_provider_account.link
         t.routes.R.zone
         ~user_id
         ~provider_account_id:(get_ok (Provider_account_id.of_string "account-1"))
     with
     | Ok () -> Alcotest.fail "the zone wrote over a log another writer moved"
     | Error error ->
       (* The route of the subscription connection gives this text to the
          person (Server_setup_account_login). *)
       Alcotest.(check bool)
         "the failure of the link names no path of the server"
         false
         (contains ~sub:(Filename.dirname t.base) (Authz_provider_account.error_to_string error)));
    let root = Filename.dirname t.base in
    let unavailable label (reply : reply) =
      Alcotest.(check int) (label ^ ": " ^ reply.body) 503 reply.status;
      Alcotest.(check bool) (label ^ " names no path of the server") false (contains ~sub:root reply.body)
    in
    List.iter
      (fun path -> unavailable path (send admin router ~meth:"GET" ~path))
      [ "/api/v1/auth/whoami"
      ; "/auth/session"
      ; Masc.Auth_preview.provider_accounts_path
      ; Masc.Auth_preview_keeper.keepers_path
      ];
    unavailable
      "who-am-I with no credential"
      (send (fresh_browser ()) router ~meth:"GET" ~path:"/api/v1/auth/whoami");
    unavailable
      "a Keeper"
      (send
         admin
         router
         ~meth:"POST"
         ~path:Masc.Auth_preview_keeper.keepers_path
         ~headers:(changing ~csrf () @ [ "Content-Type", "application/json" ])
         ~body:{|{"keeper_id":"sangsu"}|});
    unavailable
      "the sign-out"
      (send admin router ~meth:"POST" ~path:"/auth/logout" ~headers:(changing ~csrf ()));
    Alcotest.(check (list string))
      "the browser keeps the session"
      [ Q.session_cookie ]
      (List.map fst admin.cookies);
    unavailable "a new sign-in" (sign_in t (fresh_browser ()) ~user_id:583231))
;;

(* The request whose commit finds the end of the log moved is the one that
   stops the log. Its answer is one fixed sentence too, and names no path of
   the server: the reason is in the log of the server. *)
let the_request_that_meets_a_moved_log_names_no_path () =
  let signed_in_admin t =
    let admin = fresh_browser () in
    let back = sign_in t admin ~user_id:583231 ~fields:[ "invite", admin_token; "return_to", "/" ] in
    Alcotest.(check int) ("signed in: " ^ back.body) 200 back.status;
    let csrf = csrf_of t admin in
    Out_channel.with_open_gen
      [ Open_append; Open_binary ]
      0o600
      (Authz_log.path_of_base_path ~base_path:t.base)
      (fun channel -> Out_channel.output_string channel "{}\n");
    admin, csrf
  in
  let not_recorded label t (reply : reply) =
    Alcotest.(check int) (label ^ ": " ^ reply.body) 503 reply.status;
    Alcotest.(check (option string))
      (label ^ ": what the person is told")
      (Some "The server could not finish recording this. Try again later.")
      (match member "error" reply with
       | Some (`String text) -> Some text
       | Some _ | None -> None);
    Alcotest.(check bool)
      (label ^ " names no path of the server")
      false
      (contains ~sub:(Filename.dirname t.base) reply.body)
  in
  with_installation (fun t ->
    let admin, csrf = signed_in_admin t in
    not_recorded
      "the sign-out"
      t
      (send admin t.router ~meth:"POST" ~path:"/auth/logout" ~headers:(changing ~csrf ())));
  with_installation (fun t ->
    let admin, csrf = signed_in_admin t in
    not_recorded
      "an allowlist registration"
      t
      (register t admin ~csrf {|{"provider":"github","user_id":7}|}))
;;

let what_the_server_reads () =
  with_installation (fun t ->
    let check label expected (reply : reply) = Alcotest.(check int) (label ^ ": " ^ reply.body) expected reply.status in
    let b = fresh_browser () in
    check "a start from another origin" 403 (start t ~headers:[ "Origin", "https://evil.example" ] b []);
    check "a start with no origin" 403 (start t ~headers:[] b []);
    check "a start with two origins" 403 (start t ~headers:[ "Origin", same_origin; "Origin", same_origin ] b []);
    check "a field twice" 400 (start t b [ "return_to", "/"; "return_to", "/a" ]);
    check
      "a value with a bare comma"
      400
      (send b t.router ~meth:"POST" ~path:"/auth/github/start" ~headers:[ "Origin", same_origin ] ~body:"return_to=/a,b");
    check
      "empty sequences"
      303
      (send b t.router ~meth:"POST" ~path:"/auth/github/start" ~headers:[ "Origin", same_origin ] ~body:"&return_to=/&&");
    check
      "a field with no name"
      400
      (send b t.router ~meth:"POST" ~path:"/auth/github/start" ~headers:[ "Origin", same_origin ] ~body:"=");
    check
      "a body over the bound"
      413
      (send
         b
         t.router
         ~meth:"POST"
         ~path:"/auth/github/start"
         ~headers:[ "Origin", same_origin ]
         ~body:(String.make (Server_login_http.max_request_bytes + 1) 'a'));
    let back = send b t.router ~meth:"GET" ~path:"/auth/github/callback?state=s&code=c" in
    check "a callback with no transaction" 401 back;
    Alcotest.(check (list string)) "it clears the transaction cookie" [ Q.transaction_cookie ] (written_cookies back);
    let admin = fresh_browser () in
    check "the Admin joins" 200 (sign_in t admin ~fields:[ "invite", admin_token ] ~user_id:583231);
    let csrf = csrf_of t admin in
    check
      "a session read with a bearer"
      401
      (send admin t.router ~meth:"GET" ~path:"/auth/session" ~headers:[ "Authorization", "Bearer x" ]);
    (* A browser sends one session cookie, so these are written by hand. *)
    let one = Q.session_cookie ^ "=" ^ List.assoc Q.session_cookie admin.cookies in
    let in_one_field = [ "Cookie", one ^ "; " ^ one ] in
    let by_hand ~meth ~path headers = send (fresh_browser ()) t.router ~meth ~path ~headers in
    check "a session read with the cookie twice" 401 (by_hand ~meth:"GET" ~path:"/auth/session" in_one_field);
    check
      "a session read with the cookie in two fields"
      401
      (by_hand ~meth:"GET" ~path:"/auth/session" [ "Cookie", one; "Cookie", one ]);
    check
      "a sign-out with the cookie twice"
      401
      (by_hand ~meth:"POST" ~path:"/auth/logout" (in_one_field @ changing ~csrf ()));
    check
      "a start with the cookie twice"
      401
      (by_hand ~meth:"POST" ~path:"/auth/github/start" (in_one_field @ [ "Origin", same_origin ]));
    check "the session of the Admin still reads" 200 (send admin t.router ~meth:"GET" ~path:"/auth/session");
    check "a sign-out with no token" 403 (send admin t.router ~meth:"POST" ~path:"/auth/logout" ~headers:(changing ()));
    check
      "a sign-out with no origin"
      403
      (send admin t.router ~meth:"POST" ~path:"/auth/logout" ~headers:(changing ~origin:None ~csrf ()));
    Alcotest.(check (list string)) "the refusals keep the cookie" [ Q.session_cookie ] (List.map fst admin.cookies);
    check "an identity that is not JSON" 400 (register t admin ~csrf "provider=github&user_id=9");
    check
      "a removal at the collection"
      405
      (send admin t.router ~meth:"DELETE" ~path:"/api/v1/auth/allowlist" ~headers:(changing ~csrf ()));
    check
      "a removal of an id the allowlist never had"
      404
      (send admin t.router ~meth:"DELETE" ~path:"/api/v1/auth/allowlist/registration-9" ~headers:(changing ~csrf ())))
;;

let the_route_table () =
  with_installation (fun t ->
    let routes = Http.Router.routes t.router in
    Alcotest.(check (list string))
      "the paths"
      [ "/api/v1/auth/allowlist"
      ; "/api/v1/auth/allowlist/"
      ; "/api/v1/auth/invites"
      ; "/api/v1/auth/invites/"
      ; "/api/v1/auth/pats"
      ; "/api/v1/auth/pats"
      ; "/api/v1/auth/pats/"
      ; "/auth/github/callback"
      ; "/auth/github/start"
      ; "/auth/logout"
      ; "/auth/oidc/callback"
      ; "/auth/oidc/start"
      ; "/auth/session"
      ]
      (List.sort String.compare (List.map (fun route -> route.Http.Router.path) routes));
    List.iter
      (fun route ->
        Alcotest.(check bool)
          (route.Http.Router.path ^ " authenticates through the browser session")
          true
          (route.Http.Router.access = Masc.Route_access.Self_authenticated Masc.Route_access.Browser_session))
      routes)
;;

let the_query_credential () =
  List.iter
    (fun (meth, target, expected) ->
      Alcotest.(check bool)
        target
        expected
        (Server_auth.request_carries_query_credential (Httpun.Request.create meth target)))
    [ `GET, "/events/presence?token=x", true
    ; `GET, "/events/presence?token=", true
    ; `GET, "/mcp?sse_kind=observer&token=x", true
    ; `GET, "/mcp?token=x", false
    ; `GET, "/api/v1/ide/lsp?token=x", true
    ; `POST, "/api/v1/ide/lsp?token=x", false
    ; `GET, "/auth/session?token=x", false
    ; `GET, "/events/presence", false
    ]
;;

let () =
  Alcotest.run
    "server_login_http"
    [ ( "login"
      , [ Alcotest.test_case "a browser signs in, acts and signs out" `Quick a_browser_signs_in_acts_and_signs_out
        ; Alcotest.test_case "the preview follows a login" `Quick the_preview_follows_a_login
        ; Alcotest.test_case "a PAT acts until it is revoked" `Quick a_pat_acts_until_it_is_revoked
        ; Alcotest.test_case "a person calls MCP" `Quick a_person_calls_mcp
        ; Alcotest.test_case "a person keeps Keepers over MCP" `Quick a_person_keeps_keepers_over_mcp
        ; Alcotest.test_case "a stopped zone" `Quick a_stopped_zone_answers_no_person
        ; Alcotest.test_case
            "the request that meets a moved log"
            `Quick
            the_request_that_meets_a_moved_log_names_no_path
        ; Alcotest.test_case "what the server reads" `Quick what_the_server_reads
        ; Alcotest.test_case "the route table" `Quick the_route_table
        ; Alcotest.test_case "the query credential" `Quick the_query_credential
        ] )
    ]
;;
