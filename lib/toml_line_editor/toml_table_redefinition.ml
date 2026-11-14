type declaration =
  | Header of string list
  | Dotted_key of string list

type violation =
  | Inline_table_extended of
      { inline_table : string list
      ; by : declaration
      }
  | Dotted_table_reopened of string list

type located =
  { line : int
  ; first_defined_at : int
  ; violation : violation
  }

type unreadable =
  { unreadable_line : int
  ; detail : string
  }

(* What the lines read so far have closed. [inline] are the inline tables and
   [dotted] the tables dotted keys define, each with the line that wrote it.
   Paths are absolute: a statement's keys are read under [context], the table
   the last header opened. *)
type scope =
  { context : string list
  ; inline : (string list * int) list
  ; dotted : (string list * int) list
  ; found : located list
  }

let rec is_prefix prefix path =
  match prefix, path with
  | [], _ -> true
  | _ :: _, [] -> false
  | first :: prefix, next :: path -> String.equal first next && is_prefix prefix path
;;

let same_path left right = List.equal String.equal left right

let inline_ancestor scope path =
  List.find_opt (fun (inline_table, _) -> is_prefix inline_table path) scope.inline
;;

let report scope ~line ~first_defined_at violation =
  { scope with found = { line; first_defined_at; violation } :: scope.found }
;;

let open_header scope ~line path =
  let scope =
    match inline_ancestor scope path with
    | Some (inline_table, first_defined_at) ->
      report scope ~line ~first_defined_at
        (Inline_table_extended { inline_table; by = Header path })
    | None ->
      (match List.find_opt (fun (table, _) -> same_path table path) scope.dotted with
       | Some (table, first_defined_at) ->
         report scope ~line ~first_defined_at (Dotted_table_reopened table)
       | None -> scope)
  in
  { scope with context = path }
;;

(* [\[\[path\]\]] starts a new entry. What the previous entry declared under
   [path] belongs to that entry, so it no longer collides with anything. *)
let open_array_entry scope ~line path =
  let scope = open_header scope ~line path in
  let outside (declared, _) = not (is_prefix path declared) in
  { scope with
    inline = List.filter outside scope.inline
  ; dotted = List.filter outside scope.dotted
  }
;;

(* One parsed assignment. A [TomlTable] below the statement's root exists only
   because the key was dotted; a [TomlInlineTable] is a value the statement
   wrote in braces. *)
let rec declare_fields scope ~line path fields =
  List.fold_left
    (fun scope (key, value) ->
       let path = path @ [ key ] in
       match value with
       | Otoml.TomlInlineTable _ ->
         let scope =
           match inline_ancestor scope path with
           | Some (inline_table, first_defined_at) ->
             report scope ~line ~first_defined_at
               (Inline_table_extended { inline_table; by = Dotted_key path })
           | None -> scope
         in
         { scope with inline = (path, line) :: scope.inline }
       | Otoml.TomlTable fields ->
         (match inline_ancestor scope path with
          | Some (inline_table, first_defined_at) ->
            report scope ~line ~first_defined_at
              (Inline_table_extended { inline_table; by = Dotted_key path })
          | None ->
            let scope =
              if List.exists (fun (table, _) -> same_path table path) scope.dotted
              then scope
              else { scope with dotted = (path, line) :: scope.dotted }
            in
            declare_fields scope ~line path fields)
       | Otoml.TomlString _ | Otoml.TomlInteger _ | Otoml.TomlFloat _ | Otoml.TomlBoolean _
       | Otoml.TomlOffsetDateTime _ | Otoml.TomlLocalDateTime _ | Otoml.TomlLocalDate _
       | Otoml.TomlLocalTime _ | Otoml.TomlArray _ | Otoml.TomlTableArray _ -> scope)
    scope
    fields
;;

let declare_statement scope ~line statement =
  (* A CRLF file leaves a \r at the end of the statement, which the parser
     does not read as a line ending; [Toml_line_editor.header_of_line] trims
     for the same reason. *)
  match Otoml.Parser.from_string_result (String.trim statement) with
  | Error detail -> Error { unreadable_line = line; detail }
  | Ok (Otoml.TomlTable fields | Otoml.TomlInlineTable fields) ->
    Ok (declare_fields scope ~line scope.context fields)
  | Ok
      ( Otoml.TomlString _ | Otoml.TomlInteger _ | Otoml.TomlFloat _ | Otoml.TomlBoolean _
      | Otoml.TomlOffsetDateTime _ | Otoml.TomlLocalDateTime _ | Otoml.TomlLocalDate _
      | Otoml.TomlLocalTime _ | Otoml.TomlArray _ | Otoml.TomlTableArray _ ) ->
    (* A document is a table; the parser has no other root to return. *)
    Ok scope
;;

let violations content =
  let lines, _trailing_newline = Toml_line_editor.split_lines content in
  (* [lines] always starts on a structural line: a header is one line and an
     assignment is consumed together with its continuation lines. *)
  let rec read scope ~line = function
    | [] -> Ok (List.rev scope.found)
    | opening :: rest ->
      (match Toml_line_editor.header_of_line opening with
       | Some (Toml_line_editor.Table path) ->
         read (open_header scope ~line path) ~line:(line + 1) rest
       | Some (Toml_line_editor.Table_array path) ->
         read (open_array_entry scope ~line path) ~line:(line + 1) rest
       | None ->
         let after = Toml_line_editor.skip_value ~opening rest in
         let continuation_count = List.length rest - List.length after in
         let continuation, _ = Toml_line_editor.split_at continuation_count rest in
         (match declare_statement scope ~line (String.concat "\n" (opening :: continuation)) with
          | Error unreadable -> Error unreadable
          | Ok scope -> read scope ~line:(line + 1 + continuation_count) after))
  in
  read { context = []; inline = []; dotted = []; found = [] } ~line:1 lines
;;

let same_declaration left right =
  match left, right with
  | Header left, Header right | Dotted_key left, Dotted_key right -> same_path left right
  | Header _, Dotted_key _ | Dotted_key _, Header _ -> false
;;

let same_violation left right =
  match left.violation, right.violation with
  | Inline_table_extended left, Inline_table_extended right ->
    same_path left.inline_table right.inline_table && same_declaration left.by right.by
  | Dotted_table_reopened left, Dotted_table_reopened right -> same_path left right
  | Inline_table_extended _, Dotted_table_reopened _
  | Dotted_table_reopened _, Inline_table_extended _ -> false
;;

let path_text path = String.concat "." (List.map Toml_line_editor.render_key path)

let declaration_text = function
  | Header path -> Printf.sprintf "the header [%s]" (path_text path)
  | Dotted_key path -> Printf.sprintf "the dotted key %s" (path_text path)
;;

let to_string { line; first_defined_at; violation } =
  match violation with
  | Inline_table_extended { inline_table; by } ->
    Printf.sprintf
      "line %d: %s adds to %s, which line %d writes as an inline table. TOML 1.0 closes \
       an inline table where it is written, so a strict reader refuses the file. Write \
       %s as a [%s] table with one key per line"
      line
      (declaration_text by)
      (path_text inline_table)
      first_defined_at
      (path_text inline_table)
      (path_text inline_table)
  | Dotted_table_reopened table ->
    Printf.sprintf
      "line %d: the header [%s] opens a table that the dotted key on line %d already \
       defines. TOML 1.0 lets a table be defined once, so a strict reader refuses the \
       file. Move the dotted keys under the [%s] header"
      line
      (path_text table)
      first_defined_at
      (path_text table)
;;

let unreadable_to_string { unreadable_line; detail } =
  Printf.sprintf "the assignment at line %d does not parse on its own: %s" unreadable_line detail
;;
