module View = Masc_tui_portrait_view
module Portrait = Masc_tui_keeper_portrait

type t = {
  roster_rows : int;
  picture_lines : string list;
  placement : View.placement option;
}

(* Use the roster renderer's chrome budget so four selectable entries remain.
   The portrait yields before that navigation capacity is reduced. *)
let minimum_roster_rows = Masc_tui_frame.chrome_rows + 4

type figure = Face | Whole_body

let band_size = Portrait.band_size

(* A whole body in a terminal mosaic uses the compact silhouette, the same
   rule the Items preview follows; pixels get the full drawing. *)
let figure_image cache ~display ~figure ~name ~equipment size =
  match figure, display with
  | Face, (View.Pixels _ | View.Mosaic | View.No_picture) ->
      Portrait.icon_image cache ~name ~equipment size
  | Whole_body, View.Mosaic -> Portrait.image ~compact:true cache ~name ~equipment size
  | Whole_body, (View.Pixels _ | View.No_picture) ->
      Portrait.image cache ~name ~equipment size

let prepare cache ~display ~project ~figure ~name ~portrait ~rows ~cols =
  match portrait, band_size display with
  | Keeper_portrait_equipment.Unavailable _, _
  | Keeper_portrait_equipment.Ready _, None -> None
  | Keeper_portrait_equipment.Ready equipment, Some band ->
      let inner = Masc_tui_ansi.framed_inner_width cols in
      if rows < minimum_roster_rows + band.rows + 2 || inner < band.cols then None
      else
        View.fit display ~max_cols:band.cols ~max_rows:band.rows
        |> Option.map (fun box ->
          let roster_rows = rows - box.View.rows - 2 in
          let padding = (inner - box.cols) / 2 in
          let image = figure_image cache ~display ~figure ~name ~equipment box.size in
          let picture_lines =
            View.lines ~project display box image
            |> List.map (fun line -> String.make padding ' ' ^ line) in
          let placement =
            match display with
            | View.Pixels _ -> Some {
                View.image_id = Masc_tui_graphics.image_id Masc_tui_graphics.Keeper_portrait;
                row = 1;
                column = Masc_tui_ansi.framed_content_column + padding;
                box; image;
              }
            | View.Mosaic | View.No_picture -> None in
          { roster_rows; picture_lines; placement })

let session_cache = Portrait.cache ()

let shown ~figure ~name ~portrait ~rows ~cols =
  prepare session_cache ~display:(View.current_display ())
    ~project:Masc_tui_terminal_palette.best_color ~figure ~name ~portrait ~rows ~cols
