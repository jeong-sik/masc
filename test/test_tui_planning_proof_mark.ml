open Alcotest
module Mark = Masc_tui_planning_proof_mark
module Decode = Masc.Tui_decode

(* Every verdict the wire can carry. Written out rather than derived, because a
   state added to [goal_proof] should stop this list being complete and say so
   in the failure below -- the module's own matches already refuse to compile
   without a mark and a word for it. *)
let every_verdict =
  [ Decode.Proof_idle
  ; Decode.Proof_pending
  ; Decode.Proof_proven None
  ; Decode.Proof_refuted None
  ; Decode.Proof_stale None
  ; Decode.Proof_unreadable None
  ]

let test_the_legend_explains_every_mark_a_row_can_draw () =
  check (list (pair string string))
    "every verdict at once asks for the whole legend" Mark.legend
    (Mark.legend_for every_verdict);
  List.iter
    (fun verdict ->
      let mark = Mark.glyph verdict in
      if not (String.equal mark " ") then
        check bool ("the legend names " ^ mark) true
          (List.exists (fun (m, _) -> String.equal m mark) Mark.legend))
    every_verdict

let test_the_legend_says_only_what_the_list_draws () =
  check (list (pair string string)) "a list of waiting goals gets one row"
    [ ("\xe2\x80\xa6", "waiting") ]
    (Mark.legend_for
       [ Decode.Proof_pending; Decode.Proof_pending; Decode.Proof_idle ]);
  check int "no goals, no legend" 0 (List.length (Mark.legend_for []));
  check int "goals nobody asked about, no legend" 0
    (List.length (Mark.legend_for [ Decode.Proof_idle; Decode.Proof_idle ]))

let test_the_legend_keeps_its_own_order () =
  check (list string) "the order is the journey, not the row order"
    [ "\xe2\x9c\x93"; "~" ]
    (List.map fst
       (Mark.legend_for [ Decode.Proof_stale None; Decode.Proof_proven None ]))

(* The mark the column draws and the mark the legend explains come from one
   function, so they cannot disagree. This is the assertion that would have
   caught the missing entry: "criterion changed" had no word for its glyph
   while the column drew it. *)
let test_the_column_and_the_legend_read_the_same_glyph () =
  List.iter
    (fun verdict ->
      match Mark.legend_for [ verdict ] with
      | [] ->
          check string "a verdict with no legend row draws a blank" " "
            (Mark.glyph verdict)
      | [ (mark, _) ] ->
          check string ("the legend's glyph is the column's for " ^ mark)
            (Mark.glyph verdict) mark
      | rows -> failf "one verdict asked for %d legend rows" (List.length rows))
    every_verdict

let () =
  run "tui planning proof mark"
    [ ( "judge legend"
      , [ test_case "the legend explains every mark a row can draw" `Quick
            test_the_legend_explains_every_mark_a_row_can_draw
        ; test_case "the legend says only what the list draws" `Quick
            test_the_legend_says_only_what_the_list_draws
        ; test_case "the legend keeps its own order" `Quick
            test_the_legend_keeps_its_own_order
        ; test_case "the column and the legend read the same glyph" `Quick
            test_the_column_and_the_legend_read_the_same_glyph
        ] )
    ]
