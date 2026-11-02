(** Keeper TOML semantic parsing backed by Otoml.

    Keeper consumers use a flat, canonical key-path projection. Semantic TOML
    parsing, escaping, quoted/dotted key handling, and value validation remain
    owned by Otoml; comment-preserving mutation remains in
    [Keeper_toml_loader]. *)

type toml_value =
  | Toml_string of string
  | Toml_int of int
  | Toml_float of float
  | Toml_bool of bool
  | Toml_string_array of string list
  | Toml_array of toml_value list
  | Toml_table of (string * toml_value) list
  | Toml_inline_table of (string * toml_value) list
  | Toml_table_array of toml_value list
  | Toml_offset_datetime of string
  | Toml_local_datetime of string
  | Toml_local_date of string
  | Toml_local_time of string

type toml_doc = (string * toml_value) list

let rec toml_value_of_otoml = function
  | Otoml.TomlString value -> Toml_string value
  | Otoml.TomlInteger value -> Toml_int value
  | Otoml.TomlFloat value -> Toml_float value
  | Otoml.TomlBoolean value -> Toml_bool value
  | Otoml.TomlOffsetDateTime value -> Toml_offset_datetime value
  | Otoml.TomlLocalDateTime value -> Toml_local_datetime value
  | Otoml.TomlLocalDate value -> Toml_local_date value
  | Otoml.TomlLocalTime value -> Toml_local_time value
  | Otoml.TomlArray values ->
    let values = List.map toml_value_of_otoml values in
    let rec collect_strings acc = function
      | [] -> Some (List.rev acc)
      | Toml_string string :: rest -> collect_strings (string :: acc) rest
      | ( Toml_int _ | Toml_float _ | Toml_bool _ | Toml_string_array _
        | Toml_array _ | Toml_table _ | Toml_inline_table _ | Toml_table_array _
        | Toml_offset_datetime _ | Toml_local_datetime _ | Toml_local_date _
        | Toml_local_time _ )
        :: _ -> None
    in
    (match collect_strings [] values with
     | Some strings -> Toml_string_array strings
     | None -> Toml_array values)
  | Otoml.TomlTable fields ->
    Toml_table
      (List.map
         (fun (key, value) -> key, toml_value_of_otoml value)
         fields)
  | Otoml.TomlInlineTable fields ->
    Toml_inline_table
      (List.map
         (fun (key, value) -> key, toml_value_of_otoml value)
         fields)
  | Otoml.TomlTableArray values ->
    Toml_table_array (List.map toml_value_of_otoml values)
;;

let valid_bare_key key =
  String.length key > 0
  && String.for_all
       (function
         | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' | '-' -> true
         | _ -> false)
       key
;;

let canonical_key key =
  if valid_bare_key key then key else Otoml.string_of_path [ key ]
;;

let string_of_path path =
  String.concat "." (List.map canonical_key path)
;;

let rec flatten_table path fields =
  List.concat_map
    (fun (key, value) ->
      let path = path @ [ key ] in
      match value with
      | Otoml.TomlTable nested -> flatten_table path nested
      | (Otoml.TomlString _ | Otoml.TomlInteger _ | Otoml.TomlFloat _ | Otoml.TomlBoolean _ | Otoml.TomlOffsetDateTime _ | Otoml.TomlLocalDateTime _ | Otoml.TomlLocalDate _ | Otoml.TomlLocalTime _ | Otoml.TomlArray _ | Otoml.TomlInlineTable _ | Otoml.TomlTableArray _) as value -> [ string_of_path path, toml_value_of_otoml value ])
    fields
;;

type source_mode = Outside | Comment | Basic | Multiline_basic | Literal | Multiline_literal

(* Otoml 1.0.5 can consume eight hex digits after a lowercase [\u],
   although TOML assigns exactly four to that escape. Separate any following
   hex characters into their own escapes, but only inside basic strings:
   literal strings and comments must keep their original contents. The same
   pass preserves an escaped initial newline in multiline basic strings and
   prevents Otoml treating literal-string backslashes as line continuations. *)
let normalize_otoml_strings content =
  let length = String.length content in
  let output = Buffer.create length in
  let is_hex = function
    | '0' .. '9' | 'a' .. 'f' | 'A' .. 'F' -> true
    | _ -> false in
  let triple quote index =
    index + 2 < length && content.[index] = quote
    && content.[index + 1] = quote && content.[index + 2] = quote in
  let rec quote_end quote index =
    if index < length && content.[index] = quote then quote_end quote (index + 1)
    else index in
  let rec literal_close index =
    if index >= length then None
    else if triple '\'' index then
      let last = quote_end '\'' index in
      if last - index <= 5 then Some last else None
    else literal_close (index + 1) in
  let copy index count = Buffer.add_substring output content index count in
  let rec loop mode index single_line_break =
    if index >= length then single_line_break
    else
      match mode with
      | Outside ->
          (match content.[index] with
           | '#' -> copy index 1; loop Comment (index + 1) single_line_break
           | '"' when triple '"' index ->
               copy index 3;
               (* Otoml trims an initial newline after decoding escapes.
                  Supply an escaped newline for it to trim; unlike a physical
                  one this keeps later parser error line numbers unchanged. *)
               if index + 3 < length
                  && (content.[index + 3] = '\\' || content.[index + 3] = '"')
               then Buffer.add_string output "\\n";
               loop Multiline_basic (index + 3) single_line_break
           | '"' -> copy index 1; loop Basic (index + 1) single_line_break
           | '\'' when triple '\'' index ->
               (match literal_close (index + 3) with
                | None -> copy index 3; loop Multiline_literal (index + 3) single_line_break
                | Some last ->
                    Buffer.add_string output "\"\"\"";
                    if content.[index + 3] <> '\n' then Buffer.add_string output "\\n";
                    for pos = index + 3 to last - 4 do
                      (match content.[pos] with
                       | '\\' -> Buffer.add_string output "\\\\"
                       | '"' -> Buffer.add_string output "\\\""
                       | char -> Buffer.add_char output char)
                    done;
                    Buffer.add_string output "\"\"\"";
                    loop Outside last single_line_break)
           | '\'' -> copy index 1; loop Literal (index + 1) single_line_break
           | _ -> copy index 1; loop Outside (index + 1) single_line_break)
      | Comment ->
          copy index 1;
          loop (if content.[index] = '\n' then Outside else Comment) (index + 1) single_line_break
      | Literal ->
          let single_line_break =
            single_line_break || content.[index] = '\n' || content.[index] = '\r' in
          copy index 1;
          loop (if content.[index] = '\'' then Outside else Literal) (index + 1) single_line_break
      | Multiline_literal ->
          if triple '\'' index then begin
            let last = quote_end '\'' index in
            copy index (last - index); loop Outside last single_line_break
          end else begin
            copy index 1; loop Multiline_literal (index + 1) single_line_break
          end
      | Basic | Multiline_basic ->
          let single_line_break =
            single_line_break ||
            (mode = Basic &&
             (content.[index] = '\n' || content.[index] = '\r'
              || (content.[index] = '\\' && index + 1 < length
                  && (content.[index + 1] = '\n' || content.[index + 1] = '\r')))) in
          if content.[index] = '\\' && index + 1 < length then begin
            if content.[index + 1] = 'u' && index + 5 < length
               && is_hex content.[index + 2] && is_hex content.[index + 3]
               && is_hex content.[index + 4] && is_hex content.[index + 5]
            then begin
              copy index 6;
              let rec escape_hex rest =
                if rest < length && is_hex content.[rest] then begin
                  Printf.bprintf output "\\u%04x" (Char.code content.[rest]);
                  escape_hex (rest + 1)
                end else loop mode rest single_line_break in
              escape_hex (index + 6)
            end else begin
              copy index 2; loop mode (index + 2) single_line_break
            end
          end else if mode = Multiline_basic && triple '"' index then begin
            let last = quote_end '"' index in
            copy index (last - index); loop Outside last single_line_break
          end else begin
            copy index 1;
            let next = if mode = Basic && content.[index] = '"' then Outside else mode in
            loop next (index + 1) single_line_break
          end
  in
  let single_line_break = loop Outside 0 false in
  Buffer.contents output, single_line_break
;;

let normalize_source_with_single_line_break content =
  (* TOML defines CRLF and LF as equivalent newlines. Otoml 1.0.5 preserves
     CRLF bytes inside multiline strings, so normalize only CRLF boundaries
     before semantic parsing. *)
  content
  |> String.split_on_char '\n'
  |> List.map String_util.strip_trailing_cr
  |> String.concat "\n"
  |> normalize_otoml_strings
;;

let normalize_source content =
  fst (normalize_source_with_single_line_break content)
;;

let normalize_editor_source content =
  let normalized, single_line_break = normalize_source_with_single_line_break content in
  if single_line_break then
    Error "A single-line TOML string cannot contain a physical newline; use triple quotes for multiline text"
  else Ok normalized
;;

let of_otoml = function
  | Otoml.TomlTable fields -> Ok (flatten_table [] fields)
  | Otoml.TomlString _ | Otoml.TomlInteger _ | Otoml.TomlFloat _
  | Otoml.TomlBoolean _ | Otoml.TomlOffsetDateTime _ | Otoml.TomlLocalDateTime _
  | Otoml.TomlLocalDate _ | Otoml.TomlLocalTime _ | Otoml.TomlArray _
  | Otoml.TomlInlineTable _ | Otoml.TomlTableArray _ -> Error "otoml returned a non-table document root"
;;

let parse_toml content =
  Result.bind (Otoml.Parser.from_string_result (normalize_source content)) of_otoml
;;
