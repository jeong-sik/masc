(* Checks for the body of a revocation of an Admin assignment: the bytes it
   writes, that it reads back what it wrote, every way a body fails to be one,
   and who may write the record. No files, clock, or network. *)

open Authz_types
open Authz_records
module A = Authz_admin_event
module R = Authz_record

let get = function
  | Ok value -> value
  | Error _ -> Alcotest.fail "fixture value rejected"
;;

let alice = get (User_id.of_string "alice")

let to_body_exn value =
  match A.to_body value with
  | Ok body -> body
  | Error error -> Alcotest.failf "the body was refused: %s" (Authz_body.error_to_string error)
;;

let body_of_json json =
  match Authz_body.of_yojson json with
  | Ok body -> body
  | Error error -> Alcotest.failf "fixture body refused: %s" (Authz_body.error_to_string error)
;;

let bytes_of_a_revocation () =
  Alcotest.(check string)
    "security incident"
    {|{"event":"revoked","user_id":"alice","cause":"security_incident"}|}
    (Authz_body.to_string (to_body_exn (A.Revoked { user_id = alice; cause = A.Security_incident })));
  Alcotest.(check string)
    "operational"
    {|{"event":"revoked","user_id":"alice","cause":"operational"}|}
    (Authz_body.to_string (to_body_exn (A.Revoked { user_id = alice; cause = A.Operational })))
;;

let a_revocation_reads_back () =
  List.iter
    (fun cause ->
      let t = A.Revoked { user_id = alice; cause } in
      match A.of_body (to_body_exn t) with
      | Ok back -> Alcotest.(check bool) (A.cause_label cause) true (A.equal t back)
      | Error error -> Alcotest.failf "refused: %s" (A.error_to_string error))
    A.causes;
  Alcotest.(check bool)
    "another cause"
    false
    (A.equal
       (A.Revoked { user_id = alice; cause = A.Operational })
       (A.Revoked { user_id = alice; cause = A.Security_incident }))
;;

let error_name : A.error -> string = function
  | A.Not_an_object -> "not an object"
  | A.Unknown_event label -> Printf.sprintf "unknown event %S" label
  | A.Wrong_members -> "wrong members"
  | A.Invalid_user_id _ -> "invalid user id"
  | A.Unknown_cause label -> Printf.sprintf "unknown cause %S" label
;;

let body ?(user_id = `String "alice") ?(cause = `String "operational") () =
  `Assoc [ "event", `String "revoked"; "user_id", user_id; "cause", cause ]
;;

let refusals =
  [ "null", `Null, "not an object"
  ; "a string", `String "revoked", "not an object"
  ; "an empty object", `Assoc [], "wrong members"
  ; "no event first", `Assoc [ "user_id", `String "alice"; "event", `String "revoked"; "cause", `String "operational" ], "wrong members"
  ; "another event", `Assoc [ "event", `String "granted"; "user_id", `String "alice" ], {|unknown event "granted"|}
  ; "no cause", `Assoc [ "event", `String "revoked"; "user_id", `String "alice" ], "wrong members"
  ; "another member", `Assoc [ "event", `String "revoked"; "user_id", `String "alice"; "cause", `String "operational"; "note", `String "x" ], "wrong members"
  ; "a user id that is a number", body ~user_id:(`Int 1) (), "wrong members"
  ; "a cause that is a number", body ~cause:(`Int 1) (), "wrong members"
  ; "an empty user id", body ~user_id:(`String "") (), "invalid user id"
  ; "an unknown cause", body ~cause:(`String "boredom") (), {|unknown cause "boredom"|}
  ; "a cause in another case", body ~cause:(`String "Operational") (), {|unknown cause "Operational"|}
  ; "a bad user id comes before a bad cause", body ~user_id:(`String "") ~cause:(`String "x") (), "invalid user id"
  ]
;;

let a_body_that_is_not_a_revocation_is_refused () =
  List.iter
    (fun (name, json, expected) ->
      match A.of_body (body_of_json json) with
      | Ok _ -> Alcotest.failf "%s was read as a revocation" name
      | Error error -> Alcotest.(check string) name expected (error_name error))
    refusals;
  Alcotest.(check int)
    "every error reads differently"
    5
    (List.length
       (List.sort_uniq
          String.compare
          (List.map
             A.error_to_string
             [ A.Not_an_object
             ; A.Unknown_event "x"
             ; A.Wrong_members
             ; A.Invalid_user_id Authz_id.Empty
             ; A.Unknown_cause "x"
             ])))
;;

let only_an_authenticated_principal_writes_one () =
  let body = to_body_exn (A.Revoked { user_id = alice; cause = A.Operational }) in
  let make author = R.make ~head:R.genesis ~at_ms:1000 ~author ~kind:R.Kind.Admin_assignment ~body in
  (match make (Author.Authenticated (Principal.Human alice)) with
   | Error _ -> Alcotest.fail "an authenticated principal may write it"
   | Ok record ->
     (match R.of_line ~head:R.genesis (R.to_line record) with
      | Error _ -> Alcotest.fail "the line of the record is not read back"
      | Ok read -> Alcotest.(check string) "the kind" "admin_assignment" (R.Kind.to_string read.R.kind)));
  List.iter
    (fun author ->
      match make author with
      | Error (R.Author_not_admitted _) -> ()
      | Ok _ -> Alcotest.fail "an author who is not a principal wrote a revocation")
    [ Author.Local_operator; Author.System_cron; Author.System_maintenance; Author.System_migration ]
;;

let () =
  Alcotest.run
    "authz_admin_event"
    [ ( "revocation"
      , [ Alcotest.test_case "bytes" `Quick bytes_of_a_revocation
        ; Alcotest.test_case "reads back" `Quick a_revocation_reads_back
        ; Alcotest.test_case "refusals" `Quick a_body_that_is_not_a_revocation_is_refused
        ] )
    ; "record", [ Alcotest.test_case "who writes it" `Quick only_an_authenticated_principal_writes_one ]
    ]
;;
