(** Coord Identity - Session and agent identity helpers.

    Extracted from room_state.ml. *)

open Coord_utils

let generate_session_id () =
  let t = Unix.gettimeofday () in
  Printf.sprintf "%04x%04x" (Hashtbl.hash t land 0xFFFF) (Hashtbl.hash (t *. 1000.0) land 0xFFFF)

let get_hostname () =
  try Some (Unix.gethostname ()) with Unix.Unix_error _ -> None

let get_tty () =
  try
    match Sys.getenv_opt "TTY" with
    | Some tty -> Some tty
    | None ->
        try
          if Unix.isatty Unix.stdin then
            let output = Process_eio.run_argv ~timeout_sec:5.0 ["tty"] in
            let trimmed = String.trim output in
            if String.length trimmed > 0 then Some trimmed else None
          else None
        with Unix.Unix_error _ -> None
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | e ->
    Log.Misc.error "get_tty failed: %s" (Printexc.to_string e);
    None

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
        String.sub f 0 (String.length prefix) = prefix
      ) files with
      | Some file -> String.sub file 0 (String.length file - 5)
      | None -> agent_name
    else
      agent_name
  end
