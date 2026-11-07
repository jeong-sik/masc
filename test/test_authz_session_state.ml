(* The browser sessions that the session records add up to: who may write which
   event, that an id names one session for good, how a new sign-in ends the
   session its browser held, and when a session expires. No files, clock, or
   network. *)

open Authz_types
open Authz_records
module E = Authz_session_event
module S = Authz_session_state

let get = function
  | Ok value -> value
  | Error _ -> Alcotest.fail "fixture id rejected by Authz_id"
;;

let session_of text = get (Session_id.of_string text)
let first = session_of "session-1"
let second = session_of "session-2"
let third = session_of "session-3"
let user text = get (User_id.of_string text)
let alice_id = user "alice"
let bob_id = user "bob"
let dave_id = user "dave"
let alice = Author.Authenticated (Principal.Human alice_id)
let bob = Author.Authenticated (Principal.Human bob_id)
let dave = Author.Authenticated (Principal.Human dave_id)

(* Dave is disabled in these checks; everybody else is active. *)
let is_active id = not (User_id.equal id dave_id)
let issued_at = 1_000

let issued ?(session_id = first) ?(user_id = alice_id) ?(secret = "secret-1") ?replaces () =
  E.Issued { session_id; user_id; secret_digest = E.Secret_digest.of_secret secret; replaces }
;;

let revoked ?(session_id = first) () = E.Revoked { session_id }

let refusal_name : S.refusal -> string = function
  | S.Already_issued id -> "already issued " ^ Session_id.to_string id
  | S.Issued_for_another { author; user_id } ->
    Printf.sprintf "%s issues for %s" (User_id.to_string author) (User_id.to_string user_id)
  | S.User_not_active id -> "not active " ^ User_id.to_string id
  | S.Not_issued id -> "not issued " ^ Session_id.to_string id
  | S.Already_ended id -> "already ended " ^ Session_id.to_string id
  | S.Not_the_owner { session_id; author } ->
    Printf.sprintf "%s does not own %s" (User_id.to_string author) (Session_id.to_string session_id)
  | S.Not_a_human principal -> "not a human " ^ Principal.to_string principal
  | S.Not_a_session_author _ -> "not a session author"
;;

let apply_ok ?(author = alice) ?(at_ms = issued_at) t event =
  match S.apply t ~author ~at_ms ~is_active event with
  | Ok t -> t
  | Error refusal -> Alcotest.failf "refused: %s" (refusal_name refusal)
;;

let check_refused label ?(author = alice) t event expected =
  match S.apply t ~author ~at_ms:issued_at ~is_active event with
  | Ok _ -> Alcotest.failf "%s: the event was taken" label
  | Error refusal -> Alcotest.(check string) label expected (refusal_name refusal)
;;

let status_name = function
  | None -> "none"
  | Some { S.status = S.Open; _ } -> "open"
  | Some { S.status = S.Revoked; _ } -> "revoked"
  | Some { S.status = S.Replaced by; _ } -> "replaced by " ^ Session_id.to_string by
;;

let check_status label t session_id expected =
  Alcotest.(check string) label expected (status_name (S.find t session_id))
;;

let active_name t session_id ~now_ms =
  match S.find_active t session_id ~now_ms with
  | Ok { S.user_id; _ } -> "active for " ^ User_id.to_string user_id
  | Error S.Unknown -> "unknown"
  | Error S.Ended -> "ended"
  | Error S.Expired -> "expired"
;;

let check_active label t session_id ~now_ms expected =
  Alcotest.(check string) label expected (active_name t session_id ~now_ms)
;;

(* ---- the checks ---- *)

let a_principal_signs_in () =
  let t = apply_ok S.empty (issued ()) in
  (match S.find t first with
   | Some { S.status = S.Open; user_id; secret_digest; issued_at_ms } ->
     Alcotest.(check string) "the user" "alice" (User_id.to_string user_id);
     Alcotest.(check bool)
       "the digest"
       true
       (E.Secret_digest.equal secret_digest (E.Secret_digest.of_secret "secret-1"));
     Alcotest.(check int) "the time of the record" issued_at issued_at_ms
   | Some _ | None -> Alcotest.fail "the session is not open as written");
  check_active "acts now" t first ~now_ms:issued_at "active for alice";
  check_active "another id" t second ~now_ms:issued_at "unknown";
  let t = apply_ok ~author:bob t (issued ~session_id:second ~user_id:bob_id ()) in
  check_active "a second principal" t second ~now_ms:issued_at "active for bob";
  check_active "the first stays" t first ~now_ms:issued_at "active for alice";
  let t = apply_ok t (issued ~session_id:third ~secret:"secret-3" ()) in
  check_active "a second browser of the same principal" t third ~now_ms:issued_at "active for alice";
  check_active "the first browser stays" t first ~now_ms:issued_at "active for alice"
;;

let who_may_write_what () =
  let open_one = apply_ok S.empty (issued ()) in
  let keeper = Principal.Service (get (Service_id.of_string "keeper-1")) in
  List.iter
    (fun (name, author, expected) ->
      check_refused (name ^ " issues") ~author S.empty (issued ()) expected;
      check_refused (name ^ " revokes") ~author open_one (revoked ()) expected)
    [ "a service", Author.Authenticated keeper, "not a human service:keeper-1"
    ; "the local operator", Author.Local_operator, "not a session author"
    ; "system cron", Author.System_cron, "not a session author"
    ; "system maintenance", Author.System_maintenance, "not a session author"
    ; "system migration", Author.System_migration, "not a session author"
    ];
  check_refused "a session for another" ~author:bob S.empty (issued ()) "bob issues for alice";
  check_refused
    "a disabled principal"
    ~author:dave
    S.empty
    (issued ~user_id:dave_id ())
    "not active dave";
  check_refused "another revokes" ~author:bob open_one (revoked ()) "bob does not own session-1";
  check_status "nothing changed" open_one first "open"
;;

let one_session_per_id () =
  let t = apply_ok S.empty (issued ()) in
  check_refused "the id again" ~author:bob t (issued ~user_id:bob_id ()) "already issued session-1";
  let t = apply_ok t (revoked ()) in
  check_refused "the id of a revoked one" t (issued ~secret:"secret-2" ()) "already issued session-1";
  let t = apply_ok t (issued ~session_id:second ()) in
  let t = apply_ok t (issued ~session_id:third ~replaces:second ()) in
  check_refused "the id of a replaced one" t (issued ~session_id:second ()) "already issued session-2"
;;

let a_sign_out () =
  let t = apply_ok S.empty (issued ()) in
  let t = apply_ok t (revoked ()) in
  check_status "revoked" t first "revoked";
  check_active "no longer acts" t first ~now_ms:issued_at "ended";
  check_refused "revoked twice" t (revoked ()) "already ended session-1";
  check_refused "never issued" t (revoked ~session_id:second ()) "not issued session-2"
;;

(* The same browser signs in again, as another principal: the new session ends
   the old one in the same record. *)
let a_new_sign_in_ends_the_old_session () =
  let t = apply_ok ~author:bob S.empty (issued ~user_id:bob_id ()) in
  let t = apply_ok t (issued ~session_id:second ~replaces:first ()) in
  check_status "the old one" t first "replaced by session-2";
  check_active "the old one no longer acts" t first ~now_ms:issued_at "ended";
  check_active "the new one acts" t second ~now_ms:issued_at "active for alice";
  check_refused "revoking the replaced one" ~author:bob t (revoked ()) "already ended session-1";
  check_refused
    "replacing a replaced one"
    t
    (issued ~session_id:third ~replaces:first ())
    "already ended session-1";
  let t = apply_ok t (revoked ~session_id:second ()) in
  check_refused
    "replacing a revoked one"
    t
    (issued ~session_id:third ~replaces:second ())
    "already ended session-2";
  check_refused
    "replacing one never issued"
    t
    (issued ~session_id:third ~replaces:(session_of "session-9") ())
    "not issued session-9";
  check_refused "replacing itself" t (issued ~session_id:third ~replaces:third ()) "not issued session-3";
  check_status "a refused issue issues nothing" t third "none"
;;

let a_session_ends_after_its_lifetime () =
  let t = apply_ok S.empty (issued ()) in
  let last = issued_at + S.lifetime_ms - 1 in
  check_active "the last moment" t first ~now_ms:last "active for alice";
  check_active "at its lifetime" t first ~now_ms:(last + 1) "expired";
  check_active "long after" t first ~now_ms:(last + S.lifetime_ms) "expired";
  Alcotest.(check int) "seven days" (7 * 24 * 60 * 60 * 1000) S.lifetime_ms;
  let later = issued_at + 1_000 in
  let t = apply_ok ~at_ms:later t (issued ~session_id:second ()) in
  check_active "from the time of its own record" t second ~now_ms:(later + S.lifetime_ms - 1) "active for alice";
  (* An expired session is still open: its owner may sign it out, and a new
     sign-in of its browser ends it. *)
  let t = apply_ok t (revoked ()) in
  check_status "an expired one signed out" t first "revoked";
  let t = apply_ok t (issued ~session_id:third ~replaces:second ()) in
  check_status "an expired one replaced" t second "replaced by session-3"
;;

let refusals_are_told_apart () =
  let texts =
    List.map
      S.refusal_to_string
      [ S.Already_issued first
      ; S.Issued_for_another { author = bob_id; user_id = alice_id }
      ; S.User_not_active dave_id
      ; S.Not_issued first
      ; S.Already_ended first
      ; S.Not_the_owner { session_id = first; author = bob_id }
      ; S.Not_a_human (Principal.Service (get (Service_id.of_string "keeper-1")))
      ; S.Not_a_session_author Author.Local_operator
      ]
  in
  Alcotest.(check int)
    "each reason has its own text"
    (List.length texts)
    (List.length (List.sort_uniq String.compare texts))
;;

let () =
  Alcotest.run
    "authz_session_state"
    [ ( "sessions"
      , [ Alcotest.test_case "sign in" `Quick a_principal_signs_in
        ; Alcotest.test_case "who may write" `Quick who_may_write_what
        ; Alcotest.test_case "one per id" `Quick one_session_per_id
        ; Alcotest.test_case "sign out" `Quick a_sign_out
        ; Alcotest.test_case "a new sign-in" `Quick a_new_sign_in_ends_the_old_session
        ; Alcotest.test_case "lifetime" `Quick a_session_ends_after_its_lifetime
        ; Alcotest.test_case "texts" `Quick refusals_are_told_apart
        ] )
    ]
;;
