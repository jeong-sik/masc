(* The allowlist routes against the writer zone on real files: the first Admin
   joins through an invitation and holds a browser session, then registers and
   removes identities as a browser would. Each case bootstraps a fresh
   installation in a temporary directory. No network: the routes reach no
   provider. *)

open Authz_types
open Authz_records
module A = Login_allowlist_routes
module B = Authz_bootstrap
module Bs = Authz_browser_session
module E = Authz_invite_event
module Q = Authz_browser_request
module R = Login_routes
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
  ; admin : Bs.Cookie.t
  }

let fresh = ref 0

let draw () =
  incr fresh;
  Printf.sprintf "%064x" !fresh
;;

let google sub = get_ok (Authz_external_identity.google ~sub)
let github user_id = get_ok (Authz_external_identity.github ~user_id)

let sign_in zone ?invite identity =
  Authz_login.sign_in zone ~now_ms:(fun () -> start_ms) ~draw ~identity ~invite
;;

let session_for zone user_id =
  match Bs.issue zone ~user_id ~draw ~replaces:None with
  | Ok cookie -> cookie
  | Error error -> Alcotest.failf "no session: %s" (Bs.error_to_string error)
;;

let unreachable ~url ~headers:_ = Alcotest.failf "a request to %s" url

let start_instant =
  match Ptime.of_float_s (Float.of_int start_ms /. 1000.) with
  | Some instant -> instant
  | None -> Alcotest.fail "the clock left the range of Ptime"
;;

let with_installation f =
  Eio_main.run (fun _env ->
    let root = Filename.temp_dir "login-allowlist-routes-" "" in
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
           | Error error -> Alcotest.failf "invitation refused: %s" (Z.error_detail error));
          let admin =
            match sign_in zone ~invite:(E.Token_digest.of_token admin_token) (google "111") with
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
            ; now = (fun () -> start_instant)
            ; draw
            }
          in
          f { routes; zone; admin }))
;;

let request ?(origin = Q.Same_origin) ?(csrf = true) cookie =
  { Q.method_ = Q.Unsafe
  ; session_cookie = Option.map Bs.Cookie.to_value cookie
  ; bearer = false
  ; query_credential = false
  ; origin
  ; csrf = (if csrf then Option.map Bs.csrf_token cookie else None)
  }
;;

let code (answer : R.answer) = R.status_code answer.status

let member name (answer : R.answer) =
  match Yojson.Safe.from_string answer.body with
  | `Assoc fields -> List.assoc_opt name fields
  | _ -> Alcotest.failf "the answer %S is not a JSON object" answer.body
;;

let registered (answer : R.answer) =
  Alcotest.(check int) ("registered: " ^ answer.body) 200 (code answer);
  Alcotest.(check (list string)) "not cached" [ "no-store" ] (List.assoc_opt "cache-control" answer.headers |> Option.to_list);
  match member "registration_id" answer, member "previously_deleted" answer with
  | Some (`String id), Some (`Bool deleted) -> id, deleted
  | _ -> Alcotest.failf "no registration in %S" answer.body
;;

let joins zone identity =
  match sign_in zone identity with
  | Ok (Authz_login.Admitted { user_id; role; _ }) -> Some (user_id, role)
  | Ok (Authz_login.Signed_in _) -> Alcotest.fail "already a principal"
  | Error (_ : Authz_login.refusal) -> None
;;

let github_body user_id = Printf.sprintf {|{"provider":"github","user_id":%d}|} user_id
let google_body sub = Printf.sprintf {|{"provider":"google","sub":%S}|} sub

(* ---- the cases ---- *)

let an_admin_registers_and_removes () =
  with_installation (fun t ->
    let admin = Some t.admin in
    let id, deleted = registered (A.register t.routes (request admin) ~body:(github_body 583231)) in
    Alcotest.(check bool) "nobody had the identity" false deleted;
    (match joins t.zone (github 583231) with
     | Some ((_ : User_id.t), role) -> Alcotest.(check bool) "joins as a Member" true (role = E.Member)
     | None -> Alcotest.fail "the registered identity did not join");
    let other, (_ : bool) = registered (A.register t.routes (request admin) ~body:(google_body "222")) in
    Alcotest.(check bool) "a new id" false (String.equal id other);
    let removed = A.remove t.routes (request admin) ~registration_id:other in
    Alcotest.(check int) "removed" 204 (code removed);
    Alcotest.(check string) "with no body" "" removed.body;
    Alcotest.(check int) "removed again" 409 (code (A.remove t.routes (request admin) ~registration_id:other));
    Alcotest.(check int) "spent" 409 (code (A.remove t.routes (request admin) ~registration_id:id));
    Alcotest.(check bool) "the removed identity does not join" true (Option.is_none (joins t.zone (google "222"))))
;;

let a_member_does_not_write_the_allowlist () =
  with_installation (fun t ->
    let id, (_ : bool) = registered (A.register t.routes (request (Some t.admin)) ~body:(github_body 7)) in
    let member =
      match joins t.zone (github 7) with
      | Some (user_id, (_ : E.role)) -> session_for t.zone user_id
      | None -> Alcotest.fail "the Member did not join"
    in
    let answer = A.register t.routes (request (Some member)) ~body:(github_body 8) in
    Alcotest.(check int) "a Member registers" 403 (code answer);
    Alcotest.(check int) "a Member removes" 403 (code (A.remove t.routes (request (Some member)) ~registration_id:id)))
;;

let a_request_that_is_refused () =
  with_installation (fun t ->
    let admin = Some t.admin in
    let check label answer expected =
      Alcotest.(check int) label expected (code answer);
      match member "error" answer with
      | Some (`String (_ : string)) -> ()
      | _ -> Alcotest.failf "%s: no error in %S" label answer.R.body
    in
    check "no session" (A.register t.routes (request None) ~body:(github_body 1)) 401;
    check "no CSRF token" (A.register t.routes (request ~csrf:false admin) ~body:(github_body 1)) 403;
    check "another origin" (A.register t.routes (request ~origin:Q.Other_origin admin) ~body:(github_body 1)) 403;
    check "no origin" (A.remove t.routes (request ~origin:Q.No_origin admin) ~registration_id:"registration-1") 403;
    List.iter
      (fun (label, body) -> check label (A.register t.routes (request admin) ~body) 400)
      [ "not JSON", "{"
      ; "another provider", {|{"provider":"gitlab","id":1}|}
      ; "another member", {|{"provider":"github","user_id":1,"login":"someone"}|}
      ; "a user id that is not one", {|{"provider":"github","user_id":0}|}
      ; "an empty sub", {|{"provider":"google","sub":""}|}
      ];
    check "the Admin's own identity" (A.register t.routes (request admin) ~body:(google_body "111")) 409;
    let (_ : string * bool) = registered (A.register t.routes (request admin) ~body:(github_body 5)) in
    check "an identity with an open entry" (A.register t.routes (request admin) ~body:(github_body 5)) 409;
    check "an id the allowlist never had" (A.remove t.routes (request admin) ~registration_id:"registration-9") 404;
    check "a path segment" (A.remove t.routes (request admin) ~registration_id:"..") 400)
;;

let () =
  Alcotest.run
    "login_allowlist_routes"
    [ ( "allowlist"
      , [ Alcotest.test_case "an Admin registers and removes" `Quick an_admin_registers_and_removes
        ; Alcotest.test_case "a Member does not" `Quick a_member_does_not_write_the_allowlist
        ; Alcotest.test_case "refused" `Quick a_request_that_is_refused
        ] )
    ]
;;
