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
let roundtrip ~restore ~reenter (content : string) : string option =
  match editor_command () with
  | None -> None
  | Some editor ->
    let path = Filename.temp_file "masc-keeper-settings" ".json" in
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
              Some really
            with _ -> None)
         | _ -> None)
      with _ -> None
    in
    finally ();
    outcome
;;
