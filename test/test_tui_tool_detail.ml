open Alcotest

module Tool_detail = Masc_tui_tool_detail

let marked =
  { Tool_detail.branch = "<br>"
  ; label = "<lab>"
  ; separator = "<sep>"
  ; key = "<key>"
  ; string_ = "<str>"
  ; number = "<num>"
  ; literal = "<lit>"
  ; punctuation = "<pun>"
  ; note = "<note>"
  ; reset = "<->"
  }

let holds needle haystack =
  let n = String.length needle and h = String.length haystack in
  let rec scan i = i + n <= h && (String.equal (String.sub haystack i n) needle || scan (i + 1)) in
  n = 0 || scan 0

let test_a_value_is_painted_after_it_is_made_safe () =
  (* The sweep that makes a value terminal-safe replaces control bytes with
     spaces, and an escape code is control bytes. Painting a sanitised string
     keeps the marker; sanitising a painted one would eat it. The value here
     carries a real escape, which must not survive as one. *)
  let rendered =
    Tool_detail.tree ~palette:marked
      [ { Tool_detail.fd_label = "state"
        ; fd_value = Tool_detail.Text "RET\027[31mURNED"
        ; fd_tone = "<tone>"
        } ]
  in
  match rendered with
  | [ row ] ->
    check bool "the field's own tone is applied" true (holds "<tone>" row);
    check bool "the value's escape did not survive" false
      (String.contains row '\027')
  | _ -> fail "expected one row"

let fold = { Tool_detail.fold_rows = 8; fold_note = Printf.sprintf "+%d more" }

let test_a_payload_that_does_not_parse_is_terminal_safe () =
  let escape = "\027[31m" in
  check bool "an escape does not survive a payload that is not JSON" false
    (holds escape (Tool_detail.structured ("RETURNED" ^ escape)));
  check bool "nor one in a bare scalar" false
    (holds escape (Tool_detail.structured ("\"x" ^ escape ^ "\"")));
  (* Making a payload safe replaces control bytes, and a newline is not one
     of them: the lines a producer wrote are still its own. *)
  check string "a payload keeps the lines it came with" "one\ntwo"
    (Tool_detail.structured "one\ntwo")
;;

let test_structured_json_sanitizes_keys_and_values () =
  let bidi = "\226\128\174" and c1 = "\194\128" and selector = "\239\184\143" in
  let emoji = "👩‍💻" in
  let value = `Assoc [ ("key" ^ bidi, `List [`String ("value" ^ c1 ^ "\000" ^ selector ^ emoji)]) ] in
  let payload = Yojson.Safe.to_string value in
  let shown = Tool_detail.structured payload in
  List.iter (fun (label, raw) -> check bool label false (holds raw shown))
    ["bidi in key", bidi; "C1 in value", c1; "orphan selector", selector];
  List.iter (fun escape -> check bool "control has a visible escape" true (holds escape shown))
    ["\\u202E"; "\\u0080"; "\\uFE0F"];
  check bool "valid emoji stays intact" true (holds emoji shown);
  check bool "JSON value is preserved" true (Yojson.Safe.from_string shown = value);
  let painted = Tool_detail.structured ~palette:marked payload in
  check bool "key remains styled" true (holds "<key>" painted);
  check bool "string remains styled" true (holds "<str>" painted);
  check bool "styling does not expose bidi" false (holds bidi painted)

let documents =
  [ {|{"a": 1, "b": [true, null, "x"], "c": {"d": "e"}}|}
  ; {|[1, 2, {"k": "v"}]|}
  ; {|{"nested": "{\"inner\": [1, 2]}"}|}
  ; {|{}|}
  ; {|[]|}
  ; {|{"multi": "line one\nline two"}|}
  ]

let test_a_json_document_is_served_as_structured_serves_it () =
  List.iter
    (fun payload ->
      check (option string)
        (payload ^ ": the plain text is structured's")
        (Some (Tool_detail.structured payload))
        (Tool_detail.document payload);
      check (option string)
        (payload ^ ": the painted text is structured's")
        (Some (Tool_detail.structured ~palette:marked payload))
        (Tool_detail.document ~palette:marked payload))
    documents

let not_documents =
  [ ""
  ; "   "
  ; "RETURNED"
  ; "prose with \"quotes\" and 3 numbers"
  ; "\"just a string\""
  ; "42"
  ; "true"
  ; "null"
  ; {|{"a":|}
  ; "{not json}"
  ]

let test_anything_else_is_not_a_document () =
  List.iter
    (fun payload ->
      check (option string) (Printf.sprintf "%S" payload) None
        (Tool_detail.document payload))
    not_documents

let test_a_document_is_terminal_safe () =
  let payload =
    Yojson.Safe.to_string
      (`Assoc
        [ ("key\027[31m", `String "value\027[31m")
        ; ("block", `String "one\nthree\027[31m")
        ])
  in
  match Tool_detail.document ~palette:marked payload with
  | Some text ->
    check bool "no escape byte in the text" false (String.contains text '\027');
    check bool "a key is painted" true (holds "<key>" text);
    check bool "a string is painted" true (holds "<str>" text)
  | None -> fail "a JSON object is a document"

(* One member to a line, each part in its own role. *)
let test_a_document_has_one_member_to_a_line_in_its_roles () =
  check (option string) "an object"
    (Some
       (String.concat "\n"
          [ "<pun>{<->"
          ; "  <key>\"a\"<-><pun>: <-><num>1<-><pun>,<->"
          ; "  <key>\"b\"<-><pun>: <-><lit>true<-><pun>,<->"
          ; "  <key>\"c\"<-><pun>: <-><str>\"x\"<->"
          ; "<pun>}<->"
          ]))
    (Tool_detail.document ~palette:marked {|{"a": 1, "b": true, "c": "x"}|});
  check (option string) "an array"
    (Some
       (String.concat "\n"
          [ "<pun>[<->"; "  <lit>null<-><pun>,<->"; "  <num>2<->"; "<pun>]<->" ]))
    (Tool_detail.document ~palette:marked "[null, 2]")

(* A string that is itself a document is drawn as that document. *)
let test_a_string_document_is_unfolded () =
  check (option string) "the inner object is a member of the outer one"
    (Some
       (String.concat "\n"
          [ "<pun>{<->"
          ; "  <key>\"n\"<-><pun>: <-><pun>{<->"
          ; "    <key>\"i\"<-><pun>: <-><num>1<->"
          ; "  <pun>}<->"
          ; "<pun>}<->"
          ]))
    (Tool_detail.document ~palette:marked {|{"n": "{\"i\": 1}"}|})

let () =
  run
    "tui_tool_detail"
    [ ( "structured"
      , [] )
    ; ( "document"
      , [ test_case "a JSON document is served as structured serves it" `Quick
            test_a_json_document_is_served_as_structured_serves_it
        ; test_case "anything else is not a document" `Quick
            test_anything_else_is_not_a_document
        ; test_case "a document is terminal safe" `Quick
            test_a_document_is_terminal_safe
        ; test_case "a document has one member to a line in its roles" `Quick
            test_a_document_has_one_member_to_a_line_in_its_roles
        ; test_case "a string document is unfolded" `Quick
            test_a_string_document_is_unfolded
        ] )
    ; ( "tree"
      , [] )
    ; ( "fold"
      , [] )
    ; ( "palette"
      , [ test_case "a value is painted after it is made safe" `Quick
            test_a_value_is_painted_after_it_is_made_safe
        ; test_case "a payload that does not parse is terminal safe" `Quick
            test_a_payload_that_does_not_parse_is_terminal_safe
        ; test_case "structured JSON sanitizes keys and values" `Quick
            test_structured_json_sanitizes_keys_and_values
        ] )
    ]
;;
