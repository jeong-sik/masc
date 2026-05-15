(* RFC-0084 §1.5, §3.4 — Typed host configuration.
   See host_config.mli for the contract. *)

type coreutils =
  { ls : string
  ; cat : string
  ; pwd : string
  ; head : string
  ; tail : string
  ; wc : string
  }

type test_mode_kind =
  | Test
  | Production

type t =
  { cred_root : string
  ; host_bash : string
  ; host_zsh : string
  ; host_sh : string
  ; coreutils : coreutils
  ; agent_runtime_root : string
  ; sandbox_workspace_root : string
  ; test_mode : test_mode_kind
  }

let legacy_coreutils_macos =
  { ls = "/bin/ls"
  ; cat = "/bin/cat"
  ; pwd = "/bin/pwd"
  ; head = "/usr/bin/head"
  ; tail = "/usr/bin/tail"
  ; wc = "/usr/bin/wc"
  }
;;

let legacy_macos_default () =
  let tmpdir = Filename.get_temp_dir_name () in
  { cred_root =
      (match Sys.getenv_opt "MASC_CRED_ROOT" with
       | Some p -> p
       | None -> Filename.concat tmpdir "keeper-creds")
  ; host_bash = "/bin/bash"
  ; host_zsh = "/bin/zsh"
  ; host_sh = "/bin/sh"
  ; coreutils = legacy_coreutils_macos
  ; agent_runtime_root = tmpdir
  ; sandbox_workspace_root =
      (match Sys.getenv_opt "HOME" with
       | Some home -> Filename.concat home "me"
       | None -> Filename.concat tmpdir "masc-fleet")
  ; test_mode =
      (let exec = Filename.basename Sys.executable_name in
       if String.length exec >= 5 && String.sub exec 0 5 = "test_"
       then Test
       else Production)
  }
;;

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
  let one ~name ~candidates ~fallback = path_lookup ~candidates ~fallback in
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
  let base = Option.value base_path ~default:"/tmp" in
  let agent_runtime_root = Filename.concat base ".masc/runtime/agent" in
  let cred_root = Filename.concat base ".masc/credentials" in
  let sandbox_workspace_root =
    match Sys.getenv_opt "MASC_SANDBOX_ROOT" with
    | Some s -> s
    | None ->
      (match Sys.getenv_opt "HOME" with
       | Some home -> Filename.concat home "me"
       | None -> Filename.concat base "fleet")
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
    }
;;

let pp_coreutils fmt c =
  Format.fprintf
    fmt
    "{ ls=%s cat=%s pwd=%s head=%s tail=%s wc=%s }"
    c.ls
    c.cat
    c.pwd
    c.head
    c.tail
    c.wc
;;

let pp_test_mode fmt = function
  | Test -> Format.fprintf fmt "Test"
  | Production -> Format.fprintf fmt "Production"
;;

let pp fmt t =
  Format.fprintf
    fmt
    "{ cred_root=%s; host_bash=%s; host_zsh=%s; host_sh=%s; coreutils=%a; \
     agent_runtime_root=%s; sandbox_workspace_root=%s; test_mode=%a }"
    t.cred_root
    t.host_bash
    t.host_zsh
    t.host_sh
    pp_coreutils
    t.coreutils
    t.agent_runtime_root
    t.sandbox_workspace_root
    pp_test_mode
    t.test_mode
;;
