(* The PAT routes against the writer zone on real files: the first Admin joins
   through an invitation and holds a browser session, a Member joins through
   the allowlist, and each issues, lists and revokes PATs as a browser would.
   Each case bootstraps a fresh installation in a temporary directory. No
   network: the routes reach no provider. *)

open Authz_types
open Authz_records
module B = Authz_bootstrap
module Bs = Authz_browser_session
module E = Authz_invite_event
module P = Login_pat_routes
module Q = Authz_browser_request
module R = Login_routes
module Token = Authz_credential_token
module Z = Authz_zone

let start_ms = 1_700_000_000_000
let admin_token = String.make 64 'a'

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

type installation =
  { routes : R.t
  ; zone : Z.t
  ; clock : int ref  (** Milliseconds since the epoch, read by the routes. *)
  ; admin : Bs.Cookie.t
  ; member : Bs.Cookie.t
  }

let fresh = ref 0

let draw () =
  incr fresh;
  Printf.sprintf "%064x" !fresh
;;

let sign_in zone ?invite identity =
  Authz_login.sign_in zone ~now_ms:(fun () -> start_ms) ~draw ~identity ~invite
;;

let session_for zone user_id =
  match Bs.issue zone ~user_id ~draw ~replaces:None with
  | Ok cookie -> cookie
  | Error error -> Alcotest.failf "no session: %s" (Bs.error_to_string error)
;;

let unreachable ~url ~headers:_ = Alcotest.failf "a request to %s" url

let instant_of_ms ms =
  match Ptime.of_float_s (Float.of_int ms /. 1000.) with
  | Some instant -> instant
  | None -> Alcotest.fail "the clock left the range of Ptime"
;;

let request ?(method_ = Q.Unsafe) ?(origin = Q.Same_origin) ?(csrf = true) cookie =
  { Q.method_
  ; session_cookie = Option.map Bs.Cookie.to_value cookie
  ; bearer = false
  ; query_credential = false
  ; origin
  ; csrf = (if csrf then Option.map Bs.csrf_token cookie else None)
  }
;;

let read cookie = request ~method_:Q.Safe ~csrf:false cookie

let with_installation f =
  Eio_main.run (fun _env ->
    let root = Filename.temp_dir "login-pat-routes-" "" in
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
                           ; expires_at_ms = start_ms + 3_600_000
                           ; role = E.Admin
                           }))
               }
           with
           | Ok (_ : Z.committed) -> ()
           | Error error -> Alcotest.failf "invitation refused: %s" (Z.error_to_string error));
          let admin =
            match
              sign_in
                zone
                ~invite:(E.Token_digest.of_token admin_token)
                (get_ok (Authz_external_identity.google ~sub:"111"))
            with
            | Ok (Authz_login.Admitted { user_id; _ }) -> session_for zone user_id
            | Ok (Authz_login.Signed_in _) | Error _ -> Alcotest.fail "the first Admin did not join"
          in
          let routes =
            { R.zone
            ; transactions = Oidc_login_transaction.create ~capacity:1
            ; google = None
            ; github = None
            ; get = unreachable
            ; post = (fun ~url ~headers ~body:_ -> unreachable ~url ~headers)
            ; now = (fun () -> instant_of_ms !clock)
            ; draw
            }
          in
          let registered =
            Login_allowlist_routes.register
              routes
              (request (Some admin))
              ~body:{|{"provider":"github","user_id":7}|}
          in
          if R.status_code registered.R.status <> 200
          then Alcotest.failf "the Member was not registered: %s" registered.R.body;
          let member =
            match sign_in zone (get_ok (Authz_external_identity.github ~user_id:7)) with
            | Ok (Authz_login.Admitted { user_id; _ }) -> session_for zone user_id
            | Ok (Authz_login.Signed_in _) | Error _ -> Alcotest.fail "the Member did not join"
          in
          f { routes; zone; clock; admin; member }))
;;

let code (answer : R.answer) = R.status_code answer.status

let members (answer : R.answer) =
  match Yojson.Safe.from_string answer.body with
  | `Assoc fields -> fields
  | _ -> Alcotest.failf "the answer %S is not a JSON object" answer.body
;;

let scope_body = {|{"runtimes":"all","channels":["direct"],"allowed_effects":["invoke_model","read_state"]}|}

let issue_body ?(scope = scope_body) expires_at_ms =
  Printf.sprintf {|{"scope":%s,"expires_at_ms":%s}|} scope expires_at_ms
;;

(* The id and the token of an issued PAT. *)
let issued (answer : R.answer) =
  Alcotest.(check int) ("issued: " ^ answer.body) 200 (code answer);
  Alcotest.(check (option string))
    "not cached"
    (Some "no-store")
    (List.assoc_opt "cache-control" answer.headers);
  match members answer with
  | [ ("pat_id", `String pat_id); ("token", `String text) ] ->
    (match Token.read text with
     | Token.Pat_token token ->
       Alcotest.(check string) "the token names its PAT" pat_id (Pat_id.to_string (Token.Pat.id token));
       pat_id, token
     | Token.Service_credential_token _
     | Token.Pat_malformed
     | Token.Service_credential_malformed
     | Token.No_prefix -> Alcotest.failf "the token of %s is not a PAT token" pat_id)
  | _ -> Alcotest.failf "no PAT in %S" answer.body
;;

(* What the request gate reads: the token against the state now. *)
let acts t token =
  match Authz_pat.authenticate (Z.snapshot t.zone).Z.state ~now_ms:!(t.clock) token with
  | Ok { Authz_pat.pat_scope = { Pat_scope.scope; _ }; _ } -> Ok scope
  | Error refusal -> Error (Authz_pat.refusal_to_string refusal)
;;

(* Each listed PAT as (id, status, expiry), after the members are checked. *)
let listed (answer : R.answer) =
  Alcotest.(check int) ("listed: " ^ answer.body) 200 (code answer);
  match members answer with
  | [ ("pats", `List pats) ] ->
    List.map
      (function
        | `Assoc
            [ ("pat_id", `String pat_id)
            ; ("scope", scope)
            ; ("expires_at_ms", expiry)
            ; ("issued_at_ms", `Int issued_at_ms)
            ; ("status", `String status)
            ] ->
          Alcotest.(check string)
            "the scope as it was issued"
            (Yojson.Safe.to_string (Yojson.Safe.from_string scope_body))
            (Yojson.Safe.to_string scope);
          Alcotest.(check int) "issued now" start_ms issued_at_ms;
          pat_id, status, Yojson.Safe.to_string expiry
        | entry -> Alcotest.failf "a listed PAT %s" (Yojson.Safe.to_string entry))
      pats
  | _ -> Alcotest.failf "no list in %S" answer.body
;;

let entry = Alcotest.(triple string string string)

(* ---- the cases ---- *)

let a_person_issues_lists_and_revokes_their_pats () =
  with_installation (fun t ->
    let admin = Some t.admin in
    let expiring, expiring_token =
      issued (P.issue t.routes (request admin) ~body:(issue_body (string_of_int (start_ms + 60_000))))
    in
    let lasting, lasting_token = issued (P.issue t.routes (request admin) ~body:(issue_body "null")) in
    (match acts t expiring_token with
     | Ok scope ->
       Alcotest.(check bool)
         "the token acts within the scope it was issued with"
         true
         (Authorization_scope.equal
            scope
            { Authorization_scope.runtimes = Runtime_scope.all
            ; channels = Channel_scope.only (Channel.Set.singleton Channel.Direct)
            ; allowed_effects =
                Effect_scope.only (Effect.Set.of_list [ Effect.Invoke_model; Effect.Read_state ])
            })
     | Error refusal -> Alcotest.failf "the issued token does not act: %s" refusal);
    let expiry_of_expiring = string_of_int (start_ms + 60_000) in
    Alcotest.(check (list entry))
      "both open, in the order of the ids"
      (List.sort compare [ expiring, "open", expiry_of_expiring; lasting, "open", "null" ])
      (listed (P.list t.routes (read admin)));
    let revoked = P.revoke t.routes (request admin) ~pat_id:expiring in
    Alcotest.(check int) "revoked" 204 (code revoked);
    Alcotest.(check string) "with no body" "" revoked.R.body;
    Alcotest.(check (result reject string))
      "the revoked token"
      (Error (Authz_pat.refusal_to_string Authz_pat.Ended))
      (Result.map ignore (acts t expiring_token));
    Alcotest.(check bool) "the other token acts" true (Result.is_ok (acts t lasting_token));
    Alcotest.(check int)
      "revoked again"
      409
      (code (P.revoke t.routes (request admin) ~pat_id:expiring));
    let expiry_of_third = string_of_int (start_ms + 60_001) in
    let third, (_ : Token.Pat.t) =
      issued (P.issue t.routes (request admin) ~body:(issue_body expiry_of_third))
    in
    t.clock := start_ms + 60_000;
    Alcotest.(check (list entry))
      "the revoked one stays revoked when its expiry comes"
      (List.sort
         compare
         [ expiring, "revoked", expiry_of_expiring
         ; lasting, "open", "null"
         ; third, "open", expiry_of_third
         ])
      (listed (P.list t.routes (read admin)));
    t.clock := start_ms + 60_001;
    Alcotest.(check (list entry))
      "an open PAT whose expiry came is expired"
      (List.sort
         compare
         [ expiring, "revoked", expiry_of_expiring
         ; lasting, "open", "null"
         ; third, "expired", expiry_of_third
         ])
      (listed (P.list t.routes (read admin)));
    Alcotest.(check int)
      "an expired PAT is revoked too"
      204
      (code (P.revoke t.routes (request admin) ~pat_id:third));
    Alcotest.(check (list entry))
      "and says revoked from then on"
      (List.sort
         compare
         [ expiring, "revoked", expiry_of_expiring
         ; lasting, "open", "null"
         ; third, "revoked", expiry_of_third
         ])
      (listed (P.list t.routes (read admin))))
;;

let a_person_sees_and_revokes_only_their_own () =
  with_installation (fun t ->
    let admins, (_ : Token.Pat.t) =
      issued (P.issue t.routes (request (Some t.admin)) ~body:(issue_body "null"))
    in
    let member = Some t.member in
    Alcotest.(check (list entry)) "the Member lists none" [] (listed (P.list t.routes (read member)));
    let no_such_pat label pat_id =
      let answer = P.revoke t.routes (request member) ~pat_id in
      Alcotest.(check int) label 404 (code answer);
      Alcotest.(check (list (pair string string)))
        (label ^ ": the same text as for an id that names nothing")
        [ "error", "this person has no PAT " ^ pat_id ]
        (List.map
           (fun (name, value) ->
             ( name
             , match value with
               | `String text -> text
               | other -> Yojson.Safe.to_string other ))
           (members answer))
    in
    no_such_pat "the Admin's open PAT" admins;
    no_such_pat "an id that names nothing" "pat-never-issued";
    Alcotest.(check int)
      "the Admin revokes it"
      204
      (code (P.revoke t.routes (request (Some t.admin)) ~pat_id:admins));
    no_such_pat "the Admin's revoked PAT" admins;
    let (_ : string * Token.Pat.t) = issued (P.issue t.routes (request member) ~body:(issue_body "null")) in
    Alcotest.(check int)
      "the Admin lists only their own"
      1
      (List.length (listed (P.list t.routes (read (Some t.admin))))))
;;

let a_request_that_is_refused () =
  with_installation (fun t ->
    let admin = Some t.admin in
    let check label answer expected =
      Alcotest.(check int) label expected (code answer);
      match List.assoc_opt "error" (members answer) with
      | Some (`String (_ : string)) -> ()
      | _ -> Alcotest.failf "%s: no error in %S" label answer.R.body
    in
    check "an issue with no session" (P.issue t.routes (request None) ~body:(issue_body "null")) 401;
    check "a list with no session" (P.list t.routes (read None)) 401;
    check "a revoke with no session" (P.revoke t.routes (request None) ~pat_id:"pat-1") 401;
    check "no CSRF token" (P.issue t.routes (request ~csrf:false admin) ~body:(issue_body "null")) 403;
    check
      "another origin"
      (P.issue t.routes (request ~origin:Q.Other_origin admin) ~body:(issue_body "null"))
      403;
    check "a revoke with no origin" (P.revoke t.routes (request ~origin:Q.No_origin admin) ~pat_id:"pat-1") 403;
    List.iter
      (fun (label, body) -> check label (P.issue t.routes (request admin) ~body) 400)
      [ "not JSON", "{"
      ; "no scope", {|{"expires_at_ms":null}|}
      ; "no expiry", Printf.sprintf {|{"scope":%s}|} scope_body
      ; "the members in another order", Printf.sprintf {|{"expires_at_ms":null,"scope":%s}|} scope_body
      ; "another member", Printf.sprintf {|{"scope":%s,"expires_at_ms":null,"name":"ci"}|} scope_body
      ; ( "a channel that names nothing"
        , issue_body ~scope:{|{"runtimes":"all","channels":["telepathy"],"allowed_effects":[]}|} "null" )
      ; ( "effects out of order"
        , issue_body
            ~scope:{|{"runtimes":"all","channels":["direct"],"allowed_effects":["read_state","invoke_model"]}|}
            "null" )
      ; "an expiry that is now", issue_body (string_of_int start_ms)
      ; "an expiry in the past", issue_body (string_of_int (start_ms - 1))
      ; "an expiry that is text", issue_body {|"tomorrow"|}
      ; "an expiry with a fraction", issue_body "1700000060000.5"
      ];
    check "a path segment" (P.revoke t.routes (request admin) ~pat_id:"..") 400;
    Alcotest.(check (list entry))
      "a refused issue wrote nothing"
      []
      (listed (P.list t.routes (read admin))))
;;

let () =
  Alcotest.run
    "login_pat_routes"
    [ ( "pats"
      , [ Alcotest.test_case
            "a person issues, lists and revokes"
            `Quick
            a_person_issues_lists_and_revokes_their_pats
        ; Alcotest.test_case
            "only their own"
            `Quick
            a_person_sees_and_revokes_only_their_own
        ; Alcotest.test_case "refused" `Quick a_request_that_is_refused
        ] )
    ]
;;
