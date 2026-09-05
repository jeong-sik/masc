(* See lsp_position.mli. Moved from keeper_tool_code_query.ml when the REST
   route became the second caller: two copies of the column search would
   drift, and the drift would show as two surfaces disagreeing about where a
   name sits. *)

let line_of_file ~path ~line_index =
  match In_channel.with_open_bin path In_channel.input_all with
  | exception Sys_error reason ->
    Error (Printf.sprintf "cannot read %s: %s" path reason)
  | contents ->
    let lines = String.split_on_char '\n' contents in
    (match List.nth_opt lines line_index with
     | Some line -> Ok line
     | None ->
       Error
         (Printf.sprintf
            "%s has %d lines, so line %d is past its end"
            path
            (List.length lines)
            (line_index + 1)))
;;

(* Finding which column a name sits in is not parsing — the language server
   still decides what the name means. RFC §3.4 rejects deriving the position
   from a pattern; this derives it from the literal name the caller named. *)
let columns_of ~line ~symbol =
  let needle = String.length symbol in
  let rec scan from acc =
    if from + needle > String.length line
    then List.rev acc
    else if String.equal (String.sub line from needle) symbol
    then scan (from + 1) (from :: acc)
    else scan (from + 1) acc
  in
  if needle = 0 then [] else scan 0 []
;;

let column_of ~line ~symbol ~occurrence ~line_number =
  match columns_of ~line ~symbol with
  | [] ->
    Error
      (Printf.sprintf
         "%S is not on line %d, which reads: %s"
         symbol
         line_number
         (String.trim line))
  | columns ->
    (match List.nth_opt columns (occurrence - 1) with
     | Some column -> Ok column
     | None ->
       Error
         (Printf.sprintf
            "%S occurs %d time(s) on line %d, so there is no occurrence %d"
            symbol
            (List.length columns)
            line_number
            occurrence))
;;

let language_of ~path =
  match Lsp_process_manager.language_of_path path with
  | Some language -> Ok language
  | None ->
    Error
      (Printf.sprintf
         "no language server covers %s; this answers about %s"
         (Filename.extension path)
         (String.concat ", " (Lsp_process_manager.covered_extensions ())))
;;

let project_root_of ~language ~path ~boundary =
  match Lsp_project_root.resolve ~language ~file:path ~boundary with
  | Lsp_project_root.Project_root root -> Ok root
  | Lsp_project_root.No_project_root { markers; _ } ->
    Error
      (Printf.sprintf
         "%s is in the workspace but not inside a project: no %s above it. A \
          language server rooted at the workspace would answer about \
          unrelated trees."
         path
         (String.concat " or " markers))
  | Lsp_project_root.Outside_boundary { boundary; _ } ->
    Error
      (Printf.sprintf "%s resolved outside the workspace root %s" path boundary)
;;
