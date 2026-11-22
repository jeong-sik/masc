module Rect = Masc_tui_core.Rect
module Theme = Masc_tui_core.Theme
module Attr = Masc_tui_term.Attr
module Color = Masc_tui_term.Color
module Style = Masc_tui_term.Style
module Cell_grid = Masc_tui_term.Cell_grid

type row =
  | Context of string
  | Removed of string
  | Added of string

type numbered = {
  nrow : row;
  old_line : int option;
  new_line : int option;
}

let equal_row a b =
  match (a, b) with
  | Context x, Context y -> String.equal x y
  | Removed x, Removed y -> String.equal x y
  | Added x, Added y -> String.equal x y
  | (Context _ | Removed _ | Added _), _ -> false

let equal_numbered a b =
  equal_row a.nrow b.nrow
  && Option.equal Int.equal a.old_line b.old_line
  && Option.equal Int.equal a.new_line b.new_line

let lines text =
  if String.length text = 0 then []
  else
    match String.split_on_char '\n' text with
    | [] -> []
    | split -> (
        match List.rev split with
        | "" :: rest when List.length split > 1 -> List.rev rest
        | _ -> split)

let common_prefix before after =
  let rec walk taken b a =
    match (b, a) with
    | x :: bx, y :: ax when String.equal x y -> walk (x :: taken) bx ax
    | _ -> (List.rev taken, b, a)
  in
  walk [] before after

let common_suffix before after =
  let shared, b_rest, a_rest =
    common_prefix (List.rev before) (List.rev after)
  in
  (List.rev shared, List.rev b_rest, List.rev a_rest)

let rows ~before ~after =
  let b_lines = lines before and a_lines = lines after in
  let prefix, b_rest, a_rest = common_prefix b_lines a_lines in
  let suffix, b_mid, a_mid = common_suffix b_rest a_rest in
  List.concat
    [
      List.map (fun l -> Context l) prefix;
      List.map (fun l -> Removed l) b_mid;
      List.map (fun l -> Added l) a_mid;
      List.map (fun l -> Context l) suffix;
    ]

let counts rows =
  List.fold_left
    (fun (rem, add) r ->
      match r with
      | Removed _ -> (rem + 1, add)
      | Added _ -> (rem, add + 1)
      | Context _ -> (rem, add))
    (0, 0) rows

let rec take count xs =
  if count <= 0 then []
  else
    match xs with
    | [] -> []
    | x :: rest -> x :: take (count - 1) rest

let take_last count xs = xs |> List.rev |> take count |> List.rev

let is_context = function
  | Context _ -> true
  | Removed _ | Added _ -> false

let leading_context ~is_context xs =
  let rec walk acc = function
    | x :: rest when is_context x -> walk (x :: acc) rest
    | rest -> (List.rev acc, rest)
  in
  walk [] xs

let split_around_change ~is_context xs =
  let before, after_before = leading_context ~is_context xs in
  let after_rev, changed_rev =
    leading_context ~is_context (List.rev after_before)
  in
  (before, List.rev changed_rev, List.rev after_rev)

let window ~context ~max_rows ~before ~changed ~after =
  let total = List.length before + List.length changed + List.length after in
  if context < 0 || max_rows <= 0 then ([], total)
  else
    let changed_count = List.length changed in
    let shown =
      if changed_count >= max_rows then take max_rows changed
      else
        let remaining = max_rows - changed_count in
        let before_cap = take_last context before in
        let after_cap = take context after in
        let before_first = Int.min (List.length before_cap) ((remaining + 1) / 2) in
        let after_first = Int.min (List.length after_cap) (remaining - before_first) in
        let unused = remaining - before_first - after_first in
        let before_extra = Int.min (List.length before_cap - before_first) unused in
        let after_extra =
          Int.min (List.length after_cap - after_first) (unused - before_extra)
        in
        let before_count = before_first + before_extra in
        let after_count = after_first + after_extra in
        take_last before_count before_cap @ changed @ take after_count after_cap
    in
    (shown, Int.max 0 (total - List.length shown))

let preview ~context ~max_rows xs =
  let before, changed, after = split_around_change ~is_context xs in
  window ~context ~max_rows ~before ~changed ~after

let number ~old_start ~new_start xs =
  let old_cursor = ref old_start and new_cursor = ref new_start in
  List.map
    (fun r ->
      match r with
      | Context _ ->
          let n =
            { nrow = r; old_line = Some !old_cursor; new_line = !new_cursor }
          in
          incr old_cursor;
          new_cursor := Option.map succ !new_cursor;
          n
      | Removed _ ->
          let n = { nrow = r; old_line = Some !old_cursor; new_line = None } in
          incr old_cursor;
          n
      | Added _ ->
          let n = { nrow = r; old_line = None; new_line = !new_cursor } in
          new_cursor := Option.map succ !new_cursor;
          n)
    xs

let preview_numbered ~context ~max_rows xs =
  let before, changed, after =
    split_around_change ~is_context:(fun n -> is_context n.nrow) xs
  in
  window ~context ~max_rows ~before ~changed ~after

let line_number_cell = function
  | None -> "    -"
  | Some line -> Printf.sprintf "%5d" line

let numbered_gutter_cells = 14

let numbered_gutter ~old_line ~new_line ~marker =
  Printf.sprintf "%s %s %c "
    (line_number_cell old_line)
    (line_number_cell new_line)
    marker

let draw grid ~(rect : Rect.t) ~(theme : Theme.t) ?language ?(scroll = 0)
    (numbered_rows : numbered list) =
  let total = List.length numbered_rows in
  if Rect.is_empty rect || total = 0 then total
  else
    let arr = Array.of_list numbered_rows in
    let max_start = Int.max 0 (total - rect.h) in
    let start = Int.max 0 (Int.min max_start scroll) in
    let visible = Int.min rect.h (total - start) in
    for i = 0 to visible - 1 do
      let item = arr.(start + i) in
      let py = rect.y + i in
      let row_rect = Rect.make ~x:rect.x ~y:py ~w:rect.w ~h:1 in
      let marker, text, marker_fg, row_bg =
        match item.nrow with
        | Context s -> (' ', s, theme.text_muted, theme.surface_1)
        | Removed s -> ('-', s, theme.status_critical, theme.surface_1)
        | Added s -> ('+', s, theme.status_ok, theme.surface_1)
      in
      let bg = Color.of_rgb row_bg in
      let base_style = Style.make ~fg:(Color.of_rgb theme.text_primary) ~bg () in
      Cell_grid.fill_rect ~clip:rect grid ~rect:row_rect ~style:base_style ();
      let gutter_style = Style.make ~fg:(Color.of_rgb theme.text_muted) ~bg () in
      let marker_style =
        Style.make ~fg:(Color.of_rgb marker_fg) ~bg ~attrs:Attr.bold ()
      in
      let body_x =
        if rect.w >= numbered_gutter_cells + 4 then begin
          let nums =
            Printf.sprintf "%s %s "
              (line_number_cell item.old_line)
              (line_number_cell item.new_line)
          in
          let adv = Cell_grid.put_text ~clip:row_rect grid ~x:rect.x ~y:py ~style:gutter_style nums in
          Cell_grid.put_ascii ~clip:row_rect grid ~x:(rect.x + adv) ~y:py ~style:marker_style marker;
          Cell_grid.put_ascii ~clip:row_rect grid ~x:(rect.x + adv + 1) ~y:py ~style:gutter_style ' ';
          rect.x + adv + 2
        end
        else begin
          Cell_grid.put_ascii ~clip:row_rect grid ~x:rect.x ~y:py ~style:marker_style marker;
          Cell_grid.put_ascii ~clip:row_rect grid ~x:(rect.x + 1) ~y:py ~style:gutter_style ' ';
          rect.x + 2
        end
      in
      let avail_body = Int.max 0 (Rect.right rect - body_x) in
      if avail_body > 0 then
        match language with
        | Some lang ->
            let segs =
              Code_lexer.lex lang text
              |> List.map (fun (seg : Code_lexer.segment) ->
                     match seg.kind with
                     | Code_lexer.Plain -> (
                         match item.nrow with
                         | Removed _ -> { seg with kind = Code_lexer.Diff_removed }
                         | Added _ -> { seg with kind = Code_lexer.Diff_added }
                         | Context _ -> seg)
                     | Code_lexer.Keyword
                     | Code_lexer.String
                     | Code_lexer.Comment
                     | Code_lexer.Number
                     | Code_lexer.Type_or_ctor
                     | Code_lexer.Json_key
                     | Code_lexer.Json_number
                     | Code_lexer.Json_literal
                     | Code_lexer.Json_punctuation
                     | Code_lexer.Diff_added
                     | Code_lexer.Diff_removed
                     | Code_lexer.Diff_hunk ->
                         seg)
            in
            ignore
              (Code_lexer.draw_row ~clip:row_rect grid ~x:body_x ~y:py
                 ~max_w:avail_body ~theme ~bg segs)
        | None ->
            let fg =
              match item.nrow with
              | Context _ -> theme.text_primary
              | Removed _ -> theme.status_critical
              | Added _ -> theme.status_ok
            in
            let style = Style.make ~fg:(Color.of_rgb fg) ~bg () in
            ignore (Cell_grid.put_text ~clip:row_rect grid ~x:body_x ~y:py ~style text)
    done;
    total
