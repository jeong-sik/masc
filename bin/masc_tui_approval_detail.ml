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
  let rows = ref [] in
  let flush () =
    if Buffer.length current > 0 then begin
      rows := Buffer.contents current :: !rows;
      Buffer.clear current;
      current_cells := 0
    end
  in
  let add_space () =
    if !current_cells >= max_cells then flush ();
    Buffer.add_char current ' ';
    incr current_cells
  in
  let add_word word =
    let cells = Message_layout.display_width_for_wrapping word in
    if !current_cells + cells <= max_cells then begin
      Buffer.add_string current word;
      current_cells := !current_cells + cells
    end else begin
      (* Start a long word at the same boundary as the ordinary wrapper, so
         retaining indentation does not introduce new cuts in visible control
         escapes inside that word. *)
      flush ();
      let _, chunks =
        Message_layout.split_cells_after_prefix ~prefix_cells:0 ~max_cells word
      in
      let rec add_chunks = function
        | [] -> ()
        | [ last ] ->
          Buffer.add_string current last;
          current_cells := Message_layout.display_width_for_wrapping last
        | chunk :: rest ->
          rows := chunk :: !rows;
          add_chunks rest
      in
      add_chunks chunks
    end
  in
  Message_layout.iter_words_and_spaces text ~word:add_word ~space:add_space;
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
       + Message_layout.display_width_for_wrapping value
       <= width
  in
  List.concat_map
    (fun (label, value) ->
      if beside label value then
        [ { label = Some label; text = pad label ^ value_indent ^ value } ]
      else { label = Some label; text = label } :: value_rows ~width value)
    fields

type gate_origin =
  | Gate_key | Gate_key_continuation | Gate_string | Gate_json | Gate_unreadable

type gate_line =
  { gate_label : string option
  ; gate_text : string
  ; gate_origin : gate_origin
  }

let prefix = function
  | Gate_key -> "[key] "
  | Gate_key_continuation -> "[key+] "
  | Gate_string -> "[str] "
  | Gate_json -> "[json] "
  | Gate_unreadable -> "!"

(* A visible control/JSON escape must not be cut between rows. The input is
   already terminal-safe; recognizing a literal escape too only changes its
   wrapping, not its contents. *)
let is_hex = function
  | '0' .. '9' | 'a' .. 'f' | 'A' .. 'F' -> true
  | _ -> false

let rec has_hex text at stop =
  at = stop || (is_hex text.[at] && has_hex text (at + 1) stop)

type escape_syntax = Text | Json

let escape_length syntax text at =
  if text.[at] <> '\\' || at + 1 >= String.length text then 1
  else match text.[at + 1] with
    | 'x' when at + 4 <= String.length text && has_hex text (at + 2) (at + 4) -> 4
    | 'u' when at + 6 <= String.length text && has_hex text (at + 2) (at + 6) -> 6
    | 'U' when at + 10 <= String.length text && has_hex text (at + 2) (at + 10) -> 10
    | ('"' | '\\' | '/' | 'b' | 'f' | 'n' | 'r' | 't') when syntax = Json -> 2
    | _ -> 1

let split_gate_cells ~syntax ~max_cells text =
  let length = String.length text in
  if String.for_all (fun c -> c >= ' ' && c <= '~') text then
    (* ASCII is common in commands and JSON. Do not allocate one grapheme
       record per byte on every repaint. *)
    let rec loop start at rows =
      if at = length then Some (List.rev (String.sub text start (at - start) :: rows))
      else
        let next = at + escape_length syntax text at in
        if next - at > max_cells then None
        else if next - start > max_cells then
          loop at at (String.sub text start (at - start) :: rows)
        else loop start next rows
    in
    loop 0 0 []
  else
    let rows = Message_layout.split_cells ~max_cells text in
    let rec escapes at acc =
      if at >= length then List.rev acc
      else
        let next = at + escape_length syntax text at in
        escapes next (if next - at > 1 then (at, next) :: acc else acc)
    in
    let rec skip_ends at = function
      | (_, end_) :: rest when end_ <= at -> skip_ends at rest
      | rest -> rest
    in
    let rec safe_cut row limit budget =
      if budget <= 0 then "", row
      else
        let before, after = Message_layout.split_at_cells row budget in
        if String.length before <= limit then before, after
        else safe_cut row limit (budget - 1)
    in
    let rec reflow offset rows spans finished =
      match rows with
      | [] -> Some (List.rev finished)
      | row :: rest ->
        let boundary = offset + String.length row in
        let spans = skip_ends offset spans in
        let spans = skip_ends boundary spans in
        if Message_layout.display_width row > max_cells then None
        else match spans with
          | (start, end_) :: _ when start < boundary && end_ > boundary ->
            if end_ - start > max_cells then None
            else
              let limit = start - offset in
              let preceding = String.sub row 0 limit in
              let before, after = safe_cut row limit (Message_layout.display_width preceding) in
              (match before, rest with
               | "", _ | _, [] -> None
               | _, next :: rest ->
                 let reshaped = Message_layout.split_cells ~max_cells (after ^ next) in
                 reflow (offset + String.length before) (reshaped @ rest) spans
                   (before :: finished))
          | _ -> reflow boundary rest spans (row :: finished)
    in
    reflow 0 rows (escapes 0 []) []

(* The marker is owned by the renderer and is repeated for every physical
   value row. It is not part of a key or value supplied by the producer. *)
let of_gate_fields ~width fields =
  let safe_text value =
    value
    |> Masc.Tui_terminal_text.escape_invisible
    |> Masc.Tui_terminal_text.sanitize_terminal_lines
  in
  let unreadable () =
    let room = width - String.length (prefix Gate_unreadable) in
    let rows = if room < 1 then [ "" ]
      else Message_layout.split_cells ~max_cells:room "WIDEN" in
    List.map (fun text -> { gate_label = None; gate_text = text; gate_origin = Gate_unreadable }) rows
  in
  let value_rows origin syntax text =
    let room = width - String.length (prefix origin) in
    if room < 1 then unreadable ()
    else
      let rec collect rows = function
        | [] -> Some (List.rev rows)
        | line :: rest ->
          (match split_gate_cells ~syntax ~max_cells:room line with
           | None -> None
           | Some split -> collect (List.rev_append split rows) rest)
      in
      match collect [] (String.split_on_char '\n' text) with
      | None -> unreadable ()
      | Some rows -> List.map (fun text -> { gate_label = None; gate_text = text; gate_origin = origin }) rows
  in
  if fields <> [] && width <= String.length (prefix Gate_key_continuation) then unreadable ()
  else
    let rows = List.concat_map
    (fun (key, value) ->
      let key =
        key
        |> Masc.Tui_terminal_text.escape_invisible
        |> Masc.Tui_terminal_text.sanitize_terminal_text
      in
      let key_room = width - String.length (prefix Gate_key_continuation) in
      let origin, syntax, text =
        match value with
        | `String value -> Gate_string, Text, safe_text value
        | (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `Assoc _ | `List _) as json ->
          Gate_json, Json,
          (Yojson.Safe.to_string json |> Masc.Tui_terminal_json.sanitize_canonical_preview)
      in
      match split_gate_cells ~syntax:Text ~max_cells:key_room key with
      | None -> unreadable ()
      | Some key_rows ->
        List.mapi
          (fun index text ->
            { gate_label = Some text; gate_text = text;
              gate_origin = if index = 0 then Gate_key else Gate_key_continuation })
          key_rows
        @ value_rows origin syntax text)
      fields
    in
    if List.exists (fun line -> line.gate_origin = Gate_unreadable) rows
    then unreadable ()
    else rows
