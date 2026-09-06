type found =
  | Memo_at of int * Ide_memo.t
  | Broken_at of int * string

let line_of = function
  | Memo_at (line, _) -> line
  | Broken_at (line, _) -> line

type reader =
  | Lexed
  | By_markers of Ide_memo.markers

let is_blank text = String.equal (String.trim text) ""

(* A row the lexer cut into one comment and nothing else. The lexer carries
   the state a single row does not -- a string opened two rows up, a block
   comment still running -- so where there is one, it decides. *)
let lone_comment row =
  match List.filter (fun (text, _) -> not (is_blank text)) row with
  | [ (text, kind) ] when String.equal kind Masc_tui_code_lexer.kind_comment -> Some text
  | [] | [ _ ] | _ :: _ :: _ -> None

(* The row's text, however the lexer cut it -- or did not: a language
   without a lexer arrives as one code segment per row. *)
let text_of_row row = String.concat "" (List.map fst row)

(* A file written on Windows carries a carriage return at the end of every
   row, and the wire escapes it to the four characters [\x0D] rather than
   let it move a terminal cursor. It is not part of the comment. *)
let carriage_return = "\\x0D"

let drop_trailing_carriage_return text =
  match String.length text - String.length carriage_return with
  | cut when cut >= 0 && String.ends_with ~suffix:carriage_return text -> String.sub text 0 cut
  | _ -> text

(* A memo is the whole row: it opens with the file's own marker and, for a
   block marker, closes on the same row. Code before the marker makes the
   comment a comment about that code, in whatever words, and it is left
   alone. *)
let is_a_comment_row ~markers line =
  match markers with
  | Ide_memo.Block { opens; closes } ->
    String.starts_with ~prefix:opens line && String.ends_with ~suffix:closes line
  | Ide_memo.Line opens -> String.starts_with ~prefix:opens line

(* The comment on this row, or [None] when the row does not carry one whole. *)
let comment_of_row ~reader row =
  let clean text = drop_trailing_carriage_return (String.trim text) in
  match reader with
  | Lexed -> Option.map clean (lone_comment row)
  | By_markers markers ->
    let line = clean (text_of_row row) in
    if is_a_comment_row ~markers line then Some line else None

let of_rows ~reader rows =
  List.concat
    (List.mapi
       (fun index row ->
         match comment_of_row ~reader row with
         | None -> []
         | Some comment -> (
             match Ide_memo.of_comment comment with
             | Ide_memo.Memo memo -> [ Memo_at (index + 1, memo) ]
             | Ide_memo.Malformed why -> [ Broken_at (index + 1, why) ]
             | Ide_memo.Not_a_memo -> []))
       rows)

let reader_for_path path =
  match
    Option.bind
      (Masc_tui_code_lexer.language_of_path path)
      Masc_tui_code_lexer.lexer_of_language
  with
  | Some _ -> Some Lexed
  | None -> (
      match Lsp_process_manager.memo_markers_of_path path with
      | Ok markers -> Some (By_markers markers)
      | Error
          ( Lsp_process_manager.Extension_unknown _
          | Lsp_process_manager.No_comment_syntax _ ) ->
          None)

let of_file ~path rows =
  match reader_for_path path with
  | Some reader -> of_rows ~reader rows
  | None -> []
