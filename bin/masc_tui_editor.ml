(** $EDITOR round-trip for a JSON settings payload.

    The terminal handshake is the caller's: this module only decides the
    editor command, owns the temp file, and runs the child between the two
    terminal callbacks ([restore] leaves raw mode, [reenter] takes it back
    and asks for a full repaint) — the same pair [suspend] already runs
    around Ctrl-Z. The child inherits stdin/stdout straight from
    [Unix.system], so the editor talks to the terminal, not to the TUI.

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

(** [roundtrip ~restore ~reenter content] hands [content] to $EDITOR and
    returns [Some edited] when the editor exited 0, [None] when it did not
    (or no editor is configured) — in which case the settings are untouched. *)
(* Why the form came back with nothing in it. All three used to be [None],
   so a caller could only say "cancelled" -- and an editor that never started
   read to the operator as a decision they had made. *)
type abort =
  | Cancelled
  (* The editor ran and exited non-zero: [:cq] and its equivalents, which is
     the operator saying no. *)
  | Editor_unavailable of string
  (* The command never ran, or died on a signal. /bin/sh answers 127 for a
     command it cannot find, which is what an [$EDITOR] naming a binary that
     is not installed looks like from here. *)
  | Form_unreadable of string
(* The temp file could not be written or read back. Nothing to do with the
   editor or the operator. *)

let abort_detail = function
  | Cancelled -> "cancelled"
  | Editor_unavailable detail -> detail
  | Form_unreadable detail -> detail

let roundtrip ~restore ~reenter ?(suffix = ".json") (content : string)
  : (string, abort) result =
  match editor_command () with
  | None ->
    Error (Editor_unavailable "no $EDITOR or $VISUAL is set")
  | Some editor ->
    let path = Filename.temp_file "masc-editor" suffix in
    let finally () = (try Sys.remove path with _ -> ()) in
    let outcome =
      try
        let oc = open_out path in
        output_string oc content;
        close_out oc;
        restore ();
        let status = run_editor editor path in
        reenter ();
        (match status with
         | Unix.WEXITED 0 ->
           (try
              let ic = open_in path in
              let n = in_channel_length ic in
              let really = really_input_string ic n in
              close_in ic;
              Ok really
            with e ->
              Error (Form_unreadable (Printexc.to_string e)))
         | Unix.WEXITED 127 ->
           Error (Editor_unavailable (editor ^ ": command not found"))
         | Unix.WEXITED code ->
           ignore code;
           Error Cancelled
         | Unix.WSIGNALED signal | Unix.WSTOPPED signal ->
           Error
             (Editor_unavailable
                (Printf.sprintf "%s was stopped by signal %d" editor signal)))
      with e -> Error (Form_unreadable (Printexc.to_string e))
    in
    finally ();
    outcome
;;
