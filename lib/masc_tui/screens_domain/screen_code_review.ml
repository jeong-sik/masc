open Masc_tui_core
open Masc_tui_term
open Masc_tui_ui
open Masc_tui_protocol
open Masc_tui_store

module H = Domain_helpers
module L = Code_review_layout

let change_marker (c : Wire_infra.git_status_change) =
  if c.conflicted then ("!", Theme.Status_critical)
  else if c.untracked then ("?", Theme.Status_historical)
  else ("M", Theme.Status_attention)

let draw_changes ~(model : Model.t) ~grid ~(rect : Rect.t) ~(theme : Theme.t) =
  let inf = model.infra in
  let lang = model.lang in
  match Infra_store.review_changes inf with
  | [] ->
      H.draw_observed_placeholder ~grid ~rect ~theme ~lang
        ~empty_msg:(Say.make ~ko:"바뀐 파일 없음" ~en:"No changed files")
        inf.code.git_status
  | changes ->
      let total = List.length changes in
      let sel = Infra_store.review_selected_index inf in
      let start_i, _ =
        Table.compute_viewport ~total_rows:total ~viewport_rows:rect.h ~scroll:0
          ~selected:sel
      in
      let focused = Model.pane_focused model 0 in
      List.iteri
        (fun local_i (c : Wire_infra.git_status_change) ->
          let y = rect.y + local_i in
          if y < Rect.bottom rect then begin
            let is_sel = Option.equal Int.equal sel (Some (start_i + local_i)) in
            let row_rect = Rect.make ~x:rect.x ~y ~w:rect.w ~h:1 in
            let bg =
              if is_sel then H.selected_row_bg ~theme ~focused else theme.surface_1
            in
            if is_sel then
              H.paint_selected_row_bg ~grid ~clip:rect ~row_rect ~theme ~focused ();
            let marker, tone = change_marker c in
            ignore
              (H.put_clipped ~grid ~clip:row_rect ~x:(rect.x + 1) ~y ~max_w:1
                 ~style:(H.status_style ~theme ~bg tone) marker);
            ignore
              (H.put_clipped ~grid ~clip:row_rect ~x:(rect.x + 3) ~y
                 ~max_w:(Int.max 0 (rect.w - 4))
                 ~style:
                   (if is_sel then H.anchor_style ~theme ~bg ()
                    else H.text_style ~theme ~bg ())
                 c.path)
          end)
        (Store_scroll.drop start_i changes)

let hunk_text (h : Wire_infra.git_diff_hunk) =
  Printf.sprintf "@@ -%d,%d +%d,%d @@%s" h.old_start h.old_count h.new_start
    h.new_count
    (match h.section with Some s -> " " ^ s | None -> "")

let line_tone (l : Wire_infra.git_diff_line) =
  match l.kind with
  | `Add -> (Some Theme.Status_ok, '+')
  | `Delete -> (Some Theme.Status_critical, '-')
  | `Context -> (None, ' ')

let style_of ~theme = function
  | Some tone -> H.status_style ~theme tone
  | None -> H.text_style ~theme ()

(* One side of a side-by-side row: "<line> <marker> <text>". *)
let draw_half ~grid ~theme ~(clip : Rect.t) ~x ~y ~w = function
  | None -> ()
  | Some (l : Wire_infra.git_diff_line) ->
      let tone, marker = line_tone l in
      let number =
        match l.kind with
        | `Delete -> l.old_line
        | `Add | `Context -> l.new_line
      in
      ignore
        (H.put_clipped ~grid ~clip ~x ~y ~max_w:w ~style:(style_of ~theme tone)
           (Printf.sprintf "%s %c %s" (Diff.line_number_cell number) marker l.text))

let draw_row ~grid ~theme ~(rect : Rect.t) ~y = function
  | L.Hunk_header h ->
      ignore
        (H.put_clipped ~grid ~clip:rect ~x:rect.x ~y ~max_w:rect.w
           ~style:(H.accent_style ~theme ()) (hunk_text h))
  | L.Single l ->
      let tone, marker = line_tone l in
      ignore
        (H.put_clipped ~grid ~clip:rect ~x:rect.x ~y ~max_w:rect.w
           ~style:(style_of ~theme tone)
           (Diff.numbered_gutter ~old_line:l.old_line ~new_line:l.new_line ~marker
           ^ l.text))
  | L.Pair { left; right } ->
      let half = rect.w / 2 in
      draw_half ~grid ~theme ~clip:rect ~x:rect.x ~y ~w:(half - 1) left;
      draw_half ~grid ~theme ~clip:rect ~x:(rect.x + half) ~y ~w:(rect.w - half) right

let draw_diff ~(model : Model.t) ~grid ~(hdr_rect : Rect.t) ~(vis_rect : Rect.t)
    ~(theme : Theme.t) =
  let inf = model.infra in
  let lang = model.lang in
  let cols = model.viewport.cols in
  let rows = Infra_store.review_diff_rows ~cols inf in
  let selected =
    Option.bind (Infra_store.review_selected_index inf) (fun i ->
        List.nth_opt (Infra_store.review_changes inf) i)
  in
  match selected, rows with
  | None, _ ->
      H.draw_observed_placeholder ~grid ~rect:vis_rect ~theme ~lang
        ~empty_msg:(Say.make ~ko:"바뀐 파일 없음" ~en:"No changed files")
        inf.code.git_status
  | Some change, [] -> (
      match Observed.to_option inf.code.git_diff with
      | Some (_, path, (df : Wire_infra.git_diff_snapshot))
        when String.equal path change.path && not df.has_changes ->
          H.draw_empty_notice ~grid ~rect:vis_rect ~theme
            (Say.resolve lang
               (if change.untracked then
                  Say.make ~ko:"추적하지 않는 파일이라 HEAD 와 비교할 diff 가 없어요"
                    ~en:"Untracked file: no diff against HEAD"
                else Say.make ~ko:"HEAD 와 같아요" ~en:"Same as HEAD"))
      | Some _ | None ->
          H.draw_observed_placeholder ~grid ~rect:vis_rect ~theme ~lang
            inf.code.git_diff)
  | Some change, rows ->
      let total = List.length rows in
      let vis_h = Int.max 1 vis_rect.h in
      let skip = Int.min (Int.max 0 (total - vis_h)) (Int.max 0 inf.code.git_scroll_offset) in
      let hunks =
        List.filter (function L.Hunk_header _ -> true | L.Single _ | L.Pair _ -> false) rows
      in
      let current_hunk =
        List.length
          (List.filteri
             (fun i r ->
               i <= skip
               && (match r with L.Hunk_header _ -> true | L.Single _ | L.Pair _ -> false))
             rows)
      in
      let layout =
        if L.side_by_side ~cols then Say.make ~ko:"나란히" ~en:"Side by side"
        else Say.make ~ko:"한 줄" ~en:"Unified"
      in
      ignore
        (H.put_clipped ~grid ~clip:hdr_rect ~x:hdr_rect.x ~y:hdr_rect.y
           ~max_w:hdr_rect.w ~style:(H.accent_style ~theme ~attrs:Attr.bold ())
           (Printf.sprintf "%s · %s %d/%d · %s" change.path
              (Say.resolve lang (Say.make ~ko:"덩어리" ~en:"Hunk"))
              current_hunk (List.length hunks)
              (Say.resolve lang layout)));
      List.iteri
        (fun i row ->
          let y = vis_rect.y + i in
          if y < Rect.bottom vis_rect then draw_row ~grid ~theme ~rect:vis_rect ~y row)
        (Store_scroll.drop skip rows)
