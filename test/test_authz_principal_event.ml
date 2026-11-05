(* Checks for the body of a principal record: the bytes of each event, that it
   reads back what it wrote, every way a body fails to be one, and who may write
   the record. No files, clock, or network. *)

open Authz_types
open Authz_records
module E = Authz_principal_event
module X = Authz_external_identity
module R = Authz_record

let get = function
  | Ok value -> value
  | Error _ -> Alcotest.fail "fixture value rejected"
;;

let alice = get (User_id.of_string "alice")
let google = get (X.google ~sub:"111")

let to_body_exn value =
  match E.to_body value with
  | Ok body -> body
  | Error error -> Alcotest.failf "the body was refused: %s" (Authz_body.error_to_string error)
;;

let body_of_json json =
  match Authz_body.of_yojson json with
  | Ok body -> body
  | Error error -> Alcotest.failf "fixture body refused: %s" (Authz_body.error_to_string error)
;;

let events =
  [ E.Disabled { user_id = alice }
  ; E.Enabled { user_id = alice }
  ; E.Deleted { user_id = alice; identity = google }
  ]
;;

let bytes_of_each_event () =
  Alcotest.(check (list string))
    "the three events"
    [ {|{"event":"disabled","user_id":"alice"}|}
    ; {|{"event":"enabled","user_id":"alice"}|}
    ; {|{"event":"deleted","user_id":"alice","identity":{"provider":"google","sub":"111"}}|}
    ]
    (List.map (fun event -> Authz_body.to_string (to_body_exn event)) events)
;;

let each_event_reads_back () =
  List.iter
    (fun event ->
      match E.of_body (to_body_exn event) with
      | Ok back -> Alcotest.(check bool) "the same event" true (E.equal event back)
      | Error error -> Alcotest.failf "refused: %s" (E.error_to_string error))
    events;
  Alcotest.(check bool)
    "another event of the same person"
    false
    (E.equal (E.Disabled { user_id = alice }) (E.Enabled { user_id = alice }));
  Alcotest.(check string) "the principal" "alice" (User_id.to_string (E.user_id (E.Deleted { user_id = alice; identity = google })))
;;

let error_name : E.error -> string = function
  | E.Not_an_object -> "not an object"
  | E.Unknown_event label -> Printf.sprintf "unknown event %S" label
  | E.Wrong_members -> "wrong members"
  | E.Invalid_user_id _ -> "invalid user id"
  | E.Invalid_identity _ -> "invalid identity"
;;

let refusals =
  let deleted identity = `Assoc [ "event", `String "deleted"; "user_id", `String "alice"; "identity", identity ] in
  [ "null", `Null, "not an object"
  ; "an empty object", `Assoc [], "wrong members"
  ; "another event", `Assoc [ "event", `String "renamed"; "user_id", `String "alice" ], {|unknown event "renamed"|}
  ; "a disable with an identity", `Assoc [ "event", `String "disabled"; "user_id", `String "alice"; "identity", `Assoc [] ], "wrong members"
  ; "a deletion with no identity", `Assoc [ "event", `String "deleted"; "user_id", `String "alice" ], "wrong members"
  ; "a user id that is a number", `Assoc [ "event", `String "enabled"; "user_id", `Int 1 ], "wrong members"
  ; "an identity that is a string", deleted (`String "google:111"), "wrong members"
  ; "an unknown provider", deleted (`Assoc [ "provider", `String "gitlab"; "user_id", `Int 1 ]), "invalid identity"
  ; "an empty user id", `Assoc [ "event", `String "disabled"; "user_id", `String "" ], "invalid user id"
  ]
;;

let a_body_that_is_not_a_principal_event_is_refused () =
  List.iter
    (fun (name, json, expected) ->
      match E.of_body (body_of_json json) with
      | Ok _ -> Alcotest.failf "%s was read as a principal event" name
      | Error error -> Alcotest.(check string) name expected (error_name error))
    refusals
;;

let only_an_authenticated_principal_writes_one () =
  let body = to_body_exn (E.Disabled { user_id = alice }) in
  let make author = R.make ~head:R.genesis ~at_ms:1000 ~author ~kind:R.Kind.Principal ~body in
  (match make (Author.Authenticated (Principal.Human alice)) with
   | Error _ -> Alcotest.fail "an authenticated principal may write it"
   | Ok _ -> ());
  List.iter
    (fun author ->
      match make author with
      | Error (R.Author_not_admitted _) -> ()
      | Ok _ -> Alcotest.fail "an author who is not a principal wrote a principal record")
    [ Author.Local_operator; Author.System_cron; Author.System_maintenance; Author.System_migration ]
;;

let () =
  Alcotest.run
    "authz_principal_event"
    [ ( "events"
      , [ Alcotest.test_case "bytes" `Quick bytes_of_each_event
        ; Alcotest.test_case "reads back" `Quick each_event_reads_back
        ; Alcotest.test_case "refusals" `Quick a_body_that_is_not_a_principal_event_is_refused
        ] )
    ; "record", [ Alcotest.test_case "who writes it" `Quick only_an_authenticated_principal_writes_one ]
    ]
;;
