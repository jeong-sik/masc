(** Exact runtime-binary resolution for process-level tests.

    The caller or Dune owns binary selection.  This helper deliberately does
    not search parent directories: a test running from a worktree must never
    escape to a sibling or parent checkout's build artifact. *)

let candidate ~env_override ~dune_sourceroot =
  match env_override with
  | Some "" -> Error "MASC_MAIN_EIO_EXE is set but empty"
  | Some path -> Ok path
  | None ->
    (match dune_sourceroot with
     | Some "" -> Error "DUNE_SOURCEROOT is set but empty"
     | Some root -> Ok (Filename.concat root "_build/default/bin/main_eio.exe")
     | None ->
       Error
         "main_eio executable is unbound; run via Dune or set MASC_MAIN_EIO_EXE")

let validate path =
  try
    let stat = Unix.stat path in
    if stat.st_kind <> Unix.S_REG then
      Error (Printf.sprintf "main_eio path is not a regular file: %s" path)
    else begin
      Unix.access path [ Unix.X_OK ];
      Ok (Unix.realpath path)
    end
  with
  | Unix.Unix_error (error, operation, _) ->
    Error
      (Printf.sprintf "main_eio executable is unusable (%s: %s): %s" operation
         (Unix.error_message error) path)

let resolve ~env_override ~dune_sourceroot =
  match candidate ~env_override ~dune_sourceroot with
  | Error _ as error -> error
  | Ok path -> validate path

let find_main_eio_exe () =
  match
    resolve ~env_override:(Sys.getenv_opt "MASC_MAIN_EIO_EXE")
      ~dune_sourceroot:(Sys.getenv_opt "DUNE_SOURCEROOT")
  with
  | Error detail -> failwith detail
  | Ok path ->
    Printf.eprintf "[masc-test-runtime] main_eio=%s\n%!" path;
    path
