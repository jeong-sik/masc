(* The invitation routes against the writer zone on real files: the first
   Admin joins through the invitation of the operator and holds a browser
   session, then issues and revokes invitations as a browser would. Each case
   bootstraps a fresh installation in a temporary directory. No network: the
   routes reach no provider. *)

open Authz_types
open Authz_records
module B = Authz_bootstrap
module Bs = Authz_browser_session
module E = Authz_invite_event
module I = Login_invite_routes
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
  ; admin_id : User_id.t
  ; log_path : string
  ; store_path : string
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
    let root = Filename.temp_dir "login-invite-routes-" "" in
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
          let admin_id =
            match sign_in zone ~invite:(E.Token_digest.of_token admin_token) (google "111") with
            | Ok (Authz_login.Admitted { user_id; _ }) -> user_id
            | Ok (Authz_login.Signed_in _) | Error _ -> Alcotest.fail "the first Admin did not join"
          in
          let admin = session_for zone admin_id in
          let routes =
            { R.zone
            ; transactions = Oidc_login_transaction.create ()
            ; google = None
            ; github = None
            ; get = unreachable
            ; post = (fun ~url ~headers ~body:_ -> unreachable ~url ~headers)
            ; now = (fun () -> start_instant)
            ; draw
            }
          in
          f { routes; zone; admin; admin_id; log_path; store_path = store }))
;;

let request ?(origin = Q.Same_origin) ?(csrf = true) cookie =
  { Q.method_ = Q.Unsafe
  ; session_cookie =
      (match cookie with
       | None -> Q.No_cookie
       | Some cookie -> Q.One_cookie (Bs.Cookie.to_value cookie))
  ; bearer = false
  ; query_credential = false
  ; origin
  ; csrf = (if csrf then Option.map Bs.csrf_token cookie else None)
  }
;;

(* A read as a browser sends it: a GET with no CSRF token. *)
let read ?(origin = Q.Same_origin) cookie = { (request ~origin ~csrf:false cookie) with Q.method_ = Q.Safe }

let code (answer : R.answer) = R.status_code answer.status

let member name (answer : R.answer) =
  match Yojson.Safe.from_string answer.body with
  | `Assoc fields -> List.assoc_opt name fields
  | _ -> Alcotest.failf "the answer %S is not a JSON object" answer.body
;;

let link_prefix = "/accounts/invite#"

type issued =
  { invite_id : string
  ; token : string
  ; expires_at_ms : int
  }

(* The invitation of a 200 answer, with the token cut from its link. *)
let issued ~role (answer : R.answer) =
  Alcotest.(check int) ("issued: " ^ string_of_int (code answer)) 200 (code answer);
  Alcotest.(check (list string))
    "not cached"
    [ "no-store" ]
    (List.assoc_opt "cache-control" answer.headers |> Option.to_list);
  match
    member "invite_id" answer, member "role" answer, member "expires_at_ms" answer, member "link" answer
  with
  | Some (`String invite_id), Some (`String label), Some (`Int expires_at_ms), Some (`String link) ->
    Alcotest.(check string) "the role asked for" role label;
    Alcotest.(check bool) "a link of the invitation page" true (String.starts_with ~prefix:link_prefix link);
    let token =
      String.sub link (String.length link_prefix) (String.length link - String.length link_prefix)
    in
    { invite_id; token; expires_at_ms }
  | _ -> Alcotest.fail "the answer holds no invitation"
;;

let joins zone ~token identity =
  match sign_in zone ~invite:(E.Token_digest.of_token token) identity with
  | Ok (Authz_login.Admitted { user_id; role; _ }) -> Some (user_id, role)
  | Ok (Authz_login.Signed_in _) -> Alcotest.fail "already a principal"
  | Error (_ : Authz_login.refusal) -> None
;;

let body role = Printf.sprintf {|{"role":%S}|} role

let contains ~part text =
  let part_length = String.length part in
  let rec from index =
    index + part_length <= String.length text
    && (String.equal (String.sub text index part_length) part || from (index + 1))
  in
  from 0
;;

(* The invitations of a 200 list, each by its id. *)
let listed (answer : R.answer) =
  Alcotest.(check int) ("listed: " ^ answer.body) 200 (code answer);
  Alcotest.(check (list string))
    "not cached"
    [ "no-store" ]
    (List.assoc_opt "cache-control" answer.headers |> Option.to_list);
  match member "invites" answer with
  | Some (`List invites) ->
    List.map
      (function
        | `Assoc fields ->
          (match List.assoc_opt "invite_id" fields with
           | Some (`String id) -> id, fields
           | _ -> Alcotest.failf "an invitation with no id in %S" answer.body)
        | _ -> Alcotest.failf "an invitation that is not an object in %S" answer.body)
      invites
  | _ -> Alcotest.failf "no invites in %S" answer.body
;;

(* Values are compared as JSON, so a member of another type fails. *)
let json = Alcotest.testable Yojson.Safe.pp Yojson.Safe.equal
let field name fields = List.assoc_opt name fields
let text value = Some (`String value)

let status_of id invitations =
  match List.assoc_opt id invitations with
  | None -> Alcotest.failf "%s is not listed" id
  | Some fields ->
    (match field "status" fields with
     | Some (`String status) -> status
     | _ -> Alcotest.failf "%s has no status" id)
;;

let at_ms ms =
  match Ptime.of_float_s (Float.of_int ms /. 1000.) with
  | Some instant -> instant
  | None -> Alcotest.fail "the clock left the range of Ptime"
;;

let skip_for_superuser () = if Unix.geteuid () = 0 then Alcotest.skip ()

(* ---- the cases ---- *)

let an_admin_issues_and_revokes () =
  with_installation (fun t ->
    let admin = Some t.admin in
    let first = issued ~role:"member" (I.issue t.routes (request admin) ~body:(body "member")) in
    Alcotest.(check int)
      "it expires a lifetime from now"
      (start_ms + Authz_invite.lifetime_ms)
      first.expires_at_ms;
    Alcotest.(check bool)
      "the token is one the start of a login reads"
      true
      (Option.is_some (Oidc_login_transaction.Invite_token.of_form first.token));
    Alcotest.(check bool)
      "the log does not hold the token"
      false
      (contains ~part:first.token (In_channel.with_open_bin t.log_path In_channel.input_all));
    (match joins t.zone ~token:first.token (github 583231) with
     | Some ((_ : User_id.t), role) -> Alcotest.(check bool) "joins as a Member" true (role = E.Member)
     | None -> Alcotest.fail "the holder of the link did not join");
    let second_admin = issued ~role:"admin" (I.issue t.routes (request admin) ~body:(body "admin")) in
    Alcotest.(check bool) "a new id" false (String.equal first.invite_id second_admin.invite_id);
    Alcotest.(check bool) "a new token" false (String.equal first.token second_admin.token);
    (match joins t.zone ~token:second_admin.token (github 7) with
     | Some ((_ : User_id.t), role) -> Alcotest.(check bool) "joins as an Admin" true (role = E.Admin)
     | None -> Alcotest.fail "the holder of the Admin link did not join");
    let lost = issued ~role:"member" (I.issue t.routes (request admin) ~body:(body "member")) in
    let revoked = I.revoke t.routes (request admin) ~invite_id:lost.invite_id in
    Alcotest.(check int) "revoked" 204 (code revoked);
    Alcotest.(check string) "with no body" "" revoked.body;
    Alcotest.(check bool)
      "the revoked link lets no one in"
      true
      (Option.is_none (joins t.zone ~token:lost.token (github 8)));
    Alcotest.(check int)
      "revoked again"
      409
      (code (I.revoke t.routes (request admin) ~invite_id:lost.invite_id));
    Alcotest.(check int)
      "one a person joined through"
      409
      (code (I.revoke t.routes (request admin) ~invite_id:first.invite_id)))
;;

let a_member_does_not_invite () =
  with_installation (fun t ->
    let open_one = issued ~role:"member" (I.issue t.routes (request (Some t.admin)) ~body:(body "member")) in
    let spent = issued ~role:"member" (I.issue t.routes (request (Some t.admin)) ~body:(body "member")) in
    let member =
      match joins t.zone ~token:spent.token (github 7) with
      | Some (user_id, (_ : E.role)) -> session_for t.zone user_id
      | None -> Alcotest.fail "the Member did not join"
    in
    Alcotest.(check int)
      "a Member issues"
      403
      (code (I.issue t.routes (request (Some member)) ~body:(body "member")));
    Alcotest.(check int)
      "a Member issues an Admin invitation"
      403
      (code (I.issue t.routes (request (Some member)) ~body:(body "admin")));
    Alcotest.(check int)
      "a Member revokes"
      403
      (code (I.revoke t.routes (request (Some member)) ~invite_id:open_one.invite_id));
    Alcotest.(check bool)
      "the invitation the Member did not revoke still lets a person in"
      true
      (Option.is_some (joins t.zone ~token:open_one.token (github 8))))
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
    check "no session" (I.issue t.routes (request None) ~body:(body "member")) 401;
    check "no CSRF token" (I.issue t.routes (request ~csrf:false admin) ~body:(body "member")) 403;
    check "another origin" (I.issue t.routes (request ~origin:Q.Other_origin admin) ~body:(body "member")) 403;
    check "no origin" (I.revoke t.routes (request ~origin:Q.No_origin admin) ~invite_id:"invite-1") 403;
    List.iter
      (fun (label, body) -> check label (I.issue t.routes (request admin) ~body) 400)
      [ "not JSON", "{"
      ; "no role", "{}"
      ; "a role the log does not have", body "owner"
      ; "a role that is not text", {|{"role":1}|}
      ; "another member", {|{"role":"member","expires_at_ms":1}|}
      ; "the role twice", {|{"role":"member","role":"admin"}|}
      ];
    check "an id no invitation had" (I.revoke t.routes (request admin) ~invite_id:"invite-9") 404;
    check "a path segment" (I.revoke t.routes (request admin) ~invite_id:"..") 400)
;;

(* The ids are drawn counting down, so the order of the ids is the reverse of
   the order the invitations were issued in. *)
let an_admin_lists_every_invitation () =
  with_installation (fun t ->
    let countdown = ref 0x1000 in
    let routes =
      { t.routes with
        R.draw =
          (fun () ->
            decr countdown;
            Printf.sprintf "%064x" !countdown)
      }
    in
    let t = { t with routes } in
    let admin = Some t.admin in
    let issue role = issued ~role (I.issue t.routes (request admin) ~body:(body role)) in
    let spent = issue "member" in
    let joined =
      match joins t.zone ~token:spent.token (github 583231) with
      | Some (user_id, (_ : E.role)) -> user_id
      | None -> Alcotest.fail "the holder of the link did not join"
    in
    let revoked = issue "member" in
    Alcotest.(check int) "revoked" 204 (code (I.revoke t.routes (request admin) ~invite_id:revoked.invite_id));
    let open_admin = issue "admin" in
    let invitations = listed (I.list t.routes (read admin)) in
    let by_admin = Some (`Assoc [ "kind", `String "admin"; "user_id", `String (User_id.to_string t.admin_id) ]) in
    let expect label id ~role ~issuer ~status ~user_id =
      match List.assoc_opt id invitations with
      | None -> Alcotest.failf "%s: not listed" label
      | Some fields ->
        Alcotest.(check (option json)) (label ^ ": role") (text role) (field "role" fields);
        Alcotest.(check (option json)) (label ^ ": issuer") issuer (field "issuer" fields);
        Alcotest.(check (option json)) (label ^ ": status") (text status) (field "status" fields);
        Alcotest.(check (option json))
          (label ^ ": the principal it made")
          (Option.bind user_id text)
          (field "user_id" fields);
        Alcotest.(check (list string))
          (label ^ ": the members, and no token")
          ([ "invite_id"; "role"; "issuer"; "expires_at_ms"; "status" ]
           @ if Option.is_some user_id then [ "user_id" ] else [])
          (List.map fst fields)
    in
    Alcotest.(check (list string))
      "in the order of the ids, the first Admin's last"
      [ open_admin.invite_id; revoked.invite_id; spent.invite_id; "invite-admin" ]
      (List.map fst invitations);
    expect
      "the first Admin's"
      "invite-admin"
      ~role:"admin"
      ~issuer:(Some (`Assoc [ "kind", `String "local_operator" ]))
      ~status:"consumed"
      ~user_id:(Some (User_id.to_string t.admin_id));
    expect
      "spent"
      spent.invite_id
      ~role:"member"
      ~issuer:by_admin
      ~status:"consumed"
      ~user_id:(Some (User_id.to_string joined));
    expect "revoked" revoked.invite_id ~role:"member" ~issuer:by_admin ~status:"revoked" ~user_id:None;
    expect "open" open_admin.invite_id ~role:"admin" ~issuer:by_admin ~status:"open" ~user_id:None;
    Alcotest.(check (option json))
      "the expiry it was issued with"
      (Some (`Int open_admin.expires_at_ms))
      (Option.bind (List.assoc_opt open_admin.invite_id invitations) (field "expires_at_ms"));
    let at ms = listed (I.list { t.routes with R.now = (fun () -> at_ms ms) } (read admin)) in
    Alcotest.(check string)
      "a millisecond before it expires"
      "open"
      (status_of open_admin.invite_id (at (open_admin.expires_at_ms - 1)));
    Alcotest.(check string)
      "when it expires"
      "expired"
      (status_of open_admin.invite_id (at open_admin.expires_at_ms));
    Alcotest.(check string)
      "a spent one does not expire"
      "consumed"
      (status_of spent.invite_id (at open_admin.expires_at_ms));
    Alcotest.(check string)
      "nor a revoked one"
      "revoked"
      (status_of revoked.invite_id (at open_admin.expires_at_ms)))
;;

(* The clock of the server is set back after a record. An admission is
   refused before the latest time of the log, so an invitation that has
   expired by that time lets no one in, and is listed as expired though the
   clock is before its expiry. *)
let a_clock_set_back_does_not_reopen_an_invitation () =
  with_installation (fun t ->
    let admin = Some t.admin in
    let lost = issued ~role:"member" (I.issue t.routes (request admin) ~body:(body "member")) in
    let reopen ms =
      match Z.open_at_start ~now_ms:(fun () -> ms) ~log_path:t.log_path ~store_path:t.store_path with
      | Ok zone -> zone
      | Error error -> Alcotest.failf "zone not reopened: %s" (Z.open_error_to_string error)
    in
    let ahead = { t.routes with R.zone = reopen lost.expires_at_ms; now = (fun () -> at_ms lost.expires_at_ms) } in
    let (_ : issued) = issued ~role:"member" (I.issue ahead (request admin) ~body:(body "member")) in
    let back = reopen start_ms in
    Alcotest.(check string)
      "expired by the latest time of the log"
      "expired"
      (status_of lost.invite_id (listed (I.list { t.routes with R.zone = back } (read admin))));
    Alcotest.(check bool) "and no one joins through it" true (Option.is_none (joins back ~token:lost.token (github 41))))
;;

let a_member_does_not_list_invitations () =
  with_installation (fun t ->
    let spent = issued ~role:"member" (I.issue t.routes (request (Some t.admin)) ~body:(body "member")) in
    let a_member =
      match joins t.zone ~token:spent.token (github 7) with
      | Some (user_id, (_ : E.role)) -> session_for t.zone user_id
      | None -> Alcotest.fail "the Member did not join"
    in
    let answer = I.list t.routes (read (Some a_member)) in
    Alcotest.(check int) "a Member lists" 403 (code answer);
    Alcotest.(check bool) "no invitations" true (Option.is_none (member "invites" answer));
    Alcotest.(check int) "no session" 401 (code (I.list t.routes (read None)));
    Alcotest.(check int) "another origin" 403 (code (I.list t.routes (read ~origin:Q.Other_origin (Some t.admin))));
    Alcotest.(check int) "a navigation" 200 (code (I.list t.routes (read ~origin:Q.No_origin (Some t.admin)))))
;;

(* A revocation whose record cannot be appended: the log is read-only while
   the zone writes it. The next start reads the given-up intent and holds the
   invitation (design 8.3). It is listed as held, not as open, its link lets
   no one in, and a revocation made again closes it. *)
let a_held_revocation_is_not_listed_as_open () =
  skip_for_superuser ();
  with_installation (fun t ->
    let admin = Some t.admin in
    let held = issued ~role:"member" (I.issue t.routes (request admin) ~body:(body "member")) in
    Unix.chmod t.log_path 0o400;
    Fun.protect
      ~finally:(fun () -> Unix.chmod t.log_path 0o600)
      (fun () ->
        let answer = I.revoke t.routes (request admin) ~invite_id:held.invite_id in
        Alcotest.(check int) ("a revocation the log does not take: " ^ answer.R.body) 503 (code answer));
    let zone =
      match Z.open_at_start ~now_ms:(fun () -> start_ms) ~log_path:t.log_path ~store_path:t.store_path with
      | Ok zone -> zone
      | Error error -> Alcotest.failf "zone not reopened: %s" (Z.open_error_to_string error)
    in
    let routes = { t.routes with R.zone } in
    Alcotest.(check string)
      "held"
      "revocation_pending"
      (status_of held.invite_id (listed (I.list routes (read admin))));
    Alcotest.(check string)
      "held after it expires too"
      "revocation_pending"
      (status_of
         held.invite_id
         (listed (I.list { routes with R.now = (fun () -> at_ms held.expires_at_ms) } (read admin))));
    Alcotest.(check bool) "its link lets no one in" true (Option.is_none (joins zone ~token:held.token (github 31)));
    Alcotest.(check int) "revoked again" 204 (code (I.revoke routes (request admin) ~invite_id:held.invite_id));
    Alcotest.(check string) "revoked" "revoked" (status_of held.invite_id (listed (I.list routes (read admin)))))
;;

let () =
  Alcotest.run
    "login_invite_routes"
    [ ( "invitations"
      , [ Alcotest.test_case "an Admin issues and revokes" `Quick an_admin_issues_and_revokes
        ; Alcotest.test_case "a Member does not" `Quick a_member_does_not_invite
        ; Alcotest.test_case "refused" `Quick a_request_that_is_refused
        ; Alcotest.test_case "an Admin lists every invitation" `Quick an_admin_lists_every_invitation
        ; Alcotest.test_case "a Member does not list" `Quick a_member_does_not_list_invitations
        ; Alcotest.test_case "a held revocation is not open" `Quick a_held_revocation_is_not_listed_as_open
        ; Alcotest.test_case "a clock set back" `Quick a_clock_set_back_does_not_reopen_an_invitation
        ] )
    ]
;;
