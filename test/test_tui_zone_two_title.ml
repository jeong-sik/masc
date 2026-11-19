(* A title row with a position at its right (RFC tui-one-screen-grammar,
   section 2).

   A title that lays out its own parts sizes them to a frame width. Asked
   for at the whole row's width, the parts filled the row, and the row cut
   their end to keep the position: on the Keeper detail the last tab or the
   mark that counts the hidden ones, on a Config pane the connection badge
   (#53217 review). The row now asks for the title at the width the position
   leaves.

   These read the row's decision -- whether it had to cut the title -- with
   a window position, at the widths where a strip leaves less slack than
   that position takes. Each shape also checks that the part it exists to
   keep is in the title, so an empty title cannot pass as a whole one. *)

open Masc_tui_render_prim

let widths = [ 80; 100 ]

(* A window over a long body. Its text is as wide as a Keeper detail's or a
   log's gets, so the slack a strip leaves is smaller than it. *)
let window = Masc_tui_value.Position.window ~first:1_200 ~shown:30 ~total:48_000

let fresh view =
  let state = Masc_tui_types.create_state ~workspace:"test" ~port:8935 () in
  state.Masc_tui_types.ui_language <- Masc_tui_types.Lang_en;
  state.view <- view;
  state

let contains text needle =
  let n = String.length needle and m = String.length text in
  let rec at i = i + n <= m && (String.sub text i n = needle || at (i + 1)) in
  at 0

let plain = Masc_tui_theme.strip_sgr

(* The text the row keeps whole, or [None] when it cut the title. *)
let kept_whole ~cols state ~title =
  match zone_two_title_head ~cols state ~position:window ~title with
  | Masc_tui_message_layout.Whole text -> Some (plain text)
  | Masc_tui_message_layout.Cut _ -> None

(* Tab strip: the Keeper detail's tabs, from every tab, so the strip's
   window runs over every place its current entry can stand. *)
let test_the_strip_is_laid_out_in_the_cells_the_position_leaves () =
  let state = fresh (Masc_tui_types.Keepers Masc_tui_types.Keeper_detail) in
  List.iter
    (fun tab ->
      state.Masc_tui_types.detail_tab <- tab;
      let label = Masc_tui_types.keeper_detail_tab_title ~ko:false tab in
      List.iter
        (fun cols ->
          let what = Printf.sprintf "%s tab at %d cols" label cols in
          match
            kept_whole ~cols state
              ~title:(keeper_detail_title state ~keeper_name:"night-shift-reviewer")
          with
          | None -> Alcotest.failf "%s: the row cut the strip" what
          | Some title ->
              Alcotest.(check bool) (what ^ ": the strip keeps the open tab") true
                (contains title label))
        widths)
    Masc_tui_types.keeper_detail_tabs

(* Badge tail: a Config pane's row ends with the connection badge, from
   every pane. *)
let test_the_badge_is_laid_out_in_the_cells_the_position_leaves () =
  let state = fresh Masc_tui_types.Config in
  state.Masc_tui_types.observer_source_loss <- true;
  let badge = plain (connection_badge state) in
  List.iter
    (fun (pane, name) ->
      state.Masc_tui_types.config_pane <- pane;
      List.iter
        (fun cols ->
          let what = Printf.sprintf "%s pane at %d cols" name cols in
          match kept_whole ~cols state ~title:(config_pane_title ~reading:"12 presets" state) with
          | None -> Alcotest.failf "%s: the row cut the title" what
          | Some title ->
              Alcotest.(check bool) (what ^ ": the badge is whole") true
                (contains title badge))
        widths)
    Masc_tui_types.config_panes

let () =
  Alcotest.run "tui_zone_two_title"
    [ ( "title beside a position"
      , [ Alcotest.test_case "tab strip" `Quick
            test_the_strip_is_laid_out_in_the_cells_the_position_leaves
        ; Alcotest.test_case "badge tail" `Quick
            test_the_badge_is_laid_out_in_the_cells_the_position_leaves
        ] )
    ]
