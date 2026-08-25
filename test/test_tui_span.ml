(** Tests for [Masc_tui_span].

    The fault this module exists for is one string: a fragment's reset closing
    a style that a longer fragment was still holding. It cannot be seen by
    reading the pieces, only in the bytes that come out, so the assertions
    below read the rendered row. *)

open Alcotest

module Span = Masc_tui_span

let contains haystack needle =
  let n = String.length needle and h = String.length haystack in
  let rec at i = i + n <= h && (String.sub haystack i n = needle || at (i + 1)) in
  n > 0 && at 0
;;

let count_occurrences haystack needle =
  let n = String.length needle and h = String.length haystack in
  let rec go i total =
    if i + n > h then total
    else if String.sub haystack i n = needle then go (i + n) (total + 1)
    else go (i + 1) total
  in
  if n = 0 then 0 else go 0 0
;;

let red = "\027[31m"
let green_bg = "\027[42m"
let bold = "\027[1m"
let reset = "\027[0m"

(* The whole point. A row with a background and a coloured word inside it: the
   word's reset must not take the background with it, so the text after the
   word still carries it. Concatenation cannot do this -- the second fragment
   has no way to say "and keep what was on". *)
let test_inner_style_does_not_close_the_outer_one () =
  let line = Span.bg green_bg in
  let row =
    Span.concat
      [ Span.text line "before "
      ; Span.text (Span.combine line (Span.fg red)) "word"
      ; Span.text line " after"
      ]
  in
  (* Spelled out byte for byte. The fault is invisible in the pieces and
     obvious here: every run opens the background again, so the word's reset
     has nothing of its neighbours' to close, and " after" still arrives
     green. Concatenation would emit the background once and lose it at the
     word. *)
  check string "every run re-opens the background"
    (green_bg ^ "before " ^ reset
     ^ green_bg ^ red ^ "word" ^ reset
     ^ green_bg ^ " after" ^ reset)
    (Span.render row);
  check int "three openings, not one" 3
    (count_occurrences (Span.render row) green_bg)
;;

let test_combine_inherits_what_the_inner_leaves_alone () =
  let outer = Span.combine (Span.bg green_bg) (Span.weight bold) in
  let inner = Span.combine outer (Span.fg red) in
  let rendered = Span.render (Span.text inner "x") in
  check bool "keeps the background" true (contains rendered "[42m");
  check bool "keeps the weight" true (contains rendered "[1m");
  check bool "takes the new colour" true (contains rendered "[31m")
;;

(* Under NO_COLOR the escape helpers return the empty string. A caller should
   not have to notice, and a row with no styling has to come out as the plain
   string it would have been -- otherwise every unstyled row grows a reset. *)
let test_empty_escapes_render_bare () =
  let row = Span.text (Span.fg "") "plain text" in
  check string "no escapes at all" "plain text" (Span.render row)
;;

let test_width_ignores_escapes () =
  let row =
    Span.concat [ Span.text (Span.fg red) "abc"; Span.text (Span.bg green_bg) "de" ]
  in
  check int "five printable cells" 5 (Span.width row)
;;

(* A wide character occupies two columns. A row budget is spent in columns, so
   a width that counted bytes or scalars would overflow the frame. *)
let test_width_counts_wide_characters_as_two () =
  check int "one hangul syllable is two columns" 2
    (Span.width (Span.text Span.plain "\xea\xb0\x80"))
;;

let test_pad_reaches_the_edge_with_the_style () =
  let row = Span.pad_to 6 (Span.bg green_bg) (Span.text Span.plain "ab") in
  check int "padded to the target" 6 (Span.width row);
  check bool "the padding carries the background" true
    (contains (Span.render row) "[42m")
;;

(* A background that stops at the last character is not a background. Padding
   shorter than the current width leaves the row alone, because trimming is
   [truncate]'s job and two places that shorten would disagree. *)
let test_pad_does_not_shorten () =
  let row = Span.pad_to 2 Span.plain (Span.text Span.plain "abcdef") in
  check int "left alone" 6 (Span.width row)
;;

let test_truncate_spends_the_budget_across_runs () =
  let row =
    Span.concat
      [ Span.text (Span.fg red) "abc"; Span.text (Span.bg green_bg) "defgh" ]
  in
  check int "cut to four" 4 (Span.width (Span.truncate 4 row));
  check int "cut to nothing" 0 (Span.width (Span.truncate 0 row));
  check int "wider than the row is a no-op" 8 (Span.width (Span.truncate 99 row))
;;

(* Cutting happens before the escapes are written, which is the reason for
   holding runs at all: a cut on the finished string could land inside one and
   leave the terminal reading the rest of the row as parameters. *)
let test_truncate_never_splits_a_wide_character () =
  let row = Span.text Span.plain "\xea\xb0\x80\xea\xb0\x81" in
  let cut = Span.truncate 3 row in
  check int "three columns cannot hold two syllables" 2 (Span.width cut);
  check bool "no partial byte sequence" true
    (let rendered = Span.render cut in
     String.length rendered = 3)
;;

let test_render_closes_every_run_it_opens () =
  let rendered =
    Span.render
      (Span.concat [ Span.text (Span.fg red) "a"; Span.text (Span.bg green_bg) "b" ])
  in
  let resets = count_occurrences rendered reset in
  check int "one reset per styled run" 2 resets
;;

let () =
  run "tui_span"
    [ ( "composition"
      , [ test_case "inner style does not close the outer" `Quick
            test_inner_style_does_not_close_the_outer_one
        ; test_case "combine inherits" `Quick
            test_combine_inherits_what_the_inner_leaves_alone
        ; test_case "render closes what it opens" `Quick
            test_render_closes_every_run_it_opens
        ; test_case "empty escapes render bare" `Quick test_empty_escapes_render_bare
        ] )
    ; ( "width"
      , [ test_case "ignores escapes" `Quick test_width_ignores_escapes
        ; test_case "wide characters are two columns" `Quick
            test_width_counts_wide_characters_as_two
        ] )
    ; ( "fitting"
      , [ test_case "pad reaches the edge" `Quick test_pad_reaches_the_edge_with_the_style
        ; test_case "pad does not shorten" `Quick test_pad_does_not_shorten
        ; test_case "truncate spends across runs" `Quick
            test_truncate_spends_the_budget_across_runs
        ; test_case "truncate never splits a character" `Quick
            test_truncate_never_splits_a_wide_character
        ] )
    ]
;;
