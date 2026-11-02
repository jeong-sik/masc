open Masc

let test_terminal_json_preserves_source_context () =
  let selector = "\239\184\143" in
  let supplementary = "\243\160\132\128" in
  let cases =
    [ "control before selector", `String ("\000" ^ selector), false
    ; "C1 before selector", `String ("\194\128" ^ selector), false
    ; "literal backslash and digit", `String ("\\u0000" ^ selector), true
    ; "actual emoji base", `String ("0" ^ selector), true
    ; "emoji presentation", `String "❤️", true
    ; "supplementary selector", `String supplementary, false
    ; "object key and nested value",
      `Assoc [("\000" ^ selector), `List [`String ("\t" ^ selector)]], false
    ] in
  List.iter (fun (label, value, retains_selector) ->
    let source = Yojson.Safe.pretty_to_string value in
    let shown = Tui_terminal_json.sanitize_canonical_preview source in
    Alcotest.(check bool) (label ^ ": selector visibility") retains_selector
      (String_util.contains_substring shown selector);
    Alcotest.(check bool) (label ^ ": same JSON value") true
      (Yojson.Safe.from_string shown = value)) cases;
  let scalar code =
    let bytes = Buffer.create 4 in
    Buffer.add_utf_8_uchar bytes (Uchar.of_int code);
    Buffer.contents bytes in
  let tags = List.map scalar [0xe0067; 0xe0062; 0xe0073; 0xe0063; 0xe0074; 0xe007f] in
  let flag = scalar 0x1f3f4 ^ String.concat "" tags in
  List.iter (fun emoji ->
    let shown = Yojson.Safe.to_string (`String emoji)
      |> Tui_terminal_json.sanitize_canonical_preview in
    Alcotest.(check bool) "valid emoji sequence stays intact" true
      (String_util.contains_substring shown emoji)) ["👩‍💻"; "❤️‍🔥"; flag];
  let partial_flag = scalar 0x1f3f4 ^ List.hd tags in
  let shown = Yojson.Safe.to_string (`String partial_flag)
    |> Tui_terminal_json.sanitize_canonical_preview in
  Alcotest.(check bool) "an orphan tag is shown rather than hidden" false
    (String_util.contains_substring shown (List.hd tags));
  Alcotest.(check bool) "escaping an orphan tag preserves its JSON value" true
    (Yojson.Safe.from_string shown = `String partial_flag)

let test_terminal_json_truncated_and_malformed_escapes () =
  let selector = "\239\184\143" in
  let source = Yojson.Safe.to_string (`String ("\000" ^ selector)) in
  for cut = 0 to String.length source do
    let prefix = String_util.utf8_prefix ~max_bytes:cut source in
    let shown = Tui_terminal_json.sanitize_canonical_preview prefix in
    Alcotest.(check bool) "a truncated orphan selector is not emitted raw" false
      (String_util.contains_substring shown selector)
  done;
  List.iter (fun input ->
    let shown = Tui_terminal_json.sanitize_canonical_preview input in
    Alcotest.(check bool) "malformed escape does not pass ESC" false
      (String.contains shown '\027'))
    ["\"\\\027[2J"; "\"\\u00\027[2J"];
  let shown = Tui_terminal_json.sanitize_canonical_preview "\"raw\nnewline" in
  Alcotest.(check bool) "newline in an unfinished string is escaped" false
    (String.contains shown '\n')

let () = Alcotest.run "terminal JSON boundary" [
  "security", [
    Alcotest.test_case "source context" `Quick test_terminal_json_preserves_source_context;
    Alcotest.test_case "truncated and malformed escapes" `Quick test_terminal_json_truncated_and_malformed_escapes;
  ]
]
