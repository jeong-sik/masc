let index_file = Wiki_page_name.index_name ^ ".md"
let log_file = Wiki_page_name.log_name ^ ".md"
let is_own_file name = String.equal name index_file || String.equal name log_file

type entry =
  | Page of
      { file : string
      ; title : string
      ; summary : string
      }
  | Unreadable of
      { file : string
      ; reason : string
      }

let index_heading = "# Wiki index"

let render_entry = function
  | Page { file; title; summary } -> Printf.sprintf "- [%s](%s) — %s" title file summary
  | Unreadable { file; reason } -> Printf.sprintf "- %s (%s)" file reason

let render_index entries =
  match entries with
  | [] -> index_heading ^ "\n\nNo pages in the wiki.\n"
  | _ :: _ ->
    index_heading ^ "\n\n" ^ String.concat "\n" (List.map render_entry entries) ^ "\n"

let write_index ~wiki_root entries =
  match
    Fs_compat.save_file_atomic_strict_staged
      (Filename.concat wiki_root index_file)
      (render_index entries)
  with
  | Ok () -> Ok ()
  | Error failure -> Error (Fs_compat.atomic_replace_failure_to_string failure)

type action =
  | Created
  | Updated

let action_word = function
  | Created -> "create"
  | Updated -> "update"

let log_line ~(time : Unix.tm) ~action ~revision ~page ~author ~note =
  Printf.sprintf
    "## [%04d-%02d-%02d %02d:%02d] %s r%d | %s | %s | %s"
    (time.tm_year + 1900)
    (time.tm_mon + 1)
    time.tm_mday
    time.tm_hour
    time.tm_min
    (action_word action)
    revision
    page
    author
    note

let append_log ~wiki_root line =
  let path = Filename.concat wiki_root log_file in
  match
    Out_channel.with_open_gen
      [ Open_wronly; Open_append; Open_creat; Open_text ]
      0o644
      path
      (fun channel ->
         Out_channel.output_string channel line;
         Out_channel.output_char channel '\n')
  with
  | () -> Ok ()
  | exception Sys_error message -> Error message
