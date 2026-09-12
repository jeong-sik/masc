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

(* One question to the kernel, answered before the opener runs. The kernel
   decides the opener; the opener's exit status is the answer. A non-zero
   exit cannot tell "not installed" from "ran and refused", so it is
   reported as-is and no second opener is run. *)
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

let open_url_with ~run ~kernel url =
  let name = opener_command (opener_for kernel) in
  match run (command_for ~opener:name ~url) with
  | Unix.WEXITED 0 -> Ok name
  | Unix.WEXITED code -> Error (Printf.sprintf "%s exited %d for %s" name code url)
  | Unix.WSIGNALED signal | Unix.WSTOPPED signal ->
    Error (Printf.sprintf "%s stopped by signal %d for %s" name signal url)

let open_url url =
  match host_kernel () with
  | Error reason -> Error reason
  | Ok kernel -> open_url_with ~run:Unix.system ~kernel url

type undrawn_image = { title : string; page_url : string; image_url : string }

let browser_url { title = _; page_url; image_url = _ } = page_url
