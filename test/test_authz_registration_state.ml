(* The allowlist that the registration records add up to: who may write which
   event, that an identity has one open registration and a bound identity none,
   that an id names one registration for good, and how an admission spends
   one. No files, clock, or network. *)

open Authz_types
open Authz_records
module E = Authz_registration_event
module S = Authz_registration_state
module X = Authz_external_identity

let get = function
  | Ok value -> value
  | Error _ -> Alcotest.fail "fixture id rejected by Authz_id"
;;

let identity_of = function
  | Ok identity -> identity
  | Error error -> Alcotest.failf "fixture identity refused: %s" (X.error_to_string error)
;;

let registration_of text = get (Registration_id.of_string text)
let first = registration_of "registration-1"
let second = registration_of "registration-2"
let third = registration_of "registration-3"
let google = identity_of (X.google ~sub:"110169484474386276334")
let github = identity_of (X.github ~user_id:583231)

(* An identity that the caller says is bound to a principal. *)
let bound = identity_of (X.github ~user_id:1)
let user text = get (User_id.of_string text)
let alice_id = user "alice"
let carol_id = user "carol"
let alice = Author.Authenticated (Principal.Human alice_id)
let carol = Author.Authenticated (Principal.Human carol_id)

(* Alice and carol are Admins in these checks; nobody else is. *)
let is_admin id = User_id.equal id alice_id || User_id.equal id carol_id
let is_bound identity = X.equal identity bound

let registered ?(registration_id = first) ?(identity = google) () =
  E.Registered { registration_id; identity }
;;

let removed ?(registration_id = first) () = E.Removed { registration_id }

let refusal_name : S.refusal -> string = function
  | S.Already_registered id -> "already registered " ^ Registration_id.to_string id
  | S.Identity_registered id -> "identity registered in " ^ Registration_id.to_string id
  | S.Identity_bound -> "identity bound"
  | S.Not_registered id -> "not registered " ^ Registration_id.to_string id
  | S.Already_removed id -> "already removed " ^ Registration_id.to_string id
  | S.Already_consumed id -> "already consumed " ^ Registration_id.to_string id
  | S.Author_is_not_an_admin principal -> "not an admin " ^ Principal.to_string principal
  | S.Not_a_registration_author _ -> "not a registration author"
;;

let consume_refusal_name : S.consume_refusal -> string = function
  | S.Registration_not_found id -> "not found " ^ Registration_id.to_string id
  | S.Registration_removed id -> "removed " ^ Registration_id.to_string id
  | S.Registration_consumed id -> "consumed " ^ Registration_id.to_string id
  | S.Identity_differs id -> "identity differs " ^ Registration_id.to_string id
;;

let apply_ok ?(author = alice) t event =
  match S.apply t ~author ~is_admin ~is_bound event with
  | Ok t -> t
  | Error refusal -> Alcotest.failf "refused: %s" (refusal_name refusal)
;;

let check_refused label ?(author = alice) t event expected =
  match S.apply t ~author ~is_admin ~is_bound event with
  | Ok _ -> Alcotest.failf "%s: the event was taken" label
  | Error refusal -> Alcotest.(check string) label expected (refusal_name refusal)
;;

let consume_ok t registration_id ~identity ~user_id =
  match S.consume t registration_id ~identity ~user_id with
  | Ok t -> t
  | Error refusal -> Alcotest.failf "not spent: %s" (consume_refusal_name refusal)
;;

let check_not_consumed label t registration_id ~identity expected =
  match S.consume t registration_id ~identity ~user_id:(user "dave") with
  | Ok _ -> Alcotest.failf "%s: the registration was spent" label
  | Error refusal -> Alcotest.(check string) label expected (consume_refusal_name refusal)
;;

let status_name = function
  | None -> "none"
  | Some { S.status = S.Open; _ } -> "open"
  | Some { S.status = S.Removed; _ } -> "removed"
  | Some { S.status = S.Consumed user_id; _ } -> "consumed by " ^ User_id.to_string user_id
;;

let check_status label t registration_id expected =
  Alcotest.(check string) label expected (status_name (S.find t registration_id))
;;

let open_name t identity =
  match S.find_open t identity with
  | None -> "none"
  | Some (id, _) -> Registration_id.to_string id
;;

let check_open label t identity expected = Alcotest.(check string) label expected (open_name t identity)

(* ---- the checks ---- *)

let an_admin_registers_an_identity () =
  let t = apply_ok S.empty (registered ()) in
  (match S.find t first with
   | Some { S.status = S.Open; identity; registrar } ->
     Alcotest.(check bool) "the identity" true (X.equal identity google);
     Alcotest.(check string) "the registrar" "alice" (User_id.to_string registrar)
   | Some _ | None -> Alcotest.fail "the registration is not open as written");
  check_open "found by its identity" t google "registration-1";
  check_open "another identity finds nothing" t github "none";
  check_status "another id finds nothing" t second "none";
  let t = apply_ok ~author:carol t (registered ~registration_id:second ~identity:github ()) in
  (match S.find t second with
   | Some { S.registrar; _ } -> Alcotest.(check string) "the second registrar" "carol" (User_id.to_string registrar)
   | None -> Alcotest.fail "the second registration is missing");
  check_open "the first stays" t google "registration-1"
;;

let who_may_write_what () =
  let open_one = apply_ok S.empty (registered ()) in
  let bob = Principal.Human (user "bob") in
  let keeper = Principal.Service (get (Service_id.of_string "keeper-1")) in
  List.iter
    (fun (name, author, expected) ->
      check_refused (name ^ " registers") ~author S.empty (registered ()) expected;
      check_refused (name ^ " removes") ~author open_one (removed ()) expected)
    [ "a principal that is not an Admin", Author.Authenticated bob, "not an admin human:bob"
    ; "a service", Author.Authenticated keeper, "not an admin service:keeper-1"
    ; "the local operator", Author.Local_operator, "not a registration author"
    ; "system cron", Author.System_cron, "not a registration author"
    ; "system maintenance", Author.System_maintenance, "not a registration author"
    ; "system migration", Author.System_migration, "not a registration author"
    ];
  let t = apply_ok ~author:carol open_one (removed ()) in
  check_status "an Admin removes what another registered" t first "removed"
;;

let one_open_registration_per_identity () =
  let t = apply_ok S.empty (registered ()) in
  check_refused
    "the identity again"
    t
    (registered ~registration_id:second ())
    "identity registered in registration-1";
  check_refused "the id again" t (registered ~identity:github ()) "already registered registration-1";
  check_refused
    "a bound identity"
    S.empty
    (registered ~identity:bound ())
    "identity bound";
  let t = apply_ok t (removed ()) in
  check_refused "the id of a removed one" t (registered ~identity:github ()) "already registered registration-1";
  let t = apply_ok t (registered ~registration_id:second ()) in
  check_open "the identity again after a removal" t google "registration-2";
  check_status "the removed one stays removed" t first "removed";
  let t = consume_ok t second ~identity:google ~user_id:(user "dave") in
  check_refused "the id of a spent one" t (registered ~registration_id:second ~identity:github ()) "already registered registration-2";
  let t = apply_ok t (registered ~registration_id:third ()) in
  check_open "the identity again after it was spent" t google "registration-3"
;;

let a_removal () =
  let t = apply_ok S.empty (registered ()) in
  let t = apply_ok t (removed ()) in
  check_status "removed" t first "removed";
  check_open "no longer open" t google "none";
  check_refused "removed twice" t (removed ()) "already removed registration-1";
  check_refused "never written" t (removed ~registration_id:second ()) "not registered registration-2";
  let t = apply_ok t (registered ~registration_id:second ()) in
  let t = consume_ok t second ~identity:google ~user_id:(user "dave") in
  check_refused "a spent one" t (removed ~registration_id:second ()) "already consumed registration-2"
;;

let an_admission_spends_a_registration_once () =
  let t = apply_ok S.empty (registered ()) in
  check_not_consumed "another identity" t first ~identity:github "identity differs registration-1";
  check_not_consumed "an id never written" t second ~identity:google "not found registration-2";
  let t = consume_ok t first ~identity:google ~user_id:(user "dave") in
  check_status "spent" t first "consumed by dave";
  check_open "no longer open" t google "none";
  check_not_consumed "spent twice" t first ~identity:google "consumed registration-1";
  let t = apply_ok t (registered ~registration_id:second ~identity:github ()) in
  let t = apply_ok t (removed ~registration_id:second ()) in
  check_not_consumed "a removed one" t second ~identity:github "removed registration-2";
  match S.find_consumed_by t (user "dave") with
  | Some (id, { S.registrar; _ }) ->
    Alcotest.(check string) "found by who spent it" "registration-1" (Registration_id.to_string id);
    Alcotest.(check string) "its registrar" "alice" (User_id.to_string registrar)
  | None -> Alcotest.fail "the spent registration is not found by who spent it"
;;

(* An admission through an invitation spends the open registration of its
   identity too, so the identity has no entry left to come back through. *)
let an_invitation_admission_spends_the_open_registration () =
  let t = apply_ok S.empty (registered ()) in
  let t = S.spend_open t google ~user_id:(user "erin") in
  check_status "spent" t first "consumed by erin";
  check_open "no longer open" t google "none";
  let t = apply_ok t (registered ~registration_id:second ~identity:github ()) in
  let t = apply_ok t (removed ~registration_id:second ()) in
  let after = S.spend_open t github ~user_id:(user "frank") in
  check_status "a removed one stays removed" after second "removed";
  check_status "the spent one stays spent" after first "consumed by erin";
  Alcotest.(check bool)
    "an identity with no open registration changes nothing"
    true
    (S.find_consumed_by after (user "frank") = None)
;;

let nobody_spent_finds_nothing () =
  let t = apply_ok S.empty (registered ()) in
  Alcotest.(check bool) "an open one" true (S.find_consumed_by t (user "dave") = None);
  let t = consume_ok t first ~identity:google ~user_id:(user "dave") in
  Alcotest.(check bool) "another principal" true (S.find_consumed_by t (user "erin") = None)
;;

let refusals_are_told_apart () =
  let texts =
    List.map
      S.refusal_to_string
      [ S.Already_registered first
      ; S.Identity_registered first
      ; S.Identity_bound
      ; S.Not_registered first
      ; S.Already_removed first
      ; S.Already_consumed first
      ; S.Author_is_not_an_admin (Principal.Human alice_id)
      ; S.Not_a_registration_author Author.Local_operator
      ]
    @ List.map
        S.consume_refusal_to_string
        [ S.Registration_not_found first
        ; S.Registration_removed first
        ; S.Registration_consumed first
        ; S.Identity_differs first
        ]
  in
  Alcotest.(check int)
    "each reason has its own text"
    (List.length texts)
    (List.length (List.sort_uniq String.compare texts))
;;

let () =
  Alcotest.run
    "authz_registration_state"
    [ ( "allowlist"
      , [ Alcotest.test_case "by an Admin" `Quick an_admin_registers_an_identity
        ; Alcotest.test_case "who may write" `Quick who_may_write_what
        ; Alcotest.test_case "one open per identity" `Quick one_open_registration_per_identity
        ; Alcotest.test_case "removal" `Quick a_removal
        ; Alcotest.test_case "spent once" `Quick an_admission_spends_a_registration_once
        ; Alcotest.test_case "spent by an invitation" `Quick
            an_invitation_admission_spends_the_open_registration
        ; Alcotest.test_case "who spent it" `Quick nobody_spent_finds_nothing
        ; Alcotest.test_case "texts" `Quick refusals_are_told_apart
        ] )
    ]
;;
