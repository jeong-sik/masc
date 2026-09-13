(* Comment-preserving, line-based TOML editing.

   TOML round-tripping through a parser drops comments (Otoml discards them at the
   lexer and has no comment AST node), so any edit that regenerates the file from
   a parsed value destroys operator documentation. This module edits the original
   text at line granularity: it locates a target table by header, replaces or
   appends exactly the key line(s) being changed, and passes every other line —
   comments, blanks, other keys, other tables — through unchanged.

   The primitives originate from the runtime.toml routing/assignment editor in
   [Runtime]; they are hoisted here as the single home for comment-preserving TOML
   editing (RFC-0306 §3.2) so the fusion settings writer can reuse them without
   depending on the runtime library. [Runtime] delegates to these. *)

(* ── string / line helpers ─────────────────────────────────────────────── *)

let escape_string s =
  let buf = Buffer.create (String.length s) in
  String.iter
    (function
      | '"' -> Buffer.add_string buf "\\\""
      | '\\' -> Buffer.add_string buf "\\\\"
      | '\n' -> Buffer.add_string buf "\\n"
      | '\r' -> Buffer.add_string buf "\\r"
      | '\t' -> Buffer.add_string buf "\\t"
      | c when Char.code c < 0x20 || Char.code c = 0x7f ->
        (* TOML refuses a raw control character inside a basic string, so a
           value carrying one would kill the line it lands on. *)
        Buffer.add_string buf (Printf.sprintf "\\u%04X" (Char.code c))
      | c -> Buffer.add_char buf c)
    s;
  Buffer.contents buf
;;

(* A TOML bare key is letters, digits, underscore and dash. Anything else has
   to be quoted, and a dot most of all: [edgar.a.poe = "Yuna"] is not one key
   with dots in it, it is a path into nested tables, so the mapping written is
   not the mapping meant and the read-back refuses it.

   {!key_of_line} has always understood a quoted key. Only the writing side
   never produced one, so a key that needed quotes could not round-trip. *)
let render_key key =
  let bare_char = function
    | 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '_' | '-' -> true
    | _ -> false
  in
  if key <> "" && String.for_all bare_char key
  then key
  else Printf.sprintf "\"%s\"" (escape_string key)
;;

let scalar_line ~key ~value =
  Printf.sprintf "%s = \"%s\"" (render_key key) (escape_string value)
;;

(* Single-line array rendering (used by the runtime string-array editor). Fusion
   multi-line arrays are rendered by [multiline_array_lines]. *)
let string_array_line ~key ~values =
  let rendered =
    values
    |> List.map (fun value -> Printf.sprintf "\"%s\"" (escape_string value))
    |> String.concat ", "
  in
  Printf.sprintf "%s = [%s]" (render_key key) rendered
;;

(* Multi-line array block: [key = \[], one indented quoted element per line, then
   a closing []]. Mirrors the checked-in runtime.toml panel layout. *)
let multiline_array_lines ~key ~values =
  let elements =
    List.map (fun value -> Printf.sprintf "  \"%s\"," (escape_string value)) values
  in
  (Printf.sprintf "%s = [" (render_key key) :: elements) @ [ "]" ]
;;

let split_lines content =
  if String.equal content "" then [], false
  else (
    let len = String.length content in
    let trailing_newline = Char.equal content.[len - 1] '\n' in
    let parts = String.split_on_char '\n' content in
    let lines =
      if trailing_newline
      then (
        match List.rev parts with
        | "" :: rest -> List.rev rest
        | _ -> parts)
      else parts
    in
    lines, trailing_newline)
;;

let join_lines lines ~trailing_newline =
  match lines with
  | [] -> if trailing_newline then "\n" else ""
  | _ ->
    let body = String.concat "\n" lines in
    if trailing_newline then body ^ "\n" else body
;;

(* ── table headers ─────────────────────────────────────────────────────── *)

(* A table header by the key path the TOML grammar reads out of it. [\[a.b\]]
   and [\[\[a.b\]\]] carry the same path and mean different things to a
   loader, so they are kept apart. *)
type header =
  | Table of string list
  | Table_array of string list

let equal_header a b =
  match a, b with
  | Table x, Table y | Table_array x, Table_array y -> List.equal String.equal x y
  | Table _, Table_array _ | Table_array _, Table _ -> false
;;

(* A line is a table header when it parses on its own as a TOML document
   whose only content is one empty table. [\[egress.keepers.alder\]],
   [\[ egress . keepers . "alder" \]] and [\[egress.keepers.'alder'\] # note]
   all read as the path egress, keepers, alder and nothing else; the spelling
   (whitespace inside the brackets or around the dots, quoted or bare keys, a
   trailing comment) is the grammar's to decide, which is what keeps this
   editor and the loader agreeing on which table a line opens.

   A line that does not parse alone is not a header. Headers are one line in
   TOML, so a continuation line of a multi-line array or string cannot be one,
   and the parser's message has nothing to add to that. *)
let header_of_line line =
  (* A CRLF file leaves a \r on every line, and the parser reads that as part
     of the header rather than as the line ending it is. *)
  let line = String.trim line in
  let rec walk acc = function
    | Otoml.TomlTable [ (key, child) ] ->
      (match child with
       | Otoml.TomlTable [] -> Some (Table (List.rev (key :: acc)))
       | Otoml.TomlTableArray [] -> Some (Table_array (List.rev (key :: acc)))
       | Otoml.TomlTable (_ :: _) -> walk (key :: acc) child
       | Otoml.TomlTableArray (_ :: _)
       | Otoml.TomlInlineTable _
       | Otoml.TomlArray _
       | Otoml.TomlString _
       | Otoml.TomlInteger _
       | Otoml.TomlFloat _
       | Otoml.TomlBoolean _
       | Otoml.TomlOffsetDateTime _
       | Otoml.TomlLocalDateTime _
       | Otoml.TomlLocalDate _
       | Otoml.TomlLocalTime _ -> None)
    | Otoml.TomlTable ([] | _ :: _ :: _)
    | Otoml.TomlInlineTable _
    | Otoml.TomlTableArray _
    | Otoml.TomlArray _
    | Otoml.TomlString _
    | Otoml.TomlInteger _
    | Otoml.TomlFloat _
    | Otoml.TomlBoolean _
    | Otoml.TomlOffsetDateTime _
    | Otoml.TomlLocalDateTime _
    | Otoml.TomlLocalDate _
    | Otoml.TomlLocalTime _ -> None
  in
  match Otoml.Parser.from_string_result line with
  | Ok document -> walk [] document
  | Error _not_a_document_on_its_own -> None
;;

let is_table_header line =
  match header_of_line line with
  | Some (Table _ | Table_array _) -> true
  | None -> false
;;

(* [is_table ~path line]: [line] opens the standard table [\[path\]]. [path] is
   the text between the brackets as a writer emits it, so the grammar reads it
   the way it reads the line: a quoted segment is one key and a bare dotted
   one is a nested path, in both. A [path] that is not itself a header opens
   no line, and the table a writer then appends carries that same text. *)
let is_table ~path line =
  match header_of_line (Printf.sprintf "[%s]" path), header_of_line line with
  | Some expected, Some found -> equal_header expected found
  | Some _, None | None, Some _ | None, None -> false
;;

let rec split_at n xs =
  if n <= 0 then [], xs
  else
    match xs with
    | [] -> [], []
    | x :: rest ->
      let before, after = split_at (n - 1) rest in
      x :: before, after
;;

let find_index pred xs =
  let rec loop index = function
    | [] -> None
    | x :: rest -> if pred x then Some index else loop (index + 1) rest
  in
  loop 0 xs
;;

let parse_quoted_key raw =
  let len = String.length raw in
  if len < 2 || not (Char.equal raw.[0] '"') then None
  else (
    let buf = Buffer.create len in
    let rec loop index =
      if index >= len then None
      else
        match raw.[index] with
        | '"' -> Some (Buffer.contents buf)
        | '\\' when index + 1 < len ->
          let escaped =
            match raw.[index + 1] with
            | '"' -> '"'
            | '\\' -> '\\'
            | 'n' -> '\n'
            | 'r' -> '\r'
            | 't' -> '\t'
            | c -> c
          in
          Buffer.add_char buf escaped;
          loop (index + 2)
        | c ->
          Buffer.add_char buf c;
          loop (index + 1)
    in
    loop 1)
;;

let parse_literal_key raw =
  let len = String.length raw in
  if len < 2 || not (Char.equal raw.[0] '\'') then None
  else (
    match String.index_from_opt raw 1 '\'' with
    | None -> None
    | Some end_index -> Some (String.sub raw 1 (end_index - 1)))
;;

(* [key_of_line line] is the bare key of a [key = value] line, or [None] for
   comments, blanks, and non-assignment lines. Quoted/literal keys are unescaped.
   Comment and blank lines return [None], so editors never match them. *)
let key_of_line line =
  let trimmed = String.trim line in
  if String.equal trimmed "" || Char.equal trimmed.[0] '#'
  then None
  else (
    match String.index_opt trimmed '=' with
    | None -> None
    | Some eq_index ->
      let key_part = String.sub trimmed 0 eq_index |> String.trim in
      if String.equal key_part ""
      then None
      else if Char.equal key_part.[0] '"'
      then parse_quoted_key key_part
      else if Char.equal key_part.[0] '\''
      then parse_literal_key key_part
      else Some key_part)
;;

(* ── section-scoped edits ───────────────────────────────────────────────── *)

(* [with_table content ~path ~on_missing ~edit] locates the [\[path\]] table,
   splits it into (before, header, section_lines, after), runs [edit] on the
   section body (the lines up to the next table header of any kind, including
   array-of-tables), and reassembles. [on_missing] produces the whole updated
   line list when the table is absent. Trailing newline is normalized to true,
   matching the runtime editor. *)
(* ── which lines carry structure ───────────────────────────────────────── *)

(* A line-based editor has to know which lines it may read as structure. A TOML
   value can span lines in three shapes -- a triple-double-quoted string, a
   triple-single-quoted string, and a bracketed array -- and a line inside one
   of them looks exactly like a header or an assignment. A multi-line string
   carrying the text [voice.stt.fallback] on a line of its own reads as a table
   header to anything that looks at lines alone.

   Ending a section at such a line ends it in the wrong place. Reading an
   assignment inside such a string as a key is worse: the edit lands inside the
   string literal, the file still parses, and the loader keeps the old value,
   so the setting reads as saved and does not take. Both were measured against
   this module before this scanner existed.

   The scanner tracks only what it takes to answer one question: may this line
   be read as structure. It is not a TOML parser and does not try to be one. *)

type quote =
  | Basic (* inside a triple-double-quoted string *)
  | Literal (* inside a triple-single-quoted string *)

type scan =
  { quote : quote option
  ; depth : int (* open brackets of an array whose value continues *)
  }

let outside = { quote = None; depth = 0 }

(* A line may be read as structure when no value from an earlier line is still
   open across it. *)
let is_structural state = Option.is_none state.quote && state.depth = 0

let skip_basic_string line index =
  let length = String.length line in
  let rec loop index =
    if index >= length
    then index
    else (
      match line.[index] with
      | '\\' -> loop (index + 2)
      | '"' -> index + 1
      | _ -> loop (index + 1))
  in
  loop index
;;

let skip_literal_string line index =
  let length = String.length line in
  let rec loop index =
    if index >= length
    then index
    else if Char.equal line.[index] '\''
    then index + 1
    else loop (index + 1)
  in
  loop index
;;

(* The state [line] leaves behind, given the state it started in. A header line
   is returned unchanged: its brackets open a table, not an array, and counting
   them as array depth would swallow the rest of the file. *)
let scan_line state line =
  if is_structural state && is_table_header line
  then state
  else (
    let length = String.length line in
    let at index needle =
      index + String.length needle <= length
      && String.equal (String.sub line index (String.length needle)) needle
    in
    let rec walk index state =
      if index >= length
      then state
      else (
        match state.quote with
        | Some Basic ->
          if at index {|"""|}
          then walk (index + 3) { state with quote = None }
          else if Char.equal line.[index] '\\'
          then walk (index + 2) state
          else walk (index + 1) state
        | Some Literal ->
          if at index "'''"
          then walk (index + 3) { state with quote = None }
          else walk (index + 1) state
        | None ->
          (match line.[index] with
           (* A comment runs to the end of the line, inside an array too. *)
           | '#' -> state
           | '"' when at index {|"""|} -> walk (index + 3) { state with quote = Some Basic }
           | '\'' when at index "'''" -> walk (index + 3) { state with quote = Some Literal }
           | '"' -> walk (skip_basic_string line (index + 1)) state
           | '\'' -> walk (skip_literal_string line (index + 1)) state
           | '[' -> walk (index + 1) { state with depth = state.depth + 1 }
           | ']' -> walk (index + 1) { state with depth = max 0 (state.depth - 1) }
           | _ -> walk (index + 1) state))
    in
    walk 0 state)
;;

(* [find_structural_index pred lines] is {!find_index} restricted to lines that
   carry structure, so a match inside a multi-line value is not one. *)
let find_structural_index pred lines =
  let rec loop index state = function
    | [] -> None
    | line :: rest ->
      if is_structural state && pred line
      then Some index
      else loop (index + 1) (scan_line state line) rest
  in
  loop 0 outside lines
;;



(* ── typed values ─────────────────────────────────────────────────────── *)

type value =
  | String of string
  | Int of int
  | Float of float
  | Bool of bool

(* The shortest spelling that reads back as the same float. [%.17g] round-trips
   every double but renders 0.1 as 0.10000000000000001, so precision climbs
   until the rendering parses back equal. [nan] never compares equal to itself
   and falls through to the 17-digit form, which is spelled [nan] either way. *)
let float_text v =
  let rec shortest precision =
    if precision > 17
    then Printf.sprintf "%.17g" v
    else (
      let rendered = Printf.sprintf "%.*g" precision v in
      match float_of_string_opt rendered with
      | Some parsed when Float.equal parsed v -> rendered
      | Some _ | None -> shortest (precision + 1))
  in
  let rendered = shortest 1 in
  let has character = String.exists (Char.equal character) rendered in
  (* A float rendered without a point or exponent reads back as an integer, and
     a field declared float is then refused by type. [nan] and [inf] carry no
     point and must not gain one. *)
  if has '.' || has 'e' || has 'E' || has 'n' || has 'i' then rendered else rendered ^ ".0"
;;

let value_line ~key ~value =
  match value with
  | String v -> scalar_line ~key ~value:v
  | Int v -> Printf.sprintf "%s = %d" (render_key key) v
  | Float v -> Printf.sprintf "%s = %s" (render_key key) (float_text v)
  | Bool v -> Printf.sprintf "%s = %b" (render_key key) v
;;

(* ── section-scoped edits ───────────────────────────────────────────────── *)

(* [with_table content ~path ~on_missing ~edit] locates the [\[path\]] table,
   splits it into (before, header, section_lines, after), runs [edit] on the
   section body (the lines up to the next table header of any kind, including
   array-of-tables), and reassembles. [on_missing] produces the whole updated
   line list when the table is absent. Trailing newline is normalized to true,
   matching the runtime editor. *)
let with_table content ~path ~on_missing ~edit =
  let lines, _trailing = split_lines content in
  let updated =
    match find_structural_index (is_table ~path) lines with
    | None -> on_missing lines
    | Some header_index ->
      let before, from_header = split_at header_index lines in
      (match from_header with
       | [] -> on_missing lines
       | header :: after_header ->
         let section_lines, after_section =
           match find_structural_index is_table_header after_header with
           | None -> after_header, []
           | Some next -> split_at next after_header
         in
         before @ (header :: edit section_lines) @ after_section)
  in
  join_lines updated ~trailing_newline:true
;;

let has_key ~key line =
  match key_of_line line with
  | Some found -> String.equal found key
  | None -> false
;;

(* The lines left after the value opening on [opening] finishes. A value can run
   past its own line -- a bracketed array, a triple-quoted string -- and a
   replacement that took only the first line would leave the rest of the old
   value behind as loose text the loader cannot read. *)
let skip_value ~opening rest =
  let state = scan_line outside opening in
  if is_structural state
  then rest
  else (
    let rec consume state = function
      | [] -> []
      | line :: tail ->
        let next = scan_line state line in
        if is_structural next then tail else consume next tail
    in
    consume state rest)
;;

let replace_or_append_value section_lines ~key ~value =
  let line = value_line ~key ~value in
  match find_structural_index (has_key ~key) section_lines with
  | None -> section_lines @ [ line ]
  | Some index ->
    let before, from_key = split_at index section_lines in
    (match from_key with
     | [] -> before @ [ line ]
     | opening :: rest -> before @ (line :: skip_value ~opening rest))
;;

let remove_key section_lines ~key =
  match find_structural_index (has_key ~key) section_lines with
  | None -> section_lines
  | Some index ->
    let before, from_key = split_at index section_lines in
    (match from_key with
     | [] -> before
     | opening :: rest -> before @ skip_value ~opening rest)
;;

let edit_table_value content ~path ~key ~value =
  let append_table lines =
    match value with
    | None -> lines
    | Some value ->
      let section = [ Printf.sprintf "[%s]" path; value_line ~key ~value ] in
      (match List.rev lines with
       | [] -> section
       | last :: _ when String.equal (String.trim last) "" -> lines @ section
       | _ :: _ -> lines @ ("" :: section))
  in
  with_table content ~path ~on_missing:append_table ~edit:(fun section ->
    match value with
    | None -> remove_key section ~key
    | Some value -> replace_or_append_value section ~key ~value)
;;

let edit_table_scalar content ~path ~key ~value =
  edit_table_value content ~path ~key ~value:(Option.map (fun text -> String text) value)
;;

let edit_table_int content ~path ~key ~value =
  edit_table_value content ~path ~key ~value:(Some (Int value))
;;

let edit_table_bool content ~path ~key ~value =
  edit_table_value content ~path ~key ~value:(Some (Bool value))
;;

(* Replace (or append) a multi-line array inside a section. An existing
   single-line array collapses to the multi-line form; comments between array
   elements are not preserved (elements are data, RFC-0306 §7.1). Comments
   outside the value are untouched.

   The span ends where the scanner says the value closes, rather than at the
   first closing bracket outside a comment: a bracket can also sit inside a
   string element. *)
let replace_or_append_multiline_array section_lines ~key ~values =
  let block = multiline_array_lines ~key ~values in
  match find_structural_index (has_key ~key) section_lines with
  | None -> section_lines @ block
  | Some index ->
    let before, from_key = split_at index section_lines in
    (match from_key with
     | [] -> before @ block
     | opening :: rest -> before @ block @ skip_value ~opening rest)
;;

let edit_table_multiline_array content ~path ~key ~values =
  let append_table lines =
    let section = Printf.sprintf "[%s]" path :: multiline_array_lines ~key ~values in
    match List.rev lines with
    | [] -> section
    | last :: _ when String.equal (String.trim last) "" -> lines @ section
    | _ :: _ -> lines @ ("" :: section)
  in
  with_table content ~path ~on_missing:append_table ~edit:(fun section ->
    replace_or_append_multiline_array section ~key ~values)
;;

(* ── array-of-tables entries ───────────────────────────────────────────── *)

(* Endpoint lists are array-of-tables: [\[\[voice.tts.endpoints\]\]] repeated,
   each entry naming itself with an [id]. The scalar editors above address a
   table by path, which cannot separate one repeated entry from the next, so
   entries are addressed by the value of an identifying key instead. *)

type entry_error =
  | Inline_key_at_path of string
  | Standard_table_at_path of string

let entry_error_message = function
  | Inline_key_at_path path ->
    Printf.sprintf
      "%s is already assigned as a key in its parent table, so an entry cannot be \
       added under it: the file would refuse to load with \"table is duplicated by an \
       array of tables\""
      path
  | Standard_table_at_path path ->
    Printf.sprintf
      "%s already exists as a standard table, so an entry cannot be added under it: \
       the two spellings cannot both describe one path"
      path
;;

let is_table_array ~path line =
  match header_of_line (Printf.sprintf "[[%s]]" path), header_of_line line with
  | Some expected, Some found -> equal_header expected found
  | Some _, None | None, Some _ | None, None -> false
;;

let path_segments path =
  match header_of_line (Printf.sprintf "[%s]" path) with
  | Some (Table segments) | Some (Table_array segments) -> segments
  | None -> []
;;

let rec is_prefix prefix segments =
  match prefix, segments with
  | [], _ -> true
  | left :: rest_prefix, right :: rest_segments ->
    String.equal left right && is_prefix rest_prefix rest_segments
  | _ :: _, [] -> false
;;

(* A table opened below an entry and named under its path belongs to that entry:
   [\[a.b.headers\]] after [\[\[a.b\]\]] is that entry's headers table. Ending
   the entry at it costs both ways -- removing the entry would leave the
   sub-table behind, which the loader refuses outright, and appending a new
   entry would slot it above the sub-table, which loads cleanly and silently
   hands one entry's sub-table to another. *)
let is_entry_sub_table ~segments line =
  match header_of_line line with
  | Some (Table found) | Some (Table_array found) ->
    List.length found > List.length segments && is_prefix segments found
  | None -> false
;;

(* An entry body runs from just after its header to the next table header that
   is not one of its own sub-tables. *)
let split_entry_body ~segments lines =
  let ends line = is_table_header line && not (is_entry_sub_table ~segments line) in
  match find_structural_index ends lines with
  | None -> lines, []
  | Some next -> split_at next lines
;;

(* The value of a [key = value] line when it is a string, read by the same
   grammar as the headers so a quoted key, an escape, or a trailing comment is
   read here the way the loader reads it. *)
let string_value_of_line line =
  match Otoml.Parser.from_string_result (String.trim line) with
  | Ok (Otoml.TomlTable [ (_key, Otoml.TomlString value) ]) -> Some value
  | Ok _ | Error _ -> None
;;

let entry_id ~id_key body =
  match find_structural_index (has_key ~key:id_key) body with
  | None -> None
  | Some index ->
    (match snd (split_at index body) with
     | line :: _ -> string_value_of_line line
     | [] -> None)
;;

let entry_has_id ~id_key ~id body =
  match entry_id ~id_key body with
  | Some found -> String.equal found id
  | None -> false
;;

let table_array_entry_ids content ~path ~id_key =
  let lines, _trailing = split_lines content in
  let segments = path_segments path in
  let rec loop acc state = function
    | [] -> List.rev acc
    | line :: rest when is_structural state && is_table_array ~path line ->
      let body, after = split_entry_body ~segments rest in
      let acc =
        match entry_id ~id_key body with
        | Some id -> id :: acc
        | None -> acc
      in
      loop acc outside after
    | line :: rest -> loop acc (scan_line state line) rest
  in
  loop [] outside lines
;;

let trailing_blank_count lines =
  let rec loop count = function
    | line :: rest when String.equal (String.trim line) "" -> loop (count + 1) rest
    | _ :: _ | [] -> count
  in
  loop 0 (List.rev lines)
;;

(* The tail of an entry body that documents what comes after it: a comment block
   sitting just above the next header, plus the blanks between it and this
   entry. A comment directly above a header describes that header, so an entry
   appended below it would inherit a description written for something else, and
   removing an entry would take that description with it.

   Counted only when a comment is actually there. Trailing blanks alone belong
   to the entry -- they are what separates it from the next -- and treating them
   as detached would leave one behind on every add/remove round trip. *)
let trailing_documentation_count lines =
  let rec scan count saw_comment = function
    | line :: rest ->
      let trimmed = String.trim line in
      if String.equal trimmed ""
      then scan (count + 1) saw_comment rest
      else if Char.equal trimmed.[0] '#'
      then scan (count + 1) true rest
      else if saw_comment
      then count
      else 0
    | [] -> if saw_comment then count else 0
  in
  scan 0 false (List.rev lines)
;;

(* Insert [block] after the last [\[\[path\]\]] entry: past the blank lines that
   trail it, but before any comment block documenting the next header. Then
   repeat the trailing blanks below the new entry.

   The separator goes below rather than above so that adding an entry and
   removing it again restores the file byte-for-byte:
   {!remove_table_array_entry} takes an entry's trailing blanks with it, so an
   entry whose blanks sat above it would leave one behind on every round trip.

   With no entry present the block goes at the end of the file, separated by one
   blank line. *)
let append_table_array_entry lines ~segments ~path ~block =
  let rec last_entry_end index best state = function
    | [] -> best
    | line :: rest when is_structural state && is_table_array ~path line ->
      let body, after = split_entry_body ~segments rest in
      let after_index = index + 1 + List.length body in
      let insert_at = after_index - trailing_documentation_count body in
      last_entry_end after_index (Some (insert_at, trailing_blank_count body)) outside after
    | line :: rest -> last_entry_end (index + 1) best (scan_line state line) rest
  in
  match last_entry_end 0 None outside lines with
  | Some (insert_at, blanks) ->
    let before, after = split_at insert_at lines in
    before @ block @ List.init blanks (fun _ -> "") @ after
  | None ->
    (match List.rev lines with
     | [] -> block
     | last :: _ when String.equal (String.trim last) "" -> lines @ block
     | _ :: _ -> lines @ ("" :: block))
;;

(* The path a new [\[\[a.b\]\]] would open must not already exist in another
   shape. A key [b] in table [a] -- which is how an empty endpoint list is
   spelled today -- or a standard table [\[a.b\]] both make the file refuse to
   load, and a line editor cannot merge two shapes into one. *)
let path_conflict lines ~path =
  let segments = path_segments path in
  let standard_table line =
    match header_of_line line with
    | Some (Table found) -> List.equal String.equal found segments
    | Some (Table_array _) | None -> false
  in
  if Option.is_some (find_structural_index standard_table lines)
  then Some (Standard_table_at_path path)
  else (
    match List.rev segments with
    | [] | [ _ ] -> None
    | key :: reversed_parent ->
      let parent = List.rev reversed_parent in
      let parent_header line =
        match header_of_line line with
        | Some (Table found) -> List.equal String.equal found parent
        | Some (Table_array _) | None -> false
      in
      (match find_structural_index parent_header lines with
       | None -> None
       | Some index ->
         (match snd (split_at index lines) with
          | [] -> None
          | _header :: after ->
            let body =
              match find_structural_index is_table_header after with
              | None -> after
              | Some next -> fst (split_at next after)
            in
            if Option.is_some (find_structural_index (has_key ~key) body)
            then Some (Inline_key_at_path path)
            else None)))
;;

let upsert_table_array_entry content ~path ~id_key ~id ~fields =
  let lines, _trailing = split_lines content in
  match path_conflict lines ~path with
  | Some error -> Error error
  | None ->
    let segments = path_segments path in
    (* [id] is the entry's identity; a second spelling of it in [fields] could
       disagree with the entry this call just addressed. *)
    let fields = List.filter (fun (key, _) -> not (String.equal key id_key)) fields in
    let set_fields body =
      List.fold_left
        (fun body (key, value) ->
          match value with
          | Some value -> replace_or_append_value body ~key ~value
          | None -> remove_key body ~key)
        body
        fields
    in
    let rec edit acc found state = function
      | [] -> List.rev acc, found
      | line :: rest when is_structural state && is_table_array ~path line ->
        let body, after = split_entry_body ~segments rest in
        let body, found =
          if entry_has_id ~id_key ~id body then set_fields body, true else body, found
        in
        edit (List.rev_append body (line :: acc)) found outside after
      | line :: rest -> edit (line :: acc) found (scan_line state line) rest
    in
    let edited, found = edit [] false outside lines in
    let updated =
      if found
      then edited
      else (
        let block =
          Printf.sprintf "[[%s]]" path
          :: value_line ~key:id_key ~value:(String id)
          :: List.filter_map
               (fun (key, value) -> Option.map (fun value -> value_line ~key ~value) value)
               fields
        in
        append_table_array_entry edited ~segments ~path ~block)
    in
    Ok (join_lines updated ~trailing_newline:true)
;;

let remove_table_array_entry content ~path ~id_key ~id =
  let lines, _trailing = split_lines content in
  let segments = path_segments path in
  let rec loop acc state = function
    | [] -> List.rev acc
    | line :: rest when is_structural state && is_table_array ~path line ->
      let body, after = split_entry_body ~segments rest in
      if entry_has_id ~id_key ~id body
      then (
        (* A comment block documenting the next header is not this entry's to
           take. *)
        let documented = trailing_documentation_count body in
        let kept = snd (split_at (List.length body - documented) body) in
        loop (List.rev_append kept acc) outside after)
      else loop (List.rev_append body (line :: acc)) outside after
    | line :: rest -> loop (line :: acc) (scan_line state line) rest
  in
  join_lines (loop [] outside lines) ~trailing_newline:true
;;
