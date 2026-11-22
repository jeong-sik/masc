(** $EDITOR round-trip for a JSON settings payload or source text.

    The terminal handshake is the caller's: this module only decides the
    editor command, owns the temp file, and runs the child between the two
    terminal callbacks ([restore] leaves raw mode, [reenter] takes it back
    and asks for a full repaint). The child inherits stdin/stdout straight from
    [Unix.system], so the editor talks directly to the terminal.

    Exit code 0 means "take the bytes back"; anything else means the
    operator walked away and nothing changes. *)

let editor_command () =
  match Sys.getenv_opt "EDITOR" with
  | Some editor when String.length (String.trim editor) > 0 -> Some editor
  | None | Some _ -> (
    match Sys.getenv_opt "VISUAL" with
    | Some visual when String.length (String.trim visual) > 0 -> Some visual
    | None | Some _ -> None)

let run_editor editor path =
  (* [editor] is the operator's own environment and may carry arguments
     ("code -w"); the file is quoted, the command is not re-parsed. *)
  Unix.system (editor ^ " " ^ Filename.quote path)

type unavailable =
  | Unset
  | Command_not_found of string
  | Stopped_by_signal of { editor : string; signal : int }

type abort =
  | Cancelled
  | Editor_unavailable of unavailable
  | Form_unreadable of string

let abort_detail ~ko = function
  | Cancelled -> if ko then "취소" else "cancelled"
  | Editor_unavailable Unset ->
      if ko then "$EDITOR 와 $VISUAL 이 비어 있음 · EDITOR 를 설정하세요"
      else "no $EDITOR or $VISUAL is set · export EDITOR to edit here"
  | Editor_unavailable (Command_not_found editor) ->
      editor ^ (if ko then ": 명령을 찾을 수 없음" else ": command not found")
  | Editor_unavailable (Stopped_by_signal { editor; signal }) ->
      Printf.sprintf
        (if ko then "%s: 신호 %d 받고 멈춤" else "%s was stopped by signal %d")
        editor signal
  (* The system's own words for what went wrong with the file. *)
  | Form_unreadable detail -> detail

let roundtrip ~restore ~reenter ?(suffix = ".json") (content : string)
  : (string, abort) result =
  match editor_command () with
  | None -> Error (Editor_unavailable Unset)
  | Some editor ->
    try
      let path = Filename.temp_file "masc-editor" suffix in
      Fun.protect
        ~finally:(fun () -> try Sys.remove path with Sys_error _ -> ())
        (fun () ->
          let channel = open_out_bin path in
          Fun.protect ~finally:(fun () -> close_out_noerr channel)
            (fun () -> output_string channel content; flush channel);
          let status = Fun.protect ~finally:reenter (fun () ->
            restore (); run_editor editor path) in
          match status with
          | Unix.WEXITED 0 ->
            let channel = open_in_bin path in
            Fun.protect ~finally:(fun () -> close_in_noerr channel)
              (fun () -> Ok (really_input_string channel (in_channel_length channel)))
          | Unix.WEXITED 127 -> Error (Editor_unavailable (Command_not_found editor))
          | Unix.WEXITED _ -> Error Cancelled
          | Unix.WSIGNALED signal | Unix.WSTOPPED signal ->
            Error (Editor_unavailable (Stopped_by_signal { editor; signal })))
    with
    | Sys_error detail -> Error (Form_unreadable detail)
    | Unix.Unix_error _ as exn -> Error (Form_unreadable (Printexc.to_string exn))
