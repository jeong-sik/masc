module Message_layout = Masc_tui_message_layout

type line =
  { label : string option
  ; text : string
  }

(* The value is indented under its label, so the label column does not eat
   into the width every continuation line gets. *)
let value_indent = "  "

let value_rows ~width value =
  let budget = max 1 (width - String.length value_indent) in
  match String.split_on_char '\n' value with
  | [] -> []
  | lines ->
    List.concat_map
      (fun line ->
        match Message_layout.wrap_words ~max_cells:budget line with
        (* [wrap_words] answers nothing for an empty line; the blank is part
           of how the ask was written, so it is kept. *)
        | [] -> [ { label = None; text = value_indent } ]
        | wrapped ->
          List.map (fun text -> { label = None; text = value_indent ^ text }) wrapped)
      lines

let of_fields ~width fields =
  List.concat_map
    (fun (label, value) ->
      { label = Some label; text = label } :: value_rows ~width value)
    fields
