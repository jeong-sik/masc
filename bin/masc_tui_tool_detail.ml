(** See the mli for the contract. *)

module Keeper_chat = Masc.Keeper_chat
module Message_layout = Masc_tui_message_layout

(* A tool argument or result that is a whole JSON document is re-served with
   one member per line. The tree already indents continuation lines, so the
   document arrives as structure instead of as one line the terminal wraps at
   column zero -- which is what a single-line payload did, dropping the branch
   glyph from every wrapped row. A scalar or a payload that does not parse is
   its own best rendering and passes through untouched. *)
let structured value =
  match Yojson.Safe.from_string value with
  | (`Assoc _ | `List _) as json -> Yojson.Safe.pretty_to_string json
  | _ -> value
  | exception Yojson.Json_error _ -> value
;;

(* A detail is a small tree rather than another flat table. Values keep every
   producer-served line; the first line owns the field label and continuations
   stay visibly below it. The final field closes the tree, so adjacent tool
   calls do not read as one call with many unrelated rows.

   Labels are padded to the widest one in the same tree, so the separator
   column is shared and the values read as a column rather than as a ragged
   edge. The width is per-tree, not a constant: a tree whose fields are all
   short stays narrow. Terminal cells, not bytes -- a label is operator-facing
   text and a byte count would misalign the moment one is not ASCII. *)
let tree fields =
  let field_count = List.length fields in
  let label_cells =
    List.fold_left
      (fun widest (label, _) ->
        max widest (Message_layout.display_width (Keeper_chat.terminal_safe_text label)))
      0
      fields
  in
  fields
  |> List.mapi (fun index (label, value) ->
    let label = Keeper_chat.terminal_safe_text label in
    let value = Keeper_chat.terminal_safe_text ~preserve_newlines:true value in
    let padding =
      String.make (max 0 (label_cells - Message_layout.display_width label)) ' '
    in
    let last = index = field_count - 1 in
    let branch = if last then "  ╰─" else "  ├─" in
    let continuation = if last then "     " else "  │  " in
    let lines =
      match String.split_on_char '\n' value with
      | [] -> [ "" ]
      | lines -> lines
    in
    match lines with
    | [] -> []
    | first :: rest ->
      Printf.sprintf "%s %s%s · %s" branch label padding first
      :: List.map (fun line -> continuation ^ line) rest)
  |> List.concat
;;
