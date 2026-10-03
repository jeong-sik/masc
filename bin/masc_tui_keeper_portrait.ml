module View = Masc_tui_portrait_view
module Draw = Keeper_portrait_draw
module Look = Keeper_portrait_look

type band_size = { rows : int; cols : int }

(* Info and conversation headers use an icon. Only Items, where the outfit
   is the subject being inspected, uses the larger preview band. *)
let preview_band_size = function
  | View.Pixels _ -> Some { rows = 8; cols = 16 }
  | View.Mosaic -> Some { rows = 12; cols = 24 }
  | View.No_picture -> None

let band_size = function
  | View.Pixels { cell_width; cell_height } when cell_width > 0 && cell_height > 0 ->
      let rows = View.min_pixel_rows in
      Some { rows; cols = (rows * cell_height + cell_width - 1) / cell_width }
  | View.Pixels _ -> None
  | View.Mosaic ->
      let cols = Draw.min_size in
      Some { rows = cols / 2; cols }
  | View.No_picture -> None

(* Leave room for operational diagnostics below the identity/work/context header. *)
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

type drawing = Full | Compact | Icon

type entry = { name : string; equipment_key : string; edge : int; drawing : drawing; picture : Draw.image }

(* Newest first. *)
type cache = { mutable entries : entry list }

let cache () = { entries = [] }
let cached c = List.length c.entries

let cached_image drawing c ~name ~equipment size =
  let equipment_key = Keeper_portrait_equipment.key equipment in
  let edge = Draw.int_of_size size in
  let same entry =
    String.equal entry.name name && String.equal entry.equipment_key equipment_key
    && entry.edge = edge && entry.drawing = drawing
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
          match drawing, equipment.Look.face, equipment.Look.neck,
                equipment.Look.head, equipment.Look.hand with
          | Compact, Look.Bare_face, Look.Bare_neck, Look.Bare_head, Look.Empty_hand ->
              Draw.render_compact_posed body equipment Draw.still size
          | Icon, _, _, _, _ -> Draw.render_icon body equipment size
          | Full, _, _, _, _ | Compact, _, _, _, _ -> Draw.render body equipment size
        in
        { name; equipment_key; edge; drawing; picture }
  in
  c.entries <- List.filteri (fun index _ -> index < cache_capacity) (entry :: rest);
  entry.picture

let image ?(compact = false) c ~name ~equipment size =
  cached_image (if compact then Compact else Full) c ~name ~equipment size

let icon_image c ~name ~equipment size =
  cached_image Icon c ~name ~equipment size

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
             let image = icon_image c ~name ~equipment box.View.size in
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
  match preview_band_size display with
  | None -> None
  | Some size when content_rows < size.rows + 2 || content_cols < String.length indent + size.cols + 2 ->
      None
  | Some size ->
      View.fit display ~max_cols:size.cols ~max_rows:size.rows
      |> Option.map (fun box ->
             let compact =
               match display with View.Mosaic -> true | View.Pixels _ | View.No_picture -> false
             in
             let picture = image ~compact session_cache ~name ~equipment box.View.size in
             { display; box; image = picture
             ; lines = View.lines ~project:Masc_tui_terminal_palette.best_color display box picture })
