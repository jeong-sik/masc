module Layout = Masc_tui_message_layout

type span = string * string

type palette = {
  strong : span;
  emphasis : span;
  code : span;
  heading : int -> span;
  quote : span;
  link_text : span;
  link_target : span;
  rule : span;
  bullet : string;
  code_gutter : string;
  code_header : span;
  code_border : span;
  quote_gutter : string;
  table_header : span;
  table_gutter : string;
  (* Styles for fenced code that names a language this module lexes. A fence
     without a language, or one naming a language it does not, keeps the
     single [code] span: colouring a grammar nobody parsed is decoration
     pretending to be syntax. *)
  code_keyword : span;
  code_string : span;
  code_comment : span;
  code_number : span;
  code_type : span;
}

let plain_palette =
  { strong = ("", "")
  ; emphasis = ("", "")
  ; code = ("", "")
  ; heading = (fun _ -> ("", ""))
  ; quote = ("", "")
  ; link_text = ("", "")
  ; link_target = ("", "")
  ; rule = ("", "")
  ; bullet = "-"
  ; code_gutter = "| "
  ; code_header = ("", "")
  ; code_border = ("", "")
  ; quote_gutter = "> "
  ; table_header = ("", "")
  ; table_gutter = " | "
  ; code_keyword = ("", "")
  ; code_string = ("", "")
  ; code_comment = ("", "")
  ; code_number = ("", "")
  ; code_type = ("", "")
  }

type streaming_render = {
  rows : string list;
  mutable_source_start : int;
  mutable_row_start : int;
}

(* {1 Inline markers} *)

let kind_plain = "plain"
let kind_strong = "strong"
let kind_emphasis = "emphasis"
let kind_code = "code"
let kind_link_text = "link_text"
let kind_link_target = "link_target"
(* Fenced-code token kinds. All fold back to the [code] span in the plain
   palette, so an unstyled render is byte-identical to before highlighting
   existed. *)
let kind_code_keyword = "code_keyword"
let kind_code_string = "code_string"
let kind_code_comment = "code_comment"
let kind_code_number = "code_number"
let kind_code_type = "code_type"

let starts_at text index marker =
  let length = String.length marker in
  index + length <= String.length text
  && String.equal (String.sub text index length) marker

(* A marker only opens a span when its partner is on the same line. An
   unmatched [*] is a literal asterisk -- keepers write those -- and treating
   it as an opener would swallow the rest of the line. *)
let find_close text ~from ~marker =
  let length = String.length marker in
  let limit = String.length text in
  let rec scan index =
    if index + length > limit then None
    else if starts_at text index marker then Some index
    else scan (index + 1)
  in
  if from >= limit then None else scan from

let is_word_byte byte =
  (byte >= 'a' && byte <= 'z')
  || (byte >= 'A' && byte <= 'Z')
  || (byte >= '0' && byte <= '9')
  || Char.code byte >= 0x80

(* [_] does not mark emphasis inside a word. Half this workspace's chat is
   snake_case, and pairing the underscores in [keeper_tool_descriptor] ate them
   and italicised the middle. [*] keeps the permissive rule -- it is not a
   character identifiers are built from. *)
let underscore_opens text index =
  let before = if index = 0 then ' ' else text.[index - 1] in
  let after_index = index + 1 in
  let after =
    if after_index >= String.length text then ' ' else text.[after_index]
  in
  (not (is_word_byte before)) && after <> ' '

let underscore_closes text index =
  let before = if index = 0 then ' ' else text.[index - 1] in
  let after_index = index + 1 in
  let after =
    if after_index >= String.length text then ' ' else text.[after_index]
  in
  before <> ' ' && not (is_word_byte after)

let find_char text ~from char =
  match String.index_from_opt text from char with
  | Some index -> Some index
  | None -> None

let inline_segments text =
  let limit = String.length text in
  let out = ref [] in
  let pending = Buffer.create (String.length text) in
  let flush_pending () =
    if Buffer.length pending > 0 then begin
      out := (Buffer.contents pending, kind_plain) :: !out;
      Buffer.clear pending
    end
  in
  let emit body kind =
    if String.length body > 0 then begin
      flush_pending ();
      out := (body, kind) :: !out
    end
  in
  let rec walk index =
    if index >= limit then ()
    else
      let literal () =
        Buffer.add_char pending text.[index];
        walk (index + 1)
      in
      let styled ?(closes = fun _ -> true) marker kind =
        let opening = index + String.length marker in
        let rec seek from =
          match find_close text ~from ~marker with
          | None -> None
          | Some closing ->
              if closes closing then Some closing
              else seek (closing + String.length marker)
        in
        match seek opening with
        | None -> literal ()
        | Some closing ->
            let body = String.sub text opening (closing - opening) in
            if String.trim body = "" then literal ()
            else begin
              emit body kind;
              walk (closing + String.length marker)
            end
      in
      match text.[index] with
      | '`' -> styled "`" kind_code
      | '*' when starts_at text index "**" -> styled "**" kind_strong
      | '_' when starts_at text index "__" ->
          if underscore_opens text index then
            styled ~closes:(fun close -> underscore_closes text (close + 1)) "__"
              kind_strong
          else literal ()
      | '*' -> styled "*" kind_emphasis
      | '_' ->
          if underscore_opens text index then
            styled ~closes:(fun close -> underscore_closes text close) "_"
              kind_emphasis
          else literal ()
      | '[' -> (
          (* [label](target). Both halves are kept: a terminal cannot follow a
             link, so hiding the target loses the only usable half. *)
          match find_char text ~from:(index + 1) ']' with
          | Some close_label
            when starts_at text (close_label + 1) "(" -> (
              match find_char text ~from:(close_label + 2) ')' with
              | None -> literal ()
              | Some close_target ->
                  let label =
                    String.sub text (index + 1) (close_label - index - 1)
                  in
                  let target =
                    String.sub text (close_label + 2)
                      (close_target - close_label - 2)
                  in
                  emit label kind_link_text;
                  emit target kind_link_target;
                  walk (close_target + 1))
          | Some _ | None -> literal ())
      | _ -> literal ()
  in
  walk 0;
  flush_pending ();
  List.rev !out

(* {1 Wrapping styled segments} *)

let span_of_palette palette kind =
  if String.equal kind kind_strong then palette.strong
  else if String.equal kind kind_emphasis then palette.emphasis
  else if String.equal kind kind_code then palette.code
  else if String.equal kind kind_link_text then palette.link_text
  else if String.equal kind kind_link_target then palette.link_target
  else if String.equal kind kind_code_keyword then palette.code_keyword
  else if String.equal kind kind_code_string then palette.code_string
  else if String.equal kind kind_code_comment then palette.code_comment
  else if String.equal kind kind_code_number then palette.code_number
  else if String.equal kind kind_code_type then palette.code_type
  else ("", "")

type token = {
  word : string;
  kind : string;
  space_before : bool;
}

(* Words carry their styling, so a wrap inside a bold sentence reopens bold on
   the next row instead of ending it there. *)
let tokens_of_segments segments =
  let tokens = ref [] in
  let first = ref true in
  List.iter
    (fun (text, kind) ->
       let pieces = String.split_on_char ' ' text in
       List.iteri
         (fun index piece ->
            let space_before = (not !first) && index > 0 in
            if String.length piece > 0 || space_before then begin
              tokens := { word = piece; kind; space_before } :: !tokens;
              first := false
            end)
         pieces)
    segments;
  List.rev !tokens

let render_token palette token =
  let opening, closing = span_of_palette palette token.kind in
  if String.equal token.word "" then "" else opening ^ token.word ^ closing

let wrap_tokens palette ~width tokens =
  let width = max 1 width in
  let rows = ref [] in
  let current = Buffer.create 128 in
  let current_cells = ref 0 in
  let flush () =
    rows := Buffer.contents current :: !rows;
    Buffer.clear current;
    current_cells := 0
  in
  (* The word is measured once by [place] and carried in: measuring it again
     to decide the row and a third time to advance the count segmented every
     word of every rendered line three times over. *)
  let push ~word_cells token =
    let separator = if !current_cells > 0 && token.space_before then " " else "" in
    let cells = Layout.display_width separator + word_cells in
    if !current_cells > 0 && !current_cells + cells > width then flush ();
    let separator = if !current_cells > 0 && token.space_before then " " else "" in
    Buffer.add_string current separator;
    Buffer.add_string current (render_token palette token);
    current_cells :=
      !current_cells + Layout.display_width separator + word_cells
  in
  let place token =
    let word_cells = Layout.display_width token.word in
    if word_cells <= width then push ~word_cells token
    else begin
      (* A word wider than the row is split between scalars rather than allowed
         to push the frame past its border. The tail stays open so the next
         word joins it instead of starting a row of its own. *)
      if !current_cells > 0 then flush ();
      let rec emit = function
        | [] -> ()
        | [ tail ] ->
            Buffer.add_string current
              (render_token palette { token with word = tail });
            current_cells := Layout.display_width tail
        | chunk :: rest ->
            Buffer.add_string current
              (render_token palette { token with word = chunk });
            current_cells := Layout.display_width chunk;
            flush ();
            emit rest
      in
      emit (Layout.split_cells ~max_cells:width token.word)
    end
  in
  List.iter place tokens;
  if Buffer.length current > 0 || !rows = [] then flush ();
  List.rev !rows

let wrap_inline palette ~width ~prefix ~continuation text =
  let prefix_cells = Layout.display_width prefix in
  let body_width = max 1 (width - prefix_cells) in
  let rows =
    wrap_tokens palette ~width:body_width (tokens_of_segments (inline_segments text))
  in
  List.mapi
    (fun index row -> (if index = 0 then prefix else continuation) ^ row)
    rows

(* {1 Blocks} *)

let fence_marker line =
  let trimmed = String.trim line in
  if starts_at trimmed 0 "```" then Some "```"
  else if starts_at trimmed 0 "~~~" then Some "~~~"
  else None

let is_rule line =
  let trimmed = String.trim line in
  let distinct char =
    String.length trimmed >= 3 && String.for_all (fun c -> c = char) trimmed
  in
  distinct '-' || distinct '*' || distinct '_'

let heading_level line =
  let rec count index =
    if index < String.length line && line.[index] = '#' then count (index + 1)
    else index
  in
  let level = count 0 in
  if level >= 1 && level <= 6 && level < String.length line
     && line.[level] = ' '
  then Some (level, String.trim (String.sub line level (String.length line - level)))
  else None

let bullet_item line =
  let trimmed_left =
    let rec skip index =
      if index < String.length line && line.[index] = ' ' then skip (index + 1)
      else index
    in
    skip 0
  in
  let indent = trimmed_left in
  let rest = String.sub line indent (String.length line - indent) in
  if String.length rest >= 2
     && (rest.[0] = '-' || rest.[0] = '*' || rest.[0] = '+')
     && rest.[1] = ' '
  then Some (indent, String.sub rest 2 (String.length rest - 2))
  else None

let ordered_item line =
  let limit = String.length line in
  let rec digits index =
    if index < limit && line.[index] >= '0' && line.[index] <= '9' then
      digits (index + 1)
    else index
  in
  let indent =
    let rec skip index =
      if index < limit && line.[index] = ' ' then skip (index + 1) else index
    in
    skip 0
  in
  let after_digits = digits indent in
  if after_digits > indent && after_digits + 1 < limit
     && (line.[after_digits] = '.' || line.[after_digits] = ')')
     && line.[after_digits + 1] = ' '
  then
    Some
      ( indent
      , String.sub line indent (after_digits - indent + 1)
      , String.sub line (after_digits + 2) (limit - after_digits - 2) )
  else None

let quote_body line =
  let trimmed = String.trim line in
  if String.length trimmed >= 1 && trimmed.[0] = '>' then
    Some (String.trim (String.sub trimmed 1 (String.length trimmed - 1)))
  else None

(* {1 Fenced-code lexers}

   Each lexer reads one whole fence body, newlines included, and returns the
   same (text, kind) segments the inline pass produces, so the styling and the
   row splitting share one vocabulary. The whole body rather than a row at a
   time because the state that decides a token's kind -- an OCaml comment
   opened three rows up, a string still open across a line break -- does not
   exist inside a single row.

   The lexers are tokenizers, not parsers: a keyword is the identifier the
   OCaml manual reserves, a comment is the marker pair and everything it
   encloses, and nothing needs the grammar to be valid to be coloured. A fence
   whose language nobody lexes keeps the single code span. *)

(* OCaml reserved words, as the manual lists them. A word not in this set is
   not a keyword however keyword-shaped it looks -- [dune] and [Option] colour
   as themselves. *)
let ocaml_reserved =
  [ "and"; "as"; "assert"; "asr"; "begin"; "class"; "constraint"; "do"; "done"
  ; "downto"; "else"; "end"; "exception"; "external"; "false"; "for"; "fun"
  ; "function"; "functor"; "if"; "in"; "include"; "inherit"; "initializer"
  ; "land"; "lazy"; "let"; "lor"; "lsl"; "lsr"; "lxor"; "match"; "method"; "mod"
  ; "module"; "mutable"; "new"; "nonrec"; "object"; "of"; "open"; "or"
  ; "private"; "rec"; "sig"; "struct"; "then"; "to"; "true"; "try"; "type"
  ; "val"; "virtual"; "when"; "while"; "with" ]

let is_reserved word =
  List.exists (fun reserved -> String.equal word reserved) ocaml_reserved

let is_identifier_start char =
  (char >= 'a' && char <= 'z') || (char >= 'A' && char <= 'Z') || char = '_'

let is_identifier_char char =
  is_identifier_start char
  || (char >= '0' && char <= '9')
  || char = '\''

let is_digit char = char >= '0' && char <= '9'

let is_hex char =
  is_digit char || (char >= 'a' && char <= 'f') || (char >= 'A' && char <= 'F')

(* Segments accumulate kind-runs: adjacent characters of one kind become one
   segment, so a row's styling is a handful of spans, not one per character. *)
type runs =
  { mutable rev_segments : (string * string) list
  ; current : Buffer.t
  ; mutable kind : string }

let new_runs kind = { rev_segments = []; current = Buffer.create 64; kind }

let runs_push (runs : runs) kind char = Buffer.add_char runs.current char

(* Adding a character under a possibly-new kind: a kind change closes the run
   in progress and takes over -- including when the buffer is empty, which is
   how the very first token of a body inherits the right kind instead of the
   initial one. *)
let runs_add (runs : runs) kind char =
  if not (String.equal runs.kind kind) then begin
    if Buffer.length runs.current > 0 then
      runs.rev_segments <-
        (Buffer.contents runs.current, runs.kind) :: runs.rev_segments;
    Buffer.reset runs.current;
    runs.kind <- kind
  end;
  runs_push runs kind char

let runs_flush (runs : runs) =
  if Buffer.length runs.current > 0 then
    runs.rev_segments <-
      (Buffer.contents runs.current, runs.kind) :: runs.rev_segments

let runs_segments (runs : runs) =
  runs_flush runs;
  List.rev runs.rev_segments

(* Read forward from an index while a predicate holds, emitting into the runs
   under one kind. Returns the index one past the last consumed character. *)
let take_while text index pred kind (runs : runs) =
  let limit = String.length text in
  let rec advance index =
    if index < limit && pred text.[index] then begin
      runs_add runs kind text.[index];
      advance (index + 1)
    end
    else index
  in
  advance index

(* OCaml string literal from an opening quote: backslash escapes one
   character, the next bare quote closes, and a newline inside is part of the
   literal rather than a row break the caller owns. The opening quote itself
   is not a close -- the close test applies only past it, or ["x"] lexes as
   two empty strings with the body spilling out plain. *)
let take_ocaml_string text index (runs : runs) =
  let limit = String.length text in
  let opening = index in
  let rec advance index =
    if index >= limit then index
    else begin
      let char = text.[index] in
      runs_add runs kind_code_string char;
      if char = '\\' && index + 1 < limit then begin
        runs_add runs kind_code_string text.[index + 1];
        advance (index + 2)
      end
      else if char = '"' && index > opening then index + 1
      else advance (index + 1)
    end
  in
  advance index

(* OCaml character literal: a quote, then one scalar or one escape, then a
   closing quote. Type variables ('a) are also quoted but never close, so a
   quote whose closing quote is not within the literal shapes is plain text. *)
let take_ocaml_char text index (runs : runs) =
  let limit = String.length text in
  let closing =
    if index + 1 < limit && text.[index + 1] = '\\' then
      (if index + 3 < limit && text.[index + 3] = '\'' then Some (index + 4)
       else None)
    else if index + 2 < limit && text.[index + 2] = '\'' then Some (index + 3)
    else if index + 2 < limit && text.[index + 1] = '\'' && text.[index + 2] = '\'' then
      Some (index + 3)
    else None
  in
  match closing with
  | None -> runs_add runs kind_code text.[index]; index + 1
  | Some stop ->
      for i = index to stop - 1 do
        runs_add runs kind_code_string text.[i]
      done;
      stop

(* OCaml comment, nesting included: depth counts (* against *) so a comment
   holding a comment ends at its real close. Depth starts at 0 -- the opening
   pair itself raises it to 1, so the pair is counted exactly once. Returns
   the index one past the final close, or the end of the body when the
   comment never closes. *)
let take_ocaml_comment text index (runs : runs) =
  let limit = String.length text in
  let rec advance index depth =
    if index >= limit then index
    else if index + 1 < limit && text.[index] = '(' && text.[index + 1] = '*' then
      ( runs_add runs kind_code_comment text.[index]
      ; runs_add runs kind_code_comment text.[index + 1]
      ; advance (index + 2) (depth + 1) )
    else if index + 1 < limit && text.[index] = '*' && text.[index + 1] = ')' then
      ( runs_add runs kind_code_comment text.[index]
      ; runs_add runs kind_code_comment text.[index + 1]
      ; if depth = 1 then index + 2 else advance (index + 2) (depth - 1) )
    else begin
      runs_add runs kind_code_comment text.[index];
      advance (index + 1) depth
    end
  in
  advance index 0

let ocaml_lexer text =
  let runs = new_runs kind_code in
  let limit = String.length text in
  let rec advance index =
    if index >= limit then ()
    else begin
      let char = text.[index] in
      if index + 1 < limit && char = '(' && text.[index + 1] = '*' then
        advance (take_ocaml_comment text index runs)
      else if char = '"' then advance (take_ocaml_string text index runs)
      else if char = '\'' then advance (take_ocaml_char text index runs)
      else if is_identifier_start char then begin
        (* One identifier: reserved words colour as keywords, a capitalised
           start reads as a constructor or module and colours as a type,
           anything else stays the fence's plain code span. *)
        let word = Buffer.create 16 in
        Buffer.add_char word char;
        let stop =
          let rec scan i =
            if i < limit && is_identifier_char text.[i] then begin
              Buffer.add_char word text.[i];
              scan (i + 1)
            end
            else i
          in
          scan (index + 1)
        in
        let as_string = Buffer.contents word in
        let kind =
          if is_reserved as_string then kind_code_keyword
          else if
            as_string.[0] >= 'A' && as_string.[0] <= 'Z'
          then kind_code_type
          else kind_code
        in
        String.iter (fun c -> runs_add runs kind c) as_string;
        advance stop
      end
      else if is_digit char then begin
        (* Numbers only: 0x hex, decimal digits, underscores, and one
           decimal-point run. A trailing sign stays outside -- colouring the
           [+] of [1 + 2] as a number is a lie about the token. *)
        let stop =
          if index + 1 < limit && char = '0' && (text.[index + 1] = 'x' || text.[index + 1] = 'X') then begin
            runs_add runs kind_code_number char;
            runs_add runs kind_code_number text.[index + 1];
            take_while text (index + 2)
              (fun c -> is_hex c || c = '_')
              kind_code_number runs
          end
          else
            let after_digits =
              take_while text index (fun c -> is_digit c || c = '_') kind_code_number runs
            in
            if after_digits < limit && text.[after_digits] = '.' then begin
              runs_add runs kind_code_number '.';
              take_while text (after_digits + 1)
                (fun c -> is_digit c || c = '_')
                kind_code_number runs
            end
            else after_digits
        in
        advance stop
      end
      else begin
        runs_add runs kind_code char;
        advance (index + 1)
      end
    end
  in
  advance 0;
  runs_segments runs

(* A bash row comment: [#] to the row's end, but only where it starts a word
   -- colouring the [#] inside [#tag] or [a#b] recolours text mid-token. *)
let bash_lexer text =
  let runs = new_runs kind_code in
  let limit = String.length text in
  let rec advance index =
    if index >= limit then ()
    else begin
      let char = text.[index] in
      if char = '"' then advance (take_ocaml_string text index runs)
      else if char = '\'' then begin
        (* Single quotes in bash have no escapes: everything to the next
           quote is literal, backslash included. *)
        runs_add runs kind_code_string char;
        let rec literal i =
          if i >= limit then i
          else begin
            runs_add runs kind_code_string text.[i];
            if text.[i] = '\'' then i + 1 else literal (i + 1)
          end
        in
        advance (literal (index + 1))
      end
      else if
        char = '#'
        && (index = 0
           || text.[index - 1] = ' '
           || text.[index - 1] = '\t'
           || text.[index - 1] = '\n'
           || text.[index - 1] = ';')
      then begin
        let stop =
          take_while text index (fun c -> c <> '\n') kind_code_comment runs
        in
        advance stop
      end
      else begin
        runs_add runs kind_code char;
        advance (index + 1)
      end
    end
  in
  advance 0;
  runs_segments runs

(* JSON: a string followed (after spaces) by a colon is an object key; the
   others are values; numbers and the literals true/false/null read as
   numbers. The colon test is lookahead only -- it never emits, so the
   punctuation keeps the plain span. *)
let json_lexer text =
  let runs = new_runs kind_code in
  let limit = String.length text in
  let rec advance index =
    if index >= limit then ()
    else begin
      let char = text.[index] in
      if char = '"' then begin
        let stop = take_ocaml_string text index runs in
        let rec peek i =
          if i >= limit then false
          else if text.[i] = ' ' || text.[i] = '\t' then peek (i + 1)
          else text.[i] = ':'
        in
        (* A key is a differently-coloured string. The string just read is
           still the run in progress -- retagging the run colours the whole
           literal without rewriting any segment list. *)
        if peek stop then runs.kind <- kind_code_type;
        advance stop
      end
      else if is_digit char || ((char = '-') && index + 1 < limit && is_digit text.[index + 1]) then begin
        (* Digits and one decimal shape. An exponent's [e] stays plain rather
           than colouring one token wider than the set: [-] inside [3 - 1]
           must not join the number that follows it. *)
        let stop =
          take_while text index (fun c -> is_digit c || c = '.')
            kind_code_number runs
        in
        advance stop
      end
      else if starts_at text index "true" then begin
        String.iter (fun c -> runs_add runs kind_code_number c) "true";
        advance (index + 4)
      end
      else if starts_at text index "false" then begin
        String.iter (fun c -> runs_add runs kind_code_number c) "false";
        advance (index + 5)
      end
      else if starts_at text index "null" then begin
        String.iter (fun c -> runs_add runs kind_code_number c) "null";
        advance (index + 4)
      end
      else begin
        runs_add runs kind_code char;
        advance (index + 1)
      end
    end
  in
  advance 0;
  runs_segments runs

(* The fence tag decides who lexes. Untagged and unknown tags answer None and
   the fence keeps the single code span -- a guess at the grammar from the
   text alone is exactly the colouring-as-pretence the palette avoids. *)
let lexer_of_language (tag : string) =
  match String.lowercase_ascii (String.trim tag) with
  | "ocaml" | "ml" | "mli" -> Some ocaml_lexer
  | "bash" | "sh" | "shell" | "zsh" -> Some bash_lexer
  | "json" -> Some json_lexer
  | _ -> None

(* The language tag after a fence marker, ["```ocaml" -> "ocaml"]. An empty
   rest is an untagged fence: no tag, no lexer, no guess. *)
let fence_language line =
  match fence_marker (String.trim line) with
  | None -> None
  | Some marker ->
      let trimmed = String.trim line in
      let rest =
        String.trim
          (String.sub trimmed (String.length marker)
             (String.length trimmed - String.length marker))
      in
      if String.length rest = 0 then None else Some rest

(* Segments of a lexed fence body, cut into rows at the newlines the lexer
   carried as plain text. Piece order inside a row is the lexer's order, so
   the styling reads left to right as the code does. *)
let fence_rows_of_segments segments =
  let rev_rows : (string * string) list list ref = ref [ [] ] in
  List.iter
    (fun (text, kind) ->
       List.iteri
         (fun index piece ->
            if index > 0 then rev_rows := [] :: !rev_rows;
            rev_rows :=
              ((piece, kind) :: List.hd !rev_rows) :: List.tl !rev_rows)
         (String.split_on_char '\n' text))
    segments;
  List.rev_map List.rev !rev_rows

let styled_piece palette (text, kind) =
  if String.length text = 0 then ""
  else
    let opening, closing = span_of_palette palette kind in
    opening ^ text ^ closing

(* One lexed row. In the width budget it draws as its pieces; past it the
   row falls back to the single-span cell split -- a code row keeps its
   alignment before it keeps its colours, because the alignment is why it
   was fenced. *)
let styled_code_rows palette ~width pieces =
  let gutter = palette.code_gutter in
  let body_width = max 1 (width - Layout.display_width gutter) in
  let plain = String.concat "" (List.map fst pieces) in
  let cells = Layout.display_width plain in
  if cells <= body_width then
    [ gutter ^ String.concat "" (List.map (styled_piece palette) pieces) ]
  else
    let opening, closing = palette.code in
    Layout.split_cells ~max_cells:body_width plain
    |> List.map (fun chunk -> opening ^ gutter ^ chunk ^ closing)

let horizontal cells =
  String.concat "" (List.init (max 0 cells) (fun _ -> "\xe2\x94\x80"))

let styled_span (opening, closing) text = opening ^ text ^ closing

(* The tag was previously consumed only to choose a lexer, so [```bash] and an
   untagged fence looked identical. Fill the row so reverse video can provide a
   terminal-theme-safe background without choosing a light- or dark-only
   colour. A very long tag is clipped as one row; it cannot push the frame. *)
let code_header palette ~width language =
  let stem = "\xe2\x94\x8c\xe2\x94\x80 " ^ language ^ " " in
  let stem =
    if Layout.display_width stem <= width then stem
    else
      match Layout.split_cells ~max_cells:width stem with
      | first :: _ -> first
      | [] -> ""
  in
  let remaining = max 0 (width - Layout.display_width stem) in
  styled_span palette.code_header (stem ^ horizontal remaining)

let code_footer palette ~width =
  styled_span palette.code_border
    ("\xe2\x94\x94" ^ horizontal (max 0 (width - 1)))

(* Fenced code is not wrapped at spaces: the alignment is the reason it was
   fenced. A line wider than the row is split where the row ends. *)
let code_rows palette ~width line =
  let gutter = palette.code_gutter in
  let body_width = max 1 (width - Layout.display_width gutter) in
  let opening, closing = palette.code in
  if String.length line = 0 then [ opening ^ gutter ^ closing ]
  else
    Layout.split_cells ~max_cells:body_width line
    |> List.map (fun chunk -> opening ^ gutter ^ chunk ^ closing)

(* {1 Tables} *)

(* A table is the one block form that cannot be decided one line at a time. A
   row of pipes is a table only when a delimiter row follows it -- without that
   rule an OCaml [| Some x -> y] pasted outside a fence would become one -- and
   the column widths are a property of every row at once. So the whole block is
   matched together, in [render], where the rest of it is still in hand. *)

type alignment =
  | Left
  | Centre
  | Right

let table_cells line =
  let trimmed = String.trim line in
  if not (String.contains trimmed '|') then None
  else
    let parts = String.split_on_char '|' trimmed in
    (* The outer pipes are optional in the source and carry nothing, so the
       empty cells they leave are dropped rather than drawn. *)
    let parts = match parts with "" :: rest -> rest | other -> other in
    let parts =
      match List.rev parts with "" :: rest -> List.rev rest | _ -> parts
    in
    match parts with
    | [] -> None
    | cells -> Some (List.map String.trim cells)

let delimiter_alignment cell =
  let length = String.length cell in
  if length = 0 then None
  else
    let opens = cell.[0] = ':' in
    let closes = length > 1 && cell.[length - 1] = ':' in
    let first = if opens then 1 else 0 in
    let last = if closes then length - 1 else length in
    let dashes = last - first in
    let all_dashes = ref (dashes >= 1) in
    String.iteri
      (fun index char ->
        if index >= first && index < last && char <> '-' then all_dashes := false)
      cell;
    if not !all_dashes then None
    else
      Some
        (match (opens, closes) with
         | true, true -> Centre
         | false, true -> Right
         | true, false | false, false -> Left)

let table_alignments line =
  match table_cells line with
  | None | Some [] -> None
  | Some cells ->
      let alignments = List.map delimiter_alignment cells in
      if List.for_all Option.is_some alignments
      then Some (List.map Option.get alignments)
      else None

(* Every row is drawn with the same number of columns as the delimiter row
   declared: a short row is padded and a long one keeps its overflow in the
   last column rather than being cut, because a cell the source wrote is worth
   more than a straight right edge. *)
let normalise_row ~columns cells =
  let rec take taken remaining = function
    | _ when remaining = 0 -> List.rev taken
    | [] -> List.rev taken @ List.init remaining (fun _ -> "")
    | [ last ] when remaining = 1 -> List.rev (last :: taken)
    | rest when remaining = 1 -> List.rev (String.concat " " rest :: taken)
    | cell :: rest -> take (cell :: taken) (remaining - 1) rest
  in
  take [] columns cells

let pad ~alignment ~cells text =
  let missing = max 0 (cells - Layout.display_width text) in
  match alignment with
  | Left -> text ^ String.make missing ' '
  | Right -> String.make missing ' ' ^ text
  | Centre ->
      let left = missing / 2 in
      String.make left ' ' ^ text ^ String.make (missing - left) ' '

(* Columns get their natural width when the row fits. When it does not, the
   widest column gives up a cell at a time: taking it evenly would shrink a
   two-cell column that costs nothing to keep. *)
let column_widths ~width ~gutter_cells ~columns rows =
  let natural =
    List.init columns (fun index ->
      List.fold_left
        (fun widest row ->
          max widest (Layout.display_width (List.nth row index)))
        1 rows)
  in
  let spacing = gutter_cells * max 0 (columns - 1) in
  let widths = Array.of_list natural in
  let total () = Array.fold_left ( + ) 0 widths + spacing in
  let rec shrink () =
    if total () <= width then ()
    else
      let widest = ref 0 in
      Array.iteri (fun index w -> if w > widths.(!widest) then widest := index) widths;
      if widths.(!widest) <= 1 then ()
      else begin
        widths.(!widest) <- widths.(!widest) - 1;
        shrink ()
      end
  in
  shrink ();
  Array.to_list widths

let table_block palette ~width ~alignments ~header ~body =
  let columns = List.length alignments in
  let gutter = palette.table_gutter in
  let gutter_cells = Layout.display_width gutter in
  let styled cells =
    List.map
      (fun cell ->
        match
          wrap_inline palette ~width:max_int ~prefix:"" ~continuation:"" cell
        with
        | [] -> ""
        | row :: _ -> row)
      (normalise_row ~columns cells)
  in
  let header = styled header in
  let body = List.map styled body in
  let widths = column_widths ~width ~gutter_cells ~columns (header :: body) in
  let draw row =
    List.mapi
      (fun index cell ->
        let cells = List.nth widths index in
        let alignment = List.nth alignments index in
        (* [fit_width] pads on the left as well as truncating, and a cell it
           has padded has no room left for the alignment the delimiter row
           asked for. So it is asked only for the cut. *)
        let fitted =
          if Layout.display_width cell > cells then Layout.fit_width cell cells
          else cell
        in
        pad ~alignment ~cells fitted)
      row
    |> String.concat gutter
  in
  let opening, closing = palette.table_header in
  let rule_opening, rule_closing = palette.rule in
  let rule =
    List.map (fun cells -> String.concat "" (List.init cells (fun _ -> "\xe2\x94\x80"))) widths
    |> String.concat gutter
  in
  (opening ^ draw header ^ closing)
  :: (rule_opening ^ rule ^ rule_closing)
  :: List.map draw body

(* The table starting at [line], if one starts there: its delimiter row, the
   body rows that follow it, and what is left of the source. *)
type source_line = {
  source_text : string;
  source_start : int;
  terminal_line : bool;
  synthetic_terminal : bool;
}

let source_lines text =
  let lines = String.split_on_char '\n' text in
  let last_index = List.length lines - 1 in
  let ends_with_newline = String.ends_with ~suffix:"\n" text in
  let offset = ref 0 in
  List.mapi
    (fun index source_text ->
      let source_start = !offset in
      if index < last_index then
        offset := source_start + String.length source_text + 1;
      { source_text;
        source_start;
        terminal_line = index = last_index;
        synthetic_terminal = ends_with_newline && index = last_index;
      })
    lines

let table_at line rest =
  match (table_cells line.source_text, rest) with
  | Some header, delimiter :: after -> (
      match table_alignments delimiter.source_text with
      | None -> None
      | Some alignments ->
          let rec body taken = function
            | next :: more -> (
                match table_cells next.source_text with
                | Some cells when table_alignments next.source_text = None ->
                    body (cells :: taken) more
                | Some _ | None -> (List.rev taken, next :: more))
            | [] -> (List.rev taken, [])
          in
          let rows, remaining = body [] after in
          Some (header, alignments, rows, remaining))
  | Some _, [] | None, _ -> None

(* One source line outside a fence, as the rows it becomes. Flat rather than
   nested so each block form is readable next to the others. *)
let block_rows palette ~width line =
  let heading_rows level body =
    let opening, closing = palette.heading level in
    wrap_inline palette ~width ~prefix:"" ~continuation:"" body
    |> List.map (fun row -> opening ^ row ^ closing)
  in
  let quote_rows body =
    let opening, closing = palette.quote in
    wrap_inline palette ~width ~prefix:palette.quote_gutter
      ~continuation:palette.quote_gutter body
    |> List.map (fun row -> opening ^ row ^ closing)
  in
  let item_rows ~indent ~marker body =
    let prefix = String.make indent ' ' ^ marker ^ " " in
    let continuation = String.make (Layout.display_width prefix) ' ' in
    wrap_inline palette ~width ~prefix ~continuation body
  in
  if String.trim line = "" then [ "" ]
  else if is_rule line then
    let opening, closing = palette.rule in
    [ opening
      ^ String.concat "" (List.init width (fun _ -> "\xe2\x94\x80"))
      ^ closing
    ]
  else
    match heading_level line with
    | Some (level, body) -> heading_rows level body
    | None -> (
        match quote_body line with
        | Some body -> quote_rows body
        | None -> (
            match bullet_item line with
            | Some (indent, body) ->
                item_rows ~indent ~marker:palette.bullet body
            | None -> (
                match ordered_item line with
                | Some (indent, marker, body) -> item_rows ~indent ~marker body
                | None ->
                    wrap_inline palette ~width ~prefix:"" ~continuation:"" line)))

let closes_fence line ~opened =
  match (fence_marker line, opened) with
  | Some marker, Some opened -> String.equal marker opened
  | Some _, None -> true
  | None, _ -> false

let render_streaming ~palette ~width text =
  let width = max 1 width in
  let rows = ref [] in
  let rendered_rows = ref 0 in
  let block_count = ref 0 in
  let previous_source_start = ref 0 in
  let previous_row_start = ref 0 in
  let mutable_source_start = ref 0 in
  let mutable_row_start = ref 0 in
  let previous_can_absorb_terminal = ref false in
  let mutable_can_absorb_terminal = ref false in
  let mutable_block_started_at_terminal = ref false in
  let emit_all list =
    List.iter
      (fun row ->
        rows := row :: !rows;
        incr rendered_rows)
      list
  in
  (* A source ending in a newline produces one synthetic empty line from
     [String.split_on_char]. It is still rendered -- [render] has always kept
     that row -- but it cannot close the preceding block: another delta can
     append a table row or fence content immediately after that newline. *)
  let begin_block ~can_absorb_terminal line =
    if not line.synthetic_terminal then begin
      previous_source_start := !mutable_source_start;
      previous_row_start := !mutable_row_start;
      previous_can_absorb_terminal := !mutable_can_absorb_terminal;
      mutable_source_start := line.source_start;
      mutable_row_start := !rendered_rows;
      mutable_can_absorb_terminal := can_absorb_terminal;
      mutable_block_started_at_terminal := line.terminal_line;
      incr block_count
    end
  in
  (* The fence body is held until the fence closes -- or until the text ends,
     an unclosed fence still renders what it holds -- because the lexer reads
     the body whole; its state, a comment opened rows ago, decides the colour
     of rows it has not reached yet. *)
  let emit_fence ~closed language lexer rev_body =
    let body = List.rev rev_body in
    Option.iter
      (fun language -> emit_all [ code_header palette ~width language ])
      language;
    (match lexer with
     | Some lexer ->
         fence_rows_of_segments (lexer (String.concat "\n" body))
         |> List.iter
              (fun pieces -> emit_all (styled_code_rows palette ~width pieces))
     | None ->
         List.iter (fun line -> emit_all (code_rows palette ~width line)) body);
    if closed && Option.is_some language then
      emit_all [ code_footer palette ~width ]
  in
  let rec walk fence rev_body = function
    | [] -> (
        match fence with
        | Some (_, language, lexer) ->
            emit_fence ~closed:false language lexer rev_body
        | None -> ())
    | line :: rest -> (
        match fence with
        | Some (marker, language, lexer)
          when closes_fence line.source_text ~opened:(Some marker) ->
            emit_fence ~closed:true language lexer rev_body;
            mutable_can_absorb_terminal := false;
            walk None [] rest
        | Some _ -> walk fence (line.source_text :: rev_body) rest
        | None -> (
            match fence_marker line.source_text with
            | Some marker ->
                begin_block ~can_absorb_terminal:true line;
                let language = fence_language line.source_text in
                let lexer =
                  Option.bind language lexer_of_language
                in
                walk (Some (marker, language, lexer)) [] rest
            | None -> (
                match table_at line rest with
                | Some (header, alignments, body, remaining) ->
                    begin_block ~can_absorb_terminal:true line;
                    emit_all
                      (table_block palette ~width ~alignments ~header ~body);
                    walk None [] remaining
                | None ->
                    begin_block
                      ~can_absorb_terminal:
                        (Option.is_some (table_cells line.source_text))
                      line;
                    emit_all (block_rows palette ~width line.source_text);
                    walk None [] rest)))
  in
  walk None [] (source_lines text);
  let terminal_can_join_previous = !previous_can_absorb_terminal in
  let mutable_source_start, mutable_row_start =
    (* An incomplete final physical line can still turn into a table delimiter
       for a header candidate before it, or into another row of a table. Keep
       that predecessor mutable until a newline proves the separation. Other
       preceding blocks are already closed. A final line already inside a
       fence or table never called [begin_block], so its real boundary remains. *)
    if
      !mutable_block_started_at_terminal
      && !block_count > 1
      && terminal_can_join_previous
    then
      !previous_source_start, !previous_row_start
    else !mutable_source_start, !mutable_row_start
  in
  { rows = List.rev !rows;
    mutable_source_start;
    mutable_row_start;
  }

let render ~palette ~width text = (render_streaming ~palette ~width text).rows
