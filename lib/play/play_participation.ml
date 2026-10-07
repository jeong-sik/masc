type t = Connected | Departed

let path ~base_path (credential : Masc_domain.agent_credential) =
  let generation = Digestif.SHA256.(digest_string
    (credential.agent_name ^ "\000" ^ credential.token) |> to_hex) in
  Filename.concat (Filename.concat (Common.masc_dir_from_base_path ~base_path) "play")
    ("participation-" ^ generation ^ ".state")

let read ~transaction:_ ~base_path credential =
  Eio_guard.run_in_systhread ~label:"play-participation-read" (fun () ->
    let file = path ~base_path credential in
    try
      let stat = Unix.lstat file in
      if stat.Unix.st_kind <> Unix.S_REG then Error "play participation is not a regular file"
      else match In_channel.with_open_bin file In_channel.input_all with
        | "connected\n" -> Ok Connected
        | "departed\n" -> Ok Departed
        | _ -> Error "play participation is malformed"
    with
    | Unix.Unix_error (Unix.ENOENT, _, _) -> Ok Connected
    | (Unix.Unix_error _ | Sys_error _) as exn -> Error (Printexc.to_string exn))

let write ~transaction:_ ~base_path credential state =
  Eio_guard.run_in_systhread ~label:"play-participation-write" (fun () ->
    let file = path ~base_path credential in
    try
      Fs_compat.mkdir_p (Filename.dirname file);
      Fs_compat.save_file_atomic_strict file
        (match state with Connected -> "connected\n" | Departed -> "departed\n")
    with (Unix.Unix_error _ | Sys_error _ | Eio.Io _) as exn -> Error (Printexc.to_string exn))

let current ~transaction ~base_path ~name =
  let ( let* ) = Result.bind in
  let* credential = Auth.current_credential_in_transaction transaction name
    |> Result.map_error Masc_domain.masc_error_to_string in
  match credential with
  | None -> Ok Connected
  | Some credential -> read ~transaction ~base_path credential
