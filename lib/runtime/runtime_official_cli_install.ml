type client = Codex | Claude | Antigravity | Mistral_vibe | Kimi_code
let name = function
  | Codex -> "codex"
  | Claude -> "claude"
  | Antigravity -> "agy"
  | Mistral_vibe -> "vibe-acp"
  | Kimi_code -> "kimi"
let source_url = function
  | Codex -> "https://developers.openai.com/codex/cli/"
  | Claude -> "https://code.claude.com/docs/en/installation"
  | Antigravity -> "https://antigravity.google/docs/cli/install/"
  | Mistral_vibe -> "https://github.com/mistralai/mistral-vibe"
  | Kimi_code -> "https://www.kimi.com/coding/docs/en/kimi-cli.html"
let script = function
  | Codex -> "https://chatgpt.com/codex/install.sh", "sh"
  | Claude -> "https://claude.ai/install.sh", "bash"
  | Antigravity -> "https://antigravity.google/cli/install.sh", "bash"
  | Mistral_vibe -> "https://mistral.ai/vibe/install.sh", "sh"
  | Kimi_code -> "https://code.kimi.com/install.sh", "sh"
(* An executable regular file at [path], as the path was given. [stat] follows
   a link, so a link to such a file passes; the path returned is the link,
   not its target. The Claude Code installer keeps ~/.local/bin/claude as a
   link into a versioned directory that an update replaces, so the link is
   the name that stays valid. *)
let runnable path =
  match
    (Unix.access path [ Unix.X_OK ];
     (Unix.stat path).st_kind)
  with
  | Unix.S_REG -> Some path
  | Unix.S_DIR | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO | Unix.S_SOCK -> None
  | exception Unix.Unix_error _ -> None
;;

(* A PATH entry the spawn can use. A shell reads an empty or relative entry
   against the directory it is in; what is found here is spawned later from a
   keeper's own working directory, where the same relative entry names
   somewhere else, so only absolute entries are searched. *)
let path_directories () =
  match Env_config_core.raw_value_opt "PATH" with
  | Some path ->
    List.filter
      (fun directory -> directory <> "" && not (Filename.is_relative directory))
      (String.split_on_char ':' path)
  | None -> []
;;

let install_dir_variable = function
  | Codex -> Some "CODEX_INSTALL_DIR"
  | Mistral_vibe | Kimi_code -> Some "UV_TOOL_BIN_DIR"
  | Claude | Antigravity -> None

(* Where the vendor installer writes the client: the client's install
   directory variable when it is set, else ~/.local/bin (and ~/.cargo/bin for
   uv-installed ACP clients such as vibe-acp and kimi). *)
let vendor_directories client =
  let explicit =
    match Option.bind (install_dir_variable client) Env_config_core.raw_value_opt with
    | Some path when String.trim path <> "" ->
      (* Vendor installers accept relative destinations against setup's cwd.
         Persist that same destination as an absolute spelling: the eventual
         native process runs from another workspace. Do not resolve symlinks. *)
      [ if Filename.is_relative path then Filename.concat (Sys.getcwd ()) path else path ]
    | Some _ | None -> []
  in
  let home_fallbacks =
    match Env_config_core.raw_value_opt "HOME" with
    | Some home ->
      let local_bin = Filename.concat home ".local/bin" in
      (match client with
       | Mistral_vibe | Kimi_code ->
         [ local_bin; Filename.concat home ".cargo/bin" ]
       | Codex | Claude | Antigravity -> [ local_bin ])
    | None -> []
  in
  match client, explicit with
  | Codex, _ :: _ -> explicit
  | (Codex | Claude | Antigravity | Mistral_vibe | Kimi_code), _ ->
    explicit @ home_fallbacks
;;

(* Explicit relative paths belong to the materialization cwd, not the later
   native workspace. Keep their symlink spelling for vendor updates. *)
let explicit_path command =
  if String.contains command '/' && Filename.is_relative command
  then Filename.concat (Sys.getcwd ()) command
  else command
;;

let locate client ~command =
  if String.contains command '/'
  then runnable (explicit_path command)
  else (
    let first_in directories =
      List.find_map (fun directory -> runnable (Filename.concat directory command)) directories
    in
    match first_in (path_directories ()) with
    | Some path -> Some path
    | None ->
      if String.equal command (name client) then first_in (vendor_directories client) else None)
;;

let executable client = locate client ~command:(name client)

let spawn_path client ~command =
  match locate client ~command with
  | Some path -> path
  | None -> explicit_path command
;;

let install ~run client =
  let open Result.Syntax in
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
