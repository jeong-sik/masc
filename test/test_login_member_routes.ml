(* The member route against the writer zone on real files: the first Admin
   joins through an invitation and holds a browser session, others join
   through the allowlist and an Admin invitation, and the Admin lists them as
   a browser would. Each case bootstraps a fresh installation in a temporary
   directory. No network: the route reaches no provider. *)

open Authz_types
open Authz_records
module A = Login_allowlist_routes
module B = Authz_bootstrap
module Bs = Authz_browser_session
module E = Authz_invite_event
module M = Login_member_routes
module Q = Authz_browser_request
module R = Login_routes
module Z = Authz_zone

let start_ms = 1_700_000_000_000
let admin_token = String.make 64 'a'
let second_admin_token = String.make 64 'b'

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

let sign_in ?(draw = draw) zone ?invite identity =
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

(* An Admin invitation that the local operator issues, as the first Admin's. *)
let admin_invitation zone ~invite_id ~token =
  match
    Z.commit
      zone
      { Z.author = Author.Local_operator
      ; kind = Authz_record.Kind.Invite
      ; body =
          get_ok
            (E.to_body
               (E.Issued
                  { invite_id = get_ok (Invite_id.of_string invite_id)
                  ; token_digest = E.Token_digest.of_token token
                  ; expires_at_ms = start_ms + 3_600_000
                  ; role = E.Admin
                  }))
      }
  with
  | Ok (_ : Z.committed) -> ()
  | Error error -> Alcotest.failf "invitation refused: %s" (Z.error_detail error)
;;

let with_installation f =
  Eio_main.run (fun _env ->
    let root = Filename.temp_dir "login-member-routes-" "" in
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
          admin_invitation zone ~invite_id:"invite-admin" ~token:admin_token;
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

let request ?(origin = Q.Same_origin) cookie =
  { Q.method_ = Q.Unsafe
  ; session_cookie =
      (match cookie with
       | None -> Q.No_cookie
       | Some cookie -> Q.One_cookie (Bs.Cookie.to_value cookie))
  ; bearer = false
  ; query_credential = false
  ; origin
  ; csrf = Option.map Bs.csrf_token cookie
  }
;;

(* A read as a browser sends it: a GET with no CSRF token. *)
let read ?(origin = Q.Same_origin) cookie =
  { (request ~origin cookie) with Q.method_ = Q.Safe; csrf = None }
;;

let code (answer : R.answer) = R.status_code answer.status

let member name (answer : R.answer) =
  match Yojson.Safe.from_string answer.body with
  | `Assoc fields -> List.assoc_opt name fields
  | _ -> Alcotest.failf "the answer %S is not a JSON object" answer.body
;;

(* A Member who joins through an allowlist entry that the Admin registers. *)
let a_member_joins ?draw t user_id =
  let registered =
    A.register t.routes (request (Some t.admin)) ~body:(Printf.sprintf {|{"provider":"github","user_id":%d}|} user_id)
  in
  Alcotest.(check int) ("registered: " ^ registered.R.body) 200 (code registered);
  match sign_in ?draw t.zone (github user_id) with
  | Ok (Authz_login.Admitted { user_id; _ }) -> user_id
  | Ok (Authz_login.Signed_in _) | Error _ -> Alcotest.fail "the registered identity did not join"
;;

let principal_event zone ~admin event =
  Z.commit
    zone
    { Z.author = Author.Authenticated (Principal.Human admin)
    ; kind = Authz_record.Kind.Principal
    ; body = get_ok (Authz_principal_event.to_body event)
    }
;;

let disable zone ~admin user_id = principal_event zone ~admin (Authz_principal_event.Disabled { user_id })

let delete zone ~admin user_id identity =
  principal_event zone ~admin (Authz_principal_event.Deleted { user_id; identity })
;;

(* The members of a 200 list, each by its user id. *)
let listed (answer : R.answer) =
  Alcotest.(check int) ("listed: " ^ answer.body) 200 (code answer);
  Alcotest.(check (list string))
    "not cached"
    [ "no-store" ]
    (List.assoc_opt "cache-control" answer.headers |> Option.to_list);
  match member "members" answer with
  | Some (`List members) ->
    List.map
      (function
        | `Assoc fields ->
          (match List.assoc_opt "user_id" fields with
           | Some (`String id) -> id, fields
           | _ -> Alcotest.failf "a member with no id in %S" answer.body)
        | _ -> Alcotest.failf "a member that is not an object in %S" answer.body)
      members
  | _ -> Alcotest.failf "no members in %S" answer.body
;;

(* Values are compared as JSON, so a member of another type fails. *)
let json = Alcotest.testable Yojson.Safe.pp Yojson.Safe.equal
let field name fields = List.assoc_opt name fields
let text value = Some (`String value)
let labels values = Some (`List (List.map (fun value -> `String value) values))

let skip_for_superuser () = if Unix.geteuid () = 0 then Alcotest.skip ()

(* ---- the cases ---- *)

(* The two who join after the first Admin draw their ids counting down, so the
   order of the ids is not the order they joined in. *)
let an_admin_lists_every_member () =
  with_installation (fun t ->
    let admin = Some t.admin in
    let countdown = ref 0x1000 in
    let down () =
      decr countdown;
      Printf.sprintf "%064x" !countdown
    in
    let disabled = a_member_joins ~draw:down t 7 in
    admin_invitation t.zone ~invite_id:"invite-second" ~token:second_admin_token;
    let second_admin =
      match sign_in ~draw:down t.zone ~invite:(E.Token_digest.of_token second_admin_token) (google "222") with
      | Ok (Authz_login.Admitted { user_id; _ }) -> user_id
      | Ok (Authz_login.Signed_in _) | Error _ -> Alcotest.fail "the second Admin did not join"
    in
    (match disable t.zone ~admin:t.admin_id disabled with
     | Ok (_ : Z.committed) -> ()
     | Error error -> Alcotest.failf "the disable was refused: %s" (Z.error_detail error));
    let members = listed (M.list t.routes (read admin)) in
    let expect label id ~identity ~role ~status =
      match List.assoc_opt (User_id.to_string id) members with
      | None -> Alcotest.failf "%s: not listed" label
      | Some fields ->
        Alcotest.(check (option json))
          (label ^ ": identity")
          (Some (Yojson.Safe.from_string identity))
          (field "identity" fields);
        Alcotest.(check (option json)) (label ^ ": role") (text role) (field "role" fields);
        Alcotest.(check (option json)) (label ^ ": status") (text status) (field "status" fields);
        Alcotest.(check (option json)) (label ^ ": not held") (labels []) (field "held" fields);
        Alcotest.(check (list string))
          (label ^ ": the members")
          [ "user_id"; "identity"; "role"; "status"; "held" ]
          (List.map fst fields)
    in
    Alcotest.(check (list string))
      "in the order of the ids"
      (List.map User_id.to_string [ t.admin_id; second_admin; disabled ])
      (List.map fst members);
    expect "the first Admin" t.admin_id ~identity:{|{"provider":"google","sub":"111"}|} ~role:"admin" ~status:"active";
    expect "the second Admin" second_admin ~identity:{|{"provider":"google","sub":"222"}|} ~role:"admin" ~status:"active";
    expect "the disabled Member" disabled ~identity:{|{"provider":"github","user_id":7}|} ~role:"member" ~status:"disabled";
    (match disable t.zone ~admin:t.admin_id second_admin with
     | Ok (_ : Z.committed) -> ()
     | Error error -> Alcotest.failf "the second Admin was not disabled: %s" (Z.error_detail error));
    let members = listed (M.list t.routes (read admin)) in
    Alcotest.(check (option json))
      "a disabled Admin keeps the role"
      (text "admin")
      (Option.bind (List.assoc_opt (User_id.to_string second_admin) members) (field "role"));
    Alcotest.(check (option json))
      "and is disabled"
      (text "disabled")
      (Option.bind (List.assoc_opt (User_id.to_string second_admin) members) (field "status")))
;;

let a_member_does_not_list_members () =
  with_installation (fun t ->
    let a_member = session_for t.zone (a_member_joins t 7) in
    let answer = M.list t.routes (read (Some a_member)) in
    Alcotest.(check int) "a Member lists" 403 (code answer);
    Alcotest.(check bool) "no members" true (Option.is_none (member "members" answer));
    Alcotest.(check int) "no session" 401 (code (M.list t.routes (read None)));
    Alcotest.(check int) "another origin" 403 (code (M.list t.routes (read ~origin:Q.Other_origin (Some t.admin))));
    Alcotest.(check int) "a navigation" 200 (code (M.list t.routes (read ~origin:Q.No_origin (Some t.admin)))))
;;

(* A reduction whose record cannot be appended: the log is read-only while the
   zone writes it. The next start reads the given-up intent and holds the
   principal (design 8.3), who is still in the state as before. A disable,
   the disable made again, and then a deletion of the same Member are held
   so, one after the other. The list names each change once; a disable made
   again closes the holds of its own change only, and the deletion made again
   takes the Member off the list. *)
let a_held_member_is_marked () =
  skip_for_superuser ();
  with_installation (fun t ->
    let held = a_member_joins t 7 in
    let reopen () =
      match Z.open_at_start ~now_ms:(fun () -> start_ms) ~log_path:t.log_path ~store_path:t.store_path with
      | Ok zone -> zone
      | Error error -> Alcotest.failf "zone not reopened: %s" (Z.open_error_to_string error)
    in
    let not_recorded label commit =
      Unix.chmod t.log_path 0o400;
      Fun.protect
        ~finally:(fun () -> Unix.chmod t.log_path 0o600)
        (fun () ->
          match commit () with
          | Ok (_ : Z.committed) -> Alcotest.failf "%s: the read-only log took the record" label
          | Error (_ : Z.error) -> ())
    in
    not_recorded "the disable" (fun () -> disable t.zone ~admin:t.admin_id held);
    let zone = reopen () in
    not_recorded "the disable made again" (fun () -> disable zone ~admin:t.admin_id held);
    let zone = reopen () in
    not_recorded "the deletion" (fun () -> delete zone ~admin:t.admin_id held (github 7));
    let zone = reopen () in
    let routes = { t.routes with R.zone } in
    let fields_of id =
      List.assoc_opt (User_id.to_string id) (listed (M.list routes (read (Some t.admin))))
    in
    let fields () =
      match fields_of held with
      | Some fields -> fields
      | None -> Alcotest.fail "the held Member is not listed"
    in
    let before = fields () in
    Alcotest.(check (option json)) "still active in the state" (text "active") (field "status" before);
    Alcotest.(check (option json)) "each held change once" (labels [ "delete"; "disable" ]) (field "held" before);
    Alcotest.(check (option json))
      "the Admin is not held"
      (labels [])
      (Option.bind (fields_of t.admin_id) (field "held"));
    (match disable zone ~admin:t.admin_id held with
     | Ok (_ : Z.committed) -> ()
     | Error error -> Alcotest.failf "the disable made again was refused: %s" (Z.error_detail error));
    let after = fields () in
    Alcotest.(check (option json)) "disabled" (text "disabled") (field "status" after);
    Alcotest.(check (option json)) "the deletion is still held" (labels [ "delete" ]) (field "held" after);
    (match delete zone ~admin:t.admin_id held (github 7) with
     | Ok (_ : Z.committed) -> ()
     | Error error -> Alcotest.failf "the deletion made again was refused: %s" (Z.error_detail error));
    Alcotest.(check bool) "a deleted Member is not listed" true (Option.is_none (fields_of held)))
;;

let () =
  Alcotest.run
    "login_member_routes"
    [ ( "members"
      , [ Alcotest.test_case "an Admin lists every member" `Quick an_admin_lists_every_member
        ; Alcotest.test_case "a Member does not" `Quick a_member_does_not_list_members
        ; Alcotest.test_case "a held Member is marked" `Quick a_held_member_is_marked
        ] )
    ]
;;
