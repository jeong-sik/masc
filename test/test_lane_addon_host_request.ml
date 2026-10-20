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

let test_question_requests_are_strict () =
  let listing items = `Assoc [ "requests", `List items ] in
  let question = `Assoc [ "question_id", `String "q"; "header", `String "H"; "prompt", `String "P"; "choices", `List []
                        ; "mode", `String "single"; "free_text", `Assoc [ "kind", `String "allowed"; "hint", `Null ] ] in
  (match Host.listing_of_json (listing [ `Assoc [ "kind", `String "ask"; "request_id", `String "a"; "questions", `List [ question ] ]
                                       ; `Assoc [ "kind", `String "withdraw_ask"; "request_id", `String "w"; "ask_id", `String "a"
                                                ; "reason", `String "done" ] ]) with
   | Ok [ Host.Ask { questions = [ _ ]; context = None; _ }; Host.Withdraw_ask { ask_id = "a"; _ } ] -> ()
   | Ok _ | Error _ -> fail "an ask and a withdrawal must decode");
  List.iter (fun (label, item) -> check bool label true (Result.is_error (Host.listing_of_json (listing [ item ]))))
    [ "an ask without questions", `Assoc [ "kind", `String "ask"; "request_id", `String "a"; "questions", `List [] ]
    ; "a question nobody can answer", `Assoc [ "kind", `String "ask"; "request_id", `String "a"
                                             ; "questions", `List [ `Assoc [ "question_id", `String "q"; "header", `String "H"; "prompt", `String "P"
                                                                          ; "choices", `List []; "mode", `String "single"
                                                                          ; "free_text", `Assoc [ "kind", `String "choices_only" ] ] ] ]
    ; "a withdrawal without a reason", `Assoc [ "kind", `String "withdraw_ask"; "request_id", `String "w"; "ask_id", `String "a" ] ]

let test_question_request_identity_roundtrips () =
  let question = `Assoc ["question_id", `String "rich"; "header", `String "Decision";
    "prompt", `String "Pick and explain\nwhy";
    "choices", `List [`Assoc ["choice_id", `String "a"; "label", `String "First";
      "description", `String "Full description"]; `Assoc ["choice_id", `String "b";
      "label", `String "Second"; "description", `Null]];
    "mode", `String "multi"; "free_text", `Assoc ["kind", `String "allowed";
      "hint", `String "Explain the choice"]] in
  let second = `Assoc ["question_id", `String "plain"; "header", `String "Detail";
    "prompt", `String "Add detail"; "choices", `List []; "mode", `String "single";
    "free_text", `Assoc ["kind", `String "allowed"; "hint", `Null]] in
  let ask = `Assoc ["kind", `String "ask"; "request_id", `String "ask-rich";
    "questions", `List [question; second]; "context", `String "Operator context\nwith details"] in
  let withdraw = `Assoc ["kind", `String "withdraw_ask"; "request_id", `String "withdraw-rich";
    "ask_id", `String "ask-rich"; "reason", `String "Superseded\nby new evidence"] in
  match Host.listing_of_json (`Assoc ["requests", `List [ask; withdraw]]) with
  | Error detail -> fail detail
  | Ok requests ->
      check (list string) "every upper request keeps its exact id" ["ask-rich"; "withdraw-rich"]
        (List.map Host.request_id requests);
      check bool "canonical questions, context, target and reason survive retention" true
        (List.map Host.to_json requests = [ask; withdraw]);
      check bool "canonical requests decode back to the same values" true
        (Host.listing_of_json (`Assoc ["requests", `List (List.map Host.to_json requests)]) = Ok requests)

let test_the_answer_is_strict () =
  check bool "accepted" true (Host.accepted_of_json (`Assoc [ "accepted", `Bool true ]) = Ok true);
  check bool "not accepted" true (Host.accepted_of_json (`Assoc [ "accepted", `Bool false ]) = Ok false);
  List.iter (fun json -> check bool "anything else is refused" true (Result.is_error (Host.accepted_of_json json)))
    [ `Assoc []; `Assoc [ "accepted", `String "yes" ]; `Assoc [ "accepted", `Bool true; "detail", `String "x" ] ]

let test_a_result_read_is_request_bound () =
  let request : Host.t = Read_result {request_id="part"; original_request_id="page";
    source_id=Some "board"; sha256=String.make 64 'a'; offset=4096} in
  let listing json = Host.listing_of_json (`Assoc ["requests", `List [json]]) in
  check bool "continuation identity roundtrips" true (listing (Host.to_json request) = Ok [request]);
  let fields = match Host.to_json request with `Assoc fields -> fields | _ -> fail "request must be an object" in
  List.iter (fun fields -> check bool "malformed continuation is refused" true
      (Result.is_error (listing (`Assoc fields))))
    [("offset", `Int (-1)) :: List.remove_assoc "offset" fields;
     ("sha256", `String "arbitrary-hash") :: List.remove_assoc "sha256" fields;
     List.remove_assoc "source_id" fields;
     ("offset", `Int 0) :: fields;
     ("max_bytes", `Int 1) :: fields]

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
        ; test_case "question requests are strict" `Quick test_question_requests_are_strict
        ; test_case "question identities roundtrip through retention" `Quick test_question_request_identity_roundtrips
        ; test_case "the answer is strict" `Quick test_the_answer_is_strict
        ; test_case "a result read is bound to the original request" `Quick test_a_result_read_is_request_bound
        ; test_case "a package cannot export the host tools" `Quick test_a_package_cannot_export_the_host_tools ] ) ]
