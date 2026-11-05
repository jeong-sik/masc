(** Workspace Identity - Session and agent identity helpers.

    Extracted from workspace_state.ml. *)

open Workspace_utils

let generate_session_id () =
  Random_id.hex ~bytes:16

let get_hostname () =
  try Some (Unix.gethostname ()) with Unix.Unix_error _ -> None

(* The [TTY] the environment names. A child run through [Process_eio] reads
   an empty stdin (#46850), so [tty] run there answers "not a tty". *)
let get_tty () = Sys.getenv_opt "TTY"

let resolve_agent_name config agent_name =
  let exact_file = Filename.concat (agents_dir config) (safe_filename agent_name ^ ".json") in
  if Sys.file_exists exact_file then
    agent_name
  else begin
    let dir = agents_dir config in
    if Sys.file_exists dir then
      let files = Sys.readdir dir in
      let prefix = agent_name ^ "-" in
      match Array.find_opt (fun f ->
        String.length f > String.length prefix &&
        String.starts_with f ~prefix
      ) files with
      | Some file -> String.sub file 0 (String.length file - 5)
      | None -> agent_name
    else
      agent_name
  end
