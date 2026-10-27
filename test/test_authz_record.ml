(* Pure checks for one record of the authorization log: which author may write
   which kind, and that the hash chain notices every change to a line. No
   files, clock, or network. *)

open Authz_types
open Authz_records
module R = Authz_record

let get = function
  | Ok value -> value
  | Error _ -> Alcotest.fail "fixture id rejected by Authz_id"
;;

let alice = Principal.Human (get (User_id.of_string "alice"))
let keeper = Principal.Service (get (Service_id.of_string "keeper-1"))

let authors =
  [ "authenticated human", Author.Authenticated alice
  ; "authenticated service", Author.Authenticated keeper
  ; "local operator", Author.Local_operator
  ; "system cron", Author.System_cron
  ; "system maintenance", Author.System_maintenance
  ; "system migration", Author.System_migration
  ]
;;

(* Design 6.3: who may write what. Names are the author labels above. *)
let writers_of =
  let authenticated = [ "authenticated human"; "authenticated service" ] in
  R.Kind.
    [ Runtime_grant, authenticated
    ; Delegate_policy, authenticated
    ; Principal, authenticated
    ; Internal_service_credential, authenticated
    ; Permission_revocation, authenticated
    ; Trigger_evidence, [ "system cron" ]
    ; Lease_terminal_evidence, [ "system maintenance" ]
    ; Preauthorized_expiry, [ "system maintenance" ]
    ; Migration_diagnostic, [ "system migration" ]
    ; Local_recovery, [ "local operator" ]
    ]
;;

let pairing_tests =
  List.concat_map
    (fun (kind, allowed) ->
      List.map
        (fun (label, author) ->
          let name = Printf.sprintf "%s by %s" (R.Kind.to_string kind) label in
          Alcotest.test_case name `Quick (fun () ->
            Alcotest.(check bool) name (List.mem label allowed) (R.admits kind author)))
        authors)
    writers_of
;;

(* An exhaustive match, so a new kind cannot be added without this file. *)
let ordinal = function
  | R.Kind.Runtime_grant -> 0
  | R.Kind.Delegate_policy -> 1
  | R.Kind.Principal -> 2
  | R.Kind.Internal_service_credential -> 3
  | R.Kind.Permission_revocation -> 4
  | R.Kind.Trigger_evidence -> 5
  | R.Kind.Lease_terminal_evidence -> 6
  | R.Kind.Preauthorized_expiry -> 7
  | R.Kind.Migration_diagnostic -> 8
  | R.Kind.Local_recovery -> 9
;;

let kinds_are_all_listed () =
  let sorted kinds = List.sort Int.compare (List.map ordinal kinds) in
  Alcotest.(check (list int))
    "Kind.all names every kind once"
    (sorted (List.map fst writers_of))
    (sorted R.Kind.all)
;;

let kind_labels_round_trip () =
  List.iter
    (fun kind ->
      let label = R.Kind.to_string kind in
      match R.Kind.of_string label with
      | Some back -> Alcotest.(check int) label (ordinal kind) (ordinal back)
      | None -> Alcotest.failf "label %s does not read back" label)
    R.Kind.all;
  Alcotest.(check bool) "unknown label" true (Option.is_none (R.Kind.of_string "grant"))
;;

let body = `Assoc [ "x", `Int 1 ]

let make_exn ~head ~at_ms ~author ~kind ~body =
  match R.make ~head ~at_ms ~author ~kind ~body with
  | Ok record -> record
  | Error (R.Author_not_admitted _) -> Alcotest.fail "fixture author not admitted"
;;

(* Three records chained from genesis, by three different authors. *)
let chain =
  let first =
    make_exn
      ~head:R.genesis
      ~at_ms:1000
      ~author:(Author.Authenticated alice)
      ~kind:R.Kind.Runtime_grant
      ~body
  in
  let second =
    make_exn
      ~head:(R.head_after first)
      ~at_ms:2000
      ~author:Author.System_cron
      ~kind:R.Kind.Trigger_evidence
      ~body:(`List [ `String "t" ])
  in
  let third =
    make_exn
      ~head:(R.head_after second)
      ~at_ms:3000
      ~author:Author.Local_operator
      ~kind:R.Kind.Local_recovery
      ~body:`Null
  in
  [ first; second; third ]
;;

let decode_error_to_string = function
  | Ok _ -> "ok"
  | Error error -> R.decode_error_to_string error
;;

let expect_decode_error ~head line expected =
  Alcotest.(check string)
    "decode error"
    (R.decode_error_to_string expected)
    (decode_error_to_string (R.of_line ~head line))
;;

(* [of_line] answers with the same record [make] built. *)
let lines_read_back_in_order () =
  ignore
    (List.fold_left
       (fun head record ->
         match R.of_line ~head (R.to_line record) with
         | Ok back ->
           Alcotest.(check string) "line" (R.to_line record) (R.to_line back);
           Alcotest.(check int) "seq" record.R.seq back.R.seq;
           Alcotest.(check string)
             "hash"
             (R.Hash.to_hex record.R.hash)
             (R.Hash.to_hex back.R.hash);
           R.head_after back
         | Error error -> Alcotest.failf "line rejected: %s" (R.decode_error_to_string error))
       R.genesis
       chain)
;;

let heads_follow_the_chain () =
  Alcotest.(check int) "genesis starts at 1" 1 (R.next_seq R.genesis);
  Alcotest.(check string)
    "genesis hash"
    (String.make 64 '0')
    (R.Hash.to_hex (R.head_hash R.genesis));
  let first = List.hd chain in
  Alcotest.(check int) "second position" 2 (R.next_seq (R.head_after first));
  Alcotest.(check string)
    "second record points at the first"
    (R.Hash.to_hex first.R.hash)
    (R.Hash.to_hex (R.head_hash (R.head_after first)));
  Alcotest.(check string)
    "first record points at genesis"
    (R.Hash.to_hex (R.head_hash R.genesis))
    (R.Hash.to_hex first.R.previous_hash)
;;

let different_content_has_a_different_hash () =
  let hash_of ~at_ms ~body =
    R.Hash.to_hex
      (make_exn
         ~head:R.genesis
         ~at_ms
         ~author:(Author.Authenticated alice)
         ~kind:R.Kind.Runtime_grant
         ~body)
        .R.hash
  in
  let base = hash_of ~at_ms:1 ~body in
  Alcotest.(check bool) "same content, same hash" true (String.equal base (hash_of ~at_ms:1 ~body));
  Alcotest.(check bool) "time" false (String.equal base (hash_of ~at_ms:2 ~body));
  Alcotest.(check bool)
    "body"
    false
    (String.equal base (hash_of ~at_ms:1 ~body:(`Assoc [ "x", `Int 2 ])))
;;

let make_refuses_an_author_who_may_not_write () =
  match
    R.make
      ~head:R.genesis
      ~at_ms:0
      ~author:Author.System_cron
      ~kind:R.Kind.Runtime_grant
      ~body
  with
  | Error (R.Author_not_admitted { kind; author = _ }) ->
    Alcotest.(check string) "kind" "runtime_grant" (R.Kind.to_string kind)
  | Ok _ -> Alcotest.fail "a cron job wrote a grant"
;;

(* The lines of [chain], to edit one at a time. *)
let lines = List.map R.to_line chain

(* [line] with its one occurrence of [old] replaced by [by]. *)
let replace_once ~line ~old ~by =
  let rec find from =
    if from + String.length old > String.length line
    then Alcotest.failf "%S is not in %S" old line
    else if String.equal (String.sub line from (String.length old)) old
    then from
    else find (from + 1)
  in
  let index = find 0 in
  let rest = index + String.length old in
  String.sub line 0 index ^ by ^ String.sub line rest (String.length line - rest)
;;

let first_line = List.nth lines 0
let second_line = List.nth lines 1
let after_first = R.head_after (List.nth chain 0)

let tamper_tests =
  let case name ~head line expected =
    Alcotest.test_case name `Quick (fun () -> expect_decode_error ~head line expected)
  in
  [ case "not json" ~head:R.genesis "{" R.Not_json
  ; case "a number, not a record" ~head:R.genesis "7" R.Unexpected_shape
  ; case
      "an extra field"
      ~head:R.genesis
      (replace_once ~line:first_line ~old:{|,"hash"|} ~by:{|,"note":1,"hash"|})
      R.Unexpected_shape
  ; case
      "a missing field"
      ~head:R.genesis
      (replace_once ~line:first_line ~old:{|"seq":1,|} ~by:"")
      R.Unexpected_shape
  ; case
      "unknown kind"
      ~head:R.genesis
      (replace_once ~line:first_line ~old:"runtime_grant" ~by:"grant")
      (R.Unknown_kind "grant")
  ; case
      "unknown author"
      ~head:R.genesis
      (replace_once ~line:first_line ~old:{|"authenticated"|} ~by:{|"root"|})
      R.Invalid_author
  ; case
      "hash in capitals"
      ~head:R.genesis
      (replace_once ~line:first_line ~old:{|"previous_hash":"0|} ~by:{|"previous_hash":"A|})
      R.Invalid_hash
  ; case
      "the second line where the first belongs"
      ~head:R.genesis
      second_line
      (R.Seq_mismatch { expected = 1; actual = 2 })
  ; case
      "the first line again"
      ~head:after_first
      first_line
      (R.Seq_mismatch { expected = 2; actual = 1 })
  ; case
      "a line that points at another predecessor"
      ~head:after_first
      (replace_once
         ~line:second_line
         ~old:(R.Hash.to_hex (List.nth chain 0).R.hash)
         ~by:(String.make 64 'f'))
      R.Previous_hash_mismatch
  ; case
      "the body changed"
      ~head:R.genesis
      (replace_once ~line:first_line ~old:{|"x":1|} ~by:{|"x":2|})
      R.Hash_mismatch
  ; case
      "the time changed"
      ~head:R.genesis
      (replace_once ~line:first_line ~old:{|"at_ms":1000|} ~by:{|"at_ms":1001|})
      R.Hash_mismatch
  ; case
      "the author changed to another principal"
      ~head:R.genesis
      (replace_once ~line:first_line ~old:{|"id":"alice"|} ~by:{|"id":"mallory"|})
      R.Hash_mismatch
  ; case
      "an author who may not write the kind"
      ~head:R.genesis
      (replace_once
         ~line:first_line
         ~old:{|{"type":"authenticated","principal":{"type":"human","id":"alice"}}|}
         ~by:{|{"type":"system_cron"}|})
      (R.Author_not_admitted_to_write
         { kind = R.Kind.Runtime_grant; author = Author.System_cron })
  ; case
      "spaces added"
      ~head:R.genesis
      (replace_once ~line:first_line ~old:{|"seq":1,|} ~by:{|"seq": 1,|})
      R.Non_canonical
  ]
;;

let hash_hex_checks () =
  Alcotest.(check bool)
    "64 lowercase hex"
    true
    (Option.is_some (R.Hash.of_hex (String.make 64 'a')));
  Alcotest.(check bool) "capitals" true (Option.is_none (R.Hash.of_hex (String.make 64 'A')));
  Alcotest.(check bool) "too short" true (Option.is_none (R.Hash.of_hex (String.make 63 'a')));
  Alcotest.(check bool) "too long" true (Option.is_none (R.Hash.of_hex (String.make 65 'a')));
  Alcotest.(check bool) "not hex" true (Option.is_none (R.Hash.of_hex (String.make 64 'g')))
;;

let () =
  Alcotest.run
    "authz_record"
    [ "who may write what", pairing_tests
    ; ( "kinds"
      , [ Alcotest.test_case "all listed" `Quick kinds_are_all_listed
        ; Alcotest.test_case "labels round trip" `Quick kind_labels_round_trip
        ] )
    ; ( "chain"
      , [ Alcotest.test_case "lines read back in order" `Quick lines_read_back_in_order
        ; Alcotest.test_case "heads follow the chain" `Quick heads_follow_the_chain
        ; Alcotest.test_case "hash covers the content" `Quick different_content_has_a_different_hash
        ; Alcotest.test_case "hash text" `Quick hash_hex_checks
        ; Alcotest.test_case
            "make refuses an author who may not write"
            `Quick
            make_refuses_an_author_who_may_not_write
        ] )
    ; "a line that was changed", tamper_tests
    ]
;;
