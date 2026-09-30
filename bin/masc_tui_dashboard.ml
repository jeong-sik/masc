module Text = Masc_tui_message_layout
module Theme = Masc_tui_theme

type section = Attention | Work | Goals | Keepers | Usage
let sections = [ Attention; Work; Goals; Keepers; Usage ]
let next = function
  | Attention -> Work | Work -> Goals | Goals -> Keepers
  | Keepers -> Usage | Usage -> Attention
let previous = function
  | Attention -> Usage | Work -> Attention | Goals -> Work
  | Keepers -> Goals | Usage -> Keepers
let label = function
  | Attention -> "Needs you" | Work -> "Work" | Goals -> "Goals"
  | Keepers -> "Keepers" | Usage -> "Usage"

type card = {
  section : section;
  title : string;
  summary : string;
  details : string list;
  status : Theme.status;
}

let repeat cells glyph = String.concat "" (List.init (max 0 cells) (fun _ -> glyph))
let take_rows ~height lines =
  if List.length lines <= height then lines
  else if height <= 0 then []
  else
    List.take (height - 1) lines
    @ [ Printf.sprintf "+%d detail rows · Enter to open"
          (List.length lines - height + 1) ]

let border ~width ~selected ~palette card =
  let color =
    if selected = card.section then Theme.status_readable palette Theme.Info
    else Theme.status_readable palette card.status
  in
  let marker = if selected = card.section then "› " else "  " in
  let title = marker ^ card.title ^ " " in
  color ^ Theme.Box.tl ^ Theme.Sgr.bold
  ^ Text.fit_width title (min (width - 2) (Text.display_width title))
  ^ Theme.Sgr.reset ^ color
  ^ repeat (width - 2 - Text.display_width title) Theme.Box.h
  ^ Theme.Box.tr ^ Theme.Sgr.reset

let panel ~width ~height ~selected ~palette ~quiet card =
  let inner = max 1 (width - 4) in
  let color = Theme.status_readable palette card.status in
  let content =
    Text.wrap_words ~max_cells:inner card.summary
    @ List.concat_map (Text.wrap_words ~max_cells:inner) card.details
  in
  let content = take_rows ~height:(height - 2) content in
  let body =
    List.mapi
      (fun index line ->
        let style = if index = 0 then color ^ Theme.Sgr.bold else "" in
        quiet ^ Theme.Box.v ^ Theme.Sgr.reset ^ " "
        ^ style ^ Text.fit_width line inner ^ Theme.Sgr.reset ^ " "
        ^ quiet ^ Theme.Box.v ^ Theme.Sgr.reset)
      (content @ List.init (max 0 (height - 2 - List.length content)) (fun _ -> ""))
  in
  border ~width ~selected ~palette card :: body
  @ [ quiet ^ Theme.Box.bl ^ repeat (width - 2) Theme.Box.h
      ^ Theme.Box.br ^ Theme.Sgr.reset ]

(* Two 48-cell panels leave room for a useful sentence beside a measured
   value. The two-cell gutter is part of the geometry, not a runtime gate. *)
let minimum_panel_width = 48
let gutter = 2
let band_height = 5
let minimum_pair_height = 7
let wide_height = (2 * minimum_pair_height) + band_height + 2

let render ~width ~height ~selected ~palette ~quiet cards =
  let width = max 1 width in
  let height = max 0 height in
  if width >= (2 * minimum_panel_width) + gutter && height >= wide_height then
    let pair_height = min 12 ((height - band_height - 2) / 2) in
    let left_width = (width - gutter) / 2 in
    let right_width = width - gutter - left_width in
    let pair left right =
      let left = panel ~width:left_width ~height:pair_height ~selected ~palette ~quiet left in
      let right = panel ~width:right_width ~height:pair_height ~selected ~palette ~quiet right in
      List.map2 (fun l r -> l ^ String.make gutter ' ' ^ r) left right
    in
    match cards with
    | [ attention; work; goals; keepers; usage ] ->
        pair attention work @ [ "" ] @ pair goals keepers @ [ "" ]
        @ panel ~width ~height:band_height ~selected ~palette ~quiet usage
    | [] | _ :: _ ->
        List.concat_map (panel ~width ~height:minimum_pair_height ~selected ~palette ~quiet) cards
        |> take_rows ~height
  else if height < 2 * List.length cards then
    let rows =
      List.map
        (fun card ->
          let chosen = card.section = selected in
          let marker = if chosen then "› " else "  " in
          let style = if chosen then Theme.Sgr.reverse else quiet in
          style ^ Text.fit_width (marker ^ card.title ^ " · " ^ card.summary) width
          ^ Theme.Sgr.reset)
        cards
    in
    if List.length rows <= height then rows
    else
      let selected_index =
        match List.find_index (fun card -> card.section = selected) cards with
        | Some index -> index
        | None -> 0
      in
      let shown = max 1 (height - 1) in
      let offset = max 0 (min selected_index (List.length rows - shown)) in
      List.drop offset rows |> List.take shown
      |> fun visible ->
        if height <= 1 then List.take height visible
        else visible @ [ Text.fit_width "j/k cards · Enter opens selection" width ]
  else
    (* Every card keeps its heading and one summary. Only the selected card
       expands, so selection and the next action survive a small terminal. *)
    let base_rows = 2 * List.length cards in
    let detail_height = max 0 (height - base_rows) in
    List.concat_map
      (fun card ->
        let chosen = card.section = selected in
        let style =
          if chosen then Theme.Sgr.reverse else Theme.status_readable palette card.status
        in
        let marker = if chosen then "› " else "  " in
        [ style ^ Text.fit_width (marker ^ card.title) width ^ Theme.Sgr.reset
        ; "  " ^ Text.fit_width card.summary (max 0 (width - 2)) ]
        @ (if chosen then
             List.concat_map (Text.wrap_words ~max_cells:(max 1 (width - 4))) card.details
             |> take_rows ~height:detail_height
             |> List.map (fun line -> "    " ^ line)
           else []))
      cards
    |> take_rows ~height
