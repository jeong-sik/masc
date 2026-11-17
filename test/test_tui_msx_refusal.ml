open Alcotest

(* A refused answer reaches the screen as the sentence for its code, never as
   the JSON. Each code the server can send reads to a sentence, and the codes
   read differently from one another: the terminal branches on the code. *)
let test_refusal_body_reads_as_a_sentence () =
  let body code message = Yojson.Safe.to_string (Msx_wire.encode ?code message) in
  let sentence code message =
    match Masc_tui_msx_refusal.refusal_sentence (body code message) with
    | Some sentence -> sentence
    | None -> fail "a refusal body gave no sentence" in
  let said = "the server's own words" in
  let with_message = List.map (fun code -> sentence (Some code) said) Msx_wire.all_of_code in
  List.iter (fun sentence ->
    check bool "the server's words are kept" true
      (let n = String.length said and m = String.length sentence in
       let rec go i = i + n <= m && (String.sub sentence i n = said || go (i + 1)) in
       go 0);
    check bool "it is not the JSON" false (String.contains sentence '{'))
    with_message;
  check int "each code reads differently" (List.length Msx_wire.all_of_code)
    (List.length (List.sort_uniq String.compare with_message));
  List.iter (fun code ->
    match Masc_tui_msx_refusal.refusal_sentence (body (Some code) "") with
    | Some _ -> ()
    | None -> fail "a coded refusal with an empty message gave no sentence")
    Msx_wire.all_of_code;
  check (option string) "a plain message without a code is the message" (Some said)
    (Masc_tui_msx_refusal.refusal_sentence (body None said));
  List.iter (fun raw ->
    check (option string) ("not an MSX refusal: " ^ raw) None (Masc_tui_msx_refusal.refusal_sentence raw))
    [ "not json"; "[]"; {|{"error":"words"}|}; {|{"ok":true,"message":"fine"}|};
      {|{"ok":false,"code":"nope","message":"m"}|}; {|{"ok":false}|} ]

let () =
  run "tui_msx_refusal"
    [ "refusal", [ test_case "a refusal body reads as a sentence" `Quick test_refusal_body_reads_as_a_sentence ] ]
