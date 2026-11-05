(* Rows for a block of text that was written with line breaks.

   The single-line reader is what keeps an escape sequence in text someone
   else wrote from reaching the terminal, and it spells a line break as the
   four characters "\x0A" so a one-row field cannot swallow one. A block has
   rows, so handing it the whole text spelled every break into the sentence
   instead of taking the row it asks for. Each line goes through that reader
   on its own, which keeps the neutralising and drops the spelling. Text that
   already carries its colour is the one exception: see
   [preformatted_styled_rows]. *)

module Message_layout = Masc_tui_message_layout

let rec drop_leading_blank = function
  | "" :: rest -> drop_leading_blank rest
  | rows -> rows

let trim_blank_edges rows =
  rows |> drop_leading_blank |> List.rev |> drop_leading_blank |> List.rev

(* CRLF is one line terminator, so the carriage return that ends a line
   belongs to the break rather than to the text. Left in place the sanitiser
   spells it "\x0D" at the end of every line, which is the same noise this
   module exists to drop. A carriage return anywhere else is not a break and
   keeps its spelling: it would move the cursor back over what was drawn. *)
let drop_line_terminator line =
  let length = String.length line in
  if length > 0 && line.[length - 1] = '\r' then String.sub line 0 (length - 1)
  else line

let lines text =
  let rec split = function
    | [] -> []
    | [line] -> [line]
    | line :: rest -> drop_line_terminator line :: split rest
  in
  split (String.split_on_char '\n' text)

let leading_spaces line =
  let length = String.length line in
  let rec count index =
    if index < length && line.[index] = ' ' then count (index + 1) else index
  in
  count 0

(* [wrap_words] reads words, so the spaces that open a line are not part of
   what it returns. Prose has no use for them. Pretty-printed JSON, code and
   an indented list are made of them, so [keep_indent] gives them back: the
   line keeps its own indent, and so does every row it wraps to. *)
let rows_of_line ~sanitize ~wrap ~keep_indent ~max_cells line =
  let line = drop_line_terminator line in
  let opening = if keep_indent then leading_spaces line else 0 in
  (* Half the width is the most an indent can take, so a deeply nested line
     still has room for its text. *)
  let indent = min opening (max_cells / 2) in
  let text =
    if opening = 0 then line
    else String.sub line opening (String.length line - opening)
  in
  match wrap ~max_cells:(max_cells - indent) (sanitize text) with
  (* [wrap_words] answers nothing for a line with no words. The break was
     written, so the blank row it asks for is drawn. *)
  | [] -> [ "" ]
  | wrapped when indent = 0 -> wrapped
  | wrapped ->
      let margin = String.make indent ' ' in
      List.map (fun row -> margin ^ row) wrapped

let rows_with ~sanitize ~wrap ~keep_indent ~max_cells text =
  String.split_on_char '\n' text
  |> List.concat_map (rows_of_line ~sanitize ~wrap ~keep_indent ~max_cells)
  |> trim_blank_edges

let sanitize = Masc.Tui_terminal_text.sanitize_terminal_text

let rows ~max_cells text =
  rows_with ~sanitize ~wrap:Message_layout.wrap_words ~keep_indent:false
    ~max_cells text

let preformatted_rows ~max_cells text =
  rows_with ~sanitize ~wrap:Message_layout.wrap_words ~keep_indent:true
    ~max_cells text

(* The text already carries its colour, so it cannot go through the sanitiser:
   the escapes are what it would spell out. Its writer made it safe and put
   those escapes there. A wrapped row opens the style it continues and closes
   it, as {!Message_layout.wrap_styled_words} does. *)
let preformatted_styled_rows ~max_cells text =
  rows_with ~sanitize:Fun.id ~wrap:Message_layout.wrap_styled_words
    ~keep_indent:true ~max_cells text
