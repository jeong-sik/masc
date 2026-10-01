module View = Masc_tui_portrait_view
module Draw = Keeper_portrait_draw
module Look = Keeper_portrait_look

type band_size = { rows : int; cols : int }

(* The smallest box each display shows a portrait's face in, judged by
   rendering Keepers at 16, 24, 32 and 48 px. Placed pixels are scaled by
   the terminal, and eight rows is a 160 px picture on a 20 px cell. A
   mosaic draws a pixel per cell across and two per row: at 16 px a candle
   is its colours alone, and its eyes, mouth and glasses show from 24 px,
   twelve rows by 24 cells. *)
let pixel_band = { rows = 8; cols = 16 }
let mosaic_band = { rows = 12; cols = 24 }

let band_size = function
  | View.Pixels _ -> Some pixel_band
  | View.Mosaic -> Some mosaic_band
  | View.No_picture -> None

(* Rows the facts keep below the portrait. In the PTY harness the detail has
   23 content rows on a 30-row terminal and 17 on a 24-row one, so a mosaic
   portrait (20) shows on the first and gives every row to facts on the
   second; placed pixels (16) show on both. *)
let rows_kept_for_facts = 8
let min_content_rows size = size.rows + rows_kept_for_facts

(* The Name row's label column (two cells of indent, 22 of label, one
   space) and about fifteen cells of the name after it. *)
let min_fact_cols = 40

(* The cells between the pane's content edge and the portrait: the indent
   every fact row starts with. *)
let indent = "  "

let min_content_cols size = String.length indent + size.cols + min_fact_cols

(* A picture at the pixel cap is 160 x 160 RGBA, about 100 KB, so a full
   cache is about 3 MB -- and holds a roster walked end to end. *)
let cache_capacity = 32

type entry = { name : string; equipment_key : string; edge : int; compact : bool; picture : Draw.image }

(* Newest first. *)
type cache = { mutable entries : entry list }

let cache () = { entries = [] }
let cached c = List.length c.entries

let image ?(compact = false) c ~name ~equipment size =
  let equipment_key = Keeper_portrait_equipment.key equipment in
  let edge = Draw.int_of_size size in
  let same entry =
    String.equal entry.name name && String.equal entry.equipment_key equipment_key
    && entry.edge = edge && Bool.equal entry.compact compact
  in
  let rest = List.filter (fun entry -> not (same entry)) c.entries in
  let entry =
    match List.find_opt same c.entries with
    | Some entry -> entry
    | None ->
        let body = Look.body_of_name name in
        let picture =
          (* The compact silhouette draws only the body and its dish. Keep
             that geometry where it is complete; other slots need the full
             drawing rather than silently losing their observed equipment. *)
          match compact, equipment.Look.face, equipment.Look.neck,
                equipment.Look.head, equipment.Look.hand with
          | true, Look.Bare_face, Look.Bare_neck, Look.Bare_head, Look.Empty_hand ->
              Draw.render_compact_posed body equipment Draw.still size
          | _ -> Draw.render body equipment size
        in
        { name; equipment_key; edge; compact; picture }
  in
  c.entries <- List.filteri (fun index _ -> index < cache_capacity) (entry :: rest);
  entry.picture

type band = {
  display : View.display;
  box : View.box;
  image : Draw.image;
  lines : string list;
}

let band c ~display ~project ~name ~equipment ~content_rows ~content_cols =
  match band_size display with
  | None -> None
  | Some size when content_rows < min_content_rows size || content_cols < min_content_cols size ->
      None
  | Some size ->
      View.fit display ~max_cols:size.cols ~max_rows:size.rows
      |> Option.map (fun box ->
             let compact =
               match display with View.Mosaic -> true | View.Pixels _ | View.No_picture -> false
             in
             let image = image ~compact c ~name ~equipment box.View.size in
             { display; box; image; lines = View.lines ~project display box image })

let beside band facts =
  let blank = String.make band.box.View.cols ' ' in
  let rec zip portrait facts =
    match portrait, facts with
    | [], [] -> []
    | line :: portrait, fact :: facts -> (indent ^ line ^ fact) :: zip portrait facts
    | line :: portrait, [] -> (indent ^ line) :: zip portrait []
    | [], fact :: facts -> (indent ^ blank ^ fact) :: zip [] facts
  in
  zip band.lines facts

let placement band ~scroll ~visible_rows ~origin:(row, column) =
  match band.display with
  | View.Pixels _ when scroll = 0 && visible_rows >= band.box.View.rows ->
      Some
        {
          View.image_id = Masc_tui_graphics.image_id Masc_tui_graphics.Keeper_portrait;
          row;
          column = column + String.length indent;
          box = band.box;
          image = band.image;
        }
  | View.Pixels _ | View.Mosaic | View.No_picture -> None

let session_cache = cache ()

let shown ~name ~equipment ~content_rows ~content_cols =
  band session_cache ~display:(View.current_display ())
    ~project:Masc_tui_terminal_palette.best_color ~name ~equipment ~content_rows ~content_cols

let preview ~name ~equipment ~content_rows ~content_cols =
  let display = View.current_display () in
  match band_size display with
  | None -> None
  | Some size when content_rows < size.rows + 2 || content_cols < String.length indent + size.cols + 2 ->
      None
  | Some size ->
      View.fit display ~max_cols:size.cols ~max_rows:size.rows
      |> Option.map (fun box ->
             (* Item selection previews the chosen equipment. Info also uses
                the full drawing when its observed equipment has accessories;
                selecting a preview leaves that observed equipment unchanged. *)
             let picture = image session_cache ~name ~equipment box.View.size in
             { display; box; image = picture
             ; lines = View.lines ~project:Masc_tui_terminal_palette.best_color display box picture })
