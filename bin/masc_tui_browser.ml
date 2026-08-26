(** See masc_tui_browser.mli. *)

let openers = [ "open"; "xdg-open" ]

let command_for ~opener ~url = Printf.sprintf "%s %s" opener (Filename.quote url)

let open_url url =
  let rec attempt = function
    | [] ->
      Error
        (Printf.sprintf "no way to open a link here; tried %s"
           (String.concat ", " openers))
    | opener :: rest -> (
      match Unix.system (command_for ~opener ~url) with
      | Unix.WEXITED 0 -> Ok opener
      (* A missing opener exits non-zero through the shell, same as one that
         ran and refused. Trying the next either way costs one process and
         keeps this from having to tell those apart. *)
      | Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _ -> attempt rest)
  in
  attempt openers
