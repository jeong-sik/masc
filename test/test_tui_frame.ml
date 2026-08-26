(** The framed box's measurements, and that they still describe one box.

    These numbers were spelled out as literals wherever something measured
    against the frame -- [cols - 4] fifteen times, [cols - 2] four, [rows - 5]
    ten more, across three modules that could not see each other's copy. A
    caller had no way to tell which of them it was supposed to match, and the
    agenda panel matched none of them: its rows were laid out against the
    terminal's width and cut on the way through the frame.

    What is checked here is the arithmetic those callers depend on, so the
    numbers cannot drift apart from each other. *)

open Alcotest
module Frame = Masc_tui_frame

(* A row is drawn as border, pad, content, pad, border, and it spans the
   terminal. Whatever those cost, they cost the same at every width -- so a
   caller that worked its own row out once can trust the next one. *)
let test_the_frame_costs_the_same_at_every_width () =
  let cost cols = cols - Frame.inner_width ~cols in
  List.iter
    (fun cols ->
       check
         int
         (Printf.sprintf "at %d cells the frame costs what it costs at 80" cols)
         (cost 80)
         (cost cols))
    [ 20; 40; 200; 400 ]
;;

(* The rule runs between the two corner glyphs; the content sits inside the
   rule, one pad each side. *)
let test_the_rule_and_the_content_agree () =
  let pad cols = Frame.rule_width ~cols - Frame.inner_width ~cols in
  List.iter
    (fun cols ->
       check
         int
         (Printf.sprintf "at %d cells the content sits the same way in the rule" cols)
         (pad 80)
         (pad cols))
    [ 20; 40; 200; 400 ]
;;

(* The width the frame fits a row to, at the sizes a terminal actually is. *)
let test_known_widths () =
  check int "80 columns leave 76" 76 (Frame.inner_width ~cols:80);
  check int "80 columns rule 78" 78 (Frame.rule_width ~cols:80)
;;

(* A terminal narrower than the border cannot be drawn into, and the answer is
   no cells rather than a negative that would raise from [String.make]. *)
let test_a_frame_narrower_than_its_border () =
  List.iter
    (fun cols ->
       check bool (Printf.sprintf "inner at %d is not negative" cols) true
         (Frame.inner_width ~cols >= 0);
       check bool (Printf.sprintf "rule at %d is not negative" cols) true
         (Frame.rule_width ~cols >= 0))
    [ 0; 1; 2; 3; 4 ]
;;

(* The number the help sheet's viewport was written against, kept so the panel
   and the keypress that scrolls it still agree. *)
let test_content_height () =
  check int "a 43-row viewport draws 38 rows" 38 (Frame.content_height ~rows:43);
  check
    int
    "a viewport smaller than the frame still draws one row"
    1
    (Frame.content_height ~rows:2)
;;

let () =
  run
    "tui frame"
    [ ( "geometry"
      , [ test_case "the frame costs the same at every width" `Quick
            test_the_frame_costs_the_same_at_every_width
        ; test_case "the rule and the content agree" `Quick
            test_the_rule_and_the_content_agree
        ; test_case "known widths" `Quick test_known_widths
        ; test_case "a frame narrower than its border" `Quick
            test_a_frame_narrower_than_its_border
        ; test_case "content height" `Quick test_content_height
        ] )
    ]
;;
