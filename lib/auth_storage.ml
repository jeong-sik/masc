(** Auth filesystem, bootstrap token, and crypto helpers. *)

(** Generate a cryptographically random token (hex string) *)
let generate_token () =
  let random_bytes = Mirage_crypto_rng.generate 32 in
  let hex = Buffer.create 64 in
  String.iter (fun c -> Printf.bprintf hex "%02x" (Char.code c)) random_bytes;
  Buffer.contents hex
;;
(** SHA256 hash of a string using Digestif *)
let sha256_hash input = Digestif.SHA256.(digest_string input |> to_hex)

(* ============================================ *)
(* Auth directory management                    *)
(* ============================================ *)

let auth_dir config = Common.auth_dir_from_base_path ~base_path:config
let agents_dir config = Common.agents_dir_from_base_path ~base_path:config
let room_secret_file config = Filename.concat (auth_dir config) "room_secret.hash"
let auth_config_file config = Filename.concat (auth_dir config) "config.json"
let initial_admin_file config = Filename.concat (auth_dir config) "initial_admin"

let internal_keeper_token_hash_file config =
  Filename.concat (auth_dir config) "internal_keeper.token.hash"
;;

let internal_keeper_token_env_key = "MASC_INTERNAL_MCP_TOKEN"
let run_blocking_io f = Eio_guard.run_in_systhread f
let file_exists path = run_blocking_io (fun () -> Sys.file_exists path)
let read_text_file path = Fs_compat.load_file path
let write_text_file path content = Fs_compat.save_file path content
let chmod path perm = run_blocking_io (fun () -> Unix.chmod path perm)
let read_dir path = run_blocking_io (fun () -> Sys.readdir path)
let remove_file path = run_blocking_io (fun () -> Sys.remove path)

(** Ensure auth directories exist *)
let ensure_auth_dirs config =
  let auth = auth_dir config in
  let agents = agents_dir config in
  Fs_compat.mkdir_p auth;
  Fs_compat.mkdir_p agents
;;

(** Write the initial admin agent name (bootstrap grace).
    The agent who enables auth is always granted full permission. *)
let write_initial_admin config agent_name =
  ensure_auth_dirs config;
  let file = initial_admin_file config in
  write_text_file file (String.trim agent_name);
  chmod file 0o600
;;

let save_private_text_file path content =
  run_blocking_io (fun () ->
    let oc = open_out_gen [ Open_wronly; Open_creat; Open_trunc; Open_text ] 0o600 path in
    (* This body already runs in a systhread; use plain OCaml cleanup so it
       does not require an Eio fiber context in that systhread. *)
    Fun.protect
      ~finally:(fun () -> close_out_noerr oc)
      (fun () -> output_string oc content));
  chmod path 0o600
;;

let load_internal_keeper_token_hash config =
  let file = internal_keeper_token_hash_file config in
  if file_exists file
  then (
    try
      let hash = String.trim (read_text_file file) in
      if hash = "" then None else Some hash
    with
    | Sys_error _ -> None)
  else None
;;

let save_internal_keeper_token_hash config ~raw_token =
  ensure_auth_dirs config;
  let file = internal_keeper_token_hash_file config in
  save_private_text_file file (sha256_hash raw_token)
;;

let verify_internal_keeper_token config ~token =
  match load_internal_keeper_token_hash config with
  | Some stored_hash -> String.equal stored_hash (sha256_hash token)
  | None -> false
;;

let ensure_internal_keeper_token config =
  let existing_env =
    match Sys.getenv_opt internal_keeper_token_env_key with
    | Some raw ->
      let trimmed = String.trim raw in
      if trimmed = "" then None else Some trimmed
    | None -> None
  in
  match existing_env with
  | Some raw_token ->
    save_internal_keeper_token_hash config ~raw_token;
    raw_token
  | None ->
    let raw_token = generate_token () in
    save_internal_keeper_token_hash config ~raw_token;
    Unix.putenv internal_keeper_token_env_key raw_token;
    raw_token
;;

(** Read the initial admin agent name, if set. *)
let read_initial_admin config : string option =
  let file = initial_admin_file config in
  if file_exists file
  then (
    try
      let name = String.trim (read_text_file file) in
      if name = "" then None else Some name
    with
    | Sys_error _ -> None)
  else None
;;
