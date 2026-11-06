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
  | I.Local_operator_invites_only_admins -> "local operator invites only admins"
  | I.Authenticated_author_not_read principal ->
    "authenticated author not read " ^ Principal.to_string principal
  | I.Not_an_invite_author _ -> "not an invite author"
;;

let apply_ok ?(author = Author.Local_operator) t event =
  match I.apply t ~author event with
  | Ok t -> t
  | Error refusal -> Alcotest.failf "refused: %s" (refusal_name refusal)
;;

let check_refused label ?(author = Author.Local_operator) t event expected =
  match I.apply t ~author event with
  | Ok _ -> Alcotest.failf "%s: the event was taken" label
  | Error refusal -> Alcotest.(check string) label expected (refusal_name refusal)
;;

let status_name = function
  | None -> "none"
  | Some { I.status = I.Open; _ } -> "open"
  | Some { I.status = I.Revoked; _ } -> "revoked"
;;

let check_status label t invite_id expected =
  Alcotest.(check string) label expected (status_name (I.find t invite_id))
;;

let the_local_operator_issues_an_admin_invitation () =
  let t = apply_ok I.empty (issued ()) in
  (match I.find t first with
   | Some { I.status = I.Open; role = E.Admin; expires_at_ms = 10; token_digest } ->
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
  List.iter
    (fun event ->
      check_refused
        "an authenticated principal"
        ~author:(Author.Authenticated alice)
        (apply_ok I.empty (issued ()))
        event
        "authenticated author not read human:alice")
    [ issued ~invite_id:second ~token:"token-2" (); E.Revoked { invite_id = first } ];
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

let refusals_are_told_apart () =
  let texts =
    List.map
      I.refusal_to_string
      [ I.Already_issued first
      ; I.Token_digest_taken first
      ; I.Not_issued first
      ; I.Already_revoked first
      ; I.Local_operator_invites_only_admins
      ; I.Authenticated_author_not_read alice
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
        ; Alcotest.test_case "texts" `Quick refusals_are_told_apart
        ] )
    ]
;;
