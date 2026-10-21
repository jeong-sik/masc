type section = { heading : string; body : string }
type document_kind = Captured | Observation
type t = { title : string; sections : section list; offset : int; kind : document_kind }
type row = Heading of string | Content of string | Note of string
type movement = First | Last | By of int

let create ~title sections = { title; sections; offset = 0; kind = Captured }
let create_observation ~title sections = { title; sections; offset = 0; kind = Observation }
let replace ~title sections reading = {reading with title;sections}
let title reading = reading.title

let rows ~width reading =
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
  Masc_tui_scroll.normalize ~count ~height reading.offset

let move ~count ~height movement reading =
  let current = scroll ~count ~height reading in
  let offset = match movement with
    | First -> 0
    | Last -> Masc_tui_scroll.maximum ~count ~height
    | By delta ->
        if delta > 0 then
          min (Masc_tui_scroll.maximum ~count ~height)
            (current + min delta (max 0 (max_int - current)))
        else max 0 (current + delta)
  in
  { reading with offset }
