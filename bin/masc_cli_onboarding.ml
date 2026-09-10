let executable path =
  try Unix.access path [Unix.X_OK]; true with Unix.Unix_error _ -> false

let python binary =
  let bundled = Filename.concat (Filename.dirname binary) "python/bin/python3" in
  if executable bundled then Some bundled
  else
    Option.bind (Sys.getenv_opt "PATH") (fun path ->
      String.split_on_char ':' path
      |> List.filter (fun directory -> directory <> "")
      |> List.find_map (fun directory ->
        let candidate = Filename.concat directory "python3" in
        if executable candidate then Some candidate else None))

let rec wait pid =
  match Unix.waitpid [] pid with
  | _, Unix.WEXITED code -> code
  | _, (Unix.WSIGNALED _ | Unix.WSTOPPED _) -> 1
  | exception Unix.Unix_error (Unix.EINTR, _, _) -> wait pid

let run ~base_path ~port ~resume ~sandbox_step =
  try
    let binary = Unix.realpath Sys.executable_name in
    match python binary with
    | None ->
      prerr_endline "Setup needs Python 3. Reinstall the complete MASC release to restore its bundled Python, or install Python 3 and run masc setup again.";
      1
    | Some python ->
      let path, channel = Filename.open_temp_file ~perms:0o600 "masc-setup-" ".py" in
      (* This is the synchronous CLI boundary, outside Eio fibers. *)
      Fun.protect ~finally:(fun () ->
        close_out_noerr channel;
        try Sys.remove path with Sys_error _ -> ()) (fun () ->
        output_string channel Embedded_setup.script;
        close_out channel;
        let argv = [python; "-B"; path; "--binary"; binary; (if sandbox_step then "--sandbox-step" else "--journey")]
          @ (match port with None -> [] | Some port -> ["--port"; string_of_int port])
          @ (if resume then ["--resume"] else [])
          @ (match base_path with Some path -> ["--base-path"; path] | None -> []) in
        Unix.create_process python (Array.of_list argv) Unix.stdin Unix.stdout Unix.stderr
        |> wait)
  with
  | Unix.Unix_error (error, _, _) ->
    Printf.eprintf "Setup could not start: %s\n" (Unix.error_message error); 1
  | Sys_error _ -> prerr_endline "Setup could not open its private temporary helper."; 1
