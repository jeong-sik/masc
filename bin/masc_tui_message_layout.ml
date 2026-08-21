type style =
  | User
  | Keeper
  | Status
  | Error

type entry = {
  style : style;
  timestamp : string;
  role_label : string;
  request_label : string;
  body : string;
}

type row = {
  style : style;
  text : string;
}

let fit_width text width =
  if width <= 0 then ""
  else
    let length = String.length text in
    if length > width then
      let prefix = String_util.utf8_prefix ~max_bytes:(width - 1) text in
      prefix ^ String.make (width - 1 - String.length prefix) ' ' ^ "~"
    else text ^ String.make (width - length) ' '

let take_last count values =
  let drop = max 0 (List.length values - max 0 count) in
  values |> List.filteri (fun index _ -> index >= drop)

let utf8_scalar_length text offset =
  String.get_utf_8_uchar text offset |> Uchar.utf_decode_length

let split_utf8 ~max_bytes text =
  if String.equal text "" then [ "" ]
  else
    let length = String.length text in
    let rec take offset used =
      if offset >= length then offset
      else
        let scalar_length = utf8_scalar_length text offset in
        if used > 0 && used + scalar_length > max_bytes then offset
        else if used = 0 && scalar_length > max_bytes then offset + scalar_length
        else take (offset + scalar_length) (used + scalar_length)
    in
    let rec loop offset rows =
      if offset >= length then List.rev rows
      else
        let next = take offset 0 in
        let chunk = String.sub text offset (next - offset) in
        loop next (chunk :: rows)
    in
    loop 0 []

let rows_of_entry ~inner_width entry =
  let metadata =
    Printf.sprintf "[%s] %s %s" entry.timestamp entry.role_label
      entry.request_label
    |> String_util.utf8_prefix ~max_bytes:inner_width
  in
  let body_width = max 4 (inner_width - 2) in
  let body_chunks =
    entry.body |> String.split_on_char '\n'
    |> List.concat_map (split_utf8 ~max_bytes:body_width)
  in
  let body_chunks =
    let rec drop_empty = function
      | chunk :: rest when String.trim chunk = "" -> drop_empty rest
      | reversed -> List.rev reversed
    in
    match drop_empty (List.rev body_chunks) with
    | [] -> [ "" ]
    | chunks -> chunks
  in
  let body_rows =
    body_chunks
    |> List.map (fun chunk -> { style = entry.style; text = "  " ^ chunk })
  in
  { style = entry.style; text = metadata } :: body_rows

let visible_rows ~inner_width ~height entries =
  let inner_width = max 1 inner_width in
  let height = max 0 height in
  let rec collect remaining selected = function
    | [] -> selected
    | _ when remaining = 0 -> selected
    | entry :: older ->
        let rows = rows_of_entry ~inner_width entry in
        let chosen =
          if List.length rows <= remaining then rows
          else if selected = [] then
            match rows with
            | [] -> []
            | metadata :: body ->
                metadata :: take_last (remaining - 1) body
          else take_last remaining rows
        in
        collect (remaining - List.length chosen) (chosen @ selected) older
  in
  collect height [] (List.rev entries)
