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
  let check_regular_dir () =
    match Unix.lstat wiki_root with
    | st when st.Unix.st_kind = Unix.S_DIR -> Ok ()
    | _ -> Error (wiki_root ^ ": wiki directory is not a regular directory (symlinks are rejected)")
    | exception Unix.Unix_error (error, operation, _) ->
      Error (Printf.sprintf "%s: %s" operation (Unix.error_message error))
  in
  let open_log_fd path =
    match Unix.lstat path with
    | exception Unix.Unix_error (Unix.ENOENT, _, _) ->
      (* Atomic O_CREAT | O_EXCL never follows a symlink. *)
      (try
         Ok
           (Unix.openfile path
              [ Unix.O_WRONLY; Unix.O_APPEND; Unix.O_CREAT; Unix.O_EXCL; Unix.O_CLOEXEC ]
              0o644)
       with
       | Unix.Unix_error (error, operation, _) ->
         Error (Printf.sprintf "%s: %s" operation (Unix.error_message error)))
    | exception Unix.Unix_error (error, operation, _) ->
      Error (Printf.sprintf "%s: %s" operation (Unix.error_message error))
    | lstat_st when lstat_st.Unix.st_kind <> Unix.S_REG ->
      Error "log.md is not a regular file (symlinks are rejected)"
    | lstat_st ->
      (try
         let fd =
           Unix.openfile path [ Unix.O_WRONLY; Unix.O_APPEND; Unix.O_CLOEXEC ] 0o644
         in
         let fstat_st =
           try Unix.fstat fd with
           | exn ->
             let bt = Printexc.get_raw_backtrace () in
             (try Unix.close fd with Unix.Unix_error _ -> ());
             Printexc.raise_with_backtrace exn bt
         in
         if fstat_st.Unix.st_kind <> Unix.S_REG
            || fstat_st.Unix.st_dev <> lstat_st.Unix.st_dev
            || fstat_st.Unix.st_ino <> lstat_st.Unix.st_ino
         then (
           (try Unix.close fd with Unix.Unix_error _ -> ());
           Error "log.md changed or is not a regular file")
         else Ok fd
       with
       | Unix.Unix_error (error, operation, _) ->
         Error (Printf.sprintf "%s: %s" operation (Unix.error_message error)))
  in
  match check_regular_dir () with
  | Error _ as err -> err
  | Ok () ->
    let path = Filename.concat wiki_root log_file in
    (match open_log_fd path with
     | Error _ as err -> err
     | Ok fd ->
       let oc =
         try Unix.out_channel_of_descr fd with
         | exn ->
           let bt = Printexc.get_raw_backtrace () in
           (try Unix.close fd with Unix.Unix_error _ -> ());
           Printexc.raise_with_backtrace exn bt
       in
       (try
          Fun.protect ~finally:(fun () -> close_out_noerr oc) (fun () ->
            Out_channel.output_string oc line;
            Out_channel.output_char oc '\n';
            Out_channel.flush oc);
          Ok ()
        with
        | Sys_error message -> Error message
        | Unix.Unix_error (error, operation, _) ->
          Error (Printf.sprintf "%s: %s" operation (Unix.error_message error))))
