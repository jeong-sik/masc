(** What the reader makes of the bytes between the paste markers.

    Bracketed paste exists because the alternative is wrong in a way an
    operator pays for: without it every newline in a paste is Return, so a
    three-line paste is three messages and a pasted Markdown block arrives as
    three separate sends. *)

open Alcotest

let of_string bytes =
  let position = ref 0 in
  fun () ->
    if !position >= String.length bytes then None
    else begin
      let byte = bytes.[!position] in
      incr position;
      Some byte
    end
;;

let read bytes = Masc_tui_paste.read ~next_byte:(of_string bytes)

let test_newlines_stay_text () =
  let paste = read ("first\nsecond\nthird" ^ Masc_tui_paste.end_marker) in
  check string "the paste is one text" "first\nsecond\nthird"
    paste.Masc_tui_paste.text;
  check int "nothing was dropped" 0 paste.Masc_tui_paste.dropped
;;

(* Markdown and URLs are the two things most often pasted into a keeper
   message, and both are only themselves if the bytes survive unchanged. *)
let test_markdown_and_urls_survive () =
  let source =
    "See https://example.invalid/a?b=1&c=2\n\n```ocaml\nlet () = ()\n```\n\
     - one\n- two\n"
  in
  let paste = read (source ^ Masc_tui_paste.end_marker) in
  check string "byte for byte" source paste.Masc_tui_paste.text
;;

(* What a terminal writes for a line break in pasted text depends on the
   emulator and on what was copied. All three shapes are the same break, and
   the draft holds one of them. Without this the CR is sanitized to a space
   further down and the paste comes out as a single long line. *)
let test_every_line_break_becomes_lf () =
  check string "carriage returns" "a\nb"
    (read ("a\rb" ^ Masc_tui_paste.end_marker)).Masc_tui_paste.text;
  check string "crlf is one break" "a\nb"
    (read ("a\r\nb" ^ Masc_tui_paste.end_marker)).Masc_tui_paste.text;
  check string "lf is left alone" "a\nb"
    (read ("a\nb" ^ Masc_tui_paste.end_marker)).Masc_tui_paste.text;
  check string "a lone trailing cr still breaks" "a\n"
    (read ("a\r" ^ Masc_tui_paste.end_marker)).Masc_tui_paste.text
;;

let test_the_marker_ends_it () =
  let paste = read (Masc_tui_paste.end_marker ^ "typed after") in
  check string "nothing before the marker" "" paste.Masc_tui_paste.text;
  check int "and nothing dropped" 0 paste.Masc_tui_paste.dropped
;;

(* A bare ESC in the payload starts a match that then breaks. The bytes held
   back for it are payload and have to come back, and the terminator that
   follows still has to be found. *)
let test_a_broken_match_returns_its_bytes () =
  let paste = read ("a\x1b[2b" ^ Masc_tui_paste.end_marker) in
  check string "the partial marker is text" "a\x1b[2b" paste.Masc_tui_paste.text
;;

let test_a_partial_marker_before_the_end_is_text () =
  let paste = read "tail\x1b[20" in
  check string "kept as typed" "tail\x1b[20" paste.Masc_tui_paste.text
;;

(* The stream ending is a terminal that went away, not a reason to lose what
   the operator already pasted. *)
let test_an_unterminated_paste_keeps_what_arrived () =
  let paste = read "half a thought" in
  check string "kept" "half a thought" paste.Masc_tui_paste.text
;;

(* Past the cap the bytes are still read -- the marker has to be consumed or
   the tail of the paste arrives as keystrokes -- and counted, so the operator
   can be told how much of what they pasted is not in the draft. *)
let test_the_cap_counts_what_it_drops () =
  let overflow = 500 in
  let source = String.make (Masc_tui_paste.max_bytes + overflow) 'x' in
  let paste = read (source ^ Masc_tui_paste.end_marker) in
  check int "kept the cap" Masc_tui_paste.max_bytes
    (String.length paste.Masc_tui_paste.text);
  check int "counted the rest" overflow paste.Masc_tui_paste.dropped
;;

let test_the_cap_still_finds_the_marker () =
  let source = String.make (Masc_tui_paste.max_bytes + 10) 'x' in
  let next = of_string (source ^ Masc_tui_paste.end_marker ^ "q") in
  let _ = Masc_tui_paste.read ~next_byte:next in
  check (option char) "the byte after the marker is the next key" (Some 'q')
    (next ())
;;

(* A dropped file arrives as the shell would want it, and the draft is not a
   shell. Recognising that shape is only safe if everything else is refused:
   the operator has no other way to paste a backslash, so a false positive
   silently rewrites bytes they meant to send. The refusals below matter more
   than the acceptance. *)

let test_a_dropped_path_loses_its_escapes () =
  match
    Masc_tui_paste.unescaped_path "/Users/dancer/Desktop/screen\\ shot\\ 1.png"
  with
  | Some path ->
    check string "spaces are spaces" "/Users/dancer/Desktop/screen shot 1.png" path
  | None -> fail "an escaped path was not recognised"
;;

let test_a_hangul_path_survives () =
  (* The bytes that made this worth fixing. Multi-byte characters are copied
     through untouched; only the escapes go. *)
  match
    Masc_tui_paste.unescaped_path "/Users/dancer/Desktop/스크린샷\\ 2026-08-25.png"
  with
  | Some path ->
    check string "hangul intact" "/Users/dancer/Desktop/스크린샷 2026-08-25.png" path
  | None -> fail "an escaped hangul path was not recognised"
;;

let test_an_unescaped_path_is_still_a_path () =
  match Masc_tui_paste.unescaped_path "/tmp/plain.png" with
  | Some path -> check string "unchanged" "/tmp/plain.png" path
  | None -> fail "a path with nothing to unescape was refused"
;;

let refuses name text =
  match Masc_tui_paste.unescaped_path text with
  | None -> ()
  | Some path -> failf "%s was rewritten to %S" name path
;;

let test_a_code_snippet_is_left_alone () =
  (* "\\n" in pasted code is two characters the operator wants. Treating the
     backslash as escaping would hand them a bare "n". *)
  refuses "a snippet" "let x = \"a\\nb\""
;;

let test_prose_is_left_alone () = refuses "prose" "back\\slash in the middle"

let test_a_relative_path_is_left_alone () =
  (* Only an absolute path is the drop shape; a relative one is as likely to
     be prose that happens to contain a slash. *)
  refuses "a relative path" "docs/screen\\ shot.png"
;;

let test_a_multi_line_paste_is_left_alone () =
  refuses "two lines" "/tmp/one.png\n/tmp/two.png"
;;

let test_a_trailing_backslash_is_left_alone () =
  refuses "a trailing backslash" "/tmp/odd\\"
;;

let () =
  run
    "tui_paste"
    [ ( "payload"
      , [ test_case "newlines stay text" `Quick test_newlines_stay_text
        ; test_case "markdown and urls survive" `Quick
            test_markdown_and_urls_survive
        ; test_case "every line break becomes lf" `Quick
            test_every_line_break_becomes_lf
        ; test_case "the marker ends it" `Quick test_the_marker_ends_it
        ; test_case "a broken match returns its bytes" `Quick
            test_a_broken_match_returns_its_bytes
        ; test_case "a partial marker before the end is text" `Quick
            test_a_partial_marker_before_the_end_is_text
        ; test_case "an unterminated paste keeps what arrived" `Quick
            test_an_unterminated_paste_keeps_what_arrived
        ] )
    ; ( "dropped paths"
      , [ test_case "escapes are removed" `Quick test_a_dropped_path_loses_its_escapes
        ; test_case "hangul survives" `Quick test_a_hangul_path_survives
        ; test_case "a plain path passes through" `Quick
            test_an_unescaped_path_is_still_a_path
        ; test_case "a code snippet is left alone" `Quick
            test_a_code_snippet_is_left_alone
        ; test_case "prose is left alone" `Quick test_prose_is_left_alone
        ; test_case "a relative path is left alone" `Quick
            test_a_relative_path_is_left_alone
        ; test_case "a multi-line paste is left alone" `Quick
            test_a_multi_line_paste_is_left_alone
        ; test_case "a trailing backslash is left alone" `Quick
            test_a_trailing_backslash_is_left_alone
        ] )
    ; ( "cap"
      , [ test_case "counts what it drops" `Quick
            test_the_cap_counts_what_it_drops
        ; test_case "still finds the marker" `Quick
            test_the_cap_still_finds_the_marker
        ] )
    ]
;;
