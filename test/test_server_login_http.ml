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
  }

let start_instant =
  match Ptime.of_float_s (Float.of_int start_ms /. 1000.) with
  | Some instant -> instant
  | None -> Alcotest.fail "the clock left the range of Ptime"
;;

let with_installation f =
  Eio_main.run (fun _env ->
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
           | Error error -> Alcotest.failf "invitation refused: %s" (Z.error_to_string error));
          let client =
            match Login_client.make ~client_id ~client_secret ~redirect_uri with
            | Ok client -> client
            | Error error -> Alcotest.fail (Login_client.error_to_string error)
          in
          let github = { grants = Hashtbl.create 4; tokens = Hashtbl.create 4; issued = ref 0 } in
          let routes =
            { R.zone
            ; transactions = Oidc_login_transaction.create ~capacity:4
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

let whoami router browser ?(headers = []) () =
  let reply = send browser router ~meth:"GET" ~path:"/api/v1/auth/whoami" ~headers in
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

(* The localhost preview (plan, preview scope P3) as a browser uses it: the
   pages, a GitHub login from the invitation, who-am-I, and the sign-out. *)
let the_preview_follows_a_login () =
  with_installation (fun t ->
    let router = Server_login_http.add_preview_routes t.routes ~base_path:t.base t.router in
    let admin = fresh_browser () in
    let home = send admin router ~meth:"GET" ~path:"/" in
    Alcotest.(check int) "the home page" 200 home.status;
    Alcotest.(check bool)
      "a form may go to GitHub"
      true
      (contains ~sub:"form-action 'self' https://github.com" (one "content-security-policy" home));
    (* A browser sends "Origin: null" with a form POST from a no-referrer page. *)
    Alcotest.(check string) "the form posts with its origin" "same-origin" (one "referrer-policy" home);
    let invitation = send admin router ~meth:"GET" ~path:"/accounts/invite" in
    Alcotest.(check int) "the invitation page" 200 invitation.status;
    Alcotest.(check bool)
      "it starts a GitHub login"
      true
      (contains ~sub:{|action="/auth/github/start"|} invitation.body);
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
     | Error error -> Alcotest.fail (Authz_runtime.error_to_string error));
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
    let out = send admin router ~meth:"POST" ~path:"/auth/logout" ~headers:(changing ~csrf ()) in
    Alcotest.(check int) ("signed out: " ^ out.body) 204 out.status;
    Alcotest.(check string)
      "nobody again"
      ("401 " ^ Masc.Auth_gate.reason_to_string Masc.Auth_gate.Credential_required)
      (whoami router admin ());
    Alcotest.(check int)
      "and no subscriptions"
      401
      (send admin router ~meth:"GET" ~path:Masc.Auth_preview.provider_accounts_path).status)
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
        ; Alcotest.test_case "what the server reads" `Quick what_the_server_reads
        ; Alcotest.test_case "the route table" `Quick the_route_table
        ; Alcotest.test_case "the query credential" `Quick the_query_credential
        ] )
    ]
;;
