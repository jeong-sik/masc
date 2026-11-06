(* The invitations that the invite records add up to: who may write which event
   in this layer, that an invite id and a token digest name one invitation for
   good, and what a revocation does. No files, clock, or network. *)

open Authz_types
open Authz_records
module E = Authz_invite_event
module I = Authz_invite_state

let get = function
  | Ok value -> value
  | Error _ -> Alcotest.fail "fixture id rejected by Authz_id"
;;

let invite_of text = get (Invite_id.of_string text)
let first = invite_of "invite-1"
let second = invite_of "invite-2"
let digest_of = E.Token_digest.of_token
let alice = Principal.Human (get (User_id.of_string "alice"))

let issued ?(invite_id = first) ?(token = "token-1") ?(role = E.Admin) () =
  E.Issued { invite_id; token_digest = digest_of token; expires_at_ms = 10; role }
;;

let refusal_name : I.refusal -> string = function
  | I.Already_issued id -> "already issued " ^ Invite_id.to_string id
  | I.Token_digest_taken id -> "token digest taken by " ^ Invite_id.to_string id
  | I.Not_issued id -> "not issued " ^ Invite_id.to_string id
  | I.Already_revoked id -> "already revoked " ^ Invite_id.to_string id
  | I.Already_consumed id -> "already consumed " ^ Invite_id.to_string id
  | I.Local_operator_invites_only_admins -> "local operator invites only admins"
  | I.Author_is_not_an_admin principal -> "not an admin " ^ Principal.to_string principal
  | I.Not_an_invite_author _ -> "not an invite author"
;;

(* Only alice is an Admin in these checks. *)
let alice_id = get (User_id.of_string "alice")
let is_admin id = User_id.equal id alice_id

let apply_ok ?(author = Author.Local_operator) t event =
  match I.apply t ~author ~is_admin event with
  | Ok t -> t
  | Error refusal -> Alcotest.failf "refused: %s" (refusal_name refusal)
;;

let check_refused label ?(author = Author.Local_operator) t event expected =
  match I.apply t ~author ~is_admin event with
  | Ok _ -> Alcotest.failf "%s: the event was taken" label
  | Error refusal -> Alcotest.(check string) label expected (refusal_name refusal)
;;

let status_name = function
  | None -> "none"
  | Some { I.status = I.Open; _ } -> "open"
  | Some { I.status = I.Revoked; _ } -> "revoked"
  | Some { I.status = I.Consumed user_id; _ } -> "consumed by " ^ User_id.to_string user_id
;;

let check_status label t invite_id expected =
  Alcotest.(check string) label expected (status_name (I.find t invite_id))
;;

let the_local_operator_issues_an_admin_invitation () =
  let t = apply_ok I.empty (issued ()) in
  (match I.find t first with
   | Some
       { I.status = I.Open
       ; role = E.Admin
       ; expires_at_ms = 10
       ; issuer = I.Local_operator_issued
       ; token_digest
       } ->
     Alcotest.(check bool) "the digest" true (E.Token_digest.equal token_digest (digest_of "token-1"))
   | Some _ | None -> Alcotest.fail "the invitation is not open as issued");
  (match I.find_by_token_digest t (digest_of "token-1") with
   | Some (id, _) -> Alcotest.(check string) "found by its digest" "invite-1" (Invite_id.to_string id)
   | None -> Alcotest.fail "the invitation is not found by its digest");
  Alcotest.(check bool)
    "another digest finds nothing"
    true
    (Option.is_none (I.find_by_token_digest t (digest_of "token-2")));
  check_status "another id finds nothing" t second "none"
;;

let who_may_write_what () =
  check_refused
    "a member by the local operator"
    I.empty
    (issued ~role:E.Member ())
    "local operator invites only admins";
  let bob = Principal.Human (get (User_id.of_string "bob")) in
  let keeper = Principal.Service (get (Service_id.of_string "keeper-1")) in
  List.iter
    (fun (author, expected) ->
      List.iter
        (fun event ->
          check_refused
            ("an authenticated principal that is not an Admin: " ^ expected)
            ~author:(Author.Authenticated author)
            (apply_ok I.empty (issued ()))
            event
            expected)
        [ issued ~invite_id:second ~token:"token-2" (); E.Revoked { invite_id = first } ])
    [ bob, "not an admin human:bob"; keeper, "not an admin service:keeper-1" ];
  List.iter
    (fun author ->
      check_refused "a system author" ~author I.empty (issued ()) "not an invite author")
    [ Author.System_cron; Author.System_maintenance; Author.System_migration ]
;;

let an_id_and_a_digest_name_one_invitation_for_good () =
  let t = apply_ok I.empty (issued ()) in
  check_refused "the same id again" t (issued ~token:"token-2" ()) "already issued invite-1";
  check_refused
    "the same digest under another id"
    t
    (issued ~invite_id:second ())
    "token digest taken by invite-1";
  let revoked = apply_ok t (E.Revoked { invite_id = first }) in
  check_refused
    "the id of a revoked invitation"
    revoked
    (issued ~token:"token-2" ())
    "already issued invite-1";
  check_refused
    "the digest of a revoked invitation"
    revoked
    (issued ~invite_id:second ())
    "token digest taken by invite-1";
  let both = apply_ok revoked (issued ~invite_id:second ~token:"token-2" ()) in
  check_status "the first stays revoked" both first "revoked";
  check_status "the second is open" both second "open"
;;

let a_revocation () =
  check_refused "an invitation never issued" I.empty (E.Revoked { invite_id = first }) "not issued invite-1";
  let t = apply_ok I.empty (issued ()) in
  let revoked = apply_ok t (E.Revoked { invite_id = first }) in
  check_status "revoked" revoked first "revoked";
  (match I.find_by_token_digest revoked (digest_of "token-1") with
   | Some (_, { I.status = I.Revoked; _ }) -> ()
   | Some _ | None -> Alcotest.fail "the digest does not find the revoked invitation");
  check_refused "twice" revoked (E.Revoked { invite_id = first }) "already revoked invite-1";
  check_status "the state before the revocation is as it was" t first "open"
;;

let consume_name = function
  | Ok (_, role) -> "ok " ^ E.role_label role
  | Error refusal -> I.consume_refusal_to_string refusal
;;

(* An admission spends an open invitation once, and gives the role the
   invitation was issued with. *)
let an_admission_spends_an_invitation_once () =
  let bob = get (User_id.of_string "bob") in
  let t = apply_ok I.empty (issued ()) in
  Alcotest.(check string)
    "an invitation never issued"
    "no invitation invite-2 was issued"
    (consume_name (I.consume t second ~user_id:bob ~at_ms:9));
  Alcotest.(check string)
    "at the expiry"
    "the invitation invite-1 expired at 10, and the admission is at 10"
    (consume_name (I.consume t first ~user_id:bob ~at_ms:10));
  match I.consume t first ~user_id:bob ~at_ms:9 with
  | Error refusal -> Alcotest.failf "refused: %s" (I.consume_refusal_to_string refusal)
  | Ok (spent, role) ->
    Alcotest.(check string) "the role" "admin" (E.role_label role);
    check_status "spent" spent first "consumed by bob";
    check_status "the state before is as it was" t first "open";
    Alcotest.(check string)
      "twice"
      "the invitation invite-1 was spent by an admission before"
      (consume_name (I.consume spent first ~user_id:bob ~at_ms:9));
    check_refused "a spent invitation is not revoked" spent (E.Revoked { invite_id = first })
      "already consumed invite-1";
    let revoked = apply_ok t (E.Revoked { invite_id = first }) in
    Alcotest.(check string)
      "a revoked invitation"
      "the invitation invite-1 was revoked"
      (consume_name (I.consume revoked first ~user_id:bob ~at_ms:9))
;;

(* An Admin issues invitations of either role and revokes any invitation, the
   one the local operator issued included. *)
let an_admin_invites_and_revokes () =
  let by_alice = Author.Authenticated alice in
  let t = apply_ok I.empty (issued ()) in
  let t =
    apply_ok ~author:by_alice t (issued ~invite_id:second ~token:"token-2" ~role:E.Member ())
  in
  (match I.find t second with
   | Some { I.status = I.Open; role = E.Member; _ } -> ()
   | Some _ | None -> Alcotest.fail "the Member invitation is not open");
  let t = apply_ok ~author:by_alice t (E.Revoked { invite_id = first }) in
  check_status "the invitation of the local operator" t first "revoked";
  check_refused
    "the same digest again"
    ~author:by_alice
    t
    (issued ~invite_id:(invite_of "invite-3") ~token:"token-2" ())
    "token digest taken by invite-2"
;;

let issuer_name = function
  | None -> "none"
  | Some { I.issuer = I.Local_operator_issued; _ } -> "local operator"
  | Some { I.issuer = I.Admin_issued user_id; _ } -> "admin " ^ User_id.to_string user_id
;;

(* The owner of an invitation is who wrote its issue (design 4.1): the local
   operator or the Admin. A revocation and an admission do not change it. *)
let an_invitation_keeps_who_issued_it () =
  let by_operator = apply_ok I.empty (issued ()) in
  let both =
    apply_ok
      ~author:(Author.Authenticated alice)
      by_operator
      (issued ~invite_id:second ~token:"token-2" ~role:E.Member ())
  in
  Alcotest.(check string) "issued by the local operator" "local operator" (issuer_name (I.find both first));
  Alcotest.(check string) "issued by an Admin" "admin alice" (issuer_name (I.find both second));
  let revoked = apply_ok both (E.Revoked { invite_id = first }) in
  Alcotest.(check string) "after its revocation" "local operator" (issuer_name (I.find revoked first));
  match I.consume both second ~user_id:alice_id ~at_ms:1 with
  | Ok (spent, _role) ->
    Alcotest.(check string) "after an admission spends it" "admin alice" (issuer_name (I.find spent second))
  | Error _ -> Alcotest.fail "the admission was refused"
;;

let spent_by_name t user_id =
  match I.find_consumed_by t user_id with
  | None -> "none"
  | Some (invite_id, invitation) -> Invite_id.to_string invite_id ^ " " ^ status_name (Some invitation)
;;

(* The invitation a principal joined through is found by that principal, and
   only once it is spent: an open or revoked invitation names no one. *)
let an_invitation_is_found_by_who_spent_it () =
  let bob = get (User_id.of_string "bob") in
  let t = apply_ok I.empty (issued ()) in
  let t = apply_ok t (issued ~invite_id:second ~token:"token-2" ()) in
  Alcotest.(check string) "before any admission" "none" (spent_by_name t bob);
  let t = apply_ok t (E.Revoked { invite_id = second }) in
  Alcotest.(check string) "a revoked invitation" "none" (spent_by_name t bob);
  match I.consume t first ~user_id:bob ~at_ms:1 with
  | Error refusal -> Alcotest.failf "refused: %s" (I.consume_refusal_to_string refusal)
  | Ok (spent, _role) ->
    Alcotest.(check string) "the one bob spent" "invite-1 consumed by bob" (spent_by_name spent bob);
    Alcotest.(check string) "another principal" "none" (spent_by_name spent alice_id)
;;

let refusals_are_told_apart () =
  let texts =
    List.map
      I.refusal_to_string
      [ I.Already_issued first
      ; I.Token_digest_taken first
      ; I.Not_issued first
      ; I.Already_revoked first
      ; I.Already_consumed first
      ; I.Local_operator_invites_only_admins
      ; I.Author_is_not_an_admin alice
      ; I.Not_an_invite_author Author.System_cron
      ]
  in
  Alcotest.(check int)
    "each refusal has its own text"
    (List.length texts)
    (List.length (List.sort_uniq String.compare texts))
;;

let () =
  Alcotest.run
    "authz_invite_state"
    [ ( "invitations"
      , [ Alcotest.test_case "admin by the local operator" `Quick
            the_local_operator_issues_an_admin_invitation
        ; Alcotest.test_case "who may write" `Quick who_may_write_what
        ; Alcotest.test_case "one invitation for good" `Quick
            an_id_and_a_digest_name_one_invitation_for_good
        ; Alcotest.test_case "revocation" `Quick a_revocation
        ; Alcotest.test_case "by an Admin" `Quick an_admin_invites_and_revokes
        ; Alcotest.test_case "spent once" `Quick an_admission_spends_an_invitation_once
        ; Alcotest.test_case "who issued it" `Quick an_invitation_keeps_who_issued_it
        ; Alcotest.test_case "who spent it" `Quick an_invitation_is_found_by_who_spent_it
        ; Alcotest.test_case "texts" `Quick refusals_are_told_apart
        ] )
    ]
;;
