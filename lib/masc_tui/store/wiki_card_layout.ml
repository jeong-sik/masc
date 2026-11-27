module Rect = Masc_tui_core.Rect
module Layout = Masc_tui_ui.Layout
module Card = Masc_tui_ui.Card

(* Zoomed, the page card takes about two thirds of the width, or of the
   height when the cards stack on a compact screen. *)
let zoomed_page_ratio = 0.66
let zoomed_page_top_ratio = 0.68

(* Split, the topic tree takes the left part and the page card the rest. *)
let split_tree_ratio = 0.38
let split_tree_top_ratio = 0.48

(* From this inner height the title band has a second row for the
   subtitle. *)
let subtitle_min_inner_h = 7
let rail_w = 22
let rail_min_w = 68
let rail_min_h = 8

type frame = {
  bar : Rect.t;
  preview : Rect.t;
  aside : Rect.t;
  inline_rail : bool;
}

let frame ~zoomed bp (rect : Rect.t) =
  let bar, body =
    match Layout.split_v rect [ Layout.Fixed 1; Layout.Flex 1 ] with
    | [ bar; body ] -> (bar, body)
    | _ -> (Rect.empty, rect)
  in
  if zoomed then
    let preview, aside =
      Layout.adaptive_split_2 ~stack_on_compact:true
        ~left_ratio:zoomed_page_ratio ~top_ratio:zoomed_page_top_ratio bp body
    in
    { bar; preview; aside; inline_rail = false }
  else
    let aside, preview =
      Layout.adaptive_split_2 ~stack_on_compact:true
        ~left_ratio:split_tree_ratio ~top_ratio:split_tree_top_ratio bp body
    in
    { bar; preview; aside; inline_rail = true }

type page_body =
  | Rail of { prose : Rect.t; rule : Rect.t; rail : Rect.t }
  | Stacked of { backlinks : Rect.t; rule : Rect.t; markdown : Rect.t }

type page = { band : Rect.t; body : page_body option }

let pad ~bp ?(pad_y = 0) (r : Rect.t) =
  Card.pad_inner ~pad_x:(Layout.card_pad_x_for_width bp r.w) ~pad_y r

(* The first row of [r] and the rows below it. *)
let first_row (r : Rect.t) =
  if Rect.is_empty r then (Rect.empty, r)
  else
    ( Rect.make ~x:r.x ~y:r.y ~w:r.w ~h:1,
      Rect.make ~x:r.x ~y:(r.y + 1) ~w:r.w ~h:(r.h - 1) )

let page bp ~inline_rail (inner : Rect.t) =
  let band_h = if inner.h >= subtitle_min_inner_h then 2 else 1 in
  let band =
    Rect.make ~x:inner.x ~y:inner.y ~w:inner.w ~h:(Int.min band_h inner.h)
  in
  let below =
    Rect.make ~x:inner.x ~y:(inner.y + band.h) ~w:inner.w
      ~h:(inner.h - band.h)
  in
  let body =
    if Rect.is_empty below then None
    else if
      inline_rail
      && Layout.equal_breakpoint bp Layout.Wide
      && below.w >= rail_min_w
      && below.h >= rail_min_h
    then
      let prose_w = below.w - rail_w - 1 in
      let prose =
        Rect.make ~x:below.x ~y:below.y ~w:prose_w ~h:below.h
        |> pad ~bp ~pad_y:1
      in
      let rule = Rect.make ~x:(below.x + prose_w) ~y:below.y ~w:1 ~h:below.h in
      let rail =
        Rect.make ~x:(below.x + prose_w + 1) ~y:below.y ~w:rail_w ~h:below.h
        |> Card.pad_inner ~pad_x:1 ~pad_y:1
      in
      Some (Rail { prose; rule; rail })
    else
      let backlinks, rest = first_row (pad ~bp below) in
      let rule, markdown = first_row rest in
      Some (Stacked { backlinks; rule; markdown })
  in
  { band; body }

let page_markdown = function
  | { body = Some (Rail { prose; _ }); _ } -> Some prose
  | { body = Some (Stacked { markdown; _ }); _ } -> Some markdown
  | { body = None; _ } -> None

type summary = {
  heading : Rect.t;
  counts : Rect.t;
  rule : Rect.t;
  markdown : Rect.t;
}

let summary bp (inner : Rect.t) =
  let heading, rest = first_row (pad ~bp inner) in
  let counts, rest = first_row rest in
  let rule, markdown = first_row rest in
  { heading; counts; rule; markdown }
