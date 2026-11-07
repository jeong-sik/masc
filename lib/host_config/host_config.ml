(* RFC-0084 §1.5, §3.4 + RFC-0085 PR-1 — Typed host configuration.

   PR-1 of RFC-0085 (this commit):
   - Renames `legacy_macos_default ()` -> `host ()` (canonical accessor).
   - Renames inner `legacy_coreutils_macos` -> `coreutils_defaults`.
   - Adds `log_dir`, `run_dir`, `policy_dir` fields (RFC-0085 PR-2/PR-3
     absorb the corresponding host-local runtime path hardcodes).
   - Applies [@@deriving show, eq] to all record / variant types,
     replacing the ~35 lines of manual pp implementations.

   See host_config.mli for the contract. *)

type test_mode_kind =
  | Test
  | Production
[@@deriving show, eq]

type base_path_lease_root =
  | Beside_base_path
  | Lease_dir_override of string
[@@deriving show, eq]

type t =
  { cred_root : string
  ; host_bash : string
  ; host_zsh : string
  ; host_sh : string
  ; agent_runtime_root : string
  ; sandbox_workspace_root : string
  ; test_mode : test_mode_kind
  ; log_dir : string
  ; run_dir : string
  ; base_path_lease_root : base_path_lease_root
  ; policy_dir : string
  ; base_path : string option
  ; base_path_raw : string option
  ; config_dir : string option
  ; home : string option
  ; assets_dir : string option
  }
[@@deriving show, eq]

let base_path_lease_dir_env_key = "MASC_BASE_PATH_LEASE_DIR"

let base_path_lease_root_of_env get_opt =
  match get_opt base_path_lease_dir_env_key with
  | Some dir -> Lease_dir_override dir
  | None -> Beside_base_path
;;

let host () =
  let tmp = Filename.get_temp_dir_name () in
  let get_opt key =
    match Sys.getenv_opt key with
    | None -> None
    | Some s -> if String.trim s = "" then None else Some s
  in
  let base_path_raw =
    Env_config_core.base_path_source_opt () |> Option.map snd
  in
  let base_path =
    base_path_raw |> Option.map Env_config_core.normalize_masc_base_path_input
  in
  let default_workspace_root fallback =
    match base_path with
    | Some root -> root
    | None -> fallback
  in
  { cred_root = Filename.concat tmp "keeper-creds"
  ; host_bash = "/bin/bash"
  ; host_zsh = "/bin/zsh"
  ; host_sh = "/bin/sh"
  ; agent_runtime_root = tmp
  ; sandbox_workspace_root = default_workspace_root (Filename.concat tmp "masc-fleet")
  ; test_mode =
      (let exec =
         Sys.executable_name |> Filename.basename |> String.lowercase_ascii
       in
       if String.starts_with ~prefix:"test_" exec
       then Test
       else Production)
  ; log_dir = tmp
  ; run_dir = tmp
  ; base_path_lease_root = base_path_lease_root_of_env get_opt
  ; policy_dir = tmp
  ; base_path =
      (* RFC-0085 PR-9 — base_path field carries the *normalised* value
         (previously Env_config_core.base_path_opt).  Empty / missing
         env returns None; non-empty trimmed values are passed through
         Env_config_core.normalize_masc_base_path_input. *)
      base_path
  ; base_path_raw
  ; config_dir = get_opt Env_config_core.config_dir_env_key
  ; home = get_opt "HOME"
  ; assets_dir = get_opt "MASC_ASSETS_DIR"
  }
;;

let from_env = host

let is_test_mode = function
  | Test -> true
  | Production -> false
;;

