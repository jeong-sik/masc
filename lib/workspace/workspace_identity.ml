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
  if path_exists config exact_file then
    agent_name
  else begin
    let dir = agents_dir config in
    let prefix = safe_filename agent_name ^ "-" in
    let suffix = ".json" in
    let min_len = String.length prefix + String.length suffix in
    match
      list_dir config dir
      |> List.sort String.compare
      |> List.find_opt (fun f ->
           Filename.check_suffix f suffix
           && String.length f > min_len
           && String.starts_with f ~prefix)
    with
    | Some file -> Filename.chop_suffix file suffix
    | None -> agent_name
  end
