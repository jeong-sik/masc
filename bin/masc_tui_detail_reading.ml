module Position = Masc_tui_scroll.Position

type section = { heading : string; body : string }
type document_kind = Captured of bool | Observation
type row = Heading of string | Content of string | Note of string
type search_mark = No_match | Match | Current_match
type search = { query : string; editing : bool; landing : (int * int) option }
type t = { title : string; sections : section list; position : Position.t;
  kind : document_kind; prepared : (int * row list) option; hints : string option; search : search option }
type movement = First | Last | By of int | Page_down | Page_up

let create ~ko ~title sections = { title; sections; position = Position.first; kind = Captured ko; prepared=None; hints=None;search=None }
let create_observation ~title sections = { title; sections; position = Position.first; kind = Observation; prepared=None; hints=None;search=None }
let forget_landing = Option.map (fun search -> {search with landing=None})
let replace ~title sections reading = {reading with title;sections;prepared=None;hints=None;
  search=forget_landing reading.search}
let title reading = reading.title
let hints reading = reading.hints
let replace_prepared ~title ~hints ~width rows reading =
  {reading with title;sections=[];prepared=Some (width,rows);hints=Some hints;
    search=forget_landing reading.search}

let prepare_rows ~width reading = match reading.prepared with
  | Some (prepared_width, rows) when prepared_width=width -> rows
  | Some _ -> [Note "Preparing document for this width…"]
  | None ->
  let wrap text =
    Masc_tui_text_block.lines text
    |> List.concat_map (fun line ->
        Masc_tui_message_layout.split_cells ~max_cells:(max 1 width)
          (Masc.Tui_terminal_text.sanitize_terminal_text line))
  in
  let note = match reading.kind with
    | Captured ko -> List.map (fun line -> Note line)
        (wrap (if ko then "고정된 관측 · 닫고 다시 열어 현재 관측 확인 · 필요하면 닫은 뒤 r로 새로고침"
               else "Captured reading · close and reopen after refreshing to read updates."))
    | Observation -> [] in
  note @ List.concat_map (fun section ->
      Content "" ::
      (List.map (fun line -> Heading line) (wrap section.heading)
       @ List.map (fun line -> Content line) (wrap section.body))) reading.sections

type document_rows = { rows : row list; count : int }
let document_rows_cache :
    ((section list * document_kind * (int * row list) option * int)
     * document_rows) option Domain.DLS.key =
  Domain.DLS.new_key (fun () -> None)

let document_rows ~width reading =
  match Domain.DLS.get document_rows_cache with
  | Some ((sections, kind, prepared, seen_width), projection)
      when sections == reading.sections && kind = reading.kind
        && prepared == reading.prepared && seen_width = width -> projection
  | Some _ | None ->
      let rows = prepare_rows ~width reading in
      let projection = { rows; count = List.length rows } in
      Domain.DLS.set document_rows_cache
        (Some ((reading.sections, reading.kind, reading.prepared, width), projection));
      projection

let rows ~width reading = (document_rows ~width reading).rows

let scroll ~count ~height reading =
  Position.offset ~count ~height reading.position

(* Use the same wrapping as the actual document; a target is actionable only
   if its entire source section fitted in the frame, not just its first row. *)
let section_fully_visible ~width ~height ~index reading =
  let rec split index previous = function
    | [] -> None
    | section :: _ when index = 0 -> Some (List.rev previous, section)
    | section :: rest -> split (index - 1) (section :: previous) rest in
  match reading.prepared with
  | Some _ -> false
  | None when index < 0 || width <= 0 || height <= 0 -> false
  | None ->
      (match split index [] reading.sections with
       | None -> false
       | Some (previous, selected) ->
           let count sections = List.length (rows ~width {reading with sections}) in
           let first = count previous in
           let after = count (previous @ [selected]) in
           let document = rows ~width reading in
           let total = List.length document in
           let offset = scroll ~count:total ~height reading in
           let fits = function
             | Heading text | Content text | Note text ->
                 Masc_tui_message_layout.display_width text <= width in
           first < after && first >= offset && after - offset <= height
           && (document
               |> List.filteri (fun position _ -> position >= first && position < after)
               |> List.for_all fits))

let move ~count ~height movement reading =
  let movement = match movement with
    | First -> Position.First
    | Last -> Position.Last
    | By delta -> Position.By delta
    | Page_down -> Position.Page_down
    | Page_up -> Position.Page_up
  in
  { reading with position = Position.move ~count ~height movement reading.position;
    search=forget_landing reading.search }

let search_editing reading = match reading.search with
  | Some search -> search.editing
  | None -> false
let search_query reading = Option.map (fun search -> search.query) reading.search
let search_available ~width reading = match reading.prepared with
  | Some (prepared_width, _) -> prepared_width=width
  | None -> true

type search_rows = {
  marked : (row * search_mark) list;
  matches : int list;
}
let search_rows_cache :
    ((row list * bool * string) * search_rows) option Domain.DLS.key =
  Domain.DLS.new_key (fun () -> None)

let search_rows ~width reading =
  let document = rows ~width reading in
  let available = search_available ~width reading in
  let query = Option.fold ~none:"" ~some:(fun search -> search.query) reading.search in
  match Domain.DLS.get search_rows_cache with
  | Some ((seen, seen_available, seen_query), projection)
      when seen == document && seen_available = available && String.equal seen_query query -> projection
  | Some _ | None ->
      let matches = ref [] in
      let marked = List.mapi (fun index row ->
        let text = match row with Heading text | Content text | Note text -> text in
        let mark =
          if available && query<>"" && Masc_tui_pick_list.lowercase_contains ~needle:query
              (Masc_tui_theme.strip_sgr text) then begin
            matches := index :: !matches;
            Match
          end else No_match in
        row,mark) document in
      let projection = { marked; matches = List.rev !matches } in
      Domain.DLS.set search_rows_cache (Some ((document, available, query), projection));
      projection

let marked_rows_cache :
    (search_rows * int option * (row * search_mark) list) option Domain.DLS.key =
  Domain.DLS.new_key (fun () -> None)

let rows_with_search ~width reading =
  let projection = search_rows ~width reading in
  let landing = match reading.search with
    | Some {landing=Some (seen_width,index);_} when seen_width=width -> Some index
    | Some _ | None -> None in
  match landing with
  | None -> projection.marked
  | Some current ->
      match Domain.DLS.get marked_rows_cache with
      | Some (seen, seen_landing, rows) when seen == projection && seen_landing=landing -> rows
      | Some _ | None ->
          let rows = List.mapi (fun index (row,mark) ->
            row, (match mark with
              | Match when index=current -> Current_match
              | Match | No_match | Current_match -> mark)) projection.marked in
          Domain.DLS.set marked_rows_cache (Some (projection, landing, rows));
          rows

let matches ~width reading = (search_rows ~width reading).matches
let search_count ~width reading = match reading.search with
  | None -> 0
  | Some _ -> List.length (matches ~width reading)
let search_land ~width ~height ~backwards ~from_start reading = match reading.search with
  | None -> reading
  | Some search ->
    let candidates=matches ~width reading in
    let count=if search_available ~width reading then (document_rows ~width reading).count else 0 in
    let after=if from_start then -1 else match search.landing with
      | Some (landing_width,index) when landing_width=width -> index
      | Some _ | None -> scroll ~count ~height reading in
    let ordered=if backwards then List.rev candidates else candidates in
    let next=match List.find_opt (fun index -> if backwards then index<after else index>after) ordered with
      | Some index -> Some index
      | None -> List.nth_opt ordered 0 in
    match next with
    | None -> {reading with search=Some {search with landing=None}}
    | Some index -> {reading with position=Position.at index;
        search=Some {search with landing=Some (width,index)}}
let search_insert ~width ~height ~text reading = match reading.search with
  | Some {editing=true;_} as current ->
    let search=Option.map (fun search -> {search with query=search.query ^ text;landing=None}) current in
    search_land ~width ~height ~backwards:false ~from_start:true {reading with search}
  | Some {editing=false;_} | None -> reading
let search_key ~width ~height ~key reading =
  if search_editing reading then
    Some (match key with
      | "esc" -> {reading with search=None}
      | "\r" | "\n" | "enter" ->
        {reading with search=Option.map (fun search -> {search with editing=false}) reading.search}
      | "\127" | "\b" | "backspace" ->
        let search=Option.map (fun search -> {search with
          query=Masc_tui_message_layout.drop_last_utf8_scalar search.query;landing=None}) reading.search in
        search_land ~width ~height ~backwards:false ~from_start:true {reading with search}
      | text when (String.length text=1 && Char.code text.[0]>=32)
          || (String.length text>1 && Char.code text.[0]>=0x80) ->
        search_insert ~width ~height ~text reading
      | _ -> reading)
  else match key with
    | "/" -> Some {reading with search=Some {query="";editing=true;landing=None}}
    | "n" | "N" when Option.is_some reading.search ->
      Some (search_land ~width ~height ~backwards:(key="N") ~from_start:false reading)
    | _ -> None
