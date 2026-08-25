type target = {
  path : string;
  line : int;
}

type route =
  | Remote_neovim of { server : string }
  | Terminal_handoff of { editor : string }
  | No_editor

let nonblank name =
  match Sys.getenv_opt name with
  | Some value when String.length (String.trim value) > 0 -> Some (String.trim value)
  | Some _ | None -> None

(* [$NVIM] is the current spelling; [$NVIM_LISTEN_ADDRESS] is deprecated and
   documented as such, so it is not read here. Nothing sets one without the
   other in a version that still honours the old name. *)
let route () =
  match nonblank "NVIM" with
  | Some server -> Remote_neovim { server }
  | None -> (
      match Masc_tui_editor.editor_command () with
      | Some editor -> Terminal_handoff { editor }
      | None -> No_editor)

(* A Vim single-quoted string ends at the first quote, and doubling is how a
   quote is written inside one. [fnameescape] then handles what [:edit] would
   otherwise read as syntax -- spaces, [#], [%] and the rest -- which is a
   different escaping problem from ending the literal, and neither covers the
   other. Verified against a path holding both a quote and an apostrophe. *)
let vim_string_literal text =
  let buffer = Buffer.create (String.length text + 8) in
  Buffer.add_char buffer '\'';
  String.iter
    (fun c ->
      if c = '\'' then Buffer.add_string buffer "''" else Buffer.add_char buffer c)
    text;
  Buffer.add_char buffer '\'';
  Buffer.contents buffer

let remote_expression { path; line } =
  Printf.sprintf "execute('edit +%d ' . fnameescape(%s))" (max 1 line)
    (vim_string_literal path)

let send_to_neovim ~server target =
  let argv = [| "nvim"; "--server"; server; "--remote-expr"; remote_expression target |] in
  match
    (* No shell: the expression carries quotes that a shell would read, and
       there is nothing here that needs a shell's word splitting. *)
    Unix.create_process "nvim" argv Unix.stdin Unix.stdout Unix.stderr
  with
  | exception Unix.Unix_error (error, _, _) ->
      Error (Printf.sprintf "could not run nvim: %s" (Unix.error_message error))
  | pid -> (
      match Unix.waitpid [] pid with
      | exception Unix.Unix_error (error, _, _) ->
          Error (Printf.sprintf "could not wait for nvim: %s" (Unix.error_message error))
      | _, Unix.WEXITED 0 -> Ok ()
      | _, Unix.WEXITED code ->
          Error (Printf.sprintf "nvim exited %d" code)
      | _, Unix.WSIGNALED signal ->
          Error (Printf.sprintf "nvim was killed by signal %d" signal)
      | _, Unix.WSTOPPED signal ->
          Error (Printf.sprintf "nvim stopped on signal %d" signal))
