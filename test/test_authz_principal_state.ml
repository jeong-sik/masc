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

(* An open Admin invitation. The local operator issues only Admin ones. *)
let issue t invite_id token =
  match
    I.apply
      t
      ~author:Author.Local_operator
      ~is_admin:(fun _ -> false)
      (E.Issued { invite_id; token_digest = E.Token_digest.of_token token; expires_at_ms; role = E.Admin })
  with
  | Ok t -> t
  | Error refusal -> Alcotest.failf "fixture invite refused: %s" (I.refusal_to_string refusal)
;;

let invites = issue (issue I.empty first "token-1") second "token-2"

let as_person user_id = Author.Authenticated (Principal.Human user_id)

let workspace = get (Workspace_id.of_string "workspace-1")

(* Each person gets the namespace named after them unless a case says. *)
let admit ?author ?(at_ms = at_ms) ?(invites = invites) ?(workspace_id = workspace) ?namespace t ~user_id
    ~identity ~invite_id =
  let author = Option.value author ~default:(as_person user_id) in
  let account_home_namespace =
    get (Account_home_namespace.of_string (Option.value namespace ~default:("ns-" ^ User_id.to_string user_id)))
  in
  P.admit
    t
    ~invites
    ~workspace_id:workspace
    ~author
    ~at_ms
    { A.user_id; identity; invite_id; membership = { A.workspace_id; account_home_namespace } }
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
   | Some { P.status = P.Disabled; _ } -> Alcotest.fail "the principal is disabled"
   | None -> Alcotest.fail "no principal was made");
  Alcotest.(check (option string))
    "the identity names the principal"
    (Some "alice")
    (Option.map User_id.to_string (P.find_identity principals (google "111")));
  Alcotest.(check bool) "an Admin" true (P.is_admin principals alice);
  (match P.find_membership principals alice with
   | Some { P.workspace_id; account_home_namespace } ->
     Alcotest.(check string) "the workspace" "workspace-1" (Workspace_id.to_string workspace_id);
     Alcotest.(check string) "the namespace" "ns-alice" (Account_home_namespace.to_string account_home_namespace)
   | None -> Alcotest.fail "no membership was made");
  Alcotest.(check (option string))
    "the namespace names the member"
    (Some "alice")
    (Option.map User_id.to_string
       (P.find_namespace principals (get (Account_home_namespace.of_string "ns-alice"))));
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
    (admit principals ~invites:spent ~user_id:bob ~identity:(google "111") ~invite_id:second);
  check_refused
    "another workspace"
    "the admission names the workspace workspace-2, and the installation is workspace-1"
    (admit
       principals
       ~invites:spent
       ~workspace_id:(get (Workspace_id.of_string "workspace-2"))
       ~user_id:bob
       ~identity:(google "222")
       ~invite_id:second);
  check_refused
    "a namespace given before"
    "the account home namespace ns-alice was given to alice"
    (admit principals ~invites:spent ~namespace:"ns-alice" ~user_id:bob ~identity:(google "222") ~invite_id:second)
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
      ; P.Workspace_differs { given = workspace; workspace_id = workspace }
      ; P.Namespace_taken { namespace = get (Account_home_namespace.of_string "ns-alice"); user_id = alice }
      ]
  in
  Alcotest.(check int) "every refusal reads differently" (List.length texts)
    (List.length (List.sort_uniq String.compare texts))
;;

(* ---- Admin assignments ---- *)

module R = Authz_admin_event

(* alice and bob, both Admins through the two Admin invitations. *)
let two_admins () =
  let { P.principals; invites; _ } = alice_in () in
  let { P.principals; _ } =
    admitted_ok (admit principals ~invites ~user_id:bob ~identity:(google "222") ~invite_id:second)
  in
  principals
;;

let nobody_held (_ : User_id.t) = false

let revoke ?(cause = R.Operational) ?(held = nobody_held) t ~by user_id =
  P.revoke_admin t ~author:(as_person by) ~held (R.Revoked { user_id; cause })
;;

let check_revocation_refused label expected result =
  match result with
  | Ok _ -> Alcotest.failf "%s: the revocation was taken" label
  | Error refusal -> Alcotest.(check string) label expected (P.revocation_refusal_to_string refusal)
;;

let an_admin_revokes_another () =
  let t = two_admins () in
  match revoke ~cause:R.Security_incident t ~by:alice bob with
  | Error refusal -> Alcotest.failf "refused: %s" (P.revocation_refusal_to_string refusal)
  | Ok after ->
    Alcotest.(check bool) "bob is no longer an Admin" false (P.is_admin after bob);
    Alcotest.(check bool) "alice still is" true (P.is_admin after alice);
    Alcotest.(check bool) "bob is still a principal" true (Option.is_some (P.find after bob));
    Alcotest.(check bool) "the state before is as it was" true (P.is_admin t bob);
    check_revocation_refused
      "bob revokes alice"
      "the principal human:bob is not an Admin, and only an Admin revokes an Admin assignment"
      (revoke after ~by:bob alice);
    check_revocation_refused "twice" "bob has no Admin assignment" (revoke after ~by:alice bob);
    check_revocation_refused
      "the last Admin"
      "alice is the last Admin, so the assignment stays"
      (revoke after ~by:alice alice)
;;

let an_admin_revokes_their_own_while_another_remains () =
  match revoke (two_admins ()) ~by:alice alice with
  | Error refusal -> Alcotest.failf "refused: %s" (P.revocation_refusal_to_string refusal)
  | Ok after ->
    Alcotest.(check bool) "alice is no longer an Admin" false (P.is_admin after alice);
    Alcotest.(check bool) "bob still is" true (P.is_admin after bob)
;;

module Pe = Authz_principal_event

let event ?(held = nobody_held) t ~by principal_event = P.apply_event t ~author:(as_person by) ~held principal_event

let applied_ok = function
  | Ok t -> t
  | Error refusal -> Alcotest.failf "refused: %s" (P.principal_refusal_to_string refusal)
;;

let check_event_refused label expected result =
  match result with
  | Ok _ -> Alcotest.failf "%s: the event was taken" label
  | Error refusal -> Alcotest.(check string) label expected (P.principal_refusal_to_string refusal)
;;

let status_name t user_id =
  match P.find t user_id with
  | Some { P.status = P.Active; _ } -> "active"
  | Some { P.status = P.Disabled; _ } -> "disabled"
  | None -> if P.is_deleted t user_id then "deleted" else "none"
;;

(* bob is held: the store gave up a revocation of bob, so bob writes nothing,
   and alice is the last Admin who can. *)
let a_held_admin_is_not_the_one_that_remains () =
  let held id = User_id.equal id bob in
  check_event_refused
    "alice disables herself"
    "alice is the last Admin that acts, so it stays"
    (event ~held (two_admins ()) ~by:alice (Pe.Disabled { user_id = alice }));
  check_event_refused
    "alice deletes herself"
    "alice is the last Admin that acts, so it stays"
    (event ~held (two_admins ()) ~by:alice (Pe.Deleted { user_id = alice; identity = google "111" }));
  check_event_refused
    "bob writes"
    "the principal human:bob is not an Admin, and only an Admin disables, enables, or deletes a principal"
    (event ~held (two_admins ()) ~by:bob (Pe.Disabled { user_id = alice }));
  check_revocation_refused
    "bob revokes"
    "the principal human:bob is not an Admin, and only an Admin revokes an Admin assignment"
    (revoke ~held (two_admins ()) ~by:bob alice);
  check_revocation_refused
    "alice revokes her own"
    "alice is the last Admin, so the assignment stays"
    (revoke ~held (two_admins ()) ~by:alice alice);
  match revoke ~held (two_admins ()) ~by:alice bob with
  | Error refusal -> Alcotest.failf "the held Admin was kept: %s" (P.revocation_refusal_to_string refusal)
  | Ok after -> Alcotest.(check bool) "bob is no longer an Admin" false (P.is_admin after bob)
;;

(* A disabled Admin keeps the assignment and does not act, and an enable gives
   back what the disable took. *)
let a_disable_and_an_enable () =
  let t = two_admins () in
  let disabled = applied_ok (event t ~by:alice (Pe.Disabled { user_id = bob })) in
  Alcotest.(check string) "bob" "disabled" (status_name disabled bob);
  Alcotest.(check bool) "bob does not act as an Admin" false (P.is_admin disabled bob);
  Alcotest.(check string) "the state before is as it was" "active" (status_name t bob);
  check_event_refused "twice" "bob is disabled already" (event disabled ~by:alice (Pe.Disabled { user_id = bob }));
  check_event_refused
    "bob writes"
    "the principal human:bob is not an Admin, and only an Admin disables, enables, or deletes a principal"
    (event disabled ~by:bob (Pe.Enabled { user_id = bob }));
  check_event_refused
    "alice disables herself"
    "alice is the last Admin that acts, so it stays"
    (event disabled ~by:alice (Pe.Disabled { user_id = alice }));
  check_revocation_refused
    "alice revokes her own"
    "alice is the last Admin, so the assignment stays"
    (revoke disabled ~by:alice alice);
  let enabled = applied_ok (event disabled ~by:alice (Pe.Enabled { user_id = bob })) in
  Alcotest.(check string) "bob again" "active" (status_name enabled bob);
  Alcotest.(check bool) "bob acts as an Admin again" true (P.is_admin enabled bob);
  check_event_refused "an enable of someone active" "bob is not disabled" (event enabled ~by:alice (Pe.Enabled { user_id = bob }));
  check_event_refused
    "someone who never joined"
    "there is no principal carol"
    (event t ~by:alice (Pe.Disabled { user_id = get (User_id.of_string "carol") }));
  check_event_refused
    "the local operator"
    "the local operator is not an Admin, and only an Admin disables, enables, or deletes a principal"
    (P.apply_event t ~author:Author.Local_operator ~held:nobody_held (Pe.Disabled { user_id = bob }))
;;

let third = get (Invite_id.of_string "invite-3")

(* A deletion frees the identity, which may join again as a new principal
   through a new invitation. The user id and the namespace stay given. *)
let a_deletion () =
  let t = two_admins () in
  check_event_refused
    "another identity"
    "the deletion of bob names the identity google:999, which is not the one it is bound to"
    (event t ~by:alice (Pe.Deleted { user_id = bob; identity = google "999" }));
  let deleted = applied_ok (event t ~by:alice (Pe.Deleted { user_id = bob; identity = google "222" })) in
  Alcotest.(check string) "bob" "deleted" (status_name deleted bob);
  Alcotest.(check bool) "no Admin assignment" false (P.is_admin deleted bob);
  Alcotest.(check bool) "not active" false (P.is_active deleted bob);
  Alcotest.(check bool) "the identity is free" true (Option.is_none (P.find_identity deleted (google "222")));
  Alcotest.(check bool) "no membership" true (Option.is_none (P.find_membership deleted bob));
  Alcotest.(check (option string))
    "the namespace stays given"
    (Some "bob")
    (Option.map User_id.to_string (P.find_namespace deleted (get (Account_home_namespace.of_string "ns-bob"))));
  check_event_refused
    "twice"
    "there is no principal bob"
    (event deleted ~by:alice (Pe.Deleted { user_id = bob; identity = google "222" }));
  check_event_refused
    "alice deletes herself"
    "alice is the last Admin that acts, so it stays"
    (event deleted ~by:alice (Pe.Deleted { user_id = alice; identity = google "111" }));
  let open_third = issue invites third "token-3" in
  let bob_again = get (User_id.of_string "bob-2") in
  check_refused
    "the id of the deleted principal"
    "the user id bob was given before"
    (admit deleted ~invites:open_third ~namespace:"ns-bob-new" ~user_id:bob ~identity:(google "222") ~invite_id:third);
  check_refused
    "the namespace of the deleted principal"
    "the account home namespace ns-bob was given to bob"
    (admit deleted ~invites:open_third ~namespace:"ns-bob" ~user_id:bob_again ~identity:(google "222") ~invite_id:third);
  let { P.principals = rejoined; _ } =
    admitted_ok (admit deleted ~invites:open_third ~user_id:bob_again ~identity:(google "222") ~invite_id:third)
  in
  Alcotest.(check (option string))
    "the identity names the new principal"
    (Some "bob-2")
    (Option.map User_id.to_string (P.find_identity rejoined (google "222")));
  Alcotest.(check bool) "the new principal is an Admin" true (P.is_admin rejoined bob_again)
;;

let who_may_revoke () =
  let t = two_admins () in
  List.iter
    (fun (label, author, expected) ->
      check_revocation_refused
        label
        expected
        (P.revoke_admin t ~author ~held:nobody_held (R.Revoked { user_id = bob; cause = R.Operational })))
    [ ( "the local operator"
      , Author.Local_operator
      , "the local operator is not an Admin, and only an Admin revokes an Admin assignment" )
    ; ( "a service"
      , Author.Authenticated (Principal.Service (get (Service_id.of_string "keeper-1")))
      , "the principal service:keeper-1 is not an Admin, and only an Admin revokes an Admin assignment" )
    ; ( "someone who never joined"
      , as_person (get (User_id.of_string "carol"))
      , "the principal human:carol is not an Admin, and only an Admin revokes an Admin assignment" )
    ];
  check_revocation_refused
    "someone who is not an Admin"
    "carol has no Admin assignment"
    (revoke t ~by:alice (get (User_id.of_string "carol")))
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
    ; ( "admin assignment"
      , [ Alcotest.test_case "revokes another" `Quick an_admin_revokes_another
        ; Alcotest.test_case "revokes their own" `Quick an_admin_revokes_their_own_while_another_remains
        ; Alcotest.test_case "a held Admin does not remain" `Quick a_held_admin_is_not_the_one_that_remains
        ; Alcotest.test_case "who may revoke" `Quick who_may_revoke
        ] )
    ; ( "principal records"
      , [ Alcotest.test_case "disable and enable" `Quick a_disable_and_an_enable
        ; Alcotest.test_case "deletion" `Quick a_deletion
        ] )
    ]
;;
