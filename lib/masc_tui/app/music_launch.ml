open Masc_tui_store

type launch =
  | Workbench
  | Import_midi of string
  | Score of { bundle : string; index : int; cell_pixels : int * int }

let executable_name = "masc-alphatex"

(* Folder names inside [.masc/music] that the viewer's [--project-root] and
   [--session-root] flags take. *)
let projects_dirname = "projects"
let sessions_dirname = "sessions"

let score_needs_kitty =
  "/score requires Kitty graphics and measured terminal cell dimensions \
   (Ghostty, Kitty or WezTerm)"

let executable () =
  match Executable_path.absolute_on_path executable_name with
  | Some path -> Ok path
  | None ->
      Error
        (Printf.sprintf "%s is not installed; run scripts/install-alphatex.sh"
           executable_name)

let args ~base_path launch =
  let roots () =
    let music_dir =
      Filename.concat
        (Common.masc_dir_from_base_path ~base_path)
        Common.tui_music_dirname
    in
    [
      "--project-root";
      Filename.concat music_dir projects_dirname;
      "--session-root";
      Filename.concat music_dir sessions_dirname;
    ]
  in
  match launch with
  | Workbench -> "--music" :: roots ()
  | Import_midi path -> "--midi-file" :: path :: roots ()
  | Score { bundle; index; cell_pixels = (width, height) } ->
      [
        "--bundle";
        bundle;
        "--index";
        string_of_int index;
        "--cell-width";
        string_of_int width;
        "--cell-height";
        string_of_int height;
      ]

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

let remove_quietly path =
  match Sys.remove path with
  | () -> ()
  | exception Sys_error _ -> ()

let write_bundle path sources =
  Out_channel.with_open_bin path (fun channel ->
      Yojson.Safe.to_channel channel
        (`Assoc
          [ ("sources", `List (List.map (fun source -> `String source) sources)) ]))

(* The file is created with owner-only permissions and removed when [k]
   returns or raises. *)
let with_score_bundle sources k =
  match Filename.temp_file "masc-score-" ".json" with
  | exception Sys_error detail -> Error detail
  | path ->
      Fun.protect
        ~finally:(fun () -> remove_quietly path)
        (fun () ->
          match write_bundle path sources with
          | () -> k path
          | exception Sys_error detail -> Error detail)

let with_launch ~cell_pixels program k =
  match program with
  | Cmd.Music_workbench -> k Workbench
  | Cmd.Music_import_midi path ->
      if is_regular_file path then k (Import_midi path)
      else Error (Printf.sprintf "MIDI file not found: %s" path)
  | Cmd.Score_view { sources; index } -> (
      match cell_pixels with
      | None -> Error score_needs_kitty
      | Some cell_pixels ->
          with_score_bundle sources (fun bundle ->
              k (Score { bundle; index; cell_pixels })))

(* The TUI points its own fd 2 at a log file for the whole run, so a viewer
   that inherits it writes its error where the operator never looks. The
   viewer's stderr goes to a temp file instead. When the viewer exits, the
   text is copied to this process's stderr, which is that log file, and the
   last line of it ends a failure message. *)
let stderr_detail_limit = 200

let unix_error_message error fn =
  Printf.sprintf "%s: %s" fn (Unix.error_message error)

let close_quietly fd =
  match Unix.close fd with
  | () -> ()
  | exception Unix.Unix_error _ -> ()

let rec utf8_prefix text length =
  let prefix = String.sub text 0 length in
  if length = 0 || String.is_valid_utf_8 prefix then prefix
  else utf8_prefix text (length - 1)

(* The last non-blank line, with control bytes blanked so a stray escape
   sequence cannot move the terminal's cursor, cut at a scalar boundary. *)
let last_line text =
  let blank_control c =
    if Char.code c < 0x20 || Char.code c = 0x7f then ' ' else c
  in
  let non_blank line = not (String.equal (String.trim line) "") in
  match List.rev (List.filter non_blank (String.split_on_char '\n' text)) with
  | [] -> None
  | line :: _ ->
      let cleaned = String.map blank_control (String.trim line) in
      let shown =
        utf8_prefix cleaned (Int.min stderr_detail_limit (String.length cleaned))
      in
      Some
        (if String.length shown < String.length cleaned then shown ^ "…"
         else shown)

let with_detail message text =
  match last_line text with
  | None -> message
  | Some line -> Printf.sprintf "%s: %s" message line

let read_stderr stderr_path =
  match In_channel.with_open_bin stderr_path In_channel.input_all with
  | text -> text
  | exception Sys_error _ -> ""

(* A clean exit raises no toast, so the log is the only place left for a
   notice such as the path where the viewer kept edits it could not save. *)
let replay_stderr text =
  if not (String.equal text "") then (
    let line_end = if String.ends_with ~suffix:"\n" text then "" else "\n" in
    match
      prerr_string (executable_name ^ " stderr:\n" ^ text ^ line_end);
      flush stderr
    with
    | () -> ()
    | exception Sys_error _ -> ())

let spawn ~executable ~args ~stderr_path =
  let flags = [ Unix.O_WRONLY; Unix.O_TRUNC; Unix.O_CLOEXEC ] in
  match Unix.openfile stderr_path flags 0o600 with
  | exception Unix.Unix_error (error, fn, _) ->
      Error (unix_error_message error fn)
  | stderr_fd ->
      Fun.protect
        ~finally:(fun () -> close_quietly stderr_fd)
        (fun () ->
          match
            Unix.create_process executable
              (Array.of_list (executable :: args))
              Unix.stdin Unix.stdout stderr_fd
          with
          | exception Unix.Unix_error (error, fn, _) ->
              Error (unix_error_message error fn)
          | child -> Ok child)

let rec wait child =
  match Unix.waitpid [] child with
  | _, status -> Ok status
  | exception Unix.Unix_error (Unix.EINTR, _, _) -> wait child
  | exception Unix.Unix_error (error, fn, _) ->
      Error (unix_error_message error fn)

let run ~executable args =
  match Filename.temp_file "masc-alphatex-" ".err" with
  | exception Sys_error detail -> Error detail
  | stderr_path ->
      Fun.protect
        ~finally:(fun () -> remove_quietly stderr_path)
        (fun () ->
          let outcome =
            Result.bind (spawn ~executable ~args ~stderr_path) wait
          in
          let text = read_stderr stderr_path in
          replay_stderr text;
          match outcome with
          | Error detail -> Error detail
          | Ok (Unix.WEXITED 0) -> Ok ()
          | Ok (Unix.WEXITED code) ->
              Error
                (with_detail
                   (Printf.sprintf "%s exited with status %d" executable_name code)
                   text)
          | Ok (Unix.WSIGNALED signal | Unix.WSTOPPED signal) ->
              Error
                (with_detail
                   (Printf.sprintf "%s ended on signal %d" executable_name signal)
                   text))
