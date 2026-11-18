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

let conversation : E.conversation =
  { owner = get (User_id.of_string "alice")
  ; conversation_id = get (Conversation_id.of_string "conversation-1")
  }
;;

let target = E.Keeper_conversation conversation

let target_bytes =
  {|{"type":"keeper_conversation","owner":"alice","conversation_id":"conversation-1"}|}
;;

let account : E.account =
  { owner = get (User_id.of_string "alice")
  ; provider_account_id = get (Provider_account_id.of_string "account-1")
  }
;;

let account_target = E.Provider_account account
let account_bytes = {|{"type":"provider_account","owner":"alice","provider_account_id":"account-1"}|}

let events =
  [ E.Purge_pending { target }
  ; E.Purged (E.Conversation_purged { conversation; vendor_copy = E.Removed })
  ; E.Purged (E.Conversation_purged { conversation; vendor_copy = E.No_copy })
  ; E.Purge_failed
      (E.Conversation_not_purged
         { conversation; failed_stage = E.Folder_not_removed; vendor_copy = E.May_remain })
  ; E.Purge_pending { target = account_target }
  ; E.Purged (E.Account_purged { account })
  ; E.Purge_failed (E.Account_not_purged { account; failed_stage = E.Key_not_removed })
  ; E.Purge_failed (E.Account_not_purged { account; failed_stage = E.Home_not_removed })
  ]
;;

(* The bodies of the conversation purges are the bytes this module wrote
   before an account became a target: a log written then reads now. *)
let bytes =
  [ {|{"event":"pending","target":|} ^ target_bytes ^ "}"
  ; {|{"event":"purged","target":|} ^ target_bytes ^ {|,"vendor_copy":"removed"}|}
  ; {|{"event":"purged","target":|} ^ target_bytes ^ {|,"vendor_copy":"none"}|}
  ; {|{"event":"failed","target":|}
    ^ target_bytes
    ^ {|,"failed_stage":"folder_not_removed","vendor_copy":"may_remain"}|}
  ; {|{"event":"pending","target":|} ^ account_bytes ^ "}"
  ; {|{"event":"purged","target":|} ^ account_bytes ^ "}"
  ; {|{"event":"failed","target":|} ^ account_bytes ^ {|,"failed_stage":"key_not_removed"}|}
  ; {|{"event":"failed","target":|} ^ account_bytes ^ {|,"failed_stage":"home_not_removed"}|}
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
    bytes
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

let body_of_json json =
  match Authz_body.of_yojson json with
  | Ok body -> body
  | Error error -> Alcotest.failf "fixture body refused: %s" (Authz_body.error_to_string error)
;;

(* What is on disk is read and written back byte for byte. *)
let each_body_on_disk_reads_and_writes_back () =
  List.iter2
    (fun line event ->
      match E.of_body (body_of_json (Yojson.Safe.from_string line)) with
      | Error error -> Alcotest.failf "%s: refused: %s" line (E.error_to_string error)
      | Ok back ->
        Alcotest.(check bool) (line ^ ": the event") true (E.equal event back);
        Alcotest.(check string) line line (Authz_body.to_string (to_body_exn back)))
    bytes
    events
;;

let intent_of subject_bytes target =
  let hash =
    match Authz_record.Hash.of_hex (String.make 64 'a') with
    | Some hash -> hash
    | None -> Alcotest.fail "fixture hash refused"
  in
  ( {|{"kind":"intent_pending","previous_record_hash":"|}
    ^ String.make 64 'a'
    ^ {|","intended_next_record_digest":"|}
    ^ String.make 64 'a'
    ^ {|","change":{"type":"authz","event":"purge","subject":|}
    ^ subject_bytes
    ^ "}}"
  , Store.to_line
      (Store.Intent_pending
         { Store.previous_record_hash = hash
         ; intended_next_record_digest = hash
         ; change = Store.Change.Authz { event = Store.Change.Purge; subject = E.subject target }
         }) )
;;

(* The start of the purge of an account is a [Purge] intent on the credential
   of its id, the subject a turn decision stands on. *)
let the_store_names_an_account_as_its_credential () =
  let expected, written = intent_of {|{"type":"credential","id":"account-1"}|} account_target in
  Alcotest.(check string) "the intent of a start" expected written
;;

(* The start of a purge is a [Purge] intent on its target, and the store names
   that subject with the bytes of the target in the body. *)
let the_store_names_the_target_with_its_bytes () =
  let expected, written = intent_of target_bytes target in
  Alcotest.(check string) "the intent of a start" expected written
;;

let target_json ?(kind = "keeper_conversation") ?(owner = "alice") () =
  `Assoc [ "type", `String kind; "owner", `String owner; "conversation_id", `String "conversation-1" ]
;;

let account_json ?(id = "account-1") () =
  `Assoc [ "type", `String "provider_account"; "owner", `String "alice"; "provider_account_id", `String id ]
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

(* The members that follow the target are those of its kind (design 8.5-7). *)
let members_of_the_other_kind () =
  refused
    "a purged account with a vendor copy"
    E.Wrong_members
    (`Assoc [ "event", `String "purged"; "target", account_json (); "vendor_copy", `String "none" ]);
  refused
    "a purged conversation without a vendor copy"
    E.Wrong_members
    (`Assoc [ "event", `String "purged"; "target", target_json () ]);
  refused
    "a failed account with a vendor copy"
    E.Wrong_members
    (`Assoc
        [ "event", `String "failed"
        ; "target", account_json ()
        ; "failed_stage", `String "key_not_removed"
        ; "vendor_copy", `String "none"
        ]);
  refused
    "the stage of a conversation on an account"
    (E.Unknown_failed_stage "folder_not_removed")
    (`Assoc
        [ "event", `String "failed"
        ; "target", account_json ()
        ; "failed_stage", `String "folder_not_removed"
        ]);
  refused
    "the stage of an account on a conversation"
    (E.Unknown_failed_stage "key_not_removed")
    (`Assoc
        [ "event", `String "failed"
        ; "target", target_json ()
        ; "failed_stage", `String "key_not_removed"
        ; "vendor_copy", `String "none"
        ]);
  refused
    "a failed account whose stage comes before its target"
    E.Wrong_members
    (`Assoc
        [ "event", `String "failed"
        ; "failed_stage", `String "key_not_removed"
        ; "target", account_json ()
        ]);
  refused
    "an account whose id comes before its owner"
    E.Wrong_members
    (`Assoc
        [ "event", `String "pending"
        ; ( "target"
          , `Assoc
              [ "type", `String "provider_account"
              ; "provider_account_id", `String "account-1"
              ; "owner", `String "alice"
              ] )
        ]);
  refused
    "an account id that is no id"
    (E.Invalid_provider_account_id Authz_id.Empty)
    (`Assoc [ "event", `String "pending"; "target", account_json ~id:"" () ]);
  refused
    "an account named by a conversation id"
    E.Wrong_members
    (`Assoc
        [ "event", `String "pending"
        ; ( "target"
          , `Assoc
              [ "type", `String "provider_account"
              ; "owner", `String "alice"
              ; "conversation_id", `String "conversation-1"
              ] )
        ])
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
        ; Alcotest.test_case
            "each body on disk reads and writes back"
            `Quick
            each_body_on_disk_reads_and_writes_back
        ; Alcotest.test_case
            "the store names an account as its credential"
            `Quick
            the_store_names_an_account_as_its_credential
        ; Alcotest.test_case "bodies that are not one" `Quick bodies_that_are_not_one
        ; Alcotest.test_case "members of the other kind" `Quick members_of_the_other_kind
        ] )
    ]
;;
