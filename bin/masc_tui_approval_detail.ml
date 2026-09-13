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

(* As wide as the longest field name, and no wider than this: a pane whose
   labels ran long would spend the value's room on the column. A field whose
   name is longer keeps the two-row shape. *)
let label_column_cells = 16

(* A value that fits sits beside its name. Every field took two rows -- the
   name, then the value indented under it -- so the five fields of an operator
   ask filled ten rows of the screen the operator reads before pressing y,
   and the payload under them started below the fold.

   A value with its own line breaks, one too wide to sit beside the name, and
   a blank one keep the two-row shape: wrapped lines must not start under the
   label column, and a field that is present and empty has to draw a row that
   says so. *)
let of_fields ~width fields =
  let label_cells =
    List.fold_left
      (fun widest (label, _) -> max widest (Message_layout.display_width label))
      0 fields
    |> min label_column_cells
  in
  let pad label =
    label
    ^ String.make
        (max 0 (label_cells - Message_layout.display_width label))
        ' '
  in
  let beside label value =
    Message_layout.display_width label <= label_cells
    && (not (String.contains value '\n'))
    && String.trim value <> ""
    && label_cells
       + String.length value_indent
       + Message_layout.display_width value
       <= width
  in
  List.concat_map
    (fun (label, value) ->
      if beside label value then
        [ { label = Some label; text = pad label ^ value_indent ^ value } ]
      else { label = Some label; text = label } :: value_rows ~width value)
    fields
