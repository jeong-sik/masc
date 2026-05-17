(* RFC-0084 §1.5, §3.4 + RFC-0085 PR-1 — Typed host configuration.

   PR-1 of RFC-0085 (this commit):
   - Renames `legacy_macos_default ()` -> `host ()` (canonical accessor).
   - Renames inner `legacy_coreutils_macos` -> `coreutils_defaults`.
   - Adds `log_dir`, `run_dir`, `policy_dir` fields (RFC-0085 PR-2/PR-3
     absorb the corresponding host-local runtime path hardcodes).
   - Applies [@@deriving show, eq] to all record / variant types,
     replacing the ~35 lines of manual pp implementations.

   See host_config.mli for the contract. *)

type coreutils =
  { ls : string
  ; cat : string
  ; pwd : string
  ; head : string
  ; tail : string
  ; wc : string
  }
[@@deriving show, eq]

type test_mode_kind =
  | Test
  | Production
[@@deriving show, eq]

type t =
  { cred_root : string
  ; host_bash : string
  ; host_zsh : string
  ; host_sh : string
  ; coreutils : coreutils
  ; agent_runtime_root : string
  ; sandbox_workspace_root : string
  ; test_mode : test_mode_kind
  ; log_dir : string
  ; run_dir : string
  ; policy_dir : string
  ; base_path : string option
  ; base_path_raw : string option
  ; config_dir : string option
  ; data_dir : string option
  ; personas_dir : string option
  ; home : string option
  ; assets_dir : string option
  }
[@@deriving show, eq]

let coreutils_defaults =
  { ls = "/bin/ls"
  ; cat = "/bin/cat"
  ; pwd = "/bin/pwd"
  ; head = "/usr/bin/head"
  ; tail = "/usr/bin/tail"
  ; wc = "/usr/bin/wc"
  }
;;

let host () =
  let tmp = Filename.get_temp_dir_name () in
  let get_opt key =
    match Sys.getenv_opt key with
    | None -> None
    | Some s -> if String.trim s = "" then None else Some s
  in
  let default_workspace_root fallback =
    match get_opt "MASC_BASE_PATH" with
    | Some root -> Env_config_core.normalize_masc_base_path_input root
    | None -> fallback
  in
  { cred_root = Filename.concat tmp "keeper-creds"
  ; host_bash = "/bin/bash"
  ; host_zsh = "/bin/zsh"
  ; host_sh = "/bin/sh"
  ; coreutils = coreutils_defaults
  ; agent_runtime_root = tmp
  ; sandbox_workspace_root = default_workspace_root (Filename.concat tmp "masc-fleet")
  ; test_mode =
      (let exec = Filename.basename Sys.executable_name in
       if String.length exec >= 5 && String.sub exec 0 5 = "test_"
       then Test
       else Production)
  ; log_dir = tmp
  ; run_dir = tmp
  ; policy_dir = tmp
  ; base_path =
      (* RFC-0085 PR-9 — base_path field carries the *normalised* value
         (previously Env_config_core.base_path_opt).  Empty / missing
         env returns None; non-empty trimmed values are passed through
         Env_config_core.normalize_masc_base_path_input. *)
      get_opt "MASC_BASE_PATH"
      |> Option.map Env_config_core.normalize_masc_base_path_input
      |> (function
        | Some "" -> None
        | other -> other)
  ; base_path_raw = get_opt "MASC_BASE_PATH"
  ; config_dir = get_opt "MASC_CONFIG_DIR"
  ; data_dir = get_opt "MASC_DATA_DIR"
  ; personas_dir = get_opt "MASC_PERSONAS_DIR"
  ; home = get_opt "HOME"
  ; assets_dir = get_opt "MASC_ASSETS_DIR"
  }
;;

let from_env = host

let is_test_mode = function
  | Test -> true
  | Production -> false
;;

let path_lookup ~candidates ~fallback =
  let exists p =
    try
      let st = Unix.stat p in
      st.st_kind = Unix.S_REG
    with
    | Unix.Unix_error _ -> false
  in
  match List.find_opt exists candidates with
  | Some p -> p
  | None -> fallback
;;

let resolve_bash () =
  path_lookup ~candidates:[ "/bin/bash"; "/usr/bin/bash" ] ~fallback:"/bin/bash"
;;

let resolve_zsh () =
  path_lookup ~candidates:[ "/usr/bin/zsh"; "/bin/zsh" ] ~fallback:"/bin/zsh"
;;

let resolve_sh () =
  path_lookup ~candidates:[ "/bin/sh"; "/usr/bin/sh" ] ~fallback:"/bin/sh"
;;

let resolve_coreutils () =
  let one ~name:_ ~candidates ~fallback = path_lookup ~candidates ~fallback in
  { ls = one ~name:"ls" ~candidates:[ "/bin/ls"; "/usr/bin/ls" ] ~fallback:"/bin/ls"
  ; cat =
      one ~name:"cat" ~candidates:[ "/bin/cat"; "/usr/bin/cat" ] ~fallback:"/bin/cat"
  ; pwd =
      one ~name:"pwd" ~candidates:[ "/bin/pwd"; "/usr/bin/pwd" ] ~fallback:"/bin/pwd"
  ; head =
      one
        ~name:"head"
        ~candidates:[ "/usr/bin/head"; "/bin/head" ]
        ~fallback:"/usr/bin/head"
  ; tail =
      one
        ~name:"tail"
        ~candidates:[ "/usr/bin/tail"; "/bin/tail" ]
        ~fallback:"/usr/bin/tail"
  ; wc =
      one ~name:"wc" ~candidates:[ "/usr/bin/wc"; "/bin/wc" ] ~fallback:"/usr/bin/wc"
  }
;;

let resolve ?base_path () =
  let tmp = Filename.get_temp_dir_name () in
  let base = Option.value base_path ~default:tmp in
  let get_opt key =
    match Sys.getenv_opt key with
    | None -> None
    | Some s -> if String.trim s = "" then None else Some s
  in
  let default_workspace_root fallback =
    match get_opt "MASC_BASE_PATH" with
    | Some root -> Env_config_core.normalize_masc_base_path_input root
    | None -> fallback
  in
  let agent_runtime_root = Filename.concat base ".masc/runtime/agent" in
  let cred_root = Filename.concat base ".masc/credentials" in
  let sandbox_workspace_root =
    match Sys.getenv_opt "MASC_SANDBOX_ROOT" with
    | Some s -> s
    | None -> default_workspace_root (Filename.concat base "fleet")
  in
  let test_mode =
    let exec = Filename.basename Sys.executable_name in
    if String.length exec >= 5 && String.sub exec 0 5 = "test_"
    then Test
    else Production
  in
  Ok
    { cred_root
    ; host_bash = resolve_bash ()
    ; host_zsh = resolve_zsh ()
    ; host_sh = resolve_sh ()
    ; coreutils = resolve_coreutils ()
    ; agent_runtime_root
    ; sandbox_workspace_root
    ; test_mode
    ; log_dir = tmp
    ; run_dir = tmp
    ; policy_dir = tmp
    ; base_path =
        get_opt "MASC_BASE_PATH"
        |> Option.map Env_config_core.normalize_masc_base_path_input
        |> (function
          | Some "" -> None
          | other -> other)
    ; base_path_raw = get_opt "MASC_BASE_PATH"
    ; config_dir = get_opt "MASC_CONFIG_DIR"
    ; data_dir = get_opt "MASC_DATA_DIR"
    ; personas_dir = get_opt "MASC_PERSONAS_DIR"
    ; home = get_opt "HOME"
    ; assets_dir = get_opt "MASC_ASSETS_DIR"
    }
;;
