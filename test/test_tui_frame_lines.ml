open Alcotest

let split text = Masc_tui_render_prim.frame_lines text

(* The standard splitter is independent of the implementation's scan direction. *)
let expected_rows text =
  if text = "" then []
  else
    let rows = String.split_on_char '\n' text in
    if text.[String.length text - 1] = '\n' then
      List.rev (List.tl (List.rev rows))
    else rows

let buffer text =
  let result = Buffer.create 0 in
  Buffer.add_string result text;
  result

let check_partition text =
  let source = buffer text in
  check (list string) "exact byte partition" (expected_rows text) (split source);
  check string "input unchanged" text (Buffer.contents source)

let test_short_byte_combinations () =
  let rec visit remaining text =
    check_partition text;
    if remaining > 0 then
      List.iter
        (fun byte -> visit (remaining - 1) (text ^ String.make 1 byte))
        ['a'; '\n'; '\r'; '\000']
  in
  visit 6 ""

let test_raw_encoding_bytes () =
  List.iter check_partition
    [ String.init 256 Char.chr
    ; "\027[1;31m\000\255\027[0m\n\027]8;;https://example.invalid\027\\x\027]8;;\027\\\n"
    ; "한글\n🙂e\204\129👩‍💻\n"
    ; String.make 8192 'x'
    ; String.make 1024 '\n'
    ]

let test_terminators () =
  List.iter
    (fun (text, expected) ->
      check (list string) "LF byte grammar" expected (split (buffer text)))
    [ "", []
    ; "\n", [""]
    ; "\n\n", [""; ""]
    ; "a", ["a"]
    ; "a\n", ["a"]
    ; "a\n\n", ["a"; ""]
    ; "\na", [""; "a"]
    ; "a\r\nb", ["a\r"; "b"]
    ; "\000\n\255", ["\000"; "\255"]
    ]

let test_returned_rows_survive_buffer_reuse () =
  List.iter
    (fun text ->
      let source = buffer text in
      let returned = split source in
      Buffer.clear source;
      Buffer.add_string source "replacement";
      Buffer.reset source;
      Buffer.add_string source (String.make (2 * String.length text + 1) 'z');
      check (list string) "rows remain detached" (expected_rows text) returned)
    [""; "\n"; "a\n\nb"; "한글\n\000\255"; String.make 8192 'x']

let () =
  run "frame row byte partition"
    [ "byte grammar",
      [ test_case "exhaustive short byte strings" `Quick test_short_byte_combinations
      ; test_case "raw encoding bytes" `Quick test_raw_encoding_bytes
      ; test_case "LF terminators" `Quick test_terminators
      ; test_case "detached rows after buffer reuse" `Quick
          test_returned_rows_survive_buffer_reuse
      ]
    ]
