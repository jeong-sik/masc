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

(* A document is judged on what it says, not on where it puts it: the value it
   keeps, the role each part takes, and that it is safe to draw. The rows and
   their indent are what the screen captures in the pull request show. *)

let documents =
  [ {|{"a": 1, "b": [true, null, "x"], "c": {"d": "e"}}|}
  ; {|[1, 2, {"k": "v"}]|}
  ; {|{"nested": "{\"inner\": [1, 2]}"}|}
  ; {|{}|}
  ; {|[]|}
  ; {|{"multi": "line one\nline two", "table": "a\tb\nc\td"}|}
  ]

(* What a plain palette draws is what a painted one draws without its
   markers. *)
let markers =
  [ "<br>"; "<lab>"; "<sep>"; "<key>"; "<str>"; "<num>"; "<lit>"; "<pun>"; "<note>"; "<->" ]

let remove marker text =
  let length = String.length marker in
  let buffer = Buffer.create (String.length text) in
  let rec go index =
    if index < String.length text then
      if index + length <= String.length text
         && String.equal (String.sub text index length) marker
      then go (index + length)
      else (
        Buffer.add_char buffer text.[index];
        go (index + 1))
  in
  go 0;
  Buffer.contents buffer

let without_markers text = List.fold_left (fun text marker -> remove marker text) text markers

let count marker text =
  let length = String.length marker in
  let rec go index found =
    if index + length > String.length text then found
    else if String.equal (String.sub text index length) marker then
      go (index + length) (found + 1)
    else go (index + 1) found
  in
  go 0 0

let document_exn ?palette payload =
  match Tool_detail.document ?palette payload with
  | Some text -> text
  | None -> failf "%s is a JSON object or array" payload

let test_the_palette_adds_markers_and_nothing_else () =
  List.iter
    (fun payload ->
      check string
        (payload ^ ": the painted text without its markers is the plain text")
        (document_exn payload)
        (without_markers (document_exn ~palette:marked payload));
      check bool
        (payload ^ ": the plain palette draws no marker")
        false
        (List.exists (fun marker -> holds marker (document_exn payload)) markers))
    documents

(* The plain text of a document without a block reads back as the value the
   payload holds, with each string that holds a document opened into it. A
   block is drawn for reading and does not read back. *)
let reads_back =
  let nested =
    Yojson.Safe.to_string
      (`Assoc
        [ ( "a"
          , `String
              (Yojson.Safe.to_string
                 (`Assoc
                   [ ( "b"
                     , `String
                         (Yojson.Safe.to_string
                            (`List [ `Int 1; `Assoc [ ("c", `Null) ] ])) )
                   ])) )
        ])
  in
  [ ( {|{"a": 1, "b": [true, null, "x"], "c": {"d": "e"}}|}
    , `Assoc
        [ ("a", `Int 1)
        ; ("b", `List [ `Bool true; `Null; `String "x" ])
        ; ("c", `Assoc [ ("d", `String "e") ])
        ] )
  ; ( {|[1, 2.5, {"k": "v"}]|}
    , `List [ `Int 1; `Float 2.5; `Assoc [ ("k", `String "v") ] ] )
  ; ( {|{"nested": "{\"inner\": [1, 2]}"}|}
    , `Assoc [ ("nested", `Assoc [ ("inner", `List [ `Int 1; `Int 2 ]) ]) ] )
  ; ( nested
    , `Assoc [ ("a", `Assoc [ ("b", `List [ `Int 1; `Assoc [ ("c", `Null) ] ]) ]) ] )
  ; ( {|{"quoted": "42", "word": "true", "open": "[not json"}|}
    , `Assoc
        [ ("quoted", `String "42")
        ; ("word", `String "true")
        ; ("open", `String "[not json")
        ] )
  ; {|{}|}, `Assoc []
  ; {|[]|}, `List []
  ]

let test_a_document_reads_back_as_its_value () =
  List.iter
    (fun (payload, expected) ->
      check bool
        (payload ^ ": the document holds the value, strings opened")
        true
        (Yojson.Safe.equal expected (Yojson.Safe.from_string (document_exn payload))))
    reads_back

(* One role for each kind of part. The lines of a block are the command's
   output and stay in the pane's own colour. *)
let test_each_part_is_drawn_in_its_role () =
  let roles payload =
    let text = document_exn ~palette:marked payload in
    [ count "<key>" text; count "<str>" text; count "<num>" text; count "<lit>" text ]
  in
  let expect label payload expected =
    check (list int) (label ^ " (keys, strings, numbers, literals)") expected (roles payload)
  in
  expect "members, a string, a number, two literals"
    {|{"a": 1, "b": [true, null, "x"], "c": {"d": "e"}}|} [ 4; 2; 1; 2 ];
  expect "a string that holds a document is its members" {|{"n": "{\"i\": 1}"}|}
    [ 2; 0; 1; 0 ];
  expect "a string that holds no document is a string" {|{"n": "42"}|} [ 1; 1; 0; 0 ];
  expect "a block is not a string value" {|{"b": "one\ntwo"}|} [ 1; 0; 0; 0 ]

let openers = [ "<key>"; "<str>"; "<num>"; "<lit>"; "<pun>" ]

(* Every opener is reset before the next opener and before the line ends, so
   no wrapper that cuts the text into rows leaves a colour on. *)
let styles_are_paired text =
  let length = String.length text in
  let starts marker index =
    index + String.length marker <= length
    && String.equal (String.sub text index (String.length marker)) marker
  in
  let rec scan index is_open =
    if index >= length then not is_open
    else if starts "<->" index then is_open && scan (index + 3) false
    else
      match List.find_opt (fun opener -> starts opener index) openers with
      | Some opener -> (not is_open) && scan (index + String.length opener) true
      | None -> if text.[index] = '\n' && is_open then false else scan (index + 1) is_open
  in
  scan 0 false

let test_a_style_ends_before_the_next_begins_and_before_a_line_does () =
  List.iter
    (fun payload ->
      check bool (payload ^ ": styles are paired") true
        (styles_are_paired (document_exn ~palette:marked payload)))
    documents

let hostile =
  "a\027[31mb\000c\001d\127e\226\128\174f\194\128g\226\129\166h\239\184\143i"

(* The raw bytes the terminal must never receive from a value. *)
let hostile_in text =
  String.exists (fun c -> (Char.code c < 0x20 && not (Char.equal c '\n')) || Char.code c = 0x7f) text
  || List.exists
       (fun raw -> holds raw text)
       [ "\226\128\174"; "\194\128"; "\226\129\166"; "\239\184\143" ]

let test_a_document_is_terminal_safe () =
  let payload =
    Yojson.Safe.to_string
      (`Assoc
        [ ("key" ^ hostile, `String ("value" ^ hostile))
        ; ("block", `String ("one\n" ^ hostile ^ "\ntwo\tcell"))
        ; ("list", `List [ `String hostile; `Assoc [ (hostile, `Null) ] ])
        ; ("nested", `String (Yojson.Safe.to_string (`Assoc [ (hostile, `String hostile) ])))
        ])
  in
  check bool "the payload carries hostile bytes to begin with" true (hostile_in payload);
  match Tool_detail.document payload, Tool_detail.document ~palette:marked payload with
  | Some plain_text, Some painted ->
    check bool "a plain document carries no hostile byte" false (hostile_in plain_text);
    check bool "nor does a painted one" false (hostile_in painted);
    check bool "a key is painted" true (holds "<key>" painted);
    check bool "a string is painted" true (holds "<str>" painted)
  | _ -> fail "a JSON object is a document"

let numbers_json_cannot_write =
  [ "[NaN]", "NaN"
  ; "[Infinity]", "Infinity"
  ; "[-Infinity]", "-Infinity"
  ; "[1E400]", "Infinity"
  ; "[-1E400]", "-Infinity"
  ; {|{"n": NaN}|}, "NaN"
  ; {|{"n": "[Infinity]"}|}, "Infinity"
  ]

(* Yojson reads these and cannot write them back. *)
let test_a_number_json_cannot_write_is_drawn_as_a_word () =
  List.iter
    (fun (payload, word) ->
      check bool
        (payload ^ " is drawn as " ^ word ^ " in the number's role")
        true
        (holds ("<num>" ^ word ^ "<->") (document_exn ~palette:marked payload));
      check bool
        (payload ^ " is served whole where a payload is served as it arrives")
        true
        (holds word (Tool_detail.structured payload)))
    numbers_json_cannot_write

let not_documents =
  [ ""
  ; "   "
  ; "RETURNED"
  ; "prose with \"quotes\" and 3 numbers"
  ; "\"just a string\""
  ; "42"
  ; "true"
  ; "null"
  ; "NaN"
  ; {|{"a":|}
  ; "{not json}"
  ]

let test_anything_else_is_not_a_document () =
  List.iter
    (fun payload ->
      check (option string) (Printf.sprintf "%S" payload) None
        (Tool_detail.document payload))
    not_documents

let () =
  run
    "tui_tool_detail"
    [ ( "structured"
      , [] )
    ; ( "document"
      , [ test_case "the palette adds markers and nothing else" `Quick
            test_the_palette_adds_markers_and_nothing_else
        ; test_case "a document reads back as its value" `Quick
            test_a_document_reads_back_as_its_value
        ; test_case "each part is drawn in its role" `Quick
            test_each_part_is_drawn_in_its_role
        ; test_case "a style ends before the next begins and before a line does" `Quick
            test_a_style_ends_before_the_next_begins_and_before_a_line_does
        ; test_case "a document is terminal safe" `Quick
            test_a_document_is_terminal_safe
        ; test_case "a number JSON cannot write is drawn as a word" `Quick
            test_a_number_json_cannot_write_is_drawn_as_a_word
        ; test_case "anything else is not a document" `Quick
            test_anything_else_is_not_a_document
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
