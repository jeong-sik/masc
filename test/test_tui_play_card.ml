(* The play invite card: what an operator sees for the link the server
   answers with. The card is checked from what is drawn: the rows [draw]
   returns, and the pixels those coloured rows draw, read back and compared
   with the QR the library encodes for the link. *)

open Alcotest
module Card = Masc_tui_play_card

let link =
  "https://masc.example.com/play#"
  ^ "3f9a1c07d25b48e6a0c1d7e2f4b86a59c3d10e7f2a4b6c8d9e0f1a2b3c4d5e6f"
;;

let expires_at = "2026-09-30T04:12:33Z"

let true_colour =
  Masc_tui_terminal_palette.For_testing.best_color_for_level
    ~level:Masc_tui_terminal_palette.True_color
;;

let make ?(project = true_colour) ?(name = "minsu") ?(link = link) () =
  Card.make ~project ~name ~expires_at ~link
;;

let card ?project ?name () =
  match make ?project ?name () with
  | Ok card -> card
  | Error reason -> failf "the fixture link was refused: %s" reason
;;

let contains ~sub text =
  let sub_length = String.length sub in
  let rec find at =
    at + sub_length <= String.length text
    && (String.equal (String.sub text at sub_length) sub || find (at + 1))
  in
  find 0
;;

(* The link is a credential shown as text and encoded as a QR, so the card
   takes only a link it can do both with: plain http(s), printable ASCII, no
   blank. Anything else is refused before it is drawn. *)
let test_a_link_the_card_cannot_draw_is_refused () =
  List.iter
    (fun (why, bad) ->
      match make ~link:bad () with
      | Error _ -> ()
      | Ok _ -> failf "a link with %s made a card" why)
    [ ("another scheme", "javascript:alert(1)")
    ; ("no scheme", "masc.example.com/play#abc")
    ; ("a blank", "https://masc.example.com/play# abc")
    ; ("a newline", "https://masc.example.com/play#abc\ndef")
    ; ("an escape byte", "https://masc.example.com/play#abc\027[31m")
    ; ("a byte past ASCII", "https://masc.example.com/play#\xc3\xa9")
    ; ("nothing", "")
    ];
  match make ~link:"http://192.168.0.7:8935/play#abc" () with
  | Ok _ -> ()
  | Error reason -> failf "a plain http link was refused: %s" reason
;;

(* One cell of a coloured half-block row: the upper half is drawn in the
   foreground colour and the lower half in the background colour. *)
let cells_of_row row =
  let length = String.length row in
  let foreground = ref None
  and background = ref None
  and cells = ref [] in
  let upper_half_block = "\xe2\x96\x80" in
  let rec scan at =
    if at < length
    then
      if row.[at] = '\027'
      then (
        let close = String.index_from row at 'm' in
        let params =
          String.split_on_char ';' (String.sub row (at + 2) (close - at - 2))
        in
        let rec apply = function
          | "38" :: "2" :: r :: g :: b :: rest ->
            foreground := Some (int_of_string r, int_of_string g, int_of_string b);
            apply rest
          | "48" :: "2" :: r :: g :: b :: rest ->
            background := Some (int_of_string r, int_of_string g, int_of_string b);
            apply rest
          | "39" :: rest ->
            foreground := None;
            apply rest
          | "49" :: rest ->
            background := None;
            apply rest
          | _ :: rest -> apply rest
          | [] -> ()
        in
        apply params;
        scan (close + 1))
      else if at + 3 <= length && String.sub row at 3 = upper_half_block
      then (
        cells := (!foreground, !background) :: !cells;
        scan (at + 3))
      else scan (at + 1)
  in
  scan 0;
  List.rev !cells
;;

(* A QR has two colours. A pixel drawn in anything else -- the terminal's
   default colours from SGR 39/49, a grey -- is neither, and is what a QR
   drawn without its own colours would be made of. *)
type pixel =
  | Dark
  | Light
  | Neither

let pixel_of = function
  | Some (0, 0, 0) -> Dark
  | Some (255, 255, 255) -> Light
  | Some _ | None -> Neither
;;

(* The QR's pixels, top row first: each text row is two pixel rows. *)
let pixel_rows rows =
  List.concat_map
    (fun row ->
      let cells = cells_of_row row in
      [ List.map (fun (top, _) -> pixel_of top) cells
      ; List.map (fun (_, bottom) -> pixel_of bottom) cells
      ])
    rows
;;

let qr_rows_of drawn =
  List.filter_map
    (function
      | Card.Qr_row row -> Some row
      | Card.Heading _ | Card.Advice _ | Card.Link_row _ | Card.Note _
      | Card.Qr_needs _ | Card.Blank -> None)
    drawn
;;

let notes_of drawn =
  List.filter_map
    (function
      | Card.Note text -> Some text
      | Card.Heading _ | Card.Advice _ | Card.Link_row _ | Card.Qr_row _
      | Card.Qr_needs _ | Card.Blank -> None)
    drawn
;;

let needs_of drawn =
  List.filter_map
    (function
      | Card.Qr_needs { columns; rows } -> Some (columns, rows)
      | Card.Heading _ | Card.Advice _ | Card.Link_row _ | Card.Qr_row _
      | Card.Note _ | Card.Blank -> None)
    drawn
;;

let plenty = 200

let test_the_qr_is_the_libraries_qr_with_its_quiet_zone () =
  let drawn = Card.draw (card ()) ~width:plenty ~rows:plenty in
  let grid = pixel_rows (qr_rows_of drawn) in
  check bool "the card drew a QR" true (grid <> []);
  let matrix =
    match Qrc.encode link with
    | Some matrix -> matrix
    | None -> fail "the fixture link does not fit a QR"
  in
  let modules = Qrc.Matrix.w matrix in
  (* Four light modules on every side (ISO/IEC 18004), stated here as the
     standard states it rather than read from the implementation. *)
  let quiet = 4 in
  let side = modules + (2 * quiet) in
  check int "one column per module" side (List.length (List.hd grid));
  check bool "a cell stacks two pixel rows, so an odd side is padded by one"
    true
    (List.length grid = side + (side land 1));
  List.iteri
    (fun y row ->
      List.iteri
        (fun x drawn ->
          let expected =
            let module_x = x - quiet
            and module_y = y - quiet in
            if module_x >= 0 && module_x < modules && module_y >= 0 && module_y < modules
               && Qrc.Matrix.get matrix ~x:module_x ~y:module_y
            then Dark
            else Light
          in
          if drawn <> expected
          then
            failf "pixel (%d, %d) is %s, the QR has %s" x y
              (match drawn with
               | Dark -> "dark"
               | Light -> "light"
               | Neither -> "in neither of the QR's two colours")
              (match expected with
               | Dark -> "dark"
               | Light -> "light"
               | Neither -> "neither"))
        row)
    grid
;;

let test_the_qr_is_drawn_only_when_all_of_it_fits () =
  let card = card () in
  let full = Card.draw card ~width:plenty ~rows:plenty in
  let qr_rows = List.length (qr_rows_of full) in
  let side = List.length (List.hd (pixel_rows (qr_rows_of full))) in
  check bool "with room, there is a QR and nothing missing" true
    (qr_rows > 0 && notes_of full = [] && needs_of full = []);
  (* The link is cut to the width, so at the QR's own width it takes more rows
     than it does at full width, and the room the QR needs depends on the
     width it is asked at. *)
  let full_rows = List.length full in
  let rows_at_side = List.length (Card.draw card ~width:side ~rows:plenty) in
  check bool "a narrower card is taller" true (rows_at_side > full_rows);
  let pair_list = list (pair int int) in
  let narrow = Card.draw card ~width:(side - 1) ~rows:plenty in
  check int "one column short, no QR at all" 0 (List.length (qr_rows_of narrow));
  check pair_list "and it asks for the width, and the rows the QR will then take"
    [ (side, rows_at_side) ] (needs_of narrow);
  let short = Card.draw card ~width:plenty ~rows:(full_rows - 1) in
  check int "one row short, no QR at all" 0 (List.length (qr_rows_of short));
  check pair_list "and it asks for the row it lacks, not for more width"
    [ (plenty, full_rows) ] (needs_of short);
  let exact = Card.draw card ~width:side ~rows:rows_at_side in
  check int "exactly enough room draws the whole QR" qr_rows
    (List.length (qr_rows_of exact));
  let one_short = Card.draw card ~width:side ~rows:(rows_at_side - 1) in
  check int "a row short at that width draws none" 0
    (List.length (qr_rows_of one_short));
  check pair_list "and it asks for exactly the row it lacks"
    [ (side, rows_at_side) ] (needs_of one_short)
;;

let test_no_colour_draws_no_qr_and_says_why () =
  let card = card ~project:(fun _ -> None) () in
  let drawn = Card.draw card ~width:plenty ~rows:plenty in
  check int "no QR rows" 0 (List.length (qr_rows_of drawn));
  check int "one note" 1 (List.length (notes_of drawn));
  check bool "the link is still there to be sent" true
    (List.exists
       (function
         | Card.Link_row _ -> true
         | Card.Heading _ | Card.Advice _ | Card.Qr_row _ | Card.Note _
         | Card.Qr_needs _ | Card.Blank -> false)
       drawn)
;;

let test_the_link_is_cut_to_the_width_without_losing_a_byte () =
  let drawn = Card.draw (card ()) ~width:40 ~rows:plenty in
  let pieces =
    List.filter_map
      (function
        | Card.Link_row piece -> Some piece
        | Card.Heading _ | Card.Advice _ | Card.Qr_row _ | Card.Note _
        | Card.Qr_needs _ | Card.Blank -> None)
      drawn
  in
  check bool "every piece fits the width" true
    (List.for_all (fun piece -> String.length piece <= 40) pieces);
  check string "the pieces are the link" link (String.concat "" pieces);
  check bool "it took more than one row" true (List.length pieces > 1)
;;

(* The link is a credential: it is in the link rows and the clipboard copy and
   nowhere else the card draws. *)
let test_the_link_appears_only_in_its_own_rows () =
  let drawn = Card.draw (card ()) ~width:plenty ~rows:plenty in
  let mentions text = contains ~sub:"play#" text in
  List.iter
    (function
      | Card.Heading text | Card.Advice text | Card.Note text ->
        check bool (Printf.sprintf "%S does not carry the link" text) false (mentions text)
      | Card.Link_row _ | Card.Qr_row _ | Card.Qr_needs _ | Card.Blank -> ())
    drawn;
  check string "the clipboard gets the link as issued" link (Card.link (card ()))
;;

let test_a_name_from_the_wire_is_drawn_safe () =
  let card = card ~name:"min\027[31msu\n" () in
  check bool "no escape byte in the name" false (String.contains (Card.name card) '\027');
  check bool "no newline in the name" false (String.contains (Card.name card) '\n');
  let drawn = Card.draw card ~width:plenty ~rows:plenty in
  List.iter
    (function
      | Card.Heading text ->
        check bool "no escape byte in the heading" false (String.contains text '\027')
      | Card.Advice _ | Card.Link_row _ | Card.Qr_row _ | Card.Note _
      | Card.Qr_needs _ | Card.Blank -> ())
    drawn
;;

(* What the conversation keeps of an issue is a row anyone reading the chat
   sees, so it names the invite and never carries the link. *)
let test_the_issue_notice_never_carries_the_link () =
  let notice = Card.issued_notice (card ()) ~retained:false in
  check bool "it names the invite and its expiry" true
    (contains ~sub:"minsu" notice && contains ~sub:expires_at notice);
  check bool "it says how to see the card again" true (contains ~sub:"/play link" notice);
  check bool "the link is not in it" false (contains ~sub:"play#" notice);
  let retained = Card.issued_notice (card ~name:"jiwon" ()) ~retained:true in
  check bool "a second invite explains how to open the earlier card" true
    (contains ~sub:"/play link <name>" retained);
  check bool "and still does not carry a link" false (contains ~sub:"play#" retained)
;;

let () =
  run "Masc_tui_play_card"
    [ ( "card"
      , [ test_case "a link the card cannot draw is refused" `Quick
            test_a_link_the_card_cannot_draw_is_refused
        ; test_case "the QR is the library's QR with its quiet zone" `Quick
            test_the_qr_is_the_libraries_qr_with_its_quiet_zone
        ; test_case "the QR is drawn only when all of it fits" `Quick
            test_the_qr_is_drawn_only_when_all_of_it_fits
        ; test_case "no colour draws no QR and says why" `Quick
            test_no_colour_draws_no_qr_and_says_why
        ; test_case "the link is cut to the width without losing a byte" `Quick
            test_the_link_is_cut_to_the_width_without_losing_a_byte
        ; test_case "the link appears only in its own rows" `Quick
            test_the_link_appears_only_in_its_own_rows
        ; test_case "a name from the wire is drawn safe" `Quick
            test_a_name_from_the_wire_is_drawn_safe
        ; test_case "the issue notice never carries the link" `Quick
            test_the_issue_notice_never_carries_the_link
        ] )
    ]
;;
