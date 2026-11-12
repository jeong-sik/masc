(* Browser sessions against the writer zone, on real files: each case
   bootstraps a fresh installation in a temporary directory, lets the first
   Admin join through the invitation of the local operator, and issues,
   matches, and ends sessions. No network. The clock is a reference the case
   moves. *)

open Authz_types
open Authz_records
module B = Authz_bootstrap
module Bs = Authz_browser_session
module E = Authz_invite_event
module Login = Authz_login
module Z = Authz_zone

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

type installation =
  { zone : Z.t
  ; clock : int ref
  ; admin : User_id.t  (** The first Admin, who joined. *)
  ; log_path : string
  ; store_path : string
  }

let now_ms clock () = !clock
let admin_token = String.make 64 'a'

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

let google sub = get (Authz_external_identity.google ~sub)

let with_installation f =
  Eio_main.run (fun _env ->
    let root = Filename.temp_dir "authz-browser-session-" "" in
    Fun.protect
      ~finally:(fun () -> remove_tree root)
      (fun () ->
        let base = Filename.concat root "base" in
        Unix.mkdir base 0o700;
        let store = Filename.concat (Filename.concat root "store") "external.jsonl" in
        let clock = ref start_ms in
        (match
           B.fresh_bootstrap
             { B.base_path = base
             ; config_dir = Some (Filename.concat root "config")
             ; external_store = store
             ; workspace_id = get (Workspace_id.of_string "workspace-1")
             ; now_ms = now_ms clock
             }
         with
         | Ok (_ : B.completed) -> ()
         | Error error -> Alcotest.failf "bootstrap refused: %s" (B.error_to_string error));
        let log_path = Authz_log.path_of_base_path ~base_path:base in
        match Z.open_at_start ~now_ms:(now_ms clock) ~log_path ~store_path:store with
        | Error error -> Alcotest.failf "zone not opened: %s" (Z.open_error_to_string error)
        | Ok zone ->
          let invitation =
            E.Issued
              { invite_id = get (Invite_id.of_string "invite-admin")
              ; token_digest = E.Token_digest.of_token admin_token
              ; expires_at_ms = start_ms + 3_600_000
              ; role = E.Admin
              }
          in
          (match
             Z.commit
               zone
               { Z.author = Author.Local_operator
               ; kind = Authz_record.Kind.Invite
               ; body = get (E.to_body invitation)
               }
           with
           | Ok (_ : Z.committed) -> ()
           | Error error -> Alcotest.failf "invitation refused: %s" (Z.error_detail error));
          let admin =
            match
              Login.sign_in
                zone
                ~now_ms:(now_ms clock)
                ~draw:(drawing [])
                ~identity:(google "111")
                ~invite:(Some (E.Token_digest.of_token admin_token))
            with
            | Ok (Login.Admitted { user_id; _ }) -> user_id
            | Ok (Login.Signed_in _) | Error _ -> Alcotest.fail "the first Admin did not join"
          in
          f { zone; clock; admin; log_path; store_path = store }))
;;

let issue ?(draw = drawing [ "session-1" ]) ?replaces t ~user_id =
  match Bs.issue t.zone ~user_id ~draw ~replaces with
  | Ok cookie -> cookie
  | Error error -> Alcotest.failf "no session was issued: %s" (Bs.error_to_string error)
;;

let uncertain_name : Z.uncertain -> string = function
  | Z.Log_is_stopped _ -> "log stopped"
  | Z.Store_is_stopped _ -> "store stopped"
  | Z.Files_disagree _ -> "files disagree"
  | Z.Store_answers_nothing -> "store holds no answer"
;;

(* The snapshot a decision rests on, in a case whose zone can be trusted. *)
let trusted t =
  match Z.read t.zone with
  | Ok trusted -> trusted
  | Error uncertain -> Alcotest.failf "the zone cannot be trusted: %s" (uncertain_name uncertain)
;;

(* What a cookie does in the zone as it stands. A zone that cannot be trusted
   gives no snapshot to match the cookie with. *)
let acts t cookie =
  match Z.read t.zone with
  | Error uncertain -> "no decision: " ^ uncertain_name uncertain
  | Ok trusted ->
    (match Bs.authenticate trusted ~now_ms:!(t.clock) cookie with
     | Ok { Bs.user_id; session_id; expires_at_ms = _ } ->
       Printf.sprintf "acts as %s in %s" (User_id.to_string user_id) (Session_id.to_string session_id)
     | Error refusal -> Bs.refusal_to_string refusal)
;;

let read_file path = In_channel.with_open_bin path In_channel.input_all

let contains ~sub text =
  let n = String.length sub in
  let rec go i = i + n <= String.length text && (String.equal (String.sub text i n) sub || go (i + 1)) in
  go 0
;;

let cookie_of value =
  match Bs.Cookie.of_value value with
  | Some cookie -> cookie
  | None -> Alcotest.failf "the cookie value %S is refused" value
;;

let secret_of cookie =
  let value = Bs.Cookie.to_value cookie in
  String.sub value (String.length value - 64) 64
;;

(* A member that the Admin invites, who joins. *)
let member t =
  let token = String.make 64 'b' in
  (match
     Z.commit
       t.zone
       { Z.author = Author.Authenticated (Principal.Human t.admin)
       ; kind = Authz_record.Kind.Invite
       ; body =
           get
             (E.to_body
                (E.Issued
                   { invite_id = get (Invite_id.of_string "invite-2")
                   ; token_digest = E.Token_digest.of_token token
                   ; expires_at_ms = !(t.clock) + 3_600_000
                   ; role = E.Member
                   }))
       }
   with
   | Ok (_ : Z.committed) -> ()
   | Error error -> Alcotest.failf "invitation refused: %s" (Z.error_detail error));
  match
    Login.sign_in
      t.zone
      ~now_ms:(now_ms t.clock)
      ~draw:(drawing [ String.make 32 'm' ])
      ~identity:(google "222")
      ~invite:(Some (E.Token_digest.of_token token))
  with
  | Ok (Login.Admitted { user_id; _ }) -> user_id
  | Ok (Login.Signed_in _) | Error _ -> Alcotest.fail "the member did not join"
;;

(* ---- the checks ---- *)

let a_person_who_signed_in_gets_a_session () =
  with_installation (fun t ->
    let cookie = issue t ~user_id:t.admin in
    Alcotest.(check string) "the id" "session-1" (Session_id.to_string (Bs.Cookie.session_id cookie));
    Alcotest.(check string)
      "acts"
      ("acts as " ^ User_id.to_string t.admin ^ " in session-1")
      (acts t cookie);
    (match Bs.authenticate (trusted t) ~now_ms:!(t.clock) cookie with
     | Ok { Bs.expires_at_ms; _ } ->
       Alcotest.(check int) "ends a week after its record" (start_ms + Authz_session_state.lifetime_ms) expires_at_ms
     | Error refusal -> Alcotest.failf "refused: %s" (Bs.refusal_to_string refusal));
    let secret = secret_of cookie in
    Alcotest.(check bool) "the secret is 64 lowercase hex" true
      (String.for_all (function '0' .. '9' | 'a' .. 'f' -> true | _ -> false) secret);
    let log = read_file t.log_path in
    Alcotest.(check bool) "the log holds the digest" true
      (contains ~sub:(Authz_session_event.Secret_digest.to_hex (Authz_session_event.Secret_digest.of_secret secret)) log);
    Alcotest.(check bool) "the log does not hold the secret" false (contains ~sub:secret log);
    Alcotest.(check bool) "an issue writes no intent" false
      (contains ~sub:{|"type":"session"|} (read_file t.store_path));
    let other = issue t ~user_id:t.admin ~draw:(drawing [ "session-2" ]) in
    Alcotest.(check bool) "two sessions have two secrets" false (String.equal secret (secret_of other));
    Alcotest.(check string)
      "a second browser"
      ("acts as " ^ User_id.to_string t.admin ^ " in session-2")
      (acts t other);
    Alcotest.(check string)
      "the first stays"
      ("acts as " ^ User_id.to_string t.admin ^ " in session-1")
      (acts t cookie))
;;

let a_cookie_that_does_not_act () =
  with_installation (fun t ->
    let cookie = issue t ~user_id:t.admin in
    let id = Session_id.to_string (Bs.Cookie.session_id cookie) in
    Alcotest.(check string)
      "an unknown id"
      (Bs.refusal_to_string Bs.Unknown)
      (acts t (cookie_of ("session-9." ^ secret_of cookie)));
    Alcotest.(check string)
      "another secret"
      (Bs.refusal_to_string Bs.Secret_differs)
      (acts t (cookie_of (id ^ "." ^ String.make 64 '0')));
    t.clock := start_ms + Authz_session_state.lifetime_ms - 1;
    Alcotest.(check string)
      "the last moment"
      ("acts as " ^ User_id.to_string t.admin ^ " in session-1")
      (acts t cookie);
    t.clock := start_ms + Authz_session_state.lifetime_ms;
    Alcotest.(check string) "a week later" (Bs.refusal_to_string Bs.Expired) (acts t cookie);
    t.clock := start_ms;
    let member_id = member t in
    let member_cookie = issue t ~user_id:member_id ~draw:(drawing [ "session-2" ]) in
    (match
       Z.commit
         t.zone
         { Z.author = Author.Authenticated (Principal.Human t.admin)
         ; kind = Authz_record.Kind.Principal
         ; body = get (Authz_principal_event.to_body (Authz_principal_event.Disabled { user_id = member_id }))
         }
     with
     | Ok (_ : Z.committed) -> ()
     | Error error -> Alcotest.failf "disable refused: %s" (Z.error_detail error));
    Alcotest.(check string)
      "a disabled principal"
      (Bs.refusal_to_string (Bs.Principal_inactive member_id))
      (acts t member_cookie);
    (match Bs.sign_out t.zone ~user_id:t.admin (Bs.Cookie.session_id cookie) with
     | Ok () -> ()
     | Error error -> Alcotest.failf "sign-out refused: %s" (Bs.error_to_string error));
    Alcotest.(check string) "signed out" (Bs.refusal_to_string Bs.Ended) (acts t cookie);
    Alcotest.(check bool)
      "the sign-out is an intent on the session"
      true
      (contains ~sub:{|"event":"revoke","subject":{"type":"session","id":"session-1"}|} (read_file t.store_path)))
;;

(* The same browser signs in again, as the member: the new session ends the
   one it held in the same record, which is an intent on the old session. *)
let a_new_sign_in_ends_the_session_of_the_browser () =
  with_installation (fun t ->
    let old = issue t ~user_id:t.admin in
    let member_id = member t in
    let fresh =
      issue t ~user_id:member_id ~draw:(drawing [ "session-2" ]) ~replaces:(Bs.Cookie.session_id old)
    in
    Alcotest.(check string) "the old one" (Bs.refusal_to_string Bs.Ended) (acts t old);
    Alcotest.(check string)
      "the new one"
      ("acts as " ^ User_id.to_string member_id ^ " in session-2")
      (acts t fresh);
    Alcotest.(check bool)
      "an intent on the old session"
      true
      (contains ~sub:{|"event":"revoke","subject":{"type":"session","id":"session-1"}|} (read_file t.store_path));
    match Bs.issue t.zone ~user_id:t.admin ~draw:(drawing [ "session-3" ]) ~replaces:(Some (Bs.Cookie.session_id old)) with
    | Ok _ -> Alcotest.fail "a session ended twice"
    | Error (Bs.Commit_failed (_ : Z.error)) -> ()
    | Error error -> Alcotest.failf "another error: %s" (Bs.error_to_string error))
;;

let a_taken_id_is_drawn_again () =
  with_installation (fun t ->
    let (_ : Bs.Cookie.t) = issue t ~user_id:t.admin in
    let again = issue t ~user_id:t.admin ~draw:(drawing [ "session-1"; "session-2" ]) in
    Alcotest.(check string) "the next id" "session-2" (Session_id.to_string (Bs.Cookie.session_id again));
    (match Bs.issue t.zone ~user_id:t.admin ~draw:(drawing [ "session-1"; "session-1"; "session-1" ]) ~replaces:None with
     | Ok _ -> Alcotest.fail "a taken id was issued"
     | Error (Bs.Commit_failed (_ : Z.error)) -> ()
     | Error error -> Alcotest.failf "another error: %s" (Bs.error_to_string error));
    match Bs.issue t.zone ~user_id:t.admin ~draw:(drawing [ "" ]) ~replaces:None with
    | Error (Bs.Id_not_drawn Authz_id.Empty) -> ()
    | Ok _ | Error _ -> Alcotest.fail "an empty id was not refused")
;;

let skip_for_superuser () = if Unix.geteuid () = 0 then Alcotest.skip ()

(* A sign-out whose record cannot be appended: the log is read-only while the
   zone writes it. The next start reads the given-up intent and holds the block
   of the session (design 8.3), which then does not act though it is open in
   the state. *)
let a_blocked_session_does_not_act () =
  skip_for_superuser ();
  with_installation (fun t ->
    let cookie = issue t ~user_id:t.admin in
    Unix.chmod t.log_path 0o400;
    Fun.protect
      ~finally:(fun () -> Unix.chmod t.log_path 0o600)
      (fun () ->
        match Bs.sign_out t.zone ~user_id:t.admin (Bs.Cookie.session_id cookie) with
        | Ok () -> Alcotest.fail "the read-only log took the record"
        | Error (_ : Bs.error) -> ());
    let t =
      match Z.open_at_start ~now_ms:(now_ms t.clock) ~log_path:t.log_path ~store_path:t.store_path with
      | Ok zone -> { t with zone }
      | Error error -> Alcotest.failf "zone not reopened: %s" (Z.open_error_to_string error)
    in
    (match Authz_session_state.find (Z.snapshot t.zone).state.sessions (Bs.Cookie.session_id cookie) with
     | Some { Authz_session_state.status = Authz_session_state.Open; _ } -> ()
     | Some _ | None -> Alcotest.fail "the session is not open in the state");
    Alcotest.(check string) "blocked" (Bs.refusal_to_string Bs.Revocation_pending) (acts t cookie);
    (match Bs.sign_out t.zone ~user_id:t.admin (Bs.Cookie.session_id cookie) with
     | Ok () -> ()
     | Error error -> Alcotest.failf "the second sign-out refused: %s" (Bs.error_to_string error));
    Alcotest.(check string) "signed out at last" (Bs.refusal_to_string Bs.Ended) (acts t cookie))
;;

(* ---- the cookie and the token ---- *)

let a_cookie_value () =
  with_installation (fun t ->
    let cookie = issue t ~user_id:t.admin ~draw:(drawing [ "a.b" ]) in
    let value = Bs.Cookie.to_value cookie in
    Alcotest.(check string) "an id with a dot" ("a.b." ^ secret_of cookie) value;
    Alcotest.(check string)
      "reads back"
      "a.b"
      (Session_id.to_string (Bs.Cookie.session_id (cookie_of value)));
    Alcotest.(check string)
      "the read cookie acts"
      ("acts as " ^ User_id.to_string t.admin ^ " in a.b")
      (acts t (cookie_of value));
    let secret = secret_of cookie in
    List.iter
      (fun (name, text) -> Alcotest.(check bool) name true (Option.is_none (Bs.Cookie.of_value text)))
      [ "empty", ""
      ; "the secret alone", secret
      ; "no id", "." ^ secret
      ; "no dot", "a" ^ secret
      ; "a short secret", "a." ^ String.sub secret 0 63
      ; "a long secret", "a." ^ secret ^ "0"
      ; "an upper case secret", "a." ^ String.uppercase_ascii secret
      ; "a path segment id", ".." ^ "." ^ secret
      ; "a space in the id", "a b." ^ secret
      ])
;;

let a_csrf_token () =
  with_installation (fun t ->
    let cookie = issue t ~user_id:t.admin in
    let other = issue t ~user_id:t.admin ~draw:(drawing [ "session-2" ]) in
    let token = Bs.csrf_token cookie in
    let secret = secret_of cookie in
    Alcotest.(check int) "64 characters" 64 (String.length token);
    Alcotest.(check bool) "matches its cookie" true (Bs.csrf_matches cookie token);
    Alcotest.(check bool) "made again the same" true (String.equal token (Bs.csrf_token (cookie_of (Bs.Cookie.to_value cookie))));
    Alcotest.(check bool) "not the token of another session" false (Bs.csrf_matches other token);
    Alcotest.(check bool) "not the secret" false (Bs.csrf_matches cookie secret);
    Alcotest.(check bool)
      "not the digest in the log"
      false
      (String.equal token (Authz_session_event.Secret_digest.to_hex (Authz_session_event.Secret_digest.of_secret secret)));
    Alcotest.(check bool) "not empty" false (Bs.csrf_matches cookie "");
    Alcotest.(check bool) "not in another case" false (Bs.csrf_matches cookie (String.uppercase_ascii token));
    (* SHA-256 of "masc-authz-browser-session-csrf-v1\n" and 64 zeros, by
       shasum -a 256; the digest of the 64 zeros alone is 60e05bd1... *)
    Alcotest.(check string)
      "the token of a known secret"
      "11ee1f4cc4db72b7e0ff6c8ef326dd81c9d797ef63c2c6fa72bc06874d33eded"
      (Bs.csrf_token (cookie_of ("session-1." ^ String.make 64 '0'))))
;;

(* A disable whose record cannot be appended. The next start reads the
   given-up intent and holds the block of the member (design 8.3). The member
   is still active in the state and their session is open, and the cookie
   does not act: a sign-in is refused for the same block. *)
let a_session_of_a_blocked_principal_does_not_act () =
  skip_for_superuser ();
  with_installation (fun t ->
    let member_id = member t in
    let cookie = issue t ~user_id:member_id ~draw:(drawing [ "session-2" ]) in
    Unix.chmod t.log_path 0o400;
    Fun.protect
      ~finally:(fun () -> Unix.chmod t.log_path 0o600)
      (fun () ->
        match
          Z.commit
            t.zone
            { Z.author = Author.Authenticated (Principal.Human t.admin)
            ; kind = Authz_record.Kind.Principal
            ; body =
                get (Authz_principal_event.to_body (Authz_principal_event.Disabled { user_id = member_id }))
            }
        with
        | Ok (_ : Z.committed) -> Alcotest.fail "the read-only log took the record"
        | Error (_ : Z.error) -> ());
    let t =
      match Z.open_at_start ~now_ms:(now_ms t.clock) ~log_path:t.log_path ~store_path:t.store_path with
      | Ok zone -> { t with zone }
      | Error error -> Alcotest.failf "zone not reopened: %s" (Z.open_error_to_string error)
    in
    Alcotest.(check bool)
      "still active in the state"
      true
      (Authz_principal_state.is_active (Z.snapshot t.zone).state.principals member_id);
    Alcotest.(check string)
      "the cookie of the blocked member"
      (Bs.refusal_to_string (Bs.Principal_revocation_pending member_id))
      (acts t cookie))
;;

(* Bytes another writer added to the log: the next commit finds the end moved
   and stops the log. The session stays open in the published state, and no
   decision rests on that state any more, so its cookie does not act. *)
let a_stopped_zone_lets_no_cookie_act () =
  with_installation (fun t ->
    let cookie = issue t ~user_id:t.admin in
    Alcotest.(check string)
      "acts while the zone can be trusted"
      ("acts as " ^ User_id.to_string t.admin ^ " in session-1")
      (acts t cookie);
    Out_channel.with_open_gen [ Open_append; Open_binary ] 0o600 t.log_path (fun channel ->
      Out_channel.output_string channel "{}\n");
    (match Bs.issue t.zone ~user_id:t.admin ~draw:(drawing [ "session-2" ]) ~replaces:None with
     | Ok (_ : Bs.Cookie.t) -> Alcotest.fail "the zone wrote over a log another writer moved"
     | Error (_ : Bs.error) -> ());
    (match Authz_session_state.find (Z.snapshot t.zone).state.sessions (Bs.Cookie.session_id cookie) with
     | Some { Authz_session_state.status = Authz_session_state.Open; _ } -> ()
     | Some _ | None -> Alcotest.fail "the session is not open in the state");
    Alcotest.(check string) "once the log is stopped" "no decision: log stopped" (acts t cookie))
;;

let texts_are_told_apart () =
  let texts =
    List.map
      Bs.refusal_to_string
      [ Bs.Unknown
      ; Bs.Ended
      ; Bs.Expired
      ; Bs.Secret_differs
      ; Bs.Revocation_pending
      ; Bs.Principal_inactive (get (User_id.of_string "alice"))
      ; Bs.Principal_revocation_pending (get (User_id.of_string "alice"))
      ]
  in
  Alcotest.(check int)
    "each reason has its own text"
    (List.length texts)
    (List.length (List.sort_uniq String.compare texts))
;;

let () =
  Alcotest.run
    "authz_browser_session"
    [ ( "sessions"
      , [ Alcotest.test_case "issued at sign-in" `Quick a_person_who_signed_in_gets_a_session
        ; Alcotest.test_case "a cookie that does not act" `Quick a_cookie_that_does_not_act
        ; Alcotest.test_case "a new sign-in" `Quick a_new_sign_in_ends_the_session_of_the_browser
        ; Alcotest.test_case "a taken id" `Quick a_taken_id_is_drawn_again
        ; Alcotest.test_case "blocked" `Quick a_blocked_session_does_not_act
        ; Alcotest.test_case
            "a blocked principal"
            `Quick
            a_session_of_a_blocked_principal_does_not_act
        ; Alcotest.test_case "a stopped zone" `Quick a_stopped_zone_lets_no_cookie_act
        ] )
    ; ( "cookie"
      , [ Alcotest.test_case "value" `Quick a_cookie_value
        ; Alcotest.test_case "csrf token" `Quick a_csrf_token
        ; Alcotest.test_case "texts" `Quick texts_are_told_apart
        ] )
    ]
;;
