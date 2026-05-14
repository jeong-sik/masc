(* RFC-0070 Phase 3e (e) — session Plan, pure construction. See .mli. *)

type ulimit =
  { name : string
  ; soft : int
  ; hard : int
  }

type seccomp_choice =
  | Seccomp_default
  | Seccomp_unconfined
  | Seccomp_profile_file of string

type plan_error =
  | Invalid_meta_name of string
  | Invalid_container_root of string
  | Invalid_host_root of string

(* Named constants — CLAUDE.md §Magic Number 금지. *)
let default_hash_algo = Keeper_hash_algo.SHA_256
let nofile_ulimit_name = "nofile"

(* MUST match Keeper_sandbox_runtime.docker_identity_dir's subdir +
   Keeper_sandbox_runtime.docker_user_identity_mount_args's file names
   and mount targets. (Re-stated here rather than depending on those —
   docker_user_identity_mount_args also does file I/O which a pure plan
   cannot call; a later refactor may extract the pure path/content bit
   into a shared module.) *)
let identity_subdir = ".docker-identity"
let identity_passwd_file = "passwd"
let identity_group_file = "group"
let identity_passwd_target = "/etc/passwd"
let identity_group_target = "/etc/group"

(* MUST match the literal in keeper_turn_sandbox_runtime.start_container's
   trailing [ image; "sh"; "-lc"; <this> ] argv. *)
let idle_startup_command = "trap : TERM INT; while :; do sleep 3600; done"

type t =
  { container_name : Keeper_container_name.t
  ; image : string
  ; container_root : string
  ; mounts : string list
  ; identity_files : (string * string) list
  ; env_overrides : (string * string) list
  ; network_mode : Keeper_types.network_mode
  ; user : (int * int) option
  ; ulimits : ulimit list
  ; read_only_rootfs : bool
  ; tmpfs_mount : string
  ; workdir : string option
  ; startup_command : string
  ; labels : (string * string) list
  ; cap_drop_all : bool
  ; no_new_privileges : bool
  ; seccomp_profile : seccomp_choice
  ; pids_limit : int
  ; memory_limit : string
  }

(* The 7 deterministic labels, byte-identical to the deterministic
   subset of Keeper_sandbox_runtime.docker_label_args (which also emits
   owner_pid + started_at — those are added by the edge). The keys and
   the [sandbox_component_label_value] / [base_path_hash] /
   [sanitize_label_value] helpers come from Keeper_sandbox_runtime so
   they cannot drift. *)
let deterministic_labels ~base_path ~meta_name ~container_kind ~network_mode ~ttl_sec =
  let open Keeper_sandbox_runtime in
  let network_label =
    sanitize_label_value (Keeper_types.network_mode_to_string network_mode)
  in
  let base =
    [ sandbox_component_label_key, sandbox_component_label_value
    ; sandbox_base_path_hash_label_key, base_path_hash base_path
    ; sandbox_keeper_label_key, sanitize_label_value meta_name
    ; sandbox_kind_label_key, sanitize_label_value container_kind
    ; sandbox_network_label_key, network_label
    ]
  in
  match ttl_sec with
  | Some value when value > 0.0 ->
    base @ [ sandbox_ttl_sec_label_key, Printf.sprintf "%.0f" value ]
  | _ -> base
;;

let identity_paths ~host_root =
  let dir = Filename.concat host_root identity_subdir in
  Filename.concat dir identity_passwd_file, Filename.concat dir identity_group_file
;;

let identity_passwd_content ~uid ~gid =
  Printf.sprintf
    "root:x:0:0:root:/root:/bin/sh\nkeeper:x:%d:%d:MASC Keeper:/tmp:/bin/sh\n"
    uid
    gid
;;

let identity_group_content ~gid = Printf.sprintf "root:x:0:\nkeeper:x:%d:\n" gid

let docker_env_overrides ~extra_env =
  [ "HOME", "/tmp"; "USER", "keeper"; "LOGNAME", "keeper"; "SHELL", "/bin/sh" ] @ extra_env
;;

let of_request
      ~turn_id
      ~attempt
      ~meta_name
      ~image
      ~container_root
      ~base_path
      ~container_kind
      ~network_mode
      ~host_root
      ~uid
      ~gid
      ?ttl_sec
      ?(extra_env = [])
      ()
  =
  if String.equal meta_name "" then Error (Invalid_meta_name meta_name)
  else if String.equal container_root "" then Error (Invalid_container_root container_root)
  else if String.equal host_root "" then Error (Invalid_host_root host_root)
  else (
    let container_name =
      Keeper_container_name.derive
        ~algo:default_hash_algo
        ~turn_id
        ~attempt
        ~suffix:meta_name
    in
    let passwd_path, group_path = identity_paths ~host_root in
    let workspace_mount = host_root ^ ":" ^ container_root ^ ":rw" in
    let identity_mounts =
      [ passwd_path ^ ":" ^ identity_passwd_target ^ ":ro"
      ; group_path ^ ":" ^ identity_group_target ^ ":ro"
      ]
    in
    let nofile = Env_config_keeper.KeeperSandbox.nofile_limit () in
    Ok
      { container_name
      ; image
      ; container_root
      ; mounts = workspace_mount :: identity_mounts
      ; identity_files =
          [ passwd_path, identity_passwd_content ~uid ~gid
          ; group_path, identity_group_content ~gid
          ]
      ; env_overrides = docker_env_overrides ~extra_env
      ; network_mode
      ; user = Some (uid, gid)
      ; ulimits = [ { name = nofile_ulimit_name; soft = nofile; hard = nofile } ]
      ; read_only_rootfs =
          Env_config_keeper.KeeperSandbox.read_only_rootfs_args () <> []
      ; tmpfs_mount = Env_config_keeper.KeeperSandbox.tmpfs_mount ()
      ; workdir = Some container_root
      ; startup_command = idle_startup_command
      ; labels =
          deterministic_labels
            ~base_path
            ~meta_name
            ~container_kind
            ~network_mode
            ~ttl_sec
      ; cap_drop_all = true
      ; no_new_privileges = true
      ; seccomp_profile = Seccomp_default
      ; pids_limit = Env_config_keeper.KeeperSandbox.pids_limit ()
      ; memory_limit = Env_config_keeper.KeeperSandbox.memory ()
      })
;;

let container_name t = t.container_name
let image t = t.image
let container_root t = t.container_root
let mounts t = t.mounts
let identity_files t = t.identity_files
let env_overrides t = t.env_overrides
let network_mode t = t.network_mode
let user t = t.user
let ulimits t = t.ulimits
let read_only_rootfs t = t.read_only_rootfs
let tmpfs_mount t = t.tmpfs_mount
let workdir t = t.workdir
let startup_command t = t.startup_command
let labels t = t.labels
let cap_drop_all t = t.cap_drop_all
let no_new_privileges t = t.no_new_privileges
let seccomp_profile t = t.seccomp_profile
let pids_limit t = t.pids_limit
let memory_limit t = t.memory_limit

let equal_ulimit a b =
  String.equal a.name b.name && a.soft = b.soft && a.hard = b.hard
;;

let equal_seccomp a b =
  match a, b with
  | Seccomp_default, Seccomp_default | Seccomp_unconfined, Seccomp_unconfined -> true
  | Seccomp_profile_file x, Seccomp_profile_file y -> String.equal x y
  | (Seccomp_default | Seccomp_unconfined | Seccomp_profile_file _), _ -> false
;;

let equal_pairs a b =
  List.length a = List.length b
  && List.for_all2 (fun (k1, v1) (k2, v2) -> String.equal k1 k2 && String.equal v1 v2) a b
;;

let equal a b =
  Keeper_container_name.equal a.container_name b.container_name
  && String.equal a.image b.image
  && String.equal a.container_root b.container_root
  && List.equal String.equal a.mounts b.mounts
  && equal_pairs a.identity_files b.identity_files
  && equal_pairs a.env_overrides b.env_overrides
  && a.network_mode = b.network_mode
  && a.user = b.user
  && List.equal equal_ulimit a.ulimits b.ulimits
  && Bool.equal a.read_only_rootfs b.read_only_rootfs
  && String.equal a.tmpfs_mount b.tmpfs_mount
  && Option.equal String.equal a.workdir b.workdir
  && String.equal a.startup_command b.startup_command
  && equal_pairs a.labels b.labels
  && Bool.equal a.cap_drop_all b.cap_drop_all
  && Bool.equal a.no_new_privileges b.no_new_privileges
  && equal_seccomp a.seccomp_profile b.seccomp_profile
  && a.pids_limit = b.pids_limit
  && String.equal a.memory_limit b.memory_limit
;;

let pp ppf t =
  Format.fprintf
    ppf
    "@[<v 2>Sandbox_session_plan {@,container_name = %a;@,image = %S;@,container_root = \
     %S;@,mounts = [%s];@,labels = [%s]@]@,}"
    Keeper_container_name.pp
    t.container_name
    t.image
    t.container_root
    (String.concat "; " t.mounts)
    (String.concat "; " (List.map (fun (k, v) -> k ^ "=" ^ v) t.labels))
;;
