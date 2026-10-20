(** The host request listing and the result answer are strict (RFC
    operator-quiz §4.4): anything else is refused whole. *)
open Alcotest
module Host = Masc.Lane_addon_host_request
module Types = Masc.Lane_addon_types

let exact id = `Assoc [ "kind", `String "exact_output"; "request_id", `String id; "output", `String "author"
                      ; "messages", `List [ `String "Write one question." ] ]

let test_a_listing_keeps_the_package_order () =
  match Host.listing_of_json (`Assoc [ "requests", `List [ exact "b"; exact "a" ] ]) with
  | Ok requests -> check (list string) "in order" [ "b"; "a" ] (List.map Host.request_id requests)
  | Error detail -> fail detail

let test_a_listing_is_refused_whole () =
  List.iter (fun (label, json) -> check bool label true (Result.is_error (Host.listing_of_json json)))
    [ "a kind this host does not have", `Assoc [ "requests", `List [ exact "a"; `Assoc [ "kind", `String "ask"; "request_id", `String "q" ] ] ]
    ; "a request id listed twice", `Assoc [ "requests", `List [ exact "a"; exact "a" ] ]
    ; "a malformed exact request", `Assoc [ "requests", `List [ `Assoc [ "kind", `String "exact_output"; "request_id", `String "a" ] ] ]
    ; "no kind", `Assoc [ "requests", `List [ `Assoc [ "request_id", `String "a" ] ] ]
    ; "another key beside requests", `Assoc [ "requests", `List []; "cursor", `Null ]
    ; "not an object", `List [] ];
  check bool "an empty listing is a listing" true (Host.listing_of_json (`Assoc [ "requests", `List [] ]) = Ok [])

let test_a_read_request_is_strict () =
  let read fields = `Assoc [ "requests", `List [ `Assoc (("kind", `String "read_records") :: fields) ] ] in
  (match Host.listing_of_json (read [ "request_id", `String "r"; "source_id", `String "board"; "after", `Null ]) with
   | Ok [ Host.Read_records { source_id; after = None; _ } ] -> check string "the source" "board" source_id
   | Ok _ | Error _ -> fail "a read from the beginning must decode");
  List.iter (fun (label, fields) -> check bool label true (Result.is_error (Host.listing_of_json (read fields))))
    [ "an unknown key", [ "request_id", `String "r"; "source_id", `String "board"; "limit", `Int 5 ]
    ; "a cursor that is not a string", [ "request_id", `String "r"; "source_id", `String "board"; "after", `Int 3 ]
    ; "no source", [ "request_id", `String "r" ] ]

let test_a_file_request_is_strict () =
  let file fields = `Assoc [ "requests", `List [ `Assoc (("kind", `String "read_file") :: fields) ] ] in
  (match Host.listing_of_json (file [ "request_id", `String "f"; "source_id", `String "repo"; "commit", `String "abc"; "path", `String "a.md" ]) with
   | Ok [ Host.Read_file { path; _ } ] -> check string "the path" "a.md" path
   | Ok _ | Error _ -> fail "a file request must decode");
  check bool "no path is refused" true
    (Result.is_error (Host.listing_of_json (file [ "request_id", `String "f"; "source_id", `String "repo"; "commit", `String "abc" ])))

let test_the_answer_is_strict () =
  check bool "accepted" true (Host.accepted_of_json (`Assoc [ "accepted", `Bool true ]) = Ok true);
  check bool "not accepted" true (Host.accepted_of_json (`Assoc [ "accepted", `Bool false ]) = Ok false);
  List.iter (fun json -> check bool "anything else is refused" true (Result.is_error (Host.accepted_of_json json)))
    [ `Assoc []; `Assoc [ "accepted", `String "yes" ]; `Assoc [ "accepted", `Bool true; "detail", `String "x" ] ]

let test_a_package_cannot_export_the_host_tools () =
  List.iter (fun name ->
      check bool name true (Result.is_error (Types.validate_exported_tools ~action_tool:None [ name ])))
    [ Types.host_requests_tool; Types.host_result_tool ]

let () =
  run "lane add-on host requests"
    [ ( "protocol"
      , [ test_case "a listing keeps the package order" `Quick test_a_listing_keeps_the_package_order
        ; test_case "a listing is refused whole" `Quick test_a_listing_is_refused_whole
        ; test_case "a read request is strict" `Quick test_a_read_request_is_strict
        ; test_case "a file request is strict" `Quick test_a_file_request_is_strict
        ; test_case "the answer is strict" `Quick test_the_answer_is_strict
        ; test_case "a package cannot export the host tools" `Quick test_a_package_cannot_export_the_host_tools ] ) ]
