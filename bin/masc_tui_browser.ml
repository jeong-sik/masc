(** See masc_tui_browser.mli. *)

type opener = Open | Xdg_open
type kernel = Darwin | Linux

let opener_command = function Open -> "open" | Xdg_open -> "xdg-open"
let opener_for = function Darwin -> Open | Linux -> Xdg_open

let kernel_of_uname raw =
  match String.trim raw with
  | "Darwin" -> Ok Darwin
  | "Linux" -> Ok Linux
  | other ->
    Error
      (Printf.sprintf "no link opener known for kernel %S (open on Darwin, xdg-open on Linux)"
         other)

let command_for ~opener ~url = Printf.sprintf "%s %s" opener (Filename.quote url)

(* One question to the kernel, answered before any opener runs. Trying
   openers in turn on a non-zero exit cannot tell "this opener is not here"
   from "this opener ran and refused the argument", and on macOS that second
   case used to fall through to xdg-open, which is never there. *)
let host_kernel () =
  match Unix.open_process_in "uname -s" with
  | exception Unix.Unix_error (err, fn, _) ->
    Error (Printf.sprintf "uname -s: %s: %s" fn (Unix.error_message err))
  | channel -> (
    let line = In_channel.input_line channel in
    match Unix.close_process_in channel, line with
    | Unix.WEXITED 0, Some name -> kernel_of_uname name
    | Unix.WEXITED 0, None -> Error "uname -s printed nothing"
    | Unix.WEXITED code, _ -> Error (Printf.sprintf "uname -s exited %d" code)
    | Unix.WSIGNALED signal, _ | Unix.WSTOPPED signal, _ ->
      Error (Printf.sprintf "uname -s stopped by signal %d" signal))

let open_url url =
  match host_kernel () with
  | Error reason -> Error reason
  | Ok kernel -> (
    let name = opener_command (opener_for kernel) in
    match Unix.system (command_for ~opener:name ~url) with
    | Unix.WEXITED 0 -> Ok name
    | Unix.WEXITED code -> Error (Printf.sprintf "%s exited %d for %s" name code url)
    | Unix.WSIGNALED signal | Unix.WSTOPPED signal ->
      Error (Printf.sprintf "%s stopped by signal %d for %s" name signal url))
