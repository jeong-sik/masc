type found =
  | Memo_at of int * Ide_memo.t
  | Broken_at of int * string

let line_of = function
  | Memo_at (line, _) -> line
  | Broken_at (line, _) -> line

let is_blank text = String.equal (String.trim text) ""

let lone_comment row =
  match List.filter (fun (text, _) -> not (is_blank text)) row with
  | [ (text, kind) ] when String.equal kind Masc_tui_code_lexer.kind_comment -> Some text
  | [] | [ _ ] | _ :: _ :: _ -> None

let of_rows rows =
  List.concat
    (List.mapi
       (fun index row ->
         match lone_comment row with
         | None -> []
         | Some comment -> (
             match Ide_memo.of_comment comment with
             | Ide_memo.Memo memo -> [ Memo_at (index + 1, memo) ]
             | Ide_memo.Malformed why -> [ Broken_at (index + 1, why) ]
             | Ide_memo.Not_a_memo -> []))
       rows)
