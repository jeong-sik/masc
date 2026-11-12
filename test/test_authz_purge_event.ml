(* Checks for the body of a purge record: the bytes it writes, that it reads
   back what it wrote, the bytes the external store writes for the subject of
   its start, and the bodies that are not one. No files, clock, or network. *)

open Authz_types
module E = Authz_purge_event
module Store = Authz_external_store

let get = function
  | Ok value -> value
  | Error _ -> Alcotest.fail "fixture id rejected by Authz_id"
;;

let target =
  E.Keeper_conversation
    { owner = get (User_id.of_string "alice")
    ; conversation_id = get (Conversation_id.of_string "conversation-1")
    }
;;

let target_bytes =
  {|{"type":"keeper_conversation","owner":"alice","conversation_id":"conversation-1"}|}
;;

let events =
  [ E.Purge_pending { target }
  ; E.Purged { target; vendor_copy = E.Removed }
  ; E.Purged { target; vendor_copy = E.No_copy }
  ; E.Purge_failed { target; failed_stage = E.Folder_not_removed; vendor_copy = E.May_remain }
  ]
;;

let to_body_exn event =
  match E.to_body event with
  | Ok body -> body
  | Error error -> Alcotest.failf "the body was refused: %s" (Authz_body.error_to_string error)
;;

let bytes_of_each_event () =
  List.iter2
    (fun event expected ->
      Alcotest.(check string) expected expected (Authz_body.to_string (to_body_exn event)))
    events
    [ {|{"event":"pending","target":|} ^ target_bytes ^ "}"
    ; {|{"event":"purged","target":|} ^ target_bytes ^ {|,"vendor_copy":"removed"}|}
    ; {|{"event":"purged","target":|} ^ target_bytes ^ {|,"vendor_copy":"none"}|}
    ; {|{"event":"failed","target":|}
      ^ target_bytes
      ^ {|,"failed_stage":"folder_not_removed","vendor_copy":"may_remain"}|}
    ]
;;

let each_event_reads_back () =
  List.iter
    (fun event ->
      let label = Authz_body.to_string (to_body_exn event) in
      match E.of_body (to_body_exn event) with
      | Ok back -> Alcotest.(check bool) label true (E.equal event back)
      | Error error -> Alcotest.failf "%s: refused: %s" label (E.error_to_string error))
    events
;;

(* The start of a purge is a [Purge] intent on its target, and the store names
   that subject with the bytes of the target in the body. *)
let the_store_names_the_target_with_its_bytes () =
  let hash =
    match Authz_record.Hash.of_hex (String.make 64 'a') with
    | Some hash -> hash
    | None -> Alcotest.fail "fixture hash refused"
  in
  Alcotest.(check string)
    "the intent of a start"
    ({|{"kind":"intent_pending","previous_record_hash":"|}
     ^ String.make 64 'a'
     ^ {|","intended_next_record_digest":"|}
     ^ String.make 64 'a'
     ^ {|","change":{"type":"authz","event":"purge","subject":|}
     ^ target_bytes
     ^ "}}")
    (Store.to_line
       (Store.Intent_pending
          { Store.previous_record_hash = hash
          ; intended_next_record_digest = hash
          ; change = Store.Change.Authz { event = Store.Change.Purge; subject = E.subject target }
          }))
;;

let body_of_json json =
  match Authz_body.of_yojson json with
  | Ok body -> body
  | Error error -> Alcotest.failf "fixture body refused: %s" (Authz_body.error_to_string error)
;;

let target_json ?(kind = "keeper_conversation") ?(owner = "alice") () =
  `Assoc [ "type", `String kind; "owner", `String owner; "conversation_id", `String "conversation-1" ]
;;

let refused label expected json =
  match E.of_body (body_of_json json) with
  | Ok (_ : E.t) -> Alcotest.failf "%s: taken" label
  | Error error -> Alcotest.(check string) label (E.error_to_string expected) (E.error_to_string error)
;;

let bodies_that_are_not_one () =
  refused "a string" E.Not_an_object (`String "pending");
  refused
    "an unknown event"
    (E.Unknown_event "deleted")
    (`Assoc [ "event", `String "deleted"; "target", target_json () ]);
  refused
    "members in another order"
    E.Wrong_members
    (`Assoc [ "event", `String "purged"; "vendor_copy", `String "removed"; "target", target_json () ]);
  refused
    "a target that is a string"
    E.Wrong_members
    (`Assoc [ "event", `String "pending"; "target", `String "conversation-1" ]);
  refused
    "an unknown target"
    (E.Unknown_target "keeper")
    (`Assoc [ "event", `String "pending"; "target", target_json ~kind:"keeper" () ]);
  refused
    "an owner that is no id"
    (E.Invalid_owner Authz_id.Empty)
    (`Assoc [ "event", `String "pending"; "target", target_json ~owner:"" () ]);
  refused
    "an unknown stage"
    (E.Unknown_failed_stage "late")
    (`Assoc
        [ "event", `String "failed"
        ; "target", target_json ()
        ; "failed_stage", `String "late"
        ; "vendor_copy", `String "none"
        ]);
  refused
    "an unknown vendor copy"
    (E.Unknown_vendor_copy "gone")
    (`Assoc [ "event", `String "purged"; "target", target_json (); "vendor_copy", `String "gone" ])
;;

let () =
  Alcotest.run
    "authz_purge_event"
    [ ( "body"
      , [ Alcotest.test_case "bytes of each event" `Quick bytes_of_each_event
        ; Alcotest.test_case "each event reads back" `Quick each_event_reads_back
        ; Alcotest.test_case
            "the store names the target with its bytes"
            `Quick
            the_store_names_the_target_with_its_bytes
        ; Alcotest.test_case "bodies that are not one" `Quick bodies_that_are_not_one
        ] )
    ]
;;
