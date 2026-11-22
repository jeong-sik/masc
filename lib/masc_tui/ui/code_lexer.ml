module Rect = Masc_tui_core.Rect
module Theme = Masc_tui_core.Theme
module Attr = Masc_tui_term.Attr
module Color = Masc_tui_term.Color
module Style = Masc_tui_term.Style
module Cell_grid = Masc_tui_term.Cell_grid

type token_kind =
  | Plain
  | Keyword
  | String
  | Comment
  | Number
  | Type_or_ctor
  | Json_key
  | Json_number
  | Json_literal
  | Json_punctuation
  | Diff_added
  | Diff_removed
  | Diff_hunk

type segment = {
  text : string;
  kind : token_kind;
}

type language =
  | Ocaml
  | Bash
  | Json
  | Diff of language option
  | Yaml
  | Toml
  | Sql
  | C_like
  | Python
  | Markdown

let token_kind_rank = function
  | Plain -> 0
  | Keyword -> 1
  | String -> 2
  | Comment -> 3
  | Number -> 4
  | Type_or_ctor -> 5
  | Json_key -> 6
  | Json_number -> 7
  | Json_literal -> 8
  | Json_punctuation -> 9
  | Diff_added -> 10
  | Diff_removed -> 11
  | Diff_hunk -> 12

let equal_token_kind a b = Int.equal (token_kind_rank a) (token_kind_rank b)

let rec equal_language a b =
  match (a, b) with
  | Ocaml, Ocaml
  | Bash, Bash
  | Json, Json
  | Yaml, Yaml
  | Toml, Toml
  | Sql, Sql
  | C_like, C_like
  | Python, Python
  | Markdown, Markdown ->
      true
  | Diff x, Diff y -> Option.equal equal_language x y
  | ( Ocaml
    | Bash
    | Json
    | Diff _
    | Yaml
    | Toml
    | Sql
    | C_like
    | Python
    | Markdown ),
    _ ->
      false

let starts_at text index marker =
  let length = String.length marker in
  index + length <= String.length text
  &&
  let rec same offset =
    offset >= length
    || (Char.equal text.[index + offset] marker.[offset] && same (offset + 1))
  in
  same 0

let is_identifier_start c =
  (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || Char.equal c '_'

let is_identifier_char c =
  is_identifier_start c || (c >= '0' && c <= '9') || Char.equal c '\''

let is_digit c = c >= '0' && c <= '9'
let is_hex c = is_digit c || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')

type runs = {
  mutable rev_segments : segment list;
  current : Buffer.t;
  mutable kind : token_kind;
}

let new_runs kind = { rev_segments = []; current = Buffer.create 64; kind }

let runs_add (runs : runs) kind ch =
  if not (equal_token_kind runs.kind kind) then begin
    if Buffer.length runs.current > 0 then
      runs.rev_segments <-
        { text = Buffer.contents runs.current; kind = runs.kind }
        :: runs.rev_segments;
    Buffer.reset runs.current;
    runs.kind <- kind
  end;
  Buffer.add_char runs.current ch

let runs_add_string (runs : runs) kind s =
  String.iter (fun c -> runs_add runs kind c) s

let runs_segments (runs : runs) =
  if Buffer.length runs.current > 0 then
    runs.rev_segments <-
      { text = Buffer.contents runs.current; kind = runs.kind }
      :: runs.rev_segments;
  List.rev runs.rev_segments

let take_while text index pred kind runs =
  let limit = String.length text in
  let rec advance i =
    if i < limit && pred text.[i] then begin
      runs_add runs kind text.[i];
      advance (i + 1)
    end
    else i
  in
  advance index

let paint ~kind text start stop runs =
  for i = start to stop - 1 do
    runs_add runs kind text.[i]
  done

let take_quoted ~quote text index runs =
  let limit = String.length text in
  let opening = index in
  let rec advance i =
    if i >= limit then i
    else begin
      let ch = text.[i] in
      runs_add runs String ch;
      if Char.equal ch '\\' && i + 1 < limit then begin
        runs_add runs String text.[i + 1];
        advance (i + 2)
      end
      else if Char.equal ch quote && i > opening then i + 1
      else advance (i + 1)
    end
  in
  advance index

let take_number text index runs =
  let limit = String.length text in
  let ch = text.[index] in
  if
    index + 1 < limit
    && Char.equal ch '0'
    && (Char.equal text.[index + 1] 'x' || Char.equal text.[index + 1] 'X')
  then begin
    runs_add runs Number ch;
    runs_add runs Number text.[index + 1];
    take_while text (index + 2) (fun c -> is_hex c || Char.equal c '_') Number runs
  end
  else
    let after =
      take_while text index (fun c -> is_digit c || Char.equal c '_') Number runs
    in
    if after < limit && Char.equal text.[after] '.' then begin
      runs_add runs Number '.';
      take_while text (after + 1)
        (fun c -> is_digit c || Char.equal c '_')
        Number runs
    end
    else after

let take_identifier ~is_reserved text index runs =
  let limit = String.length text in
  let rec scan i =
    if i < limit && is_identifier_char text.[i] then scan (i + 1) else i
  in
  let stop = scan (index + 1) in
  let word = String.sub text index (stop - index) in
  let kind =
    if is_reserved word then Keyword
    else if word.[0] >= 'A' && word.[0] <= 'Z' then Type_or_ctor
    else Plain
  in
  runs_add_string runs kind word;
  stop

let ocaml_reserved =
  [
    "and"; "as"; "assert"; "asr"; "begin"; "class"; "constraint"; "do"; "done";
    "downto"; "else"; "end"; "exception"; "external"; "false"; "for"; "fun";
    "function"; "functor"; "if"; "in"; "include"; "inherit"; "initializer";
    "land"; "lazy"; "let"; "lor"; "lsl"; "lsr"; "lxor"; "match"; "method";
    "mod"; "module"; "mutable"; "new"; "nonrec"; "object"; "of"; "open"; "or";
    "private"; "rec"; "sig"; "struct"; "then"; "to"; "true"; "try"; "type";
    "val"; "virtual"; "when"; "while"; "with";
  ]

let is_ocaml_reserved w = List.exists (String.equal w) ocaml_reserved

let take_ocaml_char text index runs =
  let limit = String.length text in
  let closing =
    if index + 1 < limit && Char.equal text.[index + 1] '\\' then
      if index + 3 < limit && Char.equal text.[index + 3] '\'' then
        Some (index + 4)
      else None
    else if index + 2 < limit && Char.equal text.[index + 2] '\'' then
      Some (index + 3)
    else None
  in
  match closing with
  | None ->
      runs_add runs Plain text.[index];
      index + 1
  | Some stop ->
      paint ~kind:String text index stop runs;
      stop

let take_ocaml_comment text index runs =
  let limit = String.length text in
  let rec advance i depth =
    if i >= limit then i
    else if i + 1 < limit && Char.equal text.[i] '(' && Char.equal text.[i + 1] '*' then begin
      runs_add runs Comment '(';
      runs_add runs Comment '*';
      advance (i + 2) (depth + 1)
    end
    else if i + 1 < limit && Char.equal text.[i] '*' && Char.equal text.[i + 1] ')' then begin
      runs_add runs Comment '*';
      runs_add runs Comment ')';
      if depth = 1 then i + 2 else advance (i + 2) (depth - 1)
    end
    else begin
      runs_add runs Comment text.[i];
      advance (i + 1) depth
    end
  in
  advance index 0

let ocaml_lexer text =
  let runs = new_runs Plain in
  let limit = String.length text in
  let rec advance i =
    if i >= limit then ()
    else
      let ch = text.[i] in
      if i + 1 < limit && Char.equal ch '(' && Char.equal text.[i + 1] '*' then
        advance (take_ocaml_comment text i runs)
      else if Char.equal ch '"' then advance (take_quoted ~quote:'"' text i runs)
      else if Char.equal ch '\'' then advance (take_ocaml_char text i runs)
      else if is_identifier_start ch then
        advance (take_identifier ~is_reserved:is_ocaml_reserved text i runs)
      else if is_digit ch then advance (take_number text i runs)
      else begin
        runs_add runs Plain ch;
        advance (i + 1)
      end
  in
  advance 0;
  runs_segments runs

let bash_lexer text =
  let runs = new_runs Plain in
  let limit = String.length text in
  let rec advance i =
    if i >= limit then ()
    else
      let ch = text.[i] in
      if Char.equal ch '"' then advance (take_quoted ~quote:'"' text i runs)
      else if Char.equal ch '\'' then begin
        runs_add runs String '\'';
        let rec literal j =
          if j >= limit then j
          else begin
            runs_add runs String text.[j];
            if Char.equal text.[j] '\'' then j + 1 else literal (j + 1)
          end
        in
        advance (literal (i + 1))
      end
      else if
        Char.equal ch '#'
        && (i = 0
           || Char.equal text.[i - 1] ' '
           || Char.equal text.[i - 1] '\t'
           || Char.equal text.[i - 1] '\n'
           || Char.equal text.[i - 1] ';')
      then
        advance (take_while text i (fun c -> not (Char.equal c '\n')) Comment runs)
      else begin
        runs_add runs Plain ch;
        advance (i + 1)
      end
  in
  advance 0;
  runs_segments runs

let is_json_punct = function
  | '{' | '}' | '[' | ']' | ',' | ':' -> true
  | _ -> false

let json_lexer text =
  let runs = new_runs Plain in
  let limit = String.length text in
  let rec advance i =
    if i >= limit then ()
    else
      let ch = text.[i] in
      if Char.equal ch '"' then begin
        let stop = take_quoted ~quote:'"' text i runs in
        let rec peek j =
          if j >= limit then false
          else if Char.equal text.[j] ' ' || Char.equal text.[j] '\t' then peek (j + 1)
          else Char.equal text.[j] ':'
        in
        if peek stop then runs.kind <- Json_key;
        advance stop
      end
      else if
        is_digit ch || (Char.equal ch '-' && i + 1 < limit && is_digit text.[i + 1])
      then begin
        let from =
          if Char.equal ch '-' then begin
            runs_add runs Json_number '-';
            i + 1
          end
          else i
        in
        advance
          (take_while text from
             (fun c -> is_digit c || Char.equal c '.')
             Json_number runs)
      end
      else if starts_at text i "true" then begin
        runs_add_string runs Json_literal "true";
        advance (i + 4)
      end
      else if starts_at text i "false" then begin
        runs_add_string runs Json_literal "false";
        advance (i + 5)
      end
      else if starts_at text i "null" then begin
        runs_add_string runs Json_literal "null";
        advance (i + 4)
      end
      else if is_json_punct ch then begin
        runs_add runs Json_punctuation ch;
        advance (i + 1)
      end
      else begin
        runs_add runs Plain ch;
        advance (i + 1)
      end
  in
  advance 0;
  runs_segments runs

let take_c_block_comment text index runs =
  let limit = String.length text in
  runs_add runs Comment '/';
  runs_add runs Comment '*';
  let rec advance i =
    if i >= limit then i
    else if i + 1 < limit && Char.equal text.[i] '*' && Char.equal text.[i + 1] '/' then begin
      runs_add runs Comment '*';
      runs_add runs Comment '/';
      i + 2
    end
    else begin
      runs_add runs Comment text.[i];
      advance (i + 1)
    end
  in
  advance (index + 2)

let c_like_reserved =
  [
    "abstract"; "as"; "async"; "await"; "break"; "case"; "catch"; "class";
    "const"; "continue"; "debugger"; "default"; "defer"; "delete"; "do";
    "else"; "enum"; "export"; "extends"; "extern"; "final"; "finally"; "fn";
    "for"; "func"; "function"; "go"; "goto"; "if"; "impl"; "implements";
    "import"; "in"; "instanceof"; "interface"; "let"; "loop"; "match"; "mod";
    "module"; "mut"; "namespace"; "new"; "package"; "private"; "protected";
    "pub"; "public"; "readonly"; "return"; "select"; "static"; "struct";
    "super"; "switch"; "throw"; "trait"; "try"; "type"; "typeof"; "union";
    "unsafe"; "use"; "var"; "void"; "where"; "while"; "with"; "yield";
  ]

let is_c_like_reserved w = List.exists (String.equal w) c_like_reserved

let c_like_lexer text =
  let runs = new_runs Plain in
  let limit = String.length text in
  let rec advance i =
    if i >= limit then ()
    else
      let ch = text.[i] in
      if i + 1 < limit && Char.equal ch '/' && Char.equal text.[i + 1] '/' then
        advance (take_while text i (fun c -> not (Char.equal c '\n')) Comment runs)
      else if i + 1 < limit && Char.equal ch '/' && Char.equal text.[i + 1] '*' then
        advance (take_c_block_comment text i runs)
      else if Char.equal ch '"' then advance (take_quoted ~quote:'"' text i runs)
      else if Char.equal ch '\'' then advance (take_quoted ~quote:'\'' text i runs)
      else if Char.equal ch '`' then advance (take_quoted ~quote:'`' text i runs)
      else if is_identifier_start ch then
        advance (take_identifier ~is_reserved:is_c_like_reserved text i runs)
      else if is_digit ch then advance (take_number text i runs)
      else begin
        runs_add runs Plain ch;
        advance (i + 1)
      end
  in
  advance 0;
  runs_segments runs

let python_reserved =
  [
    "and"; "as"; "assert"; "async"; "await"; "break"; "case"; "class";
    "continue"; "def"; "del"; "elif"; "else"; "except"; "False"; "finally";
    "for"; "from"; "global"; "if"; "import"; "in"; "is"; "lambda"; "match";
    "None"; "nonlocal"; "not"; "or"; "pass"; "raise"; "return"; "True"; "try";
    "while"; "with"; "yield";
  ]

let is_python_reserved w = List.exists (String.equal w) python_reserved

let take_triple ~quote text index runs =
  let limit = String.length text in
  for _ = 1 to 3 do
    runs_add runs String quote
  done;
  let rec advance i =
    if i >= limit then i
    else if
      i + 3 <= limit
      && Char.equal text.[i] quote
      && Char.equal text.[i + 1] quote
      && Char.equal text.[i + 2] quote
    then begin
      for _ = 1 to 3 do
        runs_add runs String quote
      done;
      i + 3
    end
    else begin
      runs_add runs String text.[i];
      advance (i + 1)
    end
  in
  advance (index + 3)

let python_lexer text =
  let runs = new_runs Plain in
  let limit = String.length text in
  let is_triple i q =
    i + 3 <= limit
    && Char.equal text.[i] q
    && Char.equal text.[i + 1] q
    && Char.equal text.[i + 2] q
  in
  let rec advance i =
    if i >= limit then ()
    else
      let ch = text.[i] in
      if Char.equal ch '#' then
        advance (take_while text i (fun c -> not (Char.equal c '\n')) Comment runs)
      else if is_triple i '"' then advance (take_triple ~quote:'"' text i runs)
      else if is_triple i '\'' then advance (take_triple ~quote:'\'' text i runs)
      else if Char.equal ch '"' then advance (take_quoted ~quote:'"' text i runs)
      else if Char.equal ch '\'' then advance (take_quoted ~quote:'\'' text i runs)
      else if is_identifier_start ch then
        advance (take_identifier ~is_reserved:is_python_reserved text i runs)
      else if is_digit ch then advance (take_number text i runs)
      else begin
        runs_add runs Plain ch;
        advance (i + 1)
      end
  in
  advance 0;
  runs_segments runs

let scalar_continues = function
  | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' -> true
  | '_' | '.' | '-' | '/' | '@' | '+' | '%' | '~' -> true
  | _ -> false

let number_begins_at text i =
  is_digit text.[i] && (i = 0 || not (scalar_continues text.[i - 1]))

let config_literals = [ "true"; "false"; "null" ]

let literal_at text i =
  let limit = String.length text in
  if i > 0 && scalar_continues text.[i - 1] then None
  else
    List.find_opt
      (fun w ->
        starts_at text i w
        &&
        let after = i + String.length w in
        after >= limit || not (scalar_continues text.[after]))
      config_literals

let line_content_start ~list_marker text line_start =
  let limit = String.length text in
  let rec skip i =
    if i >= limit then i
    else
      match text.[i] with
      | ' ' | '\t' -> skip (i + 1)
      | '-'
        when list_marker
             && i + 1 < limit
             && (Char.equal text.[i + 1] ' ' || Char.equal text.[i + 1] '\t') ->
          skip (i + 2)
      | _ -> i
  in
  skip line_start

let key_end ~delimiter text index =
  let limit = String.length text in
  let rec word i =
    if
      i < limit
      && (is_identifier_char text.[i]
         || Char.equal text.[i] '-'
         || Char.equal text.[i] '.')
    then word (i + 1)
    else i
  in
  let stop = word index in
  let rec spaces i =
    if i < limit && (Char.equal text.[i] ' ' || Char.equal text.[i] '\t') then
      spaces (i + 1)
    else i
  in
  let after = spaces stop in
  if stop > index && after < limit && Char.equal text.[after] delimiter then
    Some stop
  else None

let yaml_lexer text =
  let runs = new_runs Plain in
  let limit = String.length text in
  let line_start = ref 0 in
  let rec advance i =
    if i >= limit then ()
    else
      let ch = text.[i] in
      if Char.equal ch '\n' then begin
        runs_add runs Plain '\n';
        line_start := i + 1;
        advance (i + 1)
      end
      else if
        Char.equal ch '#'
        && (i = !line_start || Char.equal text.[i - 1] ' ' || Char.equal text.[i - 1] '\t')
      then
        advance (take_while text i (fun c -> not (Char.equal c '\n')) Comment runs)
      else if Char.equal ch '"' then advance (take_quoted ~quote:'"' text i runs)
      else if Char.equal ch '\'' then advance (take_quoted ~quote:'\'' text i runs)
      else if i = line_content_start ~list_marker:true text !line_start then
        match key_end ~delimiter:':' text i with
        | Some stop ->
            paint ~kind:Type_or_ctor text i stop runs;
            advance stop
        | None ->
            runs_add runs Plain ch;
            advance (i + 1)
      else if number_begins_at text i then advance (take_number text i runs)
      else
        match literal_at text i with
        | Some w ->
            runs_add_string runs Number w;
            advance (i + String.length w)
        | None ->
            runs_add runs Plain ch;
            advance (i + 1)
  in
  advance 0;
  runs_segments runs

let toml_lexer text =
  let runs = new_runs Plain in
  let limit = String.length text in
  let line_start = ref 0 in
  let rec advance i =
    if i >= limit then ()
    else
      let ch = text.[i] in
      if Char.equal ch '\n' then begin
        runs_add runs Plain '\n';
        line_start := i + 1;
        advance (i + 1)
      end
      else if Char.equal ch '#' then
        advance (take_while text i (fun c -> not (Char.equal c '\n')) Comment runs)
      else if Char.equal ch '"' then advance (take_quoted ~quote:'"' text i runs)
      else if Char.equal ch '\'' then advance (take_quoted ~quote:'\'' text i runs)
      else if
        Char.equal ch '['
        && i = line_content_start ~list_marker:false text !line_start
      then
        advance (take_while text i (fun c -> not (Char.equal c '\n')) Keyword runs)
      else if i = line_content_start ~list_marker:false text !line_start then
        match key_end ~delimiter:'=' text i with
        | Some stop ->
            paint ~kind:Type_or_ctor text i stop runs;
            advance stop
        | None ->
            runs_add runs Plain ch;
            advance (i + 1)
      else if number_begins_at text i then advance (take_number text i runs)
      else
        match literal_at text i with
        | Some w ->
            runs_add_string runs Number w;
            advance (i + String.length w)
        | None ->
            runs_add runs Plain ch;
            advance (i + 1)
  in
  advance 0;
  runs_segments runs

let sql_reserved =
  [
    "add"; "all"; "alter"; "and"; "as"; "asc"; "begin"; "between"; "by";
    "case"; "cast"; "commit"; "constraint"; "create"; "cross"; "delete";
    "desc"; "distinct"; "drop"; "else"; "end"; "except"; "exists"; "from";
    "full"; "group"; "having"; "in"; "index"; "inner"; "insert"; "intersect";
    "into"; "is"; "join"; "left"; "like"; "limit"; "not"; "null"; "offset";
    "on"; "or"; "order"; "outer"; "primary"; "references"; "returning";
    "right"; "rollback"; "select"; "set"; "table"; "then"; "union"; "unique";
    "update"; "using"; "values"; "view"; "when"; "where"; "with";
  ]

let is_sql_reserved w =
  List.exists (String.equal (String.lowercase_ascii w)) sql_reserved

let sql_lexer text =
  let runs = new_runs Plain in
  let limit = String.length text in
  let rec advance i =
    if i >= limit then ()
    else
      let ch = text.[i] in
      if starts_at text i "--" then
        advance (take_while text i (fun c -> not (Char.equal c '\n')) Comment runs)
      else if starts_at text i "/*" then advance (take_c_block_comment text i runs)
      else if Char.equal ch '\'' then advance (take_quoted ~quote:'\'' text i runs)
      else if Char.equal ch '"' then begin
        runs_add runs Type_or_ctor '"';
        let stop =
          take_while text (i + 1)
            (fun c -> not (Char.equal c '"') && not (Char.equal c '\n'))
            Type_or_ctor runs
        in
        if stop < limit && Char.equal text.[stop] '"' then begin
          runs_add runs Type_or_ctor '"';
          advance (stop + 1)
        end
        else advance stop
      end
      else if is_digit ch then advance (take_number text i runs)
      else if is_identifier_start ch then
        advance (take_identifier ~is_reserved:is_sql_reserved text i runs)
      else begin
        runs_add runs Plain ch;
        advance (i + 1)
      end
  in
  advance 0;
  runs_segments runs

let rows_of_segments segments =
  let rev_rows : segment list list ref = ref [ [] ] in
  List.iter
    (fun { text; kind } ->
      List.iteri
        (fun idx piece ->
          if idx > 0 then rev_rows := [] :: !rev_rows;
          match !rev_rows with
          | hd :: tl -> rev_rows := ({ text = piece; kind } :: hd) :: tl
          | [] -> rev_rows := [ [ { text = piece; kind } ] ])
        (String.split_on_char '\n' text))
    segments;
  List.rev_map List.rev !rev_rows

let diff_line_kind line =
  let len = String.length line in
  if len = 0 then Plain
  else if len >= 3 && (starts_at line 0 "+++" || starts_at line 0 "---") then Plain
  else
    match line.[0] with
    | '+' -> Diff_added
    | '-' -> Diff_removed
    | '@' -> Diff_hunk
    | _ -> Plain

let diff_lexer ?sub text =
  let runs = new_runs Plain in
  let lines = String.split_on_char '\n' text in
  let count = List.length lines in
  List.iteri
    (fun idx line ->
      let kind = diff_line_kind line in
      (match (sub, kind) with
       | Some sub_lex, (Diff_added | Diff_removed) when String.length line > 1 ->
           runs_add runs kind line.[0];
           let body = String.sub line 1 (String.length line - 1) in
           let pieces = sub_lex body in
           List.iter
             (fun (seg : segment) ->
               let k =
                 match seg.kind with
                 | Plain -> kind
                 | ( Keyword
                   | String
                   | Comment
                   | Number
                   | Type_or_ctor
                   | Json_key
                   | Json_number
                   | Json_literal
                   | Json_punctuation
                   | Diff_added
                   | Diff_removed
                   | Diff_hunk ) as specific ->
                     specific
               in
               runs_add_string runs k seg.text)
             pieces
       | None, _
       | Some _, (Diff_added | Diff_removed)
       | Some _,
           ( Plain
           | Keyword
           | String
           | Comment
           | Number
           | Type_or_ctor
           | Json_key
           | Json_number
           | Json_literal
           | Json_punctuation
           | Diff_hunk ) ->
           runs_add_string runs kind line);
      if idx < count - 1 then runs_add runs Plain '\n')
    lines;
  runs_segments runs

let markdown_source_lexer text =
  let runs = new_runs Plain in
  let lines = String.split_on_char '\n' text in
  let count = List.length lines in
  List.iteri
    (fun idx line ->
      let trimmed = String.trim line in
      let kind =
        if String.length trimmed = 0 then Plain
        else if Char.equal trimmed.[0] '#' then Type_or_ctor
        else if starts_at trimmed 0 "```" || starts_at trimmed 0 "~~~" then Keyword
        else if Char.equal trimmed.[0] '>' then Keyword
        else if starts_at trimmed 0 "<!--" then Comment
        else Plain
      in
      runs_add_string runs kind line;
      if idx < count - 1 then runs_add runs Plain '\n')
    lines;
  runs_segments runs

let rec language_of_tag raw =
  let tag = String.lowercase_ascii (String.trim raw) in
  match String.index_opt tag ':' with
  | Some colon
    when String.equal (String.trim (String.sub tag 0 colon)) "diff" -> (
      let sub =
        String.trim (String.sub tag (colon + 1) (String.length tag - colon - 1))
      in
      match sub with
      | "" | "diff" | "patch" -> Some (Diff None)
      | other -> Some (Diff (language_of_tag other)))
  | Some _ | None -> (
      match tag with
      | "ocaml" | "ml" | "mli" -> Some Ocaml
      | "bash" | "sh" | "shell" | "zsh" -> Some Bash
      | "json" -> Some Json
      | "diff" | "patch" -> Some (Diff None)
      | "yaml" | "yml" -> Some Yaml
      | "toml" -> Some Toml
      | "sql" -> Some Sql
      | "c_like" | "typescript" | "ts" | "javascript" | "js" | "tsx" | "jsx"
      | "go" | "rust" | "rs" | "c" | "cpp" | "java" | "kotlin" | "swift"
      | "scala" | "php" | "dart" ->
          Some C_like
      | "python" | "py" -> Some Python
      | "markdown" | "md" -> Some Markdown
      | _ -> None)

let language_of_path path =
  let lower = String.lowercase_ascii path in
  let has suffix = Filename.check_suffix lower suffix in
  if has ".ml" || has ".mli" then Some Ocaml
  else if has ".sh" || has ".bash" || has ".zsh" then Some Bash
  else if has ".json" then Some Json
  else if has ".yaml" || has ".yml" then Some Yaml
  else if has ".toml" then Some Toml
  else if has ".sql" then Some Sql
  else if has ".py" then Some Python
  else if has ".md" || has ".markdown" then Some Markdown
  else if has ".patch" || has ".diff" then Some (Diff None)
  else if
    has ".ts" || has ".tsx" || has ".js" || has ".jsx" || has ".mjs"
    || has ".cjs" || has ".c" || has ".h" || has ".cpp" || has ".cc"
    || has ".hpp" || has ".go" || has ".rs" || has ".java" || has ".kt"
    || has ".swift" || has ".scala" || has ".php" || has ".dart"
  then Some C_like
  else None

let rec lex lang text =
  match lang with
  | Ocaml -> ocaml_lexer text
  | Bash -> bash_lexer text
  | Json -> json_lexer text
  | Diff None -> diff_lexer text
  | Diff (Some sub_lang) -> diff_lexer ~sub:(lex sub_lang) text
  | Yaml -> yaml_lexer text
  | Toml -> toml_lexer text
  | Sql -> sql_lexer text
  | C_like -> c_like_lexer text
  | Python -> python_lexer text
  | Markdown -> markdown_source_lexer text

let normalize_crlf text =
  if not (String.contains text '\r') then text
  else
    let len = String.length text in
    let buf = Buffer.create len in
    for i = 0 to len - 1 do
      if not (Char.equal text.[i] '\r' && i + 1 < len && Char.equal text.[i + 1] '\n')
      then Buffer.add_char buf text.[i]
    done;
    Buffer.contents buf

let rows_of_source ~language text =
  let clean = normalize_crlf text in
  let segs =
    match language with
    | Some lang -> lex lang clean
    | None -> [ { text = clean; kind = Plain } ]
  in
  rows_of_segments segs

let row_has_assignment row =
  List.exists
    (fun (seg : segment) ->
      equal_token_kind seg.kind Plain && String.contains seg.text '=')
    row

let style_of_token ~(theme : Theme.t) ~bg = function
  | Plain -> Style.make ~fg:(Color.of_rgb theme.text_primary) ~bg ()
  | Keyword -> Style.make ~fg:(Color.of_rgb theme.accent) ~bg ~attrs:Attr.bold ()
  | String -> Style.make ~fg:(Color.of_rgb theme.status_ok) ~bg ()
  | Comment -> Style.make ~fg:(Color.of_rgb theme.text_muted) ~bg ~attrs:Attr.italic ()
  | Number | Json_number -> Style.make ~fg:(Color.of_rgb theme.status_attention) ~bg ()
  | Type_or_ctor | Json_key -> Style.make ~fg:(Color.of_rgb theme.status_active) ~bg ()
  | Json_literal -> Style.make ~fg:(Color.of_rgb theme.accent) ~bg ~attrs:Attr.bold ()
  | Json_punctuation -> Style.make ~fg:(Color.of_rgb theme.text_muted) ~bg ()
  | Diff_added -> Style.make ~fg:(Color.of_rgb theme.status_ok) ~bg ()
  | Diff_removed -> Style.make ~fg:(Color.of_rgb theme.status_critical) ~bg ()
  | Diff_hunk -> Style.make ~fg:(Color.of_rgb theme.status_active) ~bg ~attrs:Attr.bold ()

let draw_row ?clip grid ~x ~y ~max_w ~theme ~bg segments =
  if max_w <= 0 then 0
  else
    let row_clip =
      let own = Rect.make ~x ~y ~w:max_w ~h:1 in
      match clip with Some c -> Rect.intersect c own | None -> own
    in
    let cx = ref x in
    let limit = x + max_w in
    List.iter
      (fun (seg : segment) ->
        if !cx < limit && String.length seg.text > 0 then begin
          let style = style_of_token ~theme ~bg seg.kind in
          let adv = Cell_grid.put_text ~clip:row_clip grid ~x:!cx ~y ~style seg.text in
          cx := !cx + adv
        end)
      segments;
    !cx - x
