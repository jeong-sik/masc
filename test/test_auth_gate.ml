(* The gate of a multi-account request, on real files: a fresh installation
   in a temporary directory, its first Admin, a Member, two PATs of the Admin,
   a Service credential and two browser sessions. Each row sends one request
   to one kind of route and reads who it acts as, or why it is refused.
   No network. *)

open Masc
open Authz_types
open Authz_records
module B = Authz_bootstrap
module E = Authz_invite_event
module Login = Authz_login
module Z = Authz_zone
module G = Auth_gate
module Q = Authz_browser_request
module Bs = Authz_browser_session
module T = Authz_credential_token

let start_ms = 1_700_000_000_000

let rec remove_tree path =
  match Unix.lstat path with
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()
  | { Unix.st_kind = Unix.S_DIR; _ } ->
    Array.iter (fun name -> remove_tree (Filename.concat path name)) (Sys.readdir path);
    Unix.rmdir path
  | { Unix.st_kind = Unix.S_REG | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO | Unix.S_SOCK; _ } ->
    Sys.remove path
;;

let get = function
  | Ok value -> value
  | Error _ -> Alcotest.fail "fixture value rejected"
;;

let now_ms () = start_ms

(* Ids from a list, then fresh ones. *)
let drawing values =
  let left = ref values in
  let fresh = ref 0 in
  fun () ->
    match !left with
    | value :: rest ->
      left := rest;
      value
    | [] ->
      incr fresh;
      Printf.sprintf "%032x" !fresh
;;

let commit zone author kind body =
  match Z.commit zone { Z.author; kind; body } with
  | Ok (_ : Z.committed) -> ()
  | Error error -> Alcotest.failf "record refused: %s" (Z.error_detail error)
;;

let invite zone author ~id ~token role =
  commit
    zone
    author
    Authz_record.Kind.Invite
    (get
       (E.to_body
          (E.Issued
             { invite_id = get (Invite_id.of_string id)
             ; token_digest = E.Token_digest.of_token token
             ; expires_at_ms = start_ms + 3_600_000
             ; role
             })))
;;

let join zone ~sub ~token =
  match
    Login.sign_in
      zone
      ~now_ms
      ~draw:(drawing [])
      ~identity:(get (Authz_external_identity.google ~sub))
      ~invite:(Some (E.Token_digest.of_token token))
  with
  | Ok (Login.Admitted { user_id; _ }) -> user_id
  | Ok (Login.Signed_in _) | Error _ -> Alcotest.failf "%s did not join" sub
;;

let session zone ~user_id ~id =
  match Bs.issue zone ~user_id ~draw:(drawing [ id ]) ~replaces:None with
  | Ok cookie -> Bs.Cookie.to_value cookie
  | Error error -> Alcotest.failf "no session: %s" (Bs.error_to_string error)
;;

let pat zone ~user_id ~id ~scope =
  match Authz_pat.issue zone ~user_id ~draw:(drawing [ id ]) ~scope ~expires_at_ms:None with
  | Ok token -> "Bearer " ^ T.Pat.to_string token
  | Error error -> Alcotest.failf "no PAT: %s" (Authz_pat.error_to_string error)
;;

type credentials =
  { admin_session : string
  ; member_session : string
  ; admin_pat : string
  ; read_only_pat : string
  ; service : string
  }

(* Runs [f] on the snapshot a decision rests on, taken after every credential
   is issued. *)
let with_credentials f =
  Eio_main.run (fun _env ->
    let root = Filename.temp_dir "auth-gate-" "" in
    Fun.protect
      ~finally:(fun () -> remove_tree root)
      (fun () ->
        let base = Filename.concat root "base" in
        Unix.mkdir base 0o700;
        let store = Filename.concat (Filename.concat root "store") "external.jsonl" in
        (match
           B.fresh_bootstrap
             { B.base_path = base
             ; config_dir = Some (Filename.concat root "config")
             ; external_store = store
             ; workspace_id = get (Workspace_id.of_string "workspace-1")
             ; now_ms
             }
         with
         | Ok (_ : B.completed) -> ()
         | Error error -> Alcotest.failf "bootstrap refused: %s" (B.error_to_string error));
        let log_path = Authz_log.path_of_base_path ~base_path:base in
        match Z.open_at_start ~now_ms ~log_path ~store_path:store with
        | Error error -> Alcotest.failf "zone not opened: %s" (Z.open_error_to_string error)
        | Ok zone ->
          let admin_token = String.make 64 'a' in
          let member_token = String.make 64 'b' in
          invite zone Author.Local_operator ~id:"invite-admin" ~token:admin_token E.Admin;
          let admin = join zone ~sub:"111" ~token:admin_token in
          invite
            zone
            (Author.Authenticated (Principal.Human admin))
            ~id:"invite-member"
            ~token:member_token
            E.Member;
          let member = join zone ~sub:"222" ~token:member_token in
          let read_only =
            { Authorization_scope.all with
              Authorization_scope.allowed_effects = Effect_scope.only (Effect.Set.singleton Effect.Read_state)
            }
          in
          let service =
            match
              Authz_service_credential.issue
                zone
                ~service_id:(get (Service_id.of_string "keeper-runner"))
                ~draw:(drawing [ "cred-1" ])
            with
            | Ok token -> "Bearer " ^ T.Service_credential.to_string token
            | Error error ->
              Alcotest.failf "no credential: %s" (Authz_service_credential.error_to_string error)
          in
          let credentials =
            { admin_session = session zone ~user_id:admin ~id:"session-admin"
            ; member_session = session zone ~user_id:member ~id:"session-member"
            ; admin_pat = pat zone ~user_id:admin ~id:"pat-all" ~scope:Authorization_scope.all
            ; read_only_pat = pat zone ~user_id:admin ~id:"pat-read" ~scope:read_only
            ; service
            }
          in
          match Z.read zone with
          | Ok trusted -> f trusted credentials
          | Error uncertain ->
            Alcotest.failf "the zone cannot be trusted: %s" (Z.uncertain_to_string uncertain)))
;;

type presented =
  | Nothing
  | Cookie of string
  | Bearer of string
  | Cookie_and_bearer of string * string

let request ?(method_ = Q.Safe) presented =
  let authorization, session_cookies =
    match presented with
    | Nothing -> [], []
    | Cookie value -> [], [ value ]
    | Bearer field -> [ field ], []
    | Cookie_and_bearer (value, field) -> [ field ], [ value ]
  in
  { G.credentials =
      { Authz_credential_presentation.authorization
      ; internal_token = []
      ; session_cookies
      ; query_credential = false
      }
  ; method_
  ; origin = Q.Same_origin
  ; csrf = None
  }
;;

let refused reason =
  (if G.is_unauthenticated reason then "401 " else "403 ") ^ G.reason_to_string reason
;;

let outcome trusted access request =
  match G.decide trusted ~now_ms:start_ms access request with
  | Ok G.Anonymous -> "anonymous"
  | Ok G.Judged_by_route -> "judged by its route"
  | Ok (G.Authenticated { G.role; binding; principal = _; pat_binding = _ }) ->
    Printf.sprintf
      "%s by %s"
      (Masc_domain.agent_role_to_string role)
      (match binding with
       | G.Session id -> Session_id.to_string id
       | G.Pat id -> Pat_id.to_string id
       | G.Service_credential id -> Service_credential_id.to_string id)
  | Error reason -> refused reason
;;

let add_task = Route_access.Tool { tool_name = "masc_add_task" }

let each_kind_of_route_judges_the_request () =
  with_credentials (fun trusted c ->
    let legacy = "Bearer " ^ String.make 64 'f' in
    (* The token of the MCP OAuth service, which no layer binds to a session
       yet (plan C5). *)
    let oauth_token = "Bearer mat_" ^ String.make 64 'f' in
    let rows =
      [ "public, nothing", Route_access.Always_public, request Nothing, "anonymous"
      ; ( "public, legacy bearer"
        , Route_access.Always_public
        , request (Bearer legacy)
        , refused G.Legacy_credential_forbidden )
      ; ( "open when strict, Admin session"
        , Route_access.Public_read Route_access.Open_when_strict
        , request (Cookie c.admin_session)
        , "admin by session-admin" )
      ; ( "credential when strict, nothing"
        , Route_access.Public_read Route_access.Credential_when_strict
        , request Nothing
        , refused G.Credential_required )
      ; "read, nothing", Route_access.Read_auth, request Nothing, refused G.Credential_required
      ; ( "read, Member session"
        , Route_access.Read_auth
        , request (Cookie c.member_session)
        , "worker by session-member" )
      ; "read, service", Route_access.Read_auth, request (Bearer c.service), "worker by cred-1"
      ; ( "read, read-only PAT"
        , Route_access.Read_auth
        , request (Bearer c.read_only_pat)
        , "admin by pat-read" )
      ; ( "read, session and PAT"
        , Route_access.Read_auth
        , request (Cookie_and_bearer (c.admin_session, c.admin_pat))
        , refused G.Several_credentials )
      ; ( "admin, Admin session"
        , Route_access.Permission Masc_domain.CanAdmin
        , request (Cookie c.admin_session)
        , "admin by session-admin" )
      ; ( "admin, Member session"
        , Route_access.Permission Masc_domain.CanAdmin
        , request (Cookie c.member_session)
        , refused (G.Permission_denied Masc_domain.CanAdmin) )
      ; ( "admin, PAT of the Admin"
        , Route_access.Permission Masc_domain.CanAdmin
        , request (Bearer c.admin_pat)
        , refused (G.Pat_admin_permission Masc_domain.CanAdmin) )
      ; "add task, PAT", add_task, request (Bearer c.admin_pat), "admin by pat-all"
      ; ( "add task, read-only PAT"
        , add_task
        , request (Bearer c.read_only_pat)
        , refused
            (G.Pat_scope_lacks { permission = Masc_domain.CanAddTask; effect_ = Effect.Use_tool }) )
      ; ( "add task, Member POST without CSRF"
        , add_task
        , request ~method_:Q.Unsafe (Cookie c.member_session)
        , refused (G.Session_refused Q.Csrf_missing) )
      ; ( "unregistered tool, Admin session"
        , Route_access.Tool { tool_name = "masc_no_such_tool" }
        , request (Cookie c.admin_session)
        , refused (G.Unregistered_tool "masc_no_such_tool") )
      ; ( "login route, nothing"
        , Route_access.Self_authenticated Route_access.Browser_session
        , request Nothing
        , "judged by its route" )
      ; ( "OAuth route, nothing"
        , Route_access.Self_authenticated Route_access.Oauth_protocol
        , request Nothing
        , refused (G.Not_served_in_multi_account Route_access.Oauth_protocol) )
      ; ( "read, MCP OAuth token"
        , Route_access.Read_auth
        , request (Bearer oauth_token)
        , refused G.Mcp_oauth_token_not_bound )
      ; ( "own provider, nothing"
        , Route_access.Manage_own_provider
        , request Nothing
        , refused G.Credential_required )
      ; ( "own provider, session and PAT"
        , Route_access.Manage_own_provider
        , request (Cookie_and_bearer (c.admin_session, c.admin_pat))
        , refused G.Several_credentials )
      ; ( "own provider, MCP OAuth token"
        , Route_access.Manage_own_provider
        , request (Bearer oauth_token)
        , refused G.Mcp_oauth_token_not_bound )
      ; ( "own provider, Member session"
        , Route_access.Manage_own_provider
        , request (Cookie c.member_session)
        , "worker by session-member" )
      ; ( "own provider, Admin session"
        , Route_access.Manage_own_provider
        , request (Cookie c.admin_session)
        , "admin by session-admin" )
      ; "own provider, PAT", Route_access.Manage_own_provider, request (Bearer c.admin_pat), "admin by pat-all"
      ; ( "own provider, read-only PAT"
        , Route_access.Manage_own_provider
        , request (Bearer c.read_only_pat)
        , refused G.Pat_scope_lacks_own_provider )
      ; ( "own provider, service"
        , Route_access.Manage_own_provider
        , request (Bearer c.service)
        , refused (G.Service_owns_no_provider (get (Service_id.of_string "keeper-runner"))) )
      ; ( "own keeper, nothing"
        , Route_access.Manage_own_keeper
        , request Nothing
        , refused G.Credential_required )
      ; ( "own keeper, session and PAT"
        , Route_access.Manage_own_keeper
        , request (Cookie_and_bearer (c.admin_session, c.admin_pat))
        , refused G.Several_credentials )
      ; ( "own keeper, MCP OAuth token"
        , Route_access.Manage_own_keeper
        , request (Bearer oauth_token)
        , refused G.Mcp_oauth_token_not_bound )
      ; ( "own keeper, Member session"
        , Route_access.Manage_own_keeper
        , request (Cookie c.member_session)
        , "worker by session-member" )
      ; "own keeper, PAT", Route_access.Manage_own_keeper, request (Bearer c.admin_pat), "admin by pat-all"
      ; ( "own keeper, read-only PAT"
        , Route_access.Manage_own_keeper
        , request (Bearer c.read_only_pat)
        , refused G.Pat_scope_lacks_own_keeper )
      ; ( "own keeper, service"
        , Route_access.Manage_own_keeper
        , request (Bearer c.service)
        , refused (G.Service_owns_no_keeper (get (Service_id.of_string "keeper-runner"))) )
      ]
    in
    List.iter
      (fun (label, access, request, expected) ->
        Alcotest.(check string) label expected (outcome trusted access request))
      rows)
;;

(* The who-am-I route of the localhost preview reads the same gate. *)
let the_preview_whoami_names_the_principal () =
  with_credentials (fun trusted c ->
    let answer presented =
      let { Login_routes.status; body; headers = _ } =
        Auth_preview.whoami trusted ~now_ms:start_ms (request presented)
      in
      let json = Yojson.Safe.from_string body in
      let field name = Yojson.Safe.Util.member name json in
      match status with
      | Login_routes.Ok_200 ->
        Printf.sprintf
          "200 %s %s by %s"
          (Yojson.Safe.Util.to_string (field "role"))
          (Yojson.Safe.Util.to_string (Yojson.Safe.Util.member "kind" (field "principal")))
          (Yojson.Safe.Util.to_string (Yojson.Safe.Util.member "kind" (field "binding")))
      | other ->
        Printf.sprintf
          "%d %s"
          (Login_routes.status_code other)
          (Yojson.Safe.Util.to_string (field "error"))
    in
    let legacy = "Bearer " ^ String.make 64 'f' in
    List.iter
      (fun (label, presented, expected) ->
        Alcotest.(check string) label expected (answer presented))
      [ "Admin session", Cookie c.admin_session, "200 admin human by session"
      ; "Member session", Cookie c.member_session, "200 worker human by session"
      ; "service", Bearer c.service, "200 worker service by service_credential"
      ; "nothing", Nothing, "401 " ^ G.reason_to_string G.Credential_required
      ; "legacy bearer", Bearer legacy, "401 " ^ G.reason_to_string G.Legacy_credential_forbidden
      ])
;;

let () =
  Alcotest.run
    "auth_gate"
    [ ( "decide"
      , [ Alcotest.test_case
            "each kind of route judges the request"
            `Quick
            each_kind_of_route_judges_the_request
        ; Alcotest.test_case
            "the preview whoami names the principal"
            `Quick
            the_preview_whoami_names_the_principal
        ] )
    ]
;;
