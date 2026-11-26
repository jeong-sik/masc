open Masc_tui_core
open Masc_tui_ui
open Masc_tui_store

module H = Domain_helpers

let line_number_cells = 6

let render ~(peek : Nav.file_peek) ~(model : Model.t) ~cache ~(rect : Rect.t) grid =
  if not (Rect.is_empty rect) then begin
    let theme = Theme.of_preset model.theme_preset in
    let lang = model.lang in
    let bp = H.layout_bp ~model ~rect in
    let body = H.body_rect ~bp rect in
    let inner =
      Card.draw ~cache grid ~rect:body ~theme
        (H.card_spec ~focused:true ~subtitle:peek.keeper
           ~hotkey:
             (Say.resolve lang
                (Say.make ~ko:"[↑/↓] 스크롤 · [Enter] 코드에서 열기 · [Esc] 닫기"
                   ~en:"[↑/↓] Scroll · [Enter] Open in Code · [Esc] Close"))
           peek.path)
    in
    let content = H.pad_content ~bp inner in
    if not (Rect.is_empty content) then
      match Infra_store.file_peek_content ~keeper:peek.keeper ~path:peek.path model.infra with
      | None ->
          H.draw_observed_placeholder ~grid ~rect:content ~theme ~lang
            (Infra_store.file_peek_state ~keeper:peek.keeper ~path:peek.path model.infra)
      | Some file ->
          let lines = String.split_on_char '\n' file.content in
          let total = List.length lines in
          ignore
            (H.put_clipped ~grid ~clip:content ~x:content.x ~y:content.y ~max_w:content.w
               ~style:(H.whisper_style ~theme ())
               (Printf.sprintf "%s %d/%d" (Say.resolve lang (Say.make ~ko:"줄" ~en:"Line"))
                  peek.line total));
          let vis = Rect.make ~x:content.x ~y:(content.y + 1) ~w:content.w ~h:(content.h - 1) in
          let skip =
            Int.min (Int.max 0 (total - Int.max 1 vis.h)) (Int.max 0 model.nav.inspector_scroll_offset)
          in
          List.iteri
            (fun i text ->
              let y = vis.y + i in
              let number = skip + i + 1 in
              if y < Rect.bottom vis then begin
                let target = Int.equal number peek.line in
                let row_rect = Rect.make ~x:vis.x ~y ~w:vis.w ~h:1 in
                if target then
                  H.paint_selected_row_bg ~grid ~clip:vis ~row_rect ~theme ~focused:true ();
                let bg = if target then Some (H.selected_row_bg ~theme ~focused:true) else None in
                ignore
                  (H.put_clipped ~grid ~clip:row_rect ~x:vis.x ~y ~max_w:line_number_cells
                     ~style:(H.whisper_style ~theme ?bg ())
                     (Printf.sprintf "%*d " (line_number_cells - 1) number));
                ignore
                  (H.put_clipped ~grid ~clip:row_rect ~x:(vis.x + line_number_cells) ~y
                     ~max_w:(Int.max 0 (vis.w - line_number_cells))
                     ~style:(H.text_style ~theme ?bg ()) text)
              end)
            (Store_scroll.drop skip lines)
  end
