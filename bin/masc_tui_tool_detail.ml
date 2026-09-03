(** See the mli for the contract. *)

module Keeper_chat = Masc_tui_keeper_chat_projection
module Message_layout = Masc_tui_message_layout

type palette = {
  branch : string;
  label : string;
  separator : string;
  key : string;
  string_ : string;
  number : string;
  literal : string;
  punctuation : string;
  reset : string;
}

let plain =
  { branch = ""
  ; label = ""
  ; separator = ""
  ; key = ""
  ; string_ = ""
  ; number = ""
  ; literal = ""
  ; punctuation = ""
  ; reset = ""
  }

type value =
  | Text of string
  | Document of string

type field = { fd_label : string; fd_value : value; fd_tone : string }

(* Empty in, empty out: with the plain palette every wrap is the identity, so
   the layout tests read the same text they always did. *)
let paint palette style text =
  if String.equal style "" then text else style ^ text ^ palette.reset

(* A string value that is itself a JSON document becomes that document.

   Tool results nest this way as a matter of course: a keeper writes a tool
   result into an artifact, then reads the artifact back, and the read's
   [content] carries the write's [content] which carries the command's
   [output]. Serialised, each layer escapes the one below it, and the third
   layer of a gh pr list table is a wall of backslashes the pane cannot make
   anything of. The value the keeper meant is the innermost one; unfolding
   until no string parses as a document shows that value where the pane
   shows every other object.

   Only a string that both looks like a document and parses as one is
   unfolded. A bare scalar in a string ("42", "true") stays a string: the
   producer quoted it, and the quotes are the fact. *)
let rec unfold (json : Yojson.Safe.t) : Yojson.Safe.t =
  match json with
  | `Assoc fields -> `Assoc (List.map (fun (key, value) -> key, unfold value) fields)
  | `List items -> `List (List.map unfold items)
  | `String text ->
    let trimmed = String.trim text in
    if String.length trimmed >= 2 && (Char.equal trimmed.[0] '{' || Char.equal trimmed.[0] '[')
    then (
      match Yojson.Safe.from_string trimmed with
      | (`Assoc _ | `List _) as document -> unfold document
      | `String _ | `Int _ | `Intlit _ | `Float _ | `Bool _ | `Null -> json
      | exception Yojson.Json_error _ -> json)
    else json
  | `Int _ | `Intlit _ | `Float _ | `Bool _ | `Null -> json
;;

(* A tab drawn as a light dashed bar, one cell wide like the tree's own box
   glyphs. Command output that is a table (gh pr list, git status --porcelain
   with tabs) keeps its columns readable without a real tab, which the pane
   would either swallow or widen to the next stop. *)
let tab_mark = " \xe2\x94\x8a "

let is_block text = String.contains text '\n' || String.contains text '\t'

let block_lines text =
  let text =
    let length = String.length text in
    if length > 0 && Char.equal text.[length - 1] '\n'
    then String.sub text 0 (length - 1)
    else text
  in
  String.split_on_char '\n' text
  |> List.map (fun line -> String.concat tab_mark (String.split_on_char '\t' line))
;;

(* One member per line, the way the JSON pretty printer lays it out, with
   two departures a reader wants and a parser would not: a string document
   has already been unfolded into the tree above, and a string that spans
   lines or holds tabs is drawn as a block under a [|] marker, its lines raw
   and indented under the member that owns them, instead of as one line of
   [\n] and [\t]. The block carries no trailing comma; the next member at the
   same indent is where it ends. This is a rendering for reading, not a
   serialisation for parsing back. *)
let rec render ~palette ~indent ~prefix ~suffix (json : Yojson.Safe.t)
  : string list
  =
  let pad = String.make indent ' ' in
  let punct = paint palette palette.punctuation in
  let members ~open_ ~close items render_item =
    let count = List.length items in
    (pad ^ prefix ^ punct open_)
    :: List.concat
         (List.mapi
            (fun index item ->
              render_item ~suffix:(if index = count - 1 then "" else punct ",") item)
            items)
    @ [ pad ^ punct close ^ suffix ]
  in
  match json with
  | `Assoc [] -> [ pad ^ prefix ^ punct "{}" ^ suffix ]
  | `List [] -> [ pad ^ prefix ^ punct "[]" ^ suffix ]
  | `Assoc fields ->
    members ~open_:"{" ~close:"}" fields (fun ~suffix (key, value) ->
      render
        ~palette
        ~indent:(indent + 2)
        ~prefix:
          (paint palette palette.key (Yojson.Safe.to_string (`String key))
           ^ punct ": ")
        ~suffix
        value)
  | `List items ->
    members ~open_:"[" ~close:"]" items (fun ~suffix item ->
      render ~palette ~indent:(indent + 2) ~prefix:"" ~suffix item)
  | `String text when is_block text ->
    (* The block's own lines stay in the pane's foreground. They are the
       command's output, not a value in a document, and colouring them would
       claim a reading of bytes this module cannot read. *)
    (pad ^ prefix ^ punct "|")
    :: List.map
         (fun line ->
           pad ^ "  " ^ Keeper_chat.terminal_safe_text line)
         (block_lines text)
  | `String _ as scalar ->
    [ pad ^ prefix
      ^ paint palette palette.string_ (Yojson.Safe.to_string scalar)
      ^ suffix ]
  | (`Int _ | `Intlit _ | `Float _) as scalar ->
    [ pad ^ prefix
      ^ paint palette palette.number (Yojson.Safe.to_string scalar)
      ^ suffix ]
  | (`Bool _ | `Null) as scalar ->
    [ pad ^ prefix
      ^ paint palette palette.literal (Yojson.Safe.to_string scalar)
      ^ suffix ]
;;

(* A tool argument or result that is a whole JSON document is re-served with
   one member per line, its string documents unfolded and its multi-line
   strings drawn as blocks. The tree already indents continuation lines, so
   the document arrives as structure instead of as one line the terminal
   wraps at column zero -- which is what a single-line payload did, dropping
   the branch glyph from every wrapped row. A scalar or a payload that does
   not parse is its own best rendering and passes through untouched. *)
let structured ?(palette = plain) value =
  match Yojson.Safe.from_string value with
  | (`Assoc _ | `List _) as json ->
    String.concat "\n"
      (render ~palette ~indent:0 ~prefix:"" ~suffix:"" (unfold json))
  | `String _ | `Int _ | `Intlit _ | `Float _ | `Bool _ | `Null -> value
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
let tree ?(palette = plain) fields =
  let field_count = List.length fields in
  let label_cells =
    List.fold_left
      (fun widest { fd_label; _ } ->
        max widest
          (Message_layout.display_width (Keeper_chat.terminal_safe_text fd_label)))
      0
      fields
  in
  fields
  |> List.mapi (fun index { fd_label; fd_value; fd_tone } ->
    let label = Keeper_chat.terminal_safe_text fd_label in
    (* Sanitised before it is painted, never after: the sweep that makes a
       value terminal-safe replaces control bytes with spaces, and an escape
       code is control bytes. Painting a sanitised string is safe; sanitising
       a painted one erases the colour and leaves the digits behind. *)
    let value_lines =
      match fd_value with
      | Text text ->
        String.split_on_char '\n'
          (Keeper_chat.terminal_safe_text ~preserve_newlines:true text)
        |> List.map (paint palette fd_tone)
      | Document payload ->
        String.split_on_char '\n' (structured ~palette payload)
    in
    let padding =
      String.make (max 0 (label_cells - Message_layout.display_width label)) ' '
    in
    let last = index = field_count - 1 in
    let branch =
      paint palette palette.branch (if last then "  ╰─" else "  ├─")
    in
    let continuation =
      paint palette palette.branch (if last then "     " else "  │  ")
    in
    let lines = match value_lines with [] -> [ "" ] | lines -> lines in
    match lines with
    | [] -> []
    | first :: rest ->
      Printf.sprintf "%s %s%s %s %s" branch
        (paint palette palette.label label)
        padding
        (paint palette palette.separator "·")
        first
      :: List.map (fun line -> continuation ^ line) rest)
  |> List.concat
;;
