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
      | c -> Buffer.add_char buf c)
    s;
  Buffer.contents buf
;;

let scalar_line ~key ~value = Printf.sprintf "%s = \"%s\"" key (escape_string value)

(* Single-line array rendering (used by the runtime string-array editor). Fusion
   multi-line arrays are rendered by [multiline_array_lines]. *)
let string_array_line ~key ~values =
  let rendered =
    values
    |> List.map (fun value -> Printf.sprintf "\"%s\"" (escape_string value))
    |> String.concat ", "
  in
  Printf.sprintf "%s = [%s]" key rendered
;;

(* Multi-line array block: [key = \[], one indented quoted element per line, then
   a closing []]. Mirrors the checked-in runtime.toml panel layout. *)
let multiline_array_lines ~key ~values =
  let elements =
    List.map (fun value -> Printf.sprintf "  \"%s\"," (escape_string value)) values
  in
  (Printf.sprintf "%s = [" key :: elements) @ [ "]" ]
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

let strip_comment line =
  match String.index_opt line '#' with
  | None -> line
  | Some index -> String.sub line 0 index
;;

let is_table_header line =
  let s = line |> strip_comment |> String.trim in
  let len = String.length s in
  len >= 2 && Char.equal s.[0] '[' && Char.equal s.[len - 1] ']'
;;

(* [is_table ~path line] matches the standard table header [\[path\]] exactly
   (comments/whitespace ignored). *)
let is_table ~path line =
  String.equal (line |> strip_comment |> String.trim) (Printf.sprintf "[%s]" path)
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
let with_table content ~path ~on_missing ~edit =
  let lines, _trailing = split_lines content in
  let updated =
    match find_index (is_table ~path) lines with
    | None -> on_missing lines
    | Some header_index ->
      let before, from_header = split_at header_index lines in
      (match from_header with
       | [] -> on_missing lines
       | header :: after_header ->
         let section_lines, after_section =
           match find_index is_table_header after_header with
           | None -> after_header, []
           | Some next -> split_at next after_header
         in
         before @ (header :: edit section_lines) @ after_section)
  in
  join_lines updated ~trailing_newline:true
;;

let replace_or_append_scalar section_lines ~key ~value =
  let line = scalar_line ~key ~value in
  let rec loop acc = function
    | [] -> List.rev_append acc [ line ]
    | existing :: rest ->
      (match key_of_line existing with
       | Some k when String.equal k key -> List.rev_append acc (line :: rest)
       | _ -> loop (existing :: acc) rest)
  in
  loop [] section_lines
;;

let remove_scalar section_lines ~key =
  List.filter
    (fun existing ->
      match key_of_line existing with
      | Some k when String.equal k key -> false
      | _ -> true)
    section_lines
;;

(* Set (or, with [value = None], remove) a scalar key inside [\[path\]]. When the
   table is absent and [value] is set, a new table is appended. *)
let edit_table_scalar content ~path ~key ~value =
  let append_table lines =
    match value with
    | None -> lines
    | Some value ->
      let section = [ Printf.sprintf "[%s]" path; scalar_line ~key ~value ] in
      (match List.rev lines with
       | [] -> section
       | last :: _ when String.equal (String.trim last) "" -> lines @ section
       | _ -> lines @ ("" :: section))
  in
  with_table content ~path ~on_missing:append_table ~edit:(fun section ->
    match value with
    | None -> remove_scalar section ~key
    | Some value -> replace_or_append_scalar section ~key ~value)
;;

(* [array_closes_on_key_line line] is true when [line] holds a complete
   single-line array ([key = \[...\]]); false when the [\[] is left open for a
   multi-line array. Model/prompt ids do not contain [\]], so a bracket in the
   value is treated as the array close. *)
let array_closes_on_key_line line = String.contains (strip_comment line) ']'

(* Replace (or append) a multi-line array [key = \[ ... \]] inside a section. An
   existing single-line array collapses to the multi-line form; comments between
   array elements are not preserved (elements are data, RFC-0306 §7.1). Comments
   outside the [key = \[ ... \]] span are untouched. *)
let replace_or_append_multiline_array section_lines ~key ~values =
  let block = multiline_array_lines ~key ~values in
  let rec find_span acc = function
    | [] -> None
    | line :: rest ->
      (match key_of_line line with
       | Some k when String.equal k key ->
         if array_closes_on_key_line line
         then Some (List.rev acc, rest)
         else (
           let rec consume = function
             | [] -> []
             | l :: r -> if String.contains l ']' then r else consume r
           in
           Some (List.rev acc, consume rest))
       | _ -> find_span (line :: acc) rest)
  in
  match find_span [] section_lines with
  | None -> section_lines @ block
  | Some (before, after) -> before @ block @ after
;;

let edit_table_multiline_array content ~path ~key ~values =
  let append_table lines =
    let section = (Printf.sprintf "[%s]" path :: multiline_array_lines ~key ~values) in
    match List.rev lines with
    | [] -> section
    | last :: _ when String.equal (String.trim last) "" -> lines @ section
    | _ -> lines @ ("" :: section)
  in
  with_table content ~path ~on_missing:append_table ~edit:(fun section ->
    replace_or_append_multiline_array section ~key ~values)
;;
