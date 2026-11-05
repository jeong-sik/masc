(* What a heading says after its id is given as pieces, each with its own
   leading gap. The pieces that fit are drawn whole from the first, the rest
   are left out whole from the end, and the tail stays. A row that cut the
   last piece at the width read "seq 212  le…" where the piece was
   "level≥DEBUG". These cases check the text and the cells it takes, not how
   a screen reads. *)

open Alcotest

let strip = Masc_tui_theme.strip_sgr
let cells = Masc_tui_message_layout.display_width
let lead = "LEAD "
let tail = "TAIL"

let heading ?(id = "") ~cols after =
  Masc_tui_ansi.detail_heading ~cols
    ~lead:(Masc_tui_ansi.Lead_text lead)
    ~id ~after ~tail

let rec take count = function
  | piece :: rest when count > 0 -> piece :: take (count - 1) rest
  | [] | _ :: _ -> []

(* The row a heading with no id comes to when its first [kept] pieces fit. *)
let row_of pieces kept = lead ^ String.concat "" (take kept pieces) ^ "  " ^ tail

(* At every width the row is the lead, the longest run of pieces from the
   first that fits, and the tail. The pieces include wide characters, so the
   cells are neither the bytes nor the characters. *)
let test_pieces_are_drawn_whole_or_left_out () =
  let pieces = [ "  (213 건)"; "  seq 212"; "  level≥DEBUG"; "  category:세션" ] in
  for cols = 20 to 100 do
    let inner = Masc_tui_ansi.framed_inner_width cols in
    let fits kept = cells (row_of pieces kept) <= inner in
    let kept =
      List.fold_left
        (fun best candidate -> if fits candidate then candidate else best)
        0
        (List.init (List.length pieces) (fun index -> index + 1))
    in
    (* Below one piece the first is cut, which the next case covers. *)
    if kept >= 1 then
      check string
        (Printf.sprintf "%d columns keep %d pieces" cols kept)
        (row_of pieces kept)
        (strip (heading ~cols pieces))
  done

(* When not even the first piece fits it is cut at its end, as a lone reading
   is, and the tail is still whole and the row no wider than the frame. *)
let test_a_first_piece_that_does_not_fit_is_cut () =
  let pieces = [ "  a reading far too long for this heading"; "  second" ] in
  for cols = 24 to 40 do
    let row = strip (heading ~cols pieces) in
    let inner = Masc_tui_ansi.framed_inner_width cols in
    check bool (Printf.sprintf "%d columns: within the frame" cols) true
      (cells row <= inner);
    check bool (Printf.sprintf "%d columns: the tail is whole" cols) true
      (Astring.String.is_suffix ~affix:("  " ^ tail) row);
    check bool (Printf.sprintf "%d columns: the second piece is left out" cols)
      false
      (Astring.String.is_infix ~affix:"second" row)
  done

(* A piece left out may be the one that closed a style an earlier piece
   opened, so the row ends the style itself. *)
let test_a_style_left_open_by_a_dropped_piece_is_closed () =
  let opened = "  \027[33mwarn" and closed = "  done\027[0m" in
  let only_the_first = ref 0 in
  for cols = 20 to 60 do
    let row = heading ~cols [ opened; closed ] in
    if
      Astring.String.is_infix ~affix:"warn" (strip row)
      && not (Astring.String.is_infix ~affix:"done" (strip row))
    then begin
      incr only_the_first;
      check bool
        (Printf.sprintf "%d columns: the style is closed after the first piece" cols)
        true
        (Astring.String.is_infix ~affix:"warn\027[0m" row)
    end
  done;
  check bool "some width draws only the first piece" true (!only_the_first > 0)

let () =
  run "tui_detail_heading"
    [ ( "pieces after the id"
      , [ test_case "pieces are drawn whole or left out" `Quick
            test_pieces_are_drawn_whole_or_left_out
        ; test_case "a first piece that does not fit is cut" `Quick
            test_a_first_piece_that_does_not_fit_is_cut
        ; test_case "a style left open by a dropped piece is closed" `Quick
            test_a_style_left_open_by_a_dropped_piece_is_closed
        ] )
    ]
