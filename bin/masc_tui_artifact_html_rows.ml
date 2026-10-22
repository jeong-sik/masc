module Html = Masc_tui_artifact_html
module Layout = Masc_tui_message_layout
module Ansi = Masc_tui_ansi

let render ~width (projection : Html.t) =
  let width = max 1 width in
  let plain value = Ansi.Terminal_text.single_line value in
  let wrap value = Layout.wrap_words ~max_cells:width (plain value) in
  let style code rows = List.map (fun row -> code ^ row ^ Ansi.Ansi.reset) rows in
  let list_line ~marker depth value =
    let indent = String.make (min (max 0 (width - 2)) (depth * 2)) ' ' in
    let prefix = indent ^ marker in
    let continuation = String.make (Layout.display_width prefix) ' ' in
    Layout.wrap_words ~max_cells:(max 1 (width - Layout.display_width prefix)) (plain value)
    |> List.mapi (fun index row -> (if index=0 then prefix else continuation) ^ row) in
  let block = function
    | Html.Paragraph value -> wrap value
    | Heading (level,value) ->
      style (if level=1 then Ansi.Ansi.bold ^ Ansi.Ansi.underline else Ansi.Ansi.bold)
        (wrap value)
    | Preformatted source ->
      source |> Masc_tui_text_block.lines
      |> List.concat_map (fun line ->
        let safe = Ansi.Terminal_text.single_line line in
        if safe = "" then [""] else Layout.split_cells ~max_cells:width safe)
      |> style Ansi.Ansi.dim
    | List_item (depth,value) -> list_line ~marker:"• " depth value
    | List_continuation (depth,value) -> list_line ~marker:"  " depth value
    | Table rows ->
      List.concat_map (fun cells ->
        let value = String.concat " │ " (List.map (fun (cell : Html.cell) -> cell.text) cells) in
        let lines = wrap value in
        if List.exists (fun (cell : Html.cell) -> cell.heading) cells
        then style Ansi.Ansi.bold lines else lines) rows
    | Image image ->
      wrap ("▧ " ^ image.label ^ " · " ^ (match image.source with
        | Html.Embedded_base64 _ -> "Ctrl-O: embedded image"
        | Unavailable reason -> reason)) in
  projection.blocks |> List.concat_map (fun value -> block value @ [""])
