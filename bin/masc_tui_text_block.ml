(* Rows for a block of text that was written with line breaks.

   The single-line reader is what keeps an escape sequence in text someone
   else wrote from reaching the terminal, and it spells a line break as the
   four characters "\x0A" so a one-row field cannot swallow one. A block has
   rows, so handing it the whole text spelled every break into the sentence
   instead of taking the row it asks for. Each line goes through that reader
   on its own, which keeps the neutralising and drops the spelling. *)

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

let rows_of_line ~max_cells line =
  match
    Message_layout.wrap_words ~max_cells
      (Masc.Tui_decode.sanitize_terminal_text (drop_line_terminator line))
  with
  (* [wrap_words] answers nothing for a line with no words. The break was
     written, so the blank row it asks for is drawn. *)
  | [] -> [ "" ]
  | wrapped -> wrapped

let rows ~max_cells text =
  String.split_on_char '\n' text
  |> List.concat_map (rows_of_line ~max_cells)
  |> trim_blank_edges
