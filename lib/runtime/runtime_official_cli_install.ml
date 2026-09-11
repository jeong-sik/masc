type client = Codex | Claude | Antigravity
let name = function Codex -> "codex" | Claude -> "claude" | Antigravity -> "agy"
let source_url = function
  | Codex -> "https://developers.openai.com/codex/cli/"
  | Claude -> "https://code.claude.com/docs/en/installation"
  | Antigravity -> "https://antigravity.google/docs/cli/install/"
let script = function
  | Codex -> "https://chatgpt.com/codex/install.sh", "sh"
  | Claude -> "https://claude.ai/install.sh", "bash"
  | Antigravity -> "https://antigravity.google/cli/install.sh", "bash"
let executable client =
  let command = name client in
  let directories = match client, Env_config_core.raw_value_opt "CODEX_INSTALL_DIR" with
    | Codex, Some path when String.trim path <> "" -> [path]
    | _ -> (match Env_config_core.raw_value_opt "HOME" with Some home -> [Filename.concat home ".local/bin"] | None -> []) in
  let path = match Env_config_core.raw_value_opt "PATH" with
    | Some path -> String.split_on_char ':' path
    | None -> [] in
  (directories @ path) |> List.find_map (fun directory ->
    if directory = "" then None else
    let candidate = Filename.concat directory command in
    try
      let candidate = Unix.realpath candidate in
      Unix.access candidate [Unix.X_OK];
      if (Unix.stat candidate).st_kind = Unix.S_REG then Some candidate else None
    with Unix.Unix_error _ -> None)
let install ~run client =
  let ( let* ) = Result.bind in
  try
    let directory = Filename.temp_dir "masc-official-client-install-" "" in
    Fun.protect ~finally:(fun () -> Fs_compat.remove_tree directory) (fun () ->
      let url, shell = script client in
      let path = Filename.concat directory "install.sh" in
      let* () = run ["curl"; "--fail"; "--show-error"; "--location";
        "--proto"; "=https"; "--proto-redir"; "=https"; "--max-time"; "300";
        "--output"; path; url]
        |> Result.map_error (fun _ -> "The official installer could not be downloaded. Check network access and retry.") in
      let info = Unix.lstat path in
      if info.st_kind <> Unix.S_REG || info.st_uid <> Unix.geteuid () || info.st_size = 0
      then Error "The official installer download was not a regular nonempty file."
      else (
        let* () = run [shell; path]
          |> Result.map_error (fun _ -> "The vendor installer did not complete. Review its terminal output and retry.") in
        match executable client with
        | None -> Error "The installer finished, but the client executable was not found. Use its official instructions or retry."
        | Some path -> run [path; "--version"]
          |> Result.map_error (fun _ -> "The installed client could not start. Review the vendor's system requirements.")))
  with Sys_error _ | Unix.Unix_error _ -> Error "The installer could not prepare or inspect its private files."
