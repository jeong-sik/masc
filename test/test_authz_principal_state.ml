(* The principals that admissions add up to: what one admission makes, the order
   of its checks, and that a user id and an identity each name one principal.
   No files, clock, or network. *)

open Authz_types
open Authz_records
module E = Authz_invite_event
module I = Authz_invite_state
module P = Authz_principal_state
module X = Authz_external_identity
module A = Authz_admission_event

let get = function
  | Ok value -> value
  | Error _ -> Alcotest.fail "fixture value rejected"
;;

let alice = get (User_id.of_string "alice")
let bob = get (User_id.of_string "bob")
let first = get (Invite_id.of_string "invite-1")
let second = get (Invite_id.of_string "invite-2")
let unknown = get (Invite_id.of_string "invite-9")
let google sub = get (X.google ~sub)
let github user_id = get (X.github ~user_id)
let expires_at_ms = 100
let at_ms = 50

(* Two open Admin invitations. The local operator issues only Admin ones. *)
let invites =
  let issue t invite_id token =
    match
      I.apply
        t
        ~author:Author.Local_operator
        (E.Issued { invite_id; token_digest = E.Token_digest.of_token token; expires_at_ms; role = E.Admin })
    with
    | Ok t -> t
    | Error refusal -> Alcotest.failf "fixture invite refused: %s" (I.refusal_to_string refusal)
  in
  issue (issue I.empty first "token-1") second "token-2"
;;

let as_person user_id = Author.Authenticated (Principal.Human user_id)

let admit ?author ?(at_ms = at_ms) ?(invites = invites) t ~user_id ~identity ~invite_id =
  let author = Option.value author ~default:(as_person user_id) in
  P.admit t ~invites ~author ~at_ms { A.user_id; identity; invite_id }
;;

let admitted_ok = function
  | Ok admitted -> admitted
  | Error refusal -> Alcotest.failf "refused: %s" (P.refusal_to_string refusal)
;;

let check_refused label expected result =
  match result with
  | Ok _ -> Alcotest.failf "%s: the admission was taken" label
  | Error refusal -> Alcotest.(check string) label expected (P.refusal_to_string refusal)
;;

let alice_in () = admitted_ok (admit P.empty ~user_id:alice ~identity:(google "111") ~invite_id:first)

let an_admission_makes_an_admin () =
  let { P.principals; invites = spent; role } = alice_in () in
  Alcotest.(check string) "the role of the invitation" "admin" (E.role_label role);
  (match P.find principals alice with
   | Some { P.identity; status = P.Active } ->
     Alcotest.(check string) "the identity" "google:111" (X.to_string identity)
   | None -> Alcotest.fail "no principal was made");
  Alcotest.(check (option string))
    "the identity names the principal"
    (Some "alice")
    (Option.map User_id.to_string (P.find_identity principals (google "111")));
  Alcotest.(check bool) "an Admin" true (P.is_admin principals alice);
  Alcotest.(check bool) "nobody else" false (P.is_admin principals bob);
  (match I.find spent first with
   | Some { I.status = I.Consumed by; _ } ->
     Alcotest.(check string) "spent by" "alice" (User_id.to_string by)
   | Some _ | None -> Alcotest.fail "the invitation is not spent");
  (match I.find invites first with
   | Some { I.status = I.Open; _ } -> ()
   | Some _ | None -> Alcotest.fail "the invitations before are not as they were");
  Alcotest.(check bool) "the state before is as it was" true (Option.is_none (P.find P.empty alice))
;;

let two_people_join () =
  let { P.principals; invites; _ } = alice_in () in
  let { P.principals; _ } =
    admitted_ok (admit principals ~invites ~user_id:bob ~identity:(github 583231) ~invite_id:second)
  in
  Alcotest.(check (option string))
    "the GitHub identity"
    (Some "bob")
    (Option.map User_id.to_string (P.find_identity principals (github 583231)));
  Alcotest.(check (option string))
    "the Google identity"
    (Some "alice")
    (Option.map User_id.to_string (P.find_identity principals (google "111")));
  Alcotest.(check (option string))
    "the same digits with another provider"
    None
    (Option.map User_id.to_string (P.find_identity principals (google "583231")))
;;

let what_is_refused () =
  let { P.principals; invites = spent; _ } = alice_in () in
  check_refused
    "written by another person"
    "the principal human:bob wrote the admission of alice, which only that person writes"
    (admit P.empty ~author:(as_person bob) ~user_id:alice ~identity:(google "111") ~invite_id:first);
  check_refused
    "written by the local operator"
    "the local operator wrote the admission of alice, which only that person writes"
    (admit P.empty ~author:Author.Local_operator ~user_id:alice ~identity:(google "111") ~invite_id:first);
  check_refused
    "an invitation never issued"
    "no invitation invite-9 was issued"
    (admit P.empty ~user_id:alice ~identity:(google "111") ~invite_id:unknown);
  check_refused
    "at the expiry"
    "the invitation invite-1 expired at 100, and the admission is at 100"
    (admit P.empty ~at_ms:expires_at_ms ~user_id:alice ~identity:(google "111") ~invite_id:first);
  Alcotest.(check bool)
    "just before the expiry"
    true
    (Result.is_ok
       (admit P.empty ~at_ms:(expires_at_ms - 1) ~user_id:alice ~identity:(google "111") ~invite_id:first));
  check_refused
    "an invitation spent before"
    "the invitation invite-1 was spent by an admission before"
    (admit principals ~invites:spent ~user_id:bob ~identity:(google "222") ~invite_id:first);
  check_refused
    "a user id given before"
    "the user id alice was given before"
    (admit principals ~invites:spent ~user_id:alice ~identity:(google "222") ~invite_id:second);
  check_refused
    "an identity bound before"
    "the identity google:111 is bound to alice"
    (admit principals ~invites:spent ~user_id:bob ~identity:(google "111") ~invite_id:second)
;;

(* Each case fails two checks, and the earlier check in the order of {!P.admit}
   is the result. *)
let the_order_of_the_checks () =
  let { P.principals; invites = spent; _ } = alice_in () in
  check_refused
    "the author before the invitation"
    "the principal human:bob wrote the admission of alice, which only that person writes"
    (admit P.empty ~author:(as_person bob) ~user_id:alice ~identity:(google "111") ~invite_id:unknown);
  check_refused
    "the invitation before the user id"
    "the invitation invite-1 was spent by an admission before"
    (admit principals ~invites:spent ~user_id:alice ~identity:(google "222") ~invite_id:first);
  check_refused
    "the user id before the identity"
    "the user id alice was given before"
    (admit principals ~invites:spent ~user_id:alice ~identity:(google "111") ~invite_id:second)
;;

let refusals_are_told_apart () =
  let texts =
    List.map
      P.refusal_to_string
      [ P.Author_is_not_the_person { author = Author.System_cron; user_id = alice }
      ; P.Invitation (I.Invitation_not_issued first)
      ; P.Invitation (I.Invitation_revoked first)
      ; P.Invitation (I.Invitation_consumed first)
      ; P.Invitation (I.Invitation_expired { invite_id = first; expires_at_ms; at_ms })
      ; P.User_id_taken alice
      ; P.Identity_bound { identity = google "111"; user_id = alice }
      ]
  in
  Alcotest.(check int) "every refusal reads differently" (List.length texts)
    (List.length (List.sort_uniq String.compare texts))
;;

let () =
  Alcotest.run
    "authz_principal_state"
    [ ( "admission"
      , [ Alcotest.test_case "makes an Admin" `Quick an_admission_makes_an_admin
        ; Alcotest.test_case "two people" `Quick two_people_join
        ; Alcotest.test_case "refused" `Quick what_is_refused
        ; Alcotest.test_case "the order of the checks" `Quick the_order_of_the_checks
        ; Alcotest.test_case "refusals told apart" `Quick refusals_are_told_apart
        ] )
    ]
;;
