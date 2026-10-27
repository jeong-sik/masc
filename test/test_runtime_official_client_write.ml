open Alcotest

module Write = Runtime_official_client_write

let hash text = Agent_core_sha256.(digest_string text |> to_hex)

let fragments (write : Write.t) =
  match write.fragments with
  | Write.Partitioned fragments -> fragments
  | Write.Serialization_mismatch -> fail "the compact serializer's own output was not partitioned"
;;

let message =
  `Assoc
    [ "uuid", `String "u-1"
    ; "type", `String "user"
    ; ( "message"
      , `Assoc
          [ "role", `String "user"
          ; ( "content"
            , `List
                [ `Assoc [ "type", `String "image"; "data", `String "aGVsbG8=" ]
                ; `Assoc [ "type", `String "text"; "text", `String "first \"quoted\"\nline" ]
                ; `Assoc [ "type", `String "text"; "text", `String "second" ]
                ] )
          ] )
    ]
;;

let selection = Write.(Fields [ "message", Fields [ "content", turn_input ] ])

(* Every byte of the line is either one selected slot or the carrier, so the
   slots plus the carrier rebuild the count, and each slot is the JSON value
   it names, read from the written bytes. *)
let test_a_json_line_partitions_the_written_bytes () =
  let payload = Yojson.Safe.to_string message in
  let write = Write.json_line selection message payload in
  check int "the write counts the line" (String.length payload) write.bytes;
  check string "the write hashes the line" (hash payload) write.sha256;
  let selected, carrier =
    List.partition
      (fun (fragment : Write.fragment) -> fragment.slot <> Write.Unattributed_carrier)
      (fragments write)
  in
  check (list int) "text elements are selected by their position after the image" [ 1; 2 ]
    (List.map
       (fun (fragment : Write.fragment) ->
          match fragment.slot with
          | Write.Turn_text index -> index
          | Write.Whole_write | Developer_instructions | Dynamic_tools | Injected_item _
          | Unattributed_carrier -> fail "a slot other than turn text was selected")
       selected);
  List.iter
    (fun (fragment : Write.fragment) ->
       match fragment.offset with
       | None -> fail "a selected slot has no offset"
       | Some offset ->
         let bytes = String.sub payload offset fragment.bytes in
         check string "the slot hash is of the bytes at its offset" (hash bytes) fragment.sha256)
    selected;
  let total =
    List.fold_left (fun sum (fragment : Write.fragment) -> sum + fragment.bytes) 0 (selected @ carrier)
  in
  check int "slots and carrier cover every byte" (String.length payload) total;
  check bool "a text matches its slot as a JSON literal" true
    (Option.is_some (Write.matching_fragment write ~slot:(Turn_text 1) "first \"quoted\"\nline"));
  check bool "a changed text does not match" true
    (Option.is_none (Write.matching_fragment write ~slot:(Turn_text 1) "first \"quoted\" line"));
  check bool "a text does not match another slot" true
    (Option.is_none (Write.matching_fragment write ~slot:(Turn_text 2) "first \"quoted\"\nline"))
;;

let test_a_layout_the_walk_does_not_expect_is_not_attributed () =
  let pretty = Yojson.Safe.pretty_to_string message in
  let write = Write.json_line selection message pretty in
  check int "the write still counts what was written" (String.length pretty) write.bytes;
  check bool "no offsets are claimed" true (write.fragments = Write.Serialization_mismatch);
  check bool "no slot matches" true
    (Option.is_none (Write.matching_fragment write ~slot:(Turn_text 1) "first \"quoted\"\nline"))
;;

let test_a_raw_write_is_one_whole_slot () =
  let text = "prompt \"as written\"\n" in
  let write = Write.raw text in
  check int "bytes" (String.length text) write.bytes;
  check string "sha256" (hash text) write.sha256;
  check int "one slot" 1 (List.length (fragments write));
  check bool "the text matches as itself, not as a JSON literal" true
    (Option.is_some (Write.matching_fragment write ~slot:Whole_write text));
  check string "the expected digest is of the text itself" (hash text)
    (Write.encoded_text_sha256 write text)
;;

let test_an_observer_failure_does_not_fail_the_write () =
  Write.report ~label:"fixture" (fun _ -> failwith "observer broke") ();
  Write.report ~label:"fixture" (fun _ -> raise Eio.Time.Timeout) ();
  check bool "a reserved exception still propagates" true
    (match Write.report ~label:"fixture" (fun _ -> raise Sys.Break) () with
     | () -> false
     | exception Sys.Break -> true)
;;

let () =
  run
    "runtime_official_client_write"
    [ ( "receipt"
      , [ test_case "a JSON line partitions the written bytes" `Quick
            test_a_json_line_partitions_the_written_bytes
        ; test_case "an unexpected layout is not attributed" `Quick
            test_a_layout_the_walk_does_not_expect_is_not_attributed
        ; test_case "a raw write is one whole slot" `Quick test_a_raw_write_is_one_whole_slot
        ; test_case "an observer failure does not fail the write" `Quick
            test_an_observer_failure_does_not_fail_the_write
        ] )
    ]
;;
