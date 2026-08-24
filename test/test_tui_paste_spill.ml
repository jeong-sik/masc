(** When a paste stops belonging in the composer.

    The composer is five rows. A four-hundred-line paste in it is a draft the
    operator cannot read, and a draft they cannot read is a message they
    cannot check before sending. *)

open Alcotest

module Spill = Masc_tui_paste_spill

let spill text = Spill.of_paste ~now_iso:"20260825-0210" ~nonce:"a3f2" text

let test_a_short_paste_stays_in_the_draft () =
  check bool "three lines is typing, not a document" true
    (spill "one\ntwo\nthree" = None);
  check bool "empty is nothing at all" true (spill "" = None)
;;

(* Both bounds spill on their own: a long paste of short lines, and one line
   that is a whole minified file. *)
let test_either_bound_spills () =
  let many_lines = String.concat "\n" (List.init (Spill.inline_max_lines + 1) (fun _ -> "x")) in
  check bool "past the line bound" true (Option.is_some (spill many_lines));
  let one_long_line = String.make (Spill.inline_max_bytes + 1) 'x' in
  check bool "past the byte bound, on one line" true
    (Option.is_some (spill one_long_line))
;;

(* The bounds are inclusive: a paste exactly at either is still the operator's
   to read in the pane. An off-by-one here spills something that fits. *)
let test_the_bounds_themselves_fit () =
  let at_line_bound =
    String.concat "\n" (List.init Spill.inline_max_lines (fun _ -> "x"))
  in
  check bool "exactly the line bound fits" true (spill at_line_bound = None);
  check bool "exactly the byte bound fits" true
    (spill (String.make Spill.inline_max_bytes 'x') = None)
;;

let test_the_text_is_kept_whole () =
  let text = String.concat "\n" (List.init 400 (fun index -> Printf.sprintf "line %d" index)) in
  match spill text with
  | None -> failf "400 lines did not spill"
  | Some kept ->
      check string "byte for byte" text kept.Spill.text;
      check int "counted its lines" 400 kept.Spill.lines;
      check int "counted its bytes" (String.length text) kept.Spill.bytes
;;

(* A keeper reads paths relative to its own directory, and the same name has
   to work on the host and inside a container. A directory in the name would
   be neither. *)
let test_the_file_is_a_bare_name () =
  match spill (String.make (Spill.inline_max_bytes + 1) 'x') with
  | None -> failf "did not spill"
  | Some kept ->
      let name = kept.Spill.file_name in
      check bool "no directory in it" false (String.contains name '/');
      check bool "no traversal in it" false
        (String.length name > 1 && String.sub name 0 2 = "..");
      check bool "named for when and which" true
        (String.equal name "pasted-20260825-0210-a3f2.txt")
;;

(* The draft line is what the composer shows in place of the text, so it has
   to be one line -- a placeholder that wraps has not solved the problem it
   exists for. *)
let test_the_draft_line_is_one_line () =
  match spill (String.make (Spill.inline_max_bytes + 1) 'x') with
  | None -> failf "did not spill"
  | Some kept ->
      let line = Spill.draft_line kept in
      check bool "one line" false (String.contains line '\n');
      check bool "says the file" true
        (let needle = kept.Spill.file_name in
         let rec found start =
           start + String.length needle <= String.length line
           && (String.equal (String.sub line start (String.length needle)) needle
               || found (start + 1))
         in
         found 0)
;;

let test_the_message_says_where_to_look () =
  match spill (String.make (Spill.inline_max_bytes + 1) 'x') with
  | None -> failf "did not spill"
  | Some kept ->
      let line = Spill.message_line kept in
      List.iter
        (fun needle ->
          let rec found start =
            start + String.length needle <= String.length line
            && (String.equal (String.sub line start (String.length needle)) needle
                || found (start + 1))
          in
          if not (found 0) then
            failf "the keeper is not told %S: %S" needle line)
        [ kept.Spill.file_name; "working directory" ]
;;

let () =
  run
    "tui_paste_spill"
    [ ( "when"
      , [ test_case "a short paste stays in the draft" `Quick
            test_a_short_paste_stays_in_the_draft
        ; test_case "either bound spills" `Quick test_either_bound_spills
        ; test_case "the bounds themselves fit" `Quick
            test_the_bounds_themselves_fit
        ] )
    ; ( "what"
      , [ test_case "the text is kept whole" `Quick test_the_text_is_kept_whole
        ; test_case "the file is a bare name" `Quick
            test_the_file_is_a_bare_name
        ; test_case "the draft line is one line" `Quick
            test_the_draft_line_is_one_line
        ; test_case "the message says where to look" `Quick
            test_the_message_says_where_to_look
        ] )
    ]
;;
