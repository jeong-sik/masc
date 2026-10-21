module Position = Masc_tui_scroll.Position

type section = { heading : string; body : string }
type document_kind = Captured | Observation
type row = Heading of string | Content of string | Note of string
type search_mark = No_match | Match | Current_match
type search = { query : string; editing : bool; landing : (int * int) option }
type t = { title : string; sections : section list; position : Position.t;
  kind : document_kind; prepared : (int * row list) option; hints : string option; search : search option }
type movement = First | Last | By of int

let create ~title sections = { title; sections; position = Position.first; kind = Captured; prepared=None; hints=None;search=None }
let create_observation ~title sections = { title; sections; position = Position.first; kind = Observation; prepared=None; hints=None;search=None }
let forget_landing = Option.map (fun search -> {search with landing=None})
let replace ~title sections reading = {reading with title;sections;prepared=None;hints=None;
  search=forget_landing reading.search}
let title reading = reading.title
let hints reading = reading.hints
let replace_prepared ~title ~hints ~width rows reading =
  {reading with title;sections=[];prepared=Some (width,rows);hints=Some hints;
    search=forget_landing reading.search}

let rows ~width reading = match reading.prepared with
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
    | Captured -> List.map (fun line -> Note line)
        (wrap "Captured reading · close and reopen after refreshing to read updates.")
    | Observation -> [] in
  note @ List.concat_map (fun section ->
      Content "" ::
      (List.map (fun line -> Heading line) (wrap section.heading)
       @ List.map (fun line -> Content line) (wrap section.body))) reading.sections

let scroll ~count ~height reading =
  Position.offset ~count ~height reading.position

let move ~count ~height movement reading =
  let movement = match movement with
    | First -> Position.First
    | Last -> Position.Last
    | By delta -> Position.By delta
  in
  { reading with position = Position.move ~count ~height movement reading.position;
    search=forget_landing reading.search }

let search_editing reading = match reading.search with
  | Some search -> search.editing
  | None -> false
let search_query reading = Option.map (fun search -> search.query) reading.search
let searchable_rows ~width reading = match reading.prepared with
  | Some (prepared_width, _) when prepared_width<>width -> []
  | Some _ | None -> rows ~width reading
let rows_with_search ~width reading =
  let available = match reading.prepared with
    | Some (prepared_width, _) -> prepared_width=width
    | None -> true in
  rows ~width reading
  |> List.mapi (fun index row ->
    let mark = match reading.search with
      | Some search when available && search.query<>"" ->
          let text=match row with Heading text | Content text | Note text -> text in
          if Masc_tui_pick_list.lowercase_contains ~needle:search.query
              (Masc_tui_theme.strip_sgr text) then
            if search.landing=Some (width,index) then Current_match else Match
          else No_match
      | Some _ | None -> No_match in
    row,mark)
let matches ~width reading =
  rows_with_search ~width reading
  |> List.mapi (fun index (_,mark) -> match mark with
      | No_match -> None
      | Match | Current_match -> Some index)
  |> List.filter_map Fun.id
let search_count ~width reading = match reading.search with
  | None -> 0
  | Some _ -> List.length (matches ~width reading)
let search_land ~width ~height ~backwards ~from_start reading = match reading.search with
  | None -> reading
  | Some search ->
    let candidates=matches ~width reading in
    let count=List.length (searchable_rows ~width reading) in
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
