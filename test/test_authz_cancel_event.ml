(* Checks for the body of a revocation cancel: the bytes it writes, that its
   subject has the bytes the external store writes for the same subject, that
   it reads back what it wrote, and every way a body fails to be one. No files,
   clock, or network. *)

open Authz_types
open Authz_records
module C = Authz_cancel_event
module R = Authz_record
module Store = Authz_external_store

let get = function
  | Ok value -> value
  | Error _ -> Alcotest.fail "fixture value rejected"
;;

let hash_of char =
  match R.Hash.of_hex (String.make 64 char) with
  | Some hash -> hash
  | None -> Alcotest.fail "fixture hash rejected"
;;

let aborted = hash_of 'a'
let invite = Subject.Invite (get (Invite_id.of_string "invite-1"))

(* Every shape of a subject. *)
let subjects =
  [ Subject.Grant (get (Grant_id.of_string "grant-1"))
  ; Subject.Credential (get (Provider_account_id.of_string "account-1"))
  ; Subject.Principal (Principal.Human (get (User_id.of_string "alice")))
  ; Subject.Principal (Principal.Service (get (Service_id.of_string "keeper-1")))
  ; Subject.Runtime (get (Runtime_id.of_string "runtime-1"))
  ; Subject.Session (get (Session_id.of_string "session-1"))
  ; Subject.Pat (get (Pat_id.of_string "pat-1"))
  ; Subject.Service_credential (get (Service_credential_id.of_string "cred-1"))
  ; invite
  ; Subject.Registration (get (Registration_id.of_string "registration-1"))
  ; Subject.Keeper_conversation
      { owner = get (User_id.of_string "alice")
      ; conversation_id = get (Conversation_id.of_string "conversation-1")
      }
  ]
;;

let to_body_exn value =
  match C.to_body value with
  | Ok body -> body
  | Error error -> Alcotest.failf "the body was refused: %s" (Authz_body.error_to_string error)
;;

let body_of_json json =
  match Authz_body.of_yojson json with
  | Ok body -> body
  | Error error -> Alcotest.failf "fixture body refused: %s" (Authz_body.error_to_string error)
;;

let bytes_of_a_cancel () =
  Alcotest.(check string)
    "an invitation"
    ({|{"aborted":"|} ^ String.make 64 'a' ^ {|","subject":{"type":"invite","id":"invite-1"}}|})
    (Authz_body.to_string (to_body_exn { C.aborted; subject = invite }));
  Alcotest.(check string)
    "a human principal"
    ({|{"aborted":"|}
     ^ String.make 64 'a'
     ^ {|","subject":{"type":"principal","principal":{"type":"human","id":"alice"}}}|})
    (Authz_body.to_string
       (to_body_exn
          { C.aborted; subject = Subject.Principal (Principal.Human (get (User_id.of_string "alice"))) }))
;;

let subject_bytes subject =
  match to_body_exn { C.aborted; subject } with
  | Authz_body.Object [ ("aborted", _); ("subject", subject) ] -> Authz_body.to_string subject
  | _ -> Alcotest.fail "the body is not the two members"
;;

(* The store writes the subject of a change inside an intent; the cancel names
   the same subject with the same bytes, so one reader reads both. *)
let the_subject_is_written_as_the_store_writes_it () =
  List.iter
    (fun subject ->
      let intent =
        { Store.previous_record_hash = hash_of 'b'
        ; intended_next_record_digest = aborted
        ; change = Store.Change.Authz { event = Store.Change.Revoke; subject }
        }
      in
      Alcotest.(check string)
        (Subject.to_string subject)
        ({|{"kind":"aborted_intent","previous_record_hash":"|}
         ^ String.make 64 'b'
         ^ {|","intended_next_record_digest":"|}
         ^ String.make 64 'a'
         ^ {|","change":{"type":"authz","event":"revoke","subject":|}
         ^ subject_bytes subject
         ^ "}}")
        (Store.to_line (Store.Aborted_intent intent)))
    subjects
;;

let a_cancel_reads_back () =
  List.iter
    (fun subject ->
      let t = { C.aborted; subject } in
      match C.of_body (to_body_exn t) with
      | Ok back -> Alcotest.(check bool) (Subject.to_string subject) true (C.equal t back)
      | Error error -> Alcotest.failf "refused: %s" (C.error_to_string error))
    subjects;
  Alcotest.(check bool)
    "another digest"
    false
    (C.equal { C.aborted; subject = invite } { C.aborted = hash_of 'c'; subject = invite });
  Alcotest.(check bool)
    "another subject"
    false
    (C.equal
       { C.aborted; subject = invite }
       { C.aborted; subject = Subject.Invite (get (Invite_id.of_string "invite-2")) });
  let registration text = Subject.Registration (get (Registration_id.of_string text)) in
  Alcotest.(check bool)
    "another allowlist entry"
    false
    (C.equal
       { C.aborted; subject = registration "registration-1" }
       { C.aborted; subject = registration "registration-2" });
  (* The text of a subject is what a refusal names, so each is pinned. *)
  Alcotest.(check (list string))
    "the text of each subject"
    [ "grant:grant-1"
    ; "credential:account-1"
    ; "principal:human:alice"
    ; "principal:service:keeper-1"
    ; "runtime:runtime-1"
    ; "session:session-1"
    ; "pat:pat-1"
    ; "service_credential:cred-1"
    ; "invite:invite-1"
    ; "registration:registration-1"
    ; "keeper_conversation:alice/conversation-1"
    ]
    (List.map Subject.to_string subjects);
  let session text = Subject.Session (get (Session_id.of_string text)) in
  Alcotest.(check bool)
    "another session"
    false
    (C.equal { C.aborted; subject = session "session-1" } { C.aborted; subject = session "session-2" });
  List.iteri
    (fun i a ->
      List.iteri
        (fun j b ->
          Alcotest.(check bool)
            (Subject.to_string a ^ " and " ^ Subject.to_string b)
            (i = j)
            (Subject.equal a b))
        subjects)
    subjects
;;

let error_name : C.error -> string = function
  | C.Not_an_object -> "not an object"
  | C.Wrong_members -> "wrong members"
  | C.Invalid_aborted -> "invalid aborted"
  | C.Invalid_subject -> "invalid subject"
;;

let result_name = function
  | Ok (_ : C.t) -> "ok"
  | Error error -> error_name error
;;

let digest = `String (String.make 64 'a')
let invite_json = `Assoc [ "type", `String "invite"; "id", `String "invite-1" ]

let bodies_that_are_refused () =
  List.iter
    (fun (label, json, expected) ->
      Alcotest.(check string) label expected (result_name (C.of_body (body_of_json json))))
    [ "a string", `String "invite-1", "not an object"
    ; "a list", `List [], "not an object"
    ; "no members", `Assoc [], "wrong members"
    ; "the members swapped", `Assoc [ "subject", invite_json; "aborted", digest ], "wrong members"
    ; ( "a member more"
      , `Assoc [ "aborted", digest; "subject", invite_json; "cause", `String "x" ]
      , "wrong members" )
    ; "no subject", `Assoc [ "aborted", digest ], "wrong members"
    ; "the digest a number", `Assoc [ "aborted", `Int 1; "subject", invite_json ], "wrong members"
    ; ( "the subject a string"
      , `Assoc [ "aborted", digest; "subject", `String "invite-1" ]
      , "wrong members" )
    ; ( "an upper case digest"
      , `Assoc [ "aborted", `String (String.make 64 'A'); "subject", invite_json ]
      , "invalid aborted" )
    ; ( "a short digest"
      , `Assoc [ "aborted", `String (String.make 63 'a'); "subject", invite_json ]
      , "invalid aborted" )
    ; ( "a bad digest and a bad subject"
      , `Assoc [ "aborted", `String "x"; "subject", `Assoc [] ]
      , "invalid aborted" )
    ; ( "an unknown type"
      , `Assoc [ "aborted", digest; "subject", `Assoc [ "type", `String "user"; "id", `String "a" ] ]
      , "invalid subject" )
    ; ( "an id that is not one"
      , `Assoc [ "aborted", digest; "subject", `Assoc [ "type", `String "invite"; "id", `String "" ] ]
      , "invalid subject" )
    ; ( "the subject members swapped"
      , `Assoc [ "aborted", digest; "subject", `Assoc [ "id", `String "invite-1"; "type", `String "invite" ] ]
      , "invalid subject" )
    ; ( "a subject with a member more"
      , `Assoc
          [ "aborted", digest
          ; "subject", `Assoc [ "type", `String "invite"; "id", `String "invite-1"; "at", `Int 1 ]
          ]
      , "invalid subject" )
    ; ( "a principal of an unknown type"
      , `Assoc
          [ "aborted", digest
          ; ( "subject"
            , `Assoc
                [ "type", `String "principal"
                ; "principal", `Assoc [ "type", `String "robot"; "id", `String "a" ]
                ] )
          ]
      , "invalid subject" )
    ; ( "a principal named as an id"
      , `Assoc [ "aborted", digest; "subject", `Assoc [ "type", `String "principal"; "id", `String "alice" ] ]
      , "invalid subject" )
    ]
;;

let errors_are_told_apart () =
  let texts =
    List.map C.error_to_string [ C.Not_an_object; C.Wrong_members; C.Invalid_aborted; C.Invalid_subject ]
  in
  Alcotest.(check int)
    "each error has its own text"
    (List.length texts)
    (List.length (List.sort_uniq String.compare texts))
;;

let () =
  Alcotest.run
    "authz_cancel_event"
    [ ( "body"
      , [ Alcotest.test_case "bytes" `Quick bytes_of_a_cancel
        ; Alcotest.test_case "the store's subject" `Quick the_subject_is_written_as_the_store_writes_it
        ; Alcotest.test_case "reads back" `Quick a_cancel_reads_back
        ; Alcotest.test_case "refused" `Quick bodies_that_are_refused
        ; Alcotest.test_case "texts" `Quick errors_are_told_apart
        ] )
    ]
;;
