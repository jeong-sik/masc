open Masc_tui_store

type command = { executable : string; args : string list }

let executable_name = "masc-alphatex"

(* Folder names inside [.masc/music] that the viewer's [--project-root] and
   [--session-root] flags take. *)
let projects_dirname = "projects"
let sessions_dirname = "sessions"

let args ~base_path program =
  let music_dir =
    Filename.concat
      (Common.masc_dir_from_base_path ~base_path)
      Common.tui_music_dirname
  in
  let roots =
    [
      "--project-root";
      Filename.concat music_dir projects_dirname;
      "--session-root";
      Filename.concat music_dir sessions_dirname;
    ]
  in
  match program with
  | Cmd.Music_workbench -> "--music" :: roots
  | Cmd.Music_import_midi path -> "--midi-file" :: path :: roots

let is_regular_file path =
  match Unix.stat path with
  | { Unix.st_kind = Unix.S_REG; _ } -> true
  | {
      Unix.st_kind =
        Unix.S_DIR | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO
        | Unix.S_SOCK;
      _;
    } ->
      false
  | exception Unix.Unix_error _ -> false

let command ~base_path program =
  let missing_input =
    match program with
    | Cmd.Music_workbench -> None
    | Cmd.Music_import_midi path ->
        if is_regular_file path then None
        else Some (Printf.sprintf "MIDI file not found: %s" path)
  in
  match missing_input with
  | Some detail -> Error detail
  | None -> (
      match Executable_path.absolute_on_path executable_name with
      | None ->
          Error
            (Printf.sprintf "%s is not installed; run scripts/install-alphatex.sh"
               executable_name)
      | Some executable -> Ok { executable; args = args ~base_path program })

let run { executable; args } =
  match
    Unix.create_process executable
      (Array.of_list (executable :: args))
      Unix.stdin Unix.stdout Unix.stderr
  with
  | exception Unix.Unix_error (error, fn, _) ->
      Error (Printf.sprintf "%s: %s" fn (Unix.error_message error))
  | child -> (
      let rec wait () =
        match Unix.waitpid [] child with
        | _, status -> Ok status
        | exception Unix.Unix_error (Unix.EINTR, _, _) -> wait ()
        | exception Unix.Unix_error (error, fn, _) ->
            Error (Printf.sprintf "%s: %s" fn (Unix.error_message error))
      in
      match wait () with
      | Error detail -> Error detail
      | Ok (Unix.WEXITED 0) -> Ok ()
      | Ok (Unix.WEXITED code) ->
          Error (Printf.sprintf "%s exited with status %d" executable_name code)
      | Ok (Unix.WSIGNALED signal | Unix.WSTOPPED signal) ->
          Error (Printf.sprintf "%s ended on signal %d" executable_name signal))
