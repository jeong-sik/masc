(* Tokenizers for source code, shared by the chat's fenced code blocks and
   the Code surface. Moved from masc_tui_markdown so a file view can colour
   content without the markdown chrome; the design notes moved with them. *)

type segment = string * string

let starts_at text index marker =
  let length = String.length marker in
  index + length <= String.length text
  && String.equal (String.sub text index length) marker

let kind_code = "code"
let kind_keyword = "code_keyword"
let kind_string = "code_string"
let kind_comment = "code_comment"
let kind_number = "code_number"
let kind_type = "code_type"

(* A diff's two answers. They are line-shaped rather than token-shaped, which
   is why they are their own kinds: no lexer run can end mid-line and mean
   something. *)
let kind_diff_added = "code_diff_added"
let kind_diff_removed = "code_diff_removed"

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
      runs_add runs kind_string char;
      if char = '\\' && index + 1 < limit then begin
        runs_add runs kind_string text.[index + 1];
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
        runs_add runs kind_string text.[i]
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
      ( runs_add runs kind_comment text.[index]
      ; runs_add runs kind_comment text.[index + 1]
      ; advance (index + 2) (depth + 1) )
    else if index + 1 < limit && text.[index] = '*' && text.[index + 1] = ')' then
      ( runs_add runs kind_comment text.[index]
      ; runs_add runs kind_comment text.[index + 1]
      ; if depth = 1 then index + 2 else advance (index + 2) (depth - 1) )
    else begin
      runs_add runs kind_comment text.[index];
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
          if is_reserved as_string then kind_keyword
          else if
            as_string.[0] >= 'A' && as_string.[0] <= 'Z'
          then kind_type
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
            runs_add runs kind_number char;
            runs_add runs kind_number text.[index + 1];
            take_while text (index + 2)
              (fun c -> is_hex c || c = '_')
              kind_number runs
          end
          else
            let after_digits =
              take_while text index (fun c -> is_digit c || c = '_') kind_number runs
            in
            if after_digits < limit && text.[after_digits] = '.' then begin
              runs_add runs kind_number '.';
              take_while text (after_digits + 1)
                (fun c -> is_digit c || c = '_')
                kind_number runs
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
        runs_add runs kind_string char;
        let rec literal i =
          if i >= limit then i
          else begin
            runs_add runs kind_string text.[i];
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
          take_while text index (fun c -> c <> '\n') kind_comment runs
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
        if peek stop then runs.kind <- kind_type;
        advance stop
      end
      else if is_digit char || ((char = '-') && index + 1 < limit && is_digit text.[index + 1]) then begin
        (* Digits and one decimal shape. An exponent's [e] stays plain rather
           than colouring one token wider than the set: [-] inside [3 - 1]
           must not join the number that follows it. *)
        let stop =
          take_while text index (fun c -> is_digit c || c = '.')
            kind_number runs
        in
        advance stop
      end
      else if starts_at text index "true" then begin
        String.iter (fun c -> runs_add runs kind_number c) "true";
        advance (index + 4)
      end
      else if starts_at text index "false" then begin
        String.iter (fun c -> runs_add runs kind_number c) "false";
        advance (index + 5)
      end
      else if starts_at text index "null" then begin
        String.iter (fun c -> runs_add runs kind_number c) "null";
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
(* A diff line is read whole: its first cell decides the whole line, so this
   emits one run per line instead of scanning for tokens. A hunk header reads
   as a comment because it locates the change rather than being part of it,
   and "---"/"+++" file headers are left plain so they are not mistaken for
   the removal and addition directly under them. *)
let diff_line_kind line =
  if String.length line = 0 then kind_code
  else if
    String.length line >= 3
    && (String.sub line 0 3 = "+++" || String.sub line 0 3 = "---")
  then
    (* A file header, not the change under it. Colouring it would put a green
       "+++" directly above the first added line and read as part of it. *)
    kind_code
  else
    match line.[0] with
    | '+' -> kind_diff_added
    | '-' -> kind_diff_removed
    | '@' -> kind_comment
    | _ -> kind_code

let diff_lexer text =
  let runs = new_runs kind_code in
  let add kind s = String.iter (fun c -> runs_add runs kind c) s in
  let lines = String.split_on_char '\n' text in
  let count = List.length lines in
  List.iteri
    (fun index line ->
      add (diff_line_kind line) line;
      (* The newline belongs to no line's colour: [rows_of_segments] cuts rows
         on it, and a coloured one would carry the run past the cut. *)
      if index < count - 1 then add kind_code "\n")
    lines;
  runs_segments runs

let lexer_of_language (tag : string) =
  match String.lowercase_ascii (String.trim tag) with
  | "ocaml" | "ml" | "mli" -> Some ocaml_lexer
  | "bash" | "sh" | "shell" | "zsh" -> Some bash_lexer
  | "json" -> Some json_lexer
  | "diff" | "patch" -> Some diff_lexer
  | _ -> None


(* Segments of a lexed fence body, cut into rows at the newlines the lexer
   carried as plain text. Piece order inside a row is the lexer's order, so
   the styling reads left to right as the code does. *)
let rows_of_segments segments =
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


(* The extension decides the language, mirroring the server's
   Lsp_process_manager.lang_of_path table. Only extensions whose language has
   a lexer here answer; the rest are None, and the caller keeps the plain
   span -- a guess at the grammar is the colouring-as-pretence the fence
   lexers already refuse. *)
let language_of_path path =
  let lower = String.lowercase_ascii path in
  let has suffix = Filename.check_suffix lower suffix in
  if has ".ml" || has ".mli" then Some "ocaml"
  else if has ".sh" || has ".bash" || has ".zsh" then Some "bash"
  else if has ".json" then Some "json"
  else None

(* A whole file as rows of (text, kind) segments. Lexing reads the whole
   text at once -- an OCaml comment opened three rows up is state no single
   row holds -- and the rows split at the newlines the lexer carried. *)
let rows_of_source ~language text =
  let segments =
    match Option.bind language lexer_of_language with
    | Some lexer -> lexer text
    | None -> [ (text, kind_code) ]
  in
  rows_of_segments segments
