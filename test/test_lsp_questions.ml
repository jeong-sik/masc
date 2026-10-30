open Alcotest

let json = Yojson.Safe.from_string

let locations = function
  | Lsp_questions.Locations locations -> locations
  | Lsp_questions.Hover_text _ -> failwith "expected locations"
;;

let hover = function
  | Lsp_questions.Hover_text text -> text
  | Lsp_questions.Locations _ -> failwith "expected hover"
;;

let parse question payload =
  match Lsp_questions.answer_of_json question (json payload) with
  | Ok answer -> answer
  | Error reason -> failwith reason
;;

let test_references_list () =
  let answer =
    parse
      Lsp_questions.References
      {|[{"uri":"file:///w/a.ml","range":{"start":{"line":3,"character":7},
          "end":{"line":3,"character":12}}},
         {"uri":"file:///w/b%20c.ml","range":{"start":{"line":9,"character":0},
          "end":{"line":9,"character":5}}}]|}
  in
  match locations answer with
  | [ first; second ] ->
    check string "first path" "/w/a.ml" first.Lsp_questions.path;
    check int "first line" 3 first.Lsp_questions.line;
    check int "first character" 7 first.Lsp_questions.character;
    (* The percent-encoded space survives the round trip, which string surgery
       on the [file://] prefix would not. *)
    check string "second path is decoded" "/w/b c.ml" second.Lsp_questions.path;
    check int "second line" 9 second.Lsp_questions.line
  | other -> failf "expected two locations, got %d" (List.length other)
;;

let test_definition_single_location () =
  let answer =
    parse
      Lsp_questions.Definition
      {|{"uri":"file:///w/a.ml","range":{"start":{"line":1,"character":2},
         "end":{"line":1,"character":8}}}|}
  in
  check int "one location" 1 (List.length (locations answer))
;;

let test_definition_location_link () =
  (* [LocationLink] is the other shape [textDocument/definition] may answer.
     [targetSelectionRange] is the symbol; [targetRange] is the whole
     definition, so the former wins when both are present. *)
  let answer =
    parse
      Lsp_questions.Definition
      {|[{"targetUri":"file:///w/a.ml",
          "targetRange":{"start":{"line":10,"character":0},
                         "end":{"line":20,"character":0}},
          "targetSelectionRange":{"start":{"line":10,"character":4},
                                  "end":{"line":10,"character":9}}}]|}
  in
  match locations answer with
  | [ only ] ->
    check string "path" "/w/a.ml" only.Lsp_questions.path;
    check int "line" 10 only.Lsp_questions.line;
    check int "selection start, not definition start" 4 only.Lsp_questions.character
  | other -> failf "expected one location, got %d" (List.length other)
;;

let test_null_is_an_empty_list_not_an_error () =
  check int "no references" 0 (List.length (locations (parse Lsp_questions.References "null")))
;;

let test_malformed_element_is_reported_not_dropped () =
  (* Dropping the bad element would answer [Locations [one]] for a file with
     two references, and nothing downstream could tell that from the truth. *)
  let result =
    Lsp_questions.answer_of_json
      Lsp_questions.References
      (json
         {|[{"uri":"file:///w/a.ml","range":{"start":{"line":1,"character":1},
             "end":{"line":1,"character":2}}},
            {"uri":"file:///w/b.ml"}]|})
  in
  match result with
  | Ok answer -> failf "expected an error, got %d locations" (List.length (locations answer))
  | Error reason -> check bool "names the missing range" true (reason <> "")
;;

let test_hover_markup_content () =
  check
    (option string)
    "markup value"
    (Some "int -> int")
    (hover (parse Lsp_questions.Hover {|{"contents":{"kind":"markdown","value":"int -> int"}}|}))
;;

let test_hover_bare_string () =
  check
    (option string)
    "bare string"
    (Some "int")
    (hover (parse Lsp_questions.Hover {|{"contents":"int"}|}))
;;

let test_hover_list_is_joined () =
  check
    (option string)
    "joined"
    (Some "int -> int\n\nthe doc")
    (hover
       (parse
          Lsp_questions.Hover
          {|{"contents":[{"language":"ocaml","value":"int -> int"},"the doc"]}|}))
;;

let test_hover_null_is_no_answer () =
  check (option string) "nothing to say" None (hover (parse Lsp_questions.Hover "null"))
;;

let test_question_names_round_trip () =
  List.iter
    (fun question ->
      let name = Lsp_questions.string_of_question question in
      check
        bool
        (Printf.sprintf "%s round trips" name)
        true
        (Lsp_questions.question_of_string name = Some question))
    [ Lsp_questions.References; Lsp_questions.Definition; Lsp_questions.Hover ];
  check
    bool
    "rename is not one of the three"
    true
    (Lsp_questions.question_of_string "rename" = None)
;;

let test_document_uri_identity () =
  let path = "/w/한글 # %.py" in
  let uri = Lsp_uri.file_uri_of_path path in
  check string "absolute file URI has an empty authority"
    "file:///w/%ED%95%9C%EA%B8%80%20%23%20%25.py" uri;
  check string "literal path survives encoding" path (Lsp_uri.path_of_file_uri uri);
  List.iter (fun other ->
    check bool "server spelling still identifies the opened document" true
      (Lsp_uri.same_local_document uri other))
    [ "file:/w/한글%20%23%20%25.py"
    ; "FILE://LOCALHOST/w/%ed%95%9c%ea%b8%80%20%23%20%25.py" ];
  List.iter (fun other ->
    check bool "another identity cannot release document analysis" false
      (Lsp_uri.same_local_document uri other))
    [ "file:///w/한글%20%23%20%2525.py"
    ; "file://remote/w/한글%20%23%20%25.py"
    ; "file://user@localhost/w/한글%20%23%20%25.py"
    ; "file://localhost:80/w/한글%20%23%20%25.py"
    ; uri ^ "?revision=1"; uri ^ "#fragment"
    ; "https:///w/한글%20%23%20%25.py"; "file:relative.py" ];
  check bool "two non-file strings are not local document identities" false
    (Lsp_uri.same_local_document "other" "other")
;;

let () =
  run
    "lsp_questions"
    [ ("document-uri", [test_case "server URI normalization preserves identity" `Quick
        test_document_uri_identity])
    ; ( "locations"
      , [ test_case "reads a list of Location" `Quick test_references_list
        ; test_case "reads a single Location" `Quick test_definition_single_location
        ; test_case "reads LocationLink" `Quick test_definition_location_link
        ; test_case "null is an empty list" `Quick test_null_is_an_empty_list_not_an_error
        ; test_case
            "a malformed element is an error"
            `Quick
            test_malformed_element_is_reported_not_dropped
        ] )
    ; ( "hover"
      , [ test_case "MarkupContent" `Quick test_hover_markup_content
        ; test_case "bare string" `Quick test_hover_bare_string
        ; test_case "list is joined" `Quick test_hover_list_is_joined
        ; test_case "null is no answer" `Quick test_hover_null_is_no_answer
        ] )
    ; "questions", [ test_case "names round trip" `Quick test_question_names_round_trip ]
    ]
;;
