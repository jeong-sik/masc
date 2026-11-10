(* The sign-in of a known identity and the admission of a new one, on real
   files: each case bootstraps a fresh installation in a temporary directory,
   writes the first Admin invitation as the local operator (as
   `masc auth bootstrap` does), and opens its writer zone. No network. The
   clock is a reference the case moves. *)

open Authz_types
open Authz_records
module B = Authz_bootstrap
module E = Authz_invite_event
module Login = Authz_login
module P = Authz_principal_state
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
  ; admin_token : string  (** The token of the first Admin invitation. *)
  ; log_path : string
  ; store_path : string
  }

let now_ms clock () = !clock
let admin_token = String.make 64 'a'

(* One day, as the first Admin invitation of [Authz_activation]. *)
let admin_invitation_lifetime_ms = 24 * 60 * 60 * 1000

let with_installation f =
  Eio_main.run (fun _env ->
    let root = Filename.temp_dir "authz-login-" "" in
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
              ; expires_at_ms = start_ms + admin_invitation_lifetime_ms
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
           | Error error -> Alcotest.failf "invitation refused: %s" (Z.error_to_string error));
          f { zone; clock; admin_token; log_path; store_path = store }))
;;

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
let digest token = Some (E.Token_digest.of_token token)
let next_seq t = Authz_record.next_seq (Z.snapshot t.zone).head

let sign_in ?(draw = drawing []) t ~identity ~invite =
  Login.sign_in t.zone ~now_ms:(now_ms t.clock) ~draw ~identity ~invite
;;

let outcome = function
  | Ok (Login.Signed_in user_id) -> "signed in " ^ User_id.to_string user_id
  | Ok (Login.Admitted { user_id; role; previously_deleted }) ->
    Printf.sprintf
      "admitted %s as %s%s"
      (User_id.to_string user_id)
      (E.role_label role)
      (if previously_deleted then ", previously deleted" else "")
  | Error refusal -> Login.refusal_to_string refusal
;;

let admitted_id = function
  | Ok (Login.Admitted { user_id; _ }) -> user_id
  | Ok (Login.Signed_in _) | Error _ -> Alcotest.fail "the admission did not go through"
;;

let commit t ~by kind body =
  match Z.commit t.zone { Z.author = Author.Authenticated (Principal.Human by); kind; body } with
  | Ok (_ : Z.committed) -> ()
  | Error error -> Alcotest.failf "fixture commit refused: %s" (Z.error_to_string error)
;;

let member_invitation t ~invite_id ~token =
  get
    (E.to_body
       (E.Issued
          { invite_id = get (Invite_id.of_string invite_id)
          ; token_digest = E.Token_digest.of_token token
          ; expires_at_ms = !(t.clock) + 3_600_000
          ; role = E.Member
          }))
;;

(* An invitation that [admin] issues, for a member, with this token. *)
let issue t ~admin ~invite_id ~token =
  commit t ~by:admin Authz_record.Kind.Invite (member_invitation t ~invite_id ~token)
;;

let issue_result t ~admin ~invite_id ~token =
  Result.map
    (fun (_ : Z.committed) -> ())
    (Z.commit
       t.zone
       { Z.author = Author.Authenticated (Principal.Human admin)
       ; kind = Authz_record.Kind.Invite
       ; body = member_invitation t ~invite_id ~token
       })
;;

let not_invited_text = Login.refusal_to_string Login.Not_invited

module Allowlist = Authz_allowlist

let register_result t ~admin ~registration_id identity =
  Allowlist.register t.zone ~admin ~draw:(drawing [ registration_id ]) identity
;;

(* An entry of the allowlist that [admin] writes for [identity] (plan C2d). *)
let register t ~admin ~registration_id identity =
  match register_result t ~admin ~registration_id identity with
  | Ok (_ : Allowlist.registered) -> ()
  | Error error -> Alcotest.failf "fixture registration refused: %s" (Allowlist.error_to_string error)
;;

let remove t ~admin ~registration_id =
  match Allowlist.remove t.zone ~admin (get (Registration_id.of_string registration_id)) with
  | Ok () -> ()
  | Error error -> Alcotest.failf "fixture removal refused: %s" (Allowlist.error_to_string error)
;;

let allowlist_word = function
  | Ok { Allowlist.registration_id; previously_deleted } ->
    Registration_id.to_string registration_id ^ if previously_deleted then ", previously deleted" else ""
  | Error error -> Allowlist.error_to_string error
;;

let refused refusal = Allowlist.error_to_string (Allowlist.Commit_failed (Z.Refused refusal))
let store_lines t = List.length (String.split_on_char '\n' (In_channel.with_open_bin t.store_path In_channel.input_all))

let contains ~sub text =
  let n = String.length sub in
  let rec go i = i + n <= String.length text && (String.equal (String.sub text i n) sub || go (i + 1)) in
  go 0
;;

let principal_event t ~admin event =
  commit t ~by:admin Authz_record.Kind.Principal (get (Authz_principal_event.to_body event))
;;

let the_first_admin_joins_and_then_signs_in () =
  with_installation (fun t ->
    let admin = sign_in t ~identity:(google "111") ~invite:(digest t.admin_token) ~draw:(drawing [ String.make 32 'a' ]) in
    Alcotest.(check string) "admitted" ("admitted " ^ String.make 32 'a' ^ " as admin") (outcome admin);
    Alcotest.(check string)
      "the next login"
      ("signed in " ^ String.make 32 'a')
      (outcome (sign_in t ~identity:(google "111") ~invite:None)))
;;

let nothing_is_written_for_who_is_not_let_in () =
  with_installation (fun t ->
    let before = next_seq t in
    Alcotest.(check string)
      "no invitation"
      not_invited_text
      (outcome (sign_in t ~identity:(google "111") ~invite:None));
    Alcotest.(check string)
      "another token"
      "no invitation has this token"
      (outcome (sign_in t ~identity:(google "111") ~invite:(digest (String.make 64 'f'))));
    Alcotest.(check int) "the log did not move" before (next_seq t))
;;

let an_invitation_is_spent_once () =
  with_installation (fun t ->
    let (_ : User_id.t) = admitted_id (sign_in t ~identity:(google "111") ~invite:(digest t.admin_token)) in
    let second = sign_in t ~identity:(google "222") ~invite:(digest t.admin_token) in
    (match second with
     | Error refusal -> Alcotest.(check bool) "a conflict" true (Login.is_conflict refusal)
     | Ok _ -> Alcotest.fail "the invitation was spent twice");
    Alcotest.(check bool)
      "the second person has no principal"
      true
      (Option.is_none (P.find_identity (Z.snapshot t.zone).state.principals (google "222"))))
;;

let a_bound_identity_with_an_invitation_leaves_it_open () =
  with_installation (fun t ->
    let admin = admitted_id (sign_in t ~identity:(google "111") ~invite:(digest t.admin_token)) in
    issue t ~admin ~invite_id:"invite-2" ~token:(String.make 64 'b');
    let refused = sign_in t ~identity:(google "111") ~invite:(digest (String.make 64 'b')) in
    (match refused with
     | Error (Login.Already_joined user_id as refusal) ->
       Alcotest.(check string) "the principal" (User_id.to_string admin) (User_id.to_string user_id);
       Alcotest.(check bool) "a conflict" true (Login.is_conflict refusal)
     | Ok _ | Error _ -> Alcotest.failf "expected a refusal: %s" (outcome refused));
    Alcotest.(check string)
      "the invitation is still open for someone else"
      ("admitted " ^ String.make 32 'b' ^ " as member")
      (outcome
         (sign_in
            t
            ~identity:(google "222")
            ~invite:(digest (String.make 64 'b'))
            ~draw:(drawing [ String.make 32 'b'; String.make 32 'c' ]))))
;;

let an_expired_invitation_is_refused () =
  with_installation (fun t ->
    t.clock := !(t.clock) + admin_invitation_lifetime_ms;
    let before = next_seq t in
    let refused = sign_in t ~identity:(google "111") ~invite:(digest t.admin_token) in
    (match refused with
     | Error (Login.Admission_refused (P.Invitation (Authz_invite_state.Invitation_expired _)) as refusal) ->
       Alcotest.(check bool) "not a conflict" false (Login.is_conflict refusal)
     | Ok _ | Error _ -> Alcotest.failf "expected the expiry: %s" (outcome refused));
    Alcotest.(check int) "nothing written" before (next_seq t))
;;

let a_disabled_principal_does_not_sign_in () =
  with_installation (fun t ->
    let admin = admitted_id (sign_in t ~identity:(google "111") ~invite:(digest t.admin_token)) in
    issue t ~admin ~invite_id:"invite-2" ~token:(String.make 64 'b');
    let member = admitted_id (sign_in t ~identity:(google "222") ~invite:(digest (String.make 64 'b'))) in
    principal_event t ~admin (Authz_principal_event.Disabled { user_id = member });
    Alcotest.(check string)
      "disabled"
      (Printf.sprintf "the principal %s is disabled" (User_id.to_string member))
      (outcome (sign_in t ~identity:(google "222") ~invite:None));
    principal_event t ~admin (Authz_principal_event.Enabled { user_id = member });
    Alcotest.(check string)
      "enabled again"
      ("signed in " ^ User_id.to_string member)
      (outcome (sign_in t ~identity:(google "222") ~invite:None)))
;;

let a_taken_id_is_drawn_again () =
  with_installation (fun t ->
    let admin = admitted_id (sign_in t ~identity:(google "111") ~invite:(digest t.admin_token)) in
    issue t ~admin ~invite_id:"invite-2" ~token:(String.make 64 'b');
    let again =
      sign_in
        t
        ~identity:(google "222")
        ~invite:(digest (String.make 64 'b'))
        ~draw:(drawing [ User_id.to_string admin; String.make 32 'c'; String.make 32 'd'; String.make 32 'e' ])
    in
    Alcotest.(check string)
      "the admin's id is not given twice"
      ("admitted " ^ String.make 32 'd' ^ " as member")
      (outcome again))
;;

let a_deleted_identity_joins_again_as_someone_new () =
  with_installation (fun t ->
    let admin = admitted_id (sign_in t ~identity:(google "111") ~invite:(digest t.admin_token)) in
    issue t ~admin ~invite_id:"invite-2" ~token:(String.make 64 'b');
    let member = admitted_id (sign_in t ~identity:(google "222") ~invite:(digest (String.make 64 'b'))) in
    principal_event t ~admin (Authz_principal_event.Deleted { user_id = member; identity = google "222" });
    Alcotest.(check string)
      "deleted is like never invited"
      not_invited_text
      (outcome (sign_in t ~identity:(google "222") ~invite:None));
    issue t ~admin ~invite_id:"invite-3" ~token:(String.make 64 'c');
    let back = sign_in t ~identity:(google "222") ~invite:(digest (String.make 64 'c')) in
    Alcotest.(check bool) "a new principal" false (User_id.equal member (admitted_id back));
    match back with
    | Ok (Login.Admitted { previously_deleted; _ }) -> Alcotest.(check bool) "marked" true previously_deleted
    | Ok (Login.Signed_in _) | Error _ -> Alcotest.fail "not admitted")
;;

(* A registered identity joins with no invitation, as a Member, through one
   admission record; its next login signs in. A removed entry lets nobody in,
   and nothing is written for it. *)
let a_registered_identity_joins_as_a_member () =
  with_installation (fun t ->
    let admin = admitted_id (sign_in t ~identity:(google "111") ~invite:(digest t.admin_token)) in
    register t ~admin ~registration_id:"registration-1" (google "333");
    let before = next_seq t in
    Alcotest.(check string)
      "an identity with no entry of its own"
      not_invited_text
      (outcome (sign_in t ~identity:(google "555") ~invite:None));
    Alcotest.(check int) "nothing written for it" before (next_seq t);
    let member = sign_in t ~identity:(google "333") ~invite:None ~draw:(drawing [ String.make 32 'c' ]) in
    Alcotest.(check string) "admitted" ("admitted " ^ String.make 32 'c' ^ " as member") (outcome member);
    Alcotest.(check int) "one record" (before + 1) (next_seq t);
    Alcotest.(check string)
      "the next login"
      ("signed in " ^ String.make 32 'c')
      (outcome (sign_in t ~identity:(google "333") ~invite:None));
    register t ~admin ~registration_id:"registration-2" (google "444");
    remove t ~admin ~registration_id:"registration-2";
    let before = next_seq t in
    Alcotest.(check string)
      "a removed entry"
      not_invited_text
      (outcome (sign_in t ~identity:(google "444") ~invite:None));
    Alcotest.(check int) "the log did not move" before (next_seq t))
;;

(* The entry a person came through is spent, so once deleted they do not come
   back through it. An Admin registers the identity again, and the person joins
   as someone new, marked as previously deleted (design 5.1-6). *)
let a_deleted_member_needs_a_new_entry () =
  with_installation (fun t ->
    let admin = admitted_id (sign_in t ~identity:(google "111") ~invite:(digest t.admin_token)) in
    register t ~admin ~registration_id:"registration-1" (google "333");
    let member = admitted_id (sign_in t ~identity:(google "333") ~invite:None) in
    principal_event t ~admin (Authz_principal_event.Deleted { user_id = member; identity = google "333" });
    Alcotest.(check string)
      "the spent entry"
      not_invited_text
      (outcome (sign_in t ~identity:(google "333") ~invite:None));
    register t ~admin ~registration_id:"registration-2" (google "333");
    let back = sign_in t ~identity:(google "333") ~invite:None in
    Alcotest.(check bool) "a new principal" false (User_id.equal member (admitted_id back));
    match back with
    | Ok (Login.Admitted { previously_deleted; role; _ }) ->
      Alcotest.(check bool) "marked" true previously_deleted;
      Alcotest.(check string) "a Member" "member" (E.role_label role)
    | Ok (Login.Signed_in _) | Error _ -> Alcotest.fail "not admitted")
;;

(* An invitation admission of a registered identity spends its entry too. When
   both logins of one identity check before either commits, one joins and the
   other is a conflict (design 5.1-3). *)
let an_invitation_and_an_entry_race_for_one_identity () =
  with_installation (fun t ->
    let admin = admitted_id (sign_in t ~identity:(google "111") ~invite:(digest t.admin_token)) in
    issue t ~admin ~invite_id:"invite-2" ~token:(String.make 64 'b');
    register t ~admin ~registration_id:"registration-1" (google "333");
    let yielding () =
      let draw = drawing [] in
      fun () ->
        Eio.Fiber.yield ();
        draw ()
    in
    let through_invitation = ref (Error Login.Not_invited) in
    let through_entry = ref (Error Login.Not_invited) in
    Eio.Fiber.both
      (fun () ->
        through_invitation
        := Login.sign_in
             t.zone
             ~now_ms:(now_ms t.clock)
             ~draw:(yielding ())
             ~identity:(google "333")
             ~invite:(digest (String.make 64 'b')))
      (fun () ->
        through_entry
        := Login.sign_in
             t.zone
             ~now_ms:(now_ms t.clock)
             ~draw:(fun () -> String.make 32 'e')
             ~identity:(google "333")
             ~invite:None);
    Alcotest.(check string)
      "the entry joins first"
      ("admitted " ^ String.make 32 'e' ^ " as member")
      (outcome !through_entry);
    match !through_invitation with
    | Ok _ -> Alcotest.fail "the identity joined twice"
    | Error refusal -> Alcotest.(check bool) "the invitation is a conflict" true (Login.is_conflict refusal))
;;

(* Only an Admin that acts writes the allowlist; an identity has one open
   entry and a bound identity none (plan C2d). A registration writes nothing to
   the external store, and a removal writes its [Revoke] intent there first
   (design 8.2). *)
let an_admin_writes_the_allowlist () =
  with_installation (fun t ->
    let admin = admitted_id (sign_in t ~identity:(google "111") ~invite:(digest t.admin_token)) in
    issue t ~admin ~invite_id:"invite-2" ~token:(String.make 64 'b');
    let member = admitted_id (sign_in t ~identity:(google "222") ~invite:(digest (String.make 64 'b'))) in
    let lines = store_lines t in
    Alcotest.(check string)
      "an Admin registers"
      "registration-1"
      (allowlist_word (register_result t ~admin ~registration_id:"registration-1" (google "333")));
    Alcotest.(check int) "no intent for a registration" lines (store_lines t);
    Alcotest.(check string)
      "a Member"
      (refused (Authz_state.Registration (Authz_registration_state.Author_is_not_an_admin (Principal.Human member))))
      (allowlist_word (register_result t ~admin:member ~registration_id:"registration-2" (google "444")));
    Alcotest.(check string)
      "the identity again"
      (refused
         (Authz_state.Registration
            (Authz_registration_state.Identity_registered (get (Registration_id.of_string "registration-1")))))
      (allowlist_word (register_result t ~admin ~registration_id:"registration-2" (google "333")));
    Alcotest.(check string)
      "a bound identity"
      (refused (Authz_state.Registration Authz_registration_state.Identity_bound))
      (allowlist_word (register_result t ~admin ~registration_id:"registration-2" (google "222")));
    let entry = get (Registration_id.of_string "registration-1") in
    (match Allowlist.remove t.zone ~admin entry with
     | Ok () -> ()
     | Error error -> Alcotest.failf "the removal was refused: %s" (Allowlist.error_to_string error));
    let store = In_channel.with_open_bin t.store_path In_channel.input_all in
    Alcotest.(check bool)
      "the removal is an intent of the store"
      true
      (contains ~sub:{|"event":"revoke","subject":{"type":"registration","id":"registration-1"}|} store);
    Alcotest.(check string)
      "removed twice"
      (refused (Authz_state.Registration (Authz_registration_state.Already_removed entry)))
      (match Allowlist.remove t.zone ~admin entry with
       | Ok () -> "removed"
       | Error error -> Allowlist.error_to_string error))
;;

(* A drawn id that names an entry already is drawn again. The identity of a
   deleted principal is registered, marked as previously deleted (design
   5.1-6). *)
let a_taken_registration_id_is_drawn_again () =
  with_installation (fun t ->
    let admin = admitted_id (sign_in t ~identity:(google "111") ~invite:(digest t.admin_token)) in
    issue t ~admin ~invite_id:"invite-2" ~token:(String.make 64 'b');
    let member = admitted_id (sign_in t ~identity:(google "222") ~invite:(digest (String.make 64 'b'))) in
    register t ~admin ~registration_id:"registration-1" (google "333");
    principal_event t ~admin (Authz_principal_event.Deleted { user_id = member; identity = google "222" });
    Alcotest.(check string)
      "drawn again, previously deleted"
      "registration-2, previously deleted"
      (allowlist_word
         (Allowlist.register
            t.zone
            ~admin
            ~draw:(drawing [ "registration-1"; "registration-2" ])
            (google "222")));
    Alcotest.(check string)
      "an id that is not one"
      "a drawn id was refused: empty"
      (allowlist_word (Allowlist.register t.zone ~admin ~draw:(fun () -> "") (google "444"))))
;;

(* Both logins check the invitation before either commits: the draw yields,
   so the other fiber runs its check in between. One joins; the other finds
   the invitation spent on its second look. *)
let two_logins_race_for_one_invitation () =
  with_installation (fun t ->
    let yielding () =
      let draw = drawing [] in
      fun () ->
        Eio.Fiber.yield ();
        draw ()
    in
    let first = ref (Error Login.Not_invited) in
    let second = ref (Error Login.Not_invited) in
    Eio.Fiber.both
      (fun () ->
        first := Login.sign_in t.zone ~now_ms:(now_ms t.clock) ~draw:(yielding ()) ~identity:(google "111") ~invite:(digest t.admin_token))
      (fun () ->
        second
        := Login.sign_in
             t.zone
             ~now_ms:(now_ms t.clock)
             ~draw:(fun () -> String.make 32 'f')
             ~identity:(google "222")
             ~invite:(digest t.admin_token));
    let admitted = List.filter Result.is_ok [ !first; !second ] in
    let conflicts =
      List.filter
        (function
          | Error refusal -> Login.is_conflict refusal
          | Ok _ -> false)
        [ !first; !second ]
    in
    Alcotest.(check int) "one joins" 1 (List.length admitted);
    Alcotest.(check int) "the other is a conflict" 1 (List.length conflicts))
;;

let skip_for_superuser () = if Unix.geteuid () = 0 then Alcotest.skip ()

(* A disable whose record cannot be appended: the log is read-only while the
   zone writes it. The zone that failed stops its log, so it signs nobody in;
   the next start reads the given-up intent and holds the block of the member
   (design 8.3), while the member is still active in the state. *)
let a_blocked_principal_does_not_sign_in () =
  skip_for_superuser ();
  with_installation (fun t ->
    let admin = admitted_id (sign_in t ~identity:(google "111") ~invite:(digest t.admin_token)) in
    issue t ~admin ~invite_id:"invite-2" ~token:(String.make 64 'b');
    let member = admitted_id (sign_in t ~identity:(google "222") ~invite:(digest (String.make 64 'b'))) in
    Unix.chmod t.log_path 0o400;
    Fun.protect
      ~finally:(fun () -> Unix.chmod t.log_path 0o600)
      (fun () ->
        match
          Z.commit
            t.zone
            { Z.author = Author.Authenticated (Principal.Human admin)
            ; kind = Authz_record.Kind.Principal
            ; body = get (Authz_principal_event.to_body (Authz_principal_event.Disabled { user_id = member }))
            }
        with
        | Ok (_ : Z.committed) -> Alcotest.fail "the read-only log took the record"
        | Error (_ : Z.error) -> ());
    Alcotest.(check string)
      "the zone that failed"
      "the authorization log cannot be trusted now, so nobody signs in"
      (outcome (sign_in t ~identity:(google "111") ~invite:None));
    let t =
      match Z.open_at_start ~now_ms:(now_ms t.clock) ~log_path:t.log_path ~store_path:t.store_path with
      | Ok zone -> { t with zone }
      | Error error -> Alcotest.failf "zone not reopened: %s" (Z.open_error_to_string error)
    in
    Alcotest.(check bool) "still active in the state" true (P.is_active (Z.snapshot t.zone).state.principals member);
    Alcotest.(check string)
      "blocked"
      (Printf.sprintf "a revocation of %s was given up and still blocks it" (User_id.to_string member))
      (outcome (sign_in t ~identity:(google "222") ~invite:None));
    Alcotest.(check string)
      "the Admin is not blocked"
      ("signed in " ^ User_id.to_string admin)
      (outcome (sign_in t ~identity:(google "111") ~invite:None)))
;;

(* Bytes another writer added to the log: the next commit finds the end moved
   and stops the log, and then nobody signs in. *)
let a_stopped_log_signs_nobody_in () =
  with_installation (fun t ->
    let admin = admitted_id (sign_in t ~identity:(google "111") ~invite:(digest t.admin_token)) in
    let invited = String.make 64 'c' in
    issue t ~admin ~invite_id:"invite-1" ~token:invited;
    Out_channel.with_open_gen [ Open_append; Open_binary ] 0o600 t.log_path (fun channel ->
      Out_channel.output_string channel "{}\n");
    (match issue_result t ~admin ~invite_id:"invite-2" ~token:(String.make 64 'b') with
     | Ok () -> Alcotest.fail "the zone wrote over a log another writer moved"
     | Error (_ : Z.error) -> ());
    let uncertain = "the authorization log cannot be trusted now, so nobody signs in" in
    Alcotest.(check string)
      "a person who joined"
      uncertain
      (outcome (sign_in t ~identity:(google "111") ~invite:None));
    (* The invitation was issued while the log was trusted. Its holder is
       refused before the admission is tried, as the person who joined is. *)
    Alcotest.(check string)
      "a person who holds an invitation"
      uncertain
      (outcome (sign_in t ~identity:(google "222") ~invite:(digest invited))))
;;

let conflicts_are_the_writer_races () =
  let user = get (User_id.of_string "user-1") in
  let invite = get (Invite_id.of_string "invite-1") in
  let registration = get (Registration_id.of_string "registration-1") in
  List.iter
    (fun (label, expected, refusal) -> Alcotest.(check bool) label expected (Login.is_conflict refusal))
    [ "spent", true, Login.Admission_refused (P.Invitation (Authz_invite_state.Invitation_consumed invite))
    ; "bound meanwhile", true, Login.Admission_refused (P.Identity_bound { identity = google "1"; user_id = user })
    ; "already joined", true, Login.Already_joined user
    ; ( "an entry spent"
      , true
      , Login.Admission_refused (P.Registration (Authz_registration_state.Registration_consumed registration)) )
    ; ( "an entry removed"
      , false
      , Login.Admission_refused (P.Registration (Authz_registration_state.Registration_removed registration)) )
    ; ( "an entry of another identity"
      , false
      , Login.Admission_refused (P.Registration (Authz_registration_state.Identity_differs registration)) )
    ; "revoked", false, Login.Admission_refused (P.Invitation (Authz_invite_state.Invitation_revoked invite))
    ; "not issued", false, Login.Admission_refused (P.Invitation (Authz_invite_state.Invitation_not_issued invite))
    ; "not invited", false, Login.Not_invited
    ; "disabled", false, Login.Disabled user
    ; "uncertain", false, Login.Uncertain
    ]
;;

let () =
  Alcotest.run
    "authz_login"
    [ ( "sign in"
      , [ Alcotest.test_case "the first Admin" `Quick the_first_admin_joins_and_then_signs_in
        ; Alcotest.test_case "nothing written" `Quick nothing_is_written_for_who_is_not_let_in
        ; Alcotest.test_case "spent once" `Quick an_invitation_is_spent_once
        ; Alcotest.test_case "a bound identity" `Quick a_bound_identity_with_an_invitation_leaves_it_open
        ; Alcotest.test_case "expired" `Quick an_expired_invitation_is_refused
        ; Alcotest.test_case "disabled" `Quick a_disabled_principal_does_not_sign_in
        ; Alcotest.test_case "a taken id" `Quick a_taken_id_is_drawn_again
        ; Alcotest.test_case "deleted, then again" `Quick a_deleted_identity_joins_again_as_someone_new
        ; Alcotest.test_case "a race" `Quick two_logins_race_for_one_invitation
        ; Alcotest.test_case "a registered identity" `Quick a_registered_identity_joins_as_a_member
        ; Alcotest.test_case "deleted, then a new entry" `Quick a_deleted_member_needs_a_new_entry
        ; Alcotest.test_case "an invitation and an entry race" `Quick
            an_invitation_and_an_entry_race_for_one_identity
        ; Alcotest.test_case "an Admin writes the allowlist" `Quick an_admin_writes_the_allowlist
        ; Alcotest.test_case "a taken registration id" `Quick a_taken_registration_id_is_drawn_again
        ; Alcotest.test_case "blocked" `Quick a_blocked_principal_does_not_sign_in
        ; Alcotest.test_case "a stopped log" `Quick a_stopped_log_signs_nobody_in
        ; Alcotest.test_case "conflicts" `Quick conflicts_are_the_writer_races
        ] )
    ]
;;
