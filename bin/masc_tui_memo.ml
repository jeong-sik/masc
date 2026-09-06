type found =
  | Memo_at of int * Ide_memo.t
  | Broken_at of int * string

let line_of = function
  | Memo_at (line, _) -> line
  | Broken_at (line, _) -> line

(* The row's text, however the lexer cut it -- or did not: a language
   without a lexer arrives as one code segment per row. *)
let text_of_row row = String.concat "" (List.map fst row)

(* A memo is the whole row: it opens with the file's own marker and, for a
   block marker, closes on the same row. Code before the marker makes the
   comment a comment about that code, in whatever words, and it is left
   alone. *)
let is_a_comment_row ~markers line =
  match markers with
  | Ide_memo.Block { opens; closes } ->
    String.starts_with ~prefix:opens line && String.ends_with ~suffix:closes line
  | Ide_memo.Line opens -> String.starts_with ~prefix:opens line

let of_rows ~markers rows =
  List.concat
    (List.mapi
       (fun index row ->
         let line = String.trim (text_of_row row) in
         if not (is_a_comment_row ~markers line) then []
         else
           match Ide_memo.of_comment line with
           | Ide_memo.Memo memo -> [ Memo_at (index + 1, memo) ]
           | Ide_memo.Malformed why -> [ Broken_at (index + 1, why) ]
           | Ide_memo.Not_a_memo -> [])
       rows)

let of_file ~path rows =
  match Lsp_process_manager.memo_markers_of_path path with
  | Ok markers -> of_rows ~markers rows
  | Error (Lsp_process_manager.Extension_unknown _ | Lsp_process_manager.No_comment_syntax _) -> []
