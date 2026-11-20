(* The reading slot at the end of zone 2 (RFC tui-one-screen-grammar,
   section 8).

   The slot keeps its cells drawn or blank, so these read the row's decisions
   and not its text: the room the path has, the cells the row keeps outside
   the slot, the cells the slot's text fills, and where the slot folds. They
   are the geometry invariants the RFC lists in section 10. *)

open Alcotest
module T = Masc_tui_types
module R = Masc_tui_reading
module Layout = Masc_tui_message_layout
module Prim = Masc_tui_render_prim

let widths = [ 60; 100; 150; 200 ]

let positions =
  [ ("no position", None)
  ; ( "a selected row"
    , Some (Masc_tui_value.Position.row ~selected:(Some 7) ~total:29) )
  ; ("a window", Masc_tui_value.Position.window ~first:1_200 ~shown:30 ~total:48_000)
  ]

let shown_values () =
  [ ("blank", R.Hidden)
  ; ("six seconds", R.Showing (R.Frozen { age_s = 6.0 }))
  ; ("a hundred days", R.Showing (R.Frozen { age_s = 100.0 *. 86_400.0 }))
  ; ("a growing length", R.Showing (R.Growing { began = Masc_tui_wake.Mono.now () }))
  ]

let fresh shown =
  let state = T.create_state ~workspace:"slot-row" ~port:0 () in
  state.T.reading_slot <- shown;
  state

let plain = Masc_tui_theme.strip_sgr

let head text cells =
  match Layout.take_cells text cells with
  | Layout.Whole text | Layout.Cut text -> text

(* What is left of the row for the path: the width the row asks a title for,
   in cells. *)
let path_room ~cols ~position shown =
  let asked = ref None in
  let (_ : Layout.head) =
    Prim.zone_two_title_head ~cols (fresh shown) ~position ~title:(fun ~cols:width ->
        asked := Some width;
        "")
  in
  match !asked with
  | Some width -> Masc_tui_ansi.framed_inner_width width
  | None -> failf "the row did not ask for a title at %d cols" cols

let test_the_slot_takes_seven_cells_from_the_path () =
  check int "the reserve is the slot and the gap ahead of it" 7
    Prim.reading_slot_reserve_cells;
  List.iter
    (fun cols ->
      check int
        (Printf.sprintf "%d cols, no position" cols)
        (Masc_tui_ansi.framed_inner_width cols - Prim.reading_slot_reserve_cells)
        (path_room ~cols ~position:None R.Hidden))
    widths

let test_the_path_has_the_same_room_whatever_the_slot_says () =
  List.iter
    (fun cols ->
      List.iter
        (fun (name, position) ->
          let blank = path_room ~cols ~position R.Hidden in
          List.iter
            (fun (what, shown) ->
              check int
                (Printf.sprintf "%s, %s, %d cols" name what cols)
                blank
                (path_room ~cols ~position shown))
            (shown_values ()))
        positions)
    widths

(* The slot folds whole when the path would be left with no cell, and not
   before: the narrowest row that keeps it leaves the path one cell. *)
let test_the_slot_folds_when_the_path_would_have_no_cell () =
  List.iter
    (fun position_cells ->
      let left_for_the_path cols =
        Masc_tui_ansi.framed_inner_width cols
        - position_cells - Prim.reading_slot_reserve_cells
      in
      let rec narrowest_kept cols =
        if cols > 400 then failf "the slot is folded at every width up to 400 cols"
        else if Prim.reading_slot_folded ~cols ~position_cells then
          narrowest_kept (cols + 1)
        else cols
      in
      let kept = narrowest_kept 1 in
      let label = Printf.sprintf "a position taking %d cells" position_cells in
      check int (label ^ ": the narrowest row that keeps the slot") 1
        (left_for_the_path kept);
      check int (label ^ ": one column narrower") 0 (left_for_the_path (kept - 1));
      check bool (label ^ ": folded there") true
        (Prim.reading_slot_folded ~cols:(kept - 1) ~position_cells))
    [ 0; 8; 20 ]

(* A folded slot is neither drawn nor blank: the path gets the cells the slot
   would have had. *)
let test_a_folded_slot_leaves_the_path_its_cells () =
  List.iter
    (fun cols ->
      let inner = Masc_tui_ansi.framed_inner_width cols in
      let expected =
        if Prim.reading_slot_folded ~cols ~position_cells:0 then inner
        else inner - Prim.reading_slot_reserve_cells
      in
      List.iter
        (fun (what, shown) ->
          check int
            (Printf.sprintf "%s, %d cols" what cols)
            expected
            (path_room ~cols ~position:None shown))
        (shown_values ()))
    [ 8; 9; 10; 11; 12; 13; 14; 15; 16 ]

let row ~cols ~position shown =
  Prim.here_row ~cols (fresh shown) ~path:[ "calls" ] ~readings:[] ~position

let test_the_slot_moves_no_other_cell () =
  List.iter
    (fun cols ->
      List.iter
        (fun (name, position) ->
          let blank = plain (row ~cols ~position R.Hidden) in
          List.iter
            (fun (what, shown) ->
              let drawn = plain (row ~cols ~position shown) in
              let label = Printf.sprintf "%s, %s, %d cols" name what cols in
              check int
                (label ^ ": the row is as wide")
                (Layout.display_width blank)
                (Layout.display_width drawn);
              let outside text =
                head text (Layout.display_width text - R.width_cells)
              in
              check string
                (label ^ ": the cells outside the slot")
                (outside blank) (outside drawn))
            (shown_values ()))
        positions)
    widths

let test_the_slot_text_fills_the_cells_it_keeps () =
  List.iter
    (fun (what, shown) ->
      let text =
        R.text ~now:(Masc_tui_wake.Mono.now ()) ~wall_now:(Unix.gettimeofday ()) shown
      in
      check int
        (what ^ ": the cells the slot's text fills")
        R.width_cells (Layout.display_width text))
    (shown_values ())

let () =
  run "tui_reading_slot_row"
    [ ( "the room the path has"
      , [ test_case "seven cells from the path" `Quick
            test_the_slot_takes_seven_cells_from_the_path
        ; test_case "the same room on or off" `Quick
            test_the_path_has_the_same_room_whatever_the_slot_says
        ; test_case "folds at no cell" `Quick
            test_the_slot_folds_when_the_path_would_have_no_cell
        ; test_case "a folded slot leaves its cells" `Quick
            test_a_folded_slot_leaves_the_path_its_cells
        ] )
    ; ( "the row"
      , [ test_case "no other cell moves" `Quick test_the_slot_moves_no_other_cell
        ; test_case "the text fills its cells" `Quick
            test_the_slot_text_fills_the_cells_it_keeps
        ] )
    ]
