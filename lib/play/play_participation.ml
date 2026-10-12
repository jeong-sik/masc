type t = Connected | Departed

(* The file key is the agent name, never the token: renewing a credential
   issues a new token, and a token-keyed name would orphan the departure
   record and read back as Connected. [Common.safe_filename] matches the
   credential store's file naming. *)
let path ~base_path (credential : Masc_domain.agent_credential) =
  Filename.concat (Filename.concat (Common.masc_dir_from_base_path ~base_path) "play")
    ("participation-" ^ Common.safe_filename credential.agent_name ^ ".state")

let read ~base_path credential =
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

let write ~base_path credential state =
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
  (* A Worker credential is an agent's MCP client, not a seat (Play_seat
     excludes it from the roster by role), so it has no browser session to
     depart. Its Keeper's input authority is the Keeper registry's. *)
  | Some { Masc_domain.role = Masc_domain.Worker; _ } -> Ok Connected
  | Some ({ Masc_domain.role = Masc_domain.Admin | Masc_domain.Player; _ } as credential) ->
    read ~base_path credential
