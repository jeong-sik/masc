module Message_layout = Masc_tui_message_layout

type line =
  { label : string option
  ; text : string
  }

(* The value is indented under its label, so the label column does not eat
   into the width every continuation line gets. *)
let value_indent = "  "

(* Unlike conversation prose, an approval can contain code whose spaces are
   part of the request. Keep them, including those at a wrap boundary, and
   prefer to move a whole word to the next row when it will fit there. *)
let wrap_value_line ~max_cells text =
  let max_cells = max 1 max_cells in
  let current = Buffer.create 128 in
  let current_cells = ref 0 in
  let has_word = ref false in
  let rows = ref [] in
  let flush () =
    if Buffer.length current > 0 then begin
      rows := Buffer.contents current :: !rows;
      Buffer.clear current;
      current_cells := 0;
      has_word := false
    end
  in
  let add_space () =
    if !current_cells >= max_cells then flush ();
    Buffer.add_char current ' ';
    incr current_cells
  in
  let add_word word =
    if not (String.equal word "") then begin
      let cells = Message_layout.display_width word in
      if !current_cells + cells <= max_cells then begin
        Buffer.add_string current word;
        current_cells := !current_cells + cells;
        has_word := true
      end else begin
        if !has_word then flush ();
        (* If a row holds only indentation, fill the rest of it before
           continuing the word. Otherwise the indentation would be drawn on
           a row of its own and detached from the source it belongs to. *)
        let prefix, chunks =
          Message_layout.split_cells_after_prefix
            ~prefix_cells:(max_cells - !current_cells) ~max_cells word
        in
        if not (String.equal prefix "") then begin
          Buffer.add_string current prefix;
          has_word := true
        end;
        (match chunks with
         | [] ->
           current_cells := !current_cells + Message_layout.display_width prefix
         | _ ->
           flush ();
           let rec add_chunks = function
             | [] -> ()
             | [ last ] ->
               Buffer.add_string current last;
               current_cells := Message_layout.display_width last;
               has_word := true
             | chunk :: rest ->
               rows := chunk :: !rows;
               add_chunks rest
           in
           add_chunks chunks)
      end
    end
  in
  String.split_on_char ' ' text
  |> List.iteri (fun index word ->
       if index > 0 then add_space ();
       add_word word);
  flush ();
  List.rev !rows

let value_rows ~width value =
  let budget = max 1 (width - String.length value_indent) in
  match String.split_on_char '\n' value with
  | [] -> []
  | lines ->
    List.concat_map
      (fun line ->
        match wrap_value_line ~max_cells:budget line with
        (* The wrapper answers nothing for an empty line; the blank is part
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
  (* Every value is a Keeper's, a model's or another operator's text, and this
     is the one place a row of the pane is built, so it is the one place the
     bytes are made safe to print. A value carrying ESC [ 1 A ESC [ 2 K would
     otherwise move the cursor and rub out rows the operator already read, and
     [y] would approve what the store holds rather than what the screen
     showed. The escape is drawn as [\x1B], not blanked: a blank would hide
     that one was tried, and a Makefile's tab would read as spaces. The
     newlines are kept -- they are how the ask was written -- and a label is
     a single row, so it keeps none. *)
  let fields =
    List.map
      (fun (label, value) ->
        ( Masc.Tui_terminal_text.sanitize_terminal_text label
        , Masc.Tui_terminal_text.sanitize_terminal_lines value ))
      fields
  in
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
