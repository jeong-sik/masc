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
    ; Mode_event, [ "local operator" ]
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
  | R.Kind.Mode_event -> 10
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

let body_of json =
  match Authz_body.of_yojson json with
  | Ok body -> body
  | Error error -> Alcotest.failf "fixture body refused: %s" (Authz_body.error_to_string error)
;;

let body = body_of (`Assoc [ "x", `Int 1 ])

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
      ~body:(body_of (`List [ `String "t" ]))
  in
  let third =
    make_exn
      ~head:(R.head_after second)
      ~at_ms:3000
      ~author:Author.Local_operator
      ~kind:R.Kind.Local_recovery
      ~body:Authz_body.null
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
    (String.equal base (hash_of ~at_ms:1 ~body:(body_of (`Assoc [ "x", `Int 2 ]))))
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

(* One record written out by hand. Python rebuilt this line and its hash from
   the design alone: the field order, the "masc-authz-record-v1\n" prefix, and
   the escapes of Python's json module. The bytes matched. If this module
   changes a field, an escape, or the hash prefix, a log already on disk stops
   verifying, and this test fails first. *)
let golden_body =
  body_of
    (`Assoc
        [ "text", `String "quote \" backslash \\ tab \t control \001 caf\u{e9} \u{65e5}\u{672c}"
        ; "count", `Int (-12345)
        ; "flag", `Bool true
        ; "none", `Null
        ; "items", `List [ `Int 1; `String "two" ]
        ])
;;

let golden_hash = "8d1574bce143d9011dcd49a49471526da380e87ad6a066b6fcb374bc86f74a68"
let golden_line = {|{"seq":1,"previous_hash":"0000000000000000000000000000000000000000000000000000000000000000","at_ms":1793145600000,"author":{"type":"authenticated","principal":{"type":"human","id":"alice"}},"kind":"runtime_grant","body":{"text":"quote \" backslash \\ tab \t control \u0001 café 日本","count":-12345,"flag":true,"none":null,"items":[1,"two"]},"hash":"8d1574bce143d9011dcd49a49471526da380e87ad6a066b6fcb374bc86f74a68"}|}

let a_fixed_line_keeps_its_bytes_and_its_hash () =
  let record =
    make_exn
      ~head:R.genesis
      ~at_ms:1793145600000
      ~author:(Author.Authenticated alice)
      ~kind:R.Kind.Runtime_grant
      ~body:golden_body
  in
  Alcotest.(check string) "line" golden_line (R.to_line record);
  Alcotest.(check string) "hash" golden_hash (R.Hash.to_hex record.R.hash);
  match R.of_line ~head:R.genesis golden_line with
  | Ok back -> Alcotest.(check string) "read back" golden_line (R.to_line back)
  | Error error ->
    Alcotest.failf "the fixed line is rejected: %s" (R.decode_error_to_string error)
;;

let contains ~sub text =
  let sub_length = String.length sub in
  let rec from index =
    index + sub_length <= String.length text
    && (String.equal (String.sub text index sub_length) sub || from (index + 1))
  in
  from 0
;;

(* The words that name a kind and an author on disk. Renaming one orphans every
   line already written with it. *)
let kind_labels_are_the_names_on_disk () =
  Alcotest.(check (list string))
    "labels"
    [ "runtime_grant"
    ; "delegate_policy"
    ; "principal"
    ; "internal_service_credential"
    ; "permission_revocation"
    ; "trigger_evidence"
    ; "lease_terminal_evidence"
    ; "preauthorized_expiry"
    ; "migration_diagnostic"
    ; "local_recovery"
    ; "mode_event"
    ]
    (List.map R.Kind.to_string R.Kind.all)
;;

let author_words =
  [ ( Author.Authenticated alice
    , R.Kind.Runtime_grant
    , {|{"type":"authenticated","principal":{"type":"human","id":"alice"}}|} )
  ; ( Author.Authenticated keeper
    , R.Kind.Runtime_grant
    , {|{"type":"authenticated","principal":{"type":"service","id":"keeper-1"}}|} )
  ; Author.Local_operator, R.Kind.Local_recovery, {|{"type":"local_operator"}|}
  ; Author.System_cron, R.Kind.Trigger_evidence, {|{"type":"system_cron"}|}
  ; Author.System_maintenance, R.Kind.Lease_terminal_evidence, {|{"type":"system_maintenance"}|}
  ; Author.System_migration, R.Kind.Migration_diagnostic, {|{"type":"system_migration"}|}
  ]
;;

let author_shapes_are_the_names_on_disk () =
  List.iter
    (fun (author, kind, words) ->
      let line =
        R.to_line (make_exn ~head:R.genesis ~at_ms:0 ~author ~kind ~body:Authz_body.null)
      in
      let expected = {|"author":|} ^ words ^ {|,"kind":"|} ^ R.Kind.to_string kind ^ {|"|} in
      Alcotest.(check bool) expected true (contains ~sub:expected line))
    author_words
;;

(* Which bodies exist is tested in test_authz_body. These check that a record
   keeps a body that holds each kind of value, and reads it back. *)

let plain_bodies =
  [ "null", `Null
  ; ( "nested objects and lists"
    , `Assoc [ "a", `Assoc [ "b", `List [ `Int 1; `Null; `Bool false ] ]; "c", `String "text" ] )
  ; "the same name at different depths", `Assoc [ "x", `Assoc [ "x", `Int 1 ] ]
  ; "non-ASCII text", `Assoc [ "name", `String "caf\u{e9} \u{65e5}\u{672c}" ]
  ; "the largest int every reader reads exactly", `Int 9007199254740991
  ; "an empty object and an empty list", `List [ `Assoc []; `List [] ]
  ]
;;

let plain_bodies_are_accepted () =
  List.iter
    (fun (label, json) ->
      let body = body_of json in
      let record =
        make_exn
          ~head:R.genesis
          ~at_ms:0
          ~author:(Author.Authenticated alice)
          ~kind:R.Kind.Runtime_grant
          ~body
      in
      match R.of_line ~head:R.genesis (R.to_line record) with
      | Ok back ->
        Alcotest.(check string)
          label
          (Authz_body.to_string body)
          (Authz_body.to_string back.R.body)
      | Error error ->
        Alcotest.failf "%s: written but not read back: %s" label (R.decode_error_to_string error))
    plain_bodies
;;

(* [line] with its hash made over what it now says, as a writer would sign it.
   The prefix is the one the golden line pins. *)
let resign line =
  let hash_member_start = {|,"hash":"|} in
  let hash_member_length = String.length hash_member_start + 64 + String.length {|"}|} in
  let cut = String.length line - hash_member_length in
  let unsigned = String.sub line 0 cut ^ "}" in
  let hash =
    Agent_core_sha256.to_hex
      (Agent_core_sha256.digest_string ("masc-authz-record-v1\n" ^ unsigned))
  in
  String.sub line 0 cut ^ hash_member_start ^ hash ^ {|"}|}
;;

let resigning_an_untouched_line_changes_nothing () =
  Alcotest.(check string) "first line" first_line (resign first_line);
  Alcotest.(check string) "second line" second_line (resign second_line)
;;

(* Each line below carries a correct hash over its own text, and the body is the
   only thing wrong with it. *)
let invalid_body_line_tests =
  let case name ~by expected =
    Alcotest.test_case name `Quick (fun () ->
      expect_decode_error
        ~head:R.genesis
        (resign (replace_once ~line:first_line ~old:{|"x":1|} ~by))
        (R.Invalid_body expected))
  in
  [ case "a repeated name, signed" ~by:{|"x":1,"x":2|} (Authz_body.Repeated_name "x")
  ; case "a float, signed" ~by:{|"x":1.5|} Authz_body.Float_not_allowed
  ; case "a float written as a whole number, signed" ~by:{|"x":1.0|} Authz_body.Float_not_allowed
  ; case "an exponent, signed" ~by:{|"x":1e2|} Authz_body.Float_not_allowed
  ; case "text that is not UTF-8, signed" ~by:"\"x\":\"\xff\"" Authz_body.Invalid_utf8
  ; case "an int above 2^53 - 1, signed" ~by:{|"x":9007199254740992|} Authz_body.Integer_out_of_range
  ; case
      "an int below -(2^53 - 1), signed"
      ~by:{|"x":-9007199254740992|}
      Authz_body.Integer_out_of_range
  ; case
      "an int too large for an OCaml int, signed"
      ~by:{|"x":123456789012345678901234567890|}
      Authz_body.Integer_out_of_range
  ; (* Yojson 3.0.0 reads the escape of a low surrogate half as three bytes that
       are not UTF-8. *)
    case "half of a surrogate pair, signed" ~by:{|"x":"\udc00"|} Authz_body.Invalid_utf8
  ]
;;

(* Yojson 3.0.0 refuses the escape of a high surrogate half that has no low half
   after it, so the line is not read at all. *)
let a_high_surrogate_half_is_not_json () =
  expect_decode_error
    ~head:R.genesis
    (resign (replace_once ~line:first_line ~old:{|"x":1|} ~by:{|"x":"\ud800"|}))
    R.Not_json
;;

(* The characters of an identifier are written as they are, so the author text
   is the identifier between quotes. *)
let no_identifier_character_needs_an_escape () =
  let accepted = ref 0 in
  for byte = 0 to 255 do
    let text = "x" ^ String.make 1 (Char.chr byte) in
    match User_id.of_string text, Service_id.of_string text with
    | Ok _, Ok _ ->
      incr accepted;
      Alcotest.(check string)
        (Printf.sprintf "byte %d" byte)
        ("\"" ^ text ^ "\"")
        (Authz_body.string_literal text)
    | Error _, Error _ -> ()
    | Ok _, Error _ | Error _, Ok _ -> Alcotest.failf "byte %d: the two id types disagree" byte
  done;
  Alcotest.(check bool) "some bytes are accepted" true (!accepted > 0)
;;

let () =
  Alcotest.run
    "authz_record"
    [ "who may write what", pairing_tests
    ; ( "kinds"
      , [ Alcotest.test_case "all listed" `Quick kinds_are_all_listed
        ; Alcotest.test_case "labels round trip" `Quick kind_labels_round_trip
        ; Alcotest.test_case "labels are the names on disk" `Quick kind_labels_are_the_names_on_disk
        ; Alcotest.test_case "author shapes are the names on disk" `Quick author_shapes_are_the_names_on_disk
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
        ; Alcotest.test_case "a fixed line keeps its bytes and its hash" `Quick a_fixed_line_keeps_its_bytes_and_its_hash
        ] )
    ; "a line that was changed", tamper_tests
    ; ( "a body that is plain JSON"
      , [ Alcotest.test_case "accepted and read back" `Quick plain_bodies_are_accepted
        ; Alcotest.test_case "resigning changes nothing" `Quick resigning_an_untouched_line_changes_nothing
        ; Alcotest.test_case
            "no identifier character needs an escape"
            `Quick
            no_identifier_character_needs_an_escape
        ] )
    ; ( "a signed line with a body that is not plain"
      , Alcotest.test_case
          "half of a surrogate pair that cannot be read"
          `Quick
          a_high_surrogate_half_is_not_json
        :: invalid_body_line_tests )
    ]
;;
