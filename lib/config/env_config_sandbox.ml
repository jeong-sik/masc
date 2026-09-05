(** Env_config_sandbox — sandbox configuration SSOT.

    See {!Env_config_sandbox} module doc in the .mli for the full
    rationale.  Notes:

    - Fresh read per call.
    - [Shell_timeout.Cleanup_rm] is still a hardcoded literal exposed
      as a getter; it has callers, so the getter is the seam an
      env-override would use. *)

open Env_config_core

(* --------------------------------------------------------------- *)
(* Hardening                                                       *)
(* --------------------------------------------------------------- *)

module Hardening = struct
  let pids_limit () =
    max 32 (get_int ~default:128 "MASC_KEEPER_SANDBOX_PIDS_LIMIT")

  let nofile_limit () =
    max 1024 (get_int ~default:245_760 "MASC_KEEPER_SANDBOX_NOFILE_LIMIT")

  let memory () =
    get_string ~default:"2g" "MASC_KEEPER_SANDBOX_MEMORY"

  let tmpfs_size () =
    get_string ~default:"256m" "MASC_KEEPER_SANDBOX_TMPFS_SIZE"

  let relax_fs () =
    get_bool ~default:false "MASC_KEEPER_SANDBOX_RELAX_FS"

  let read_only_rootfs_args () =
    if relax_fs () then [] else [ "--read-only" ]

  let tmpfs_mount () =
    let exec_suffix = if relax_fs () then "" else ",noexec" in
    Printf.sprintf "/tmp:rw,nosuid,nodev%s,size=%s"
      exec_suffix (tmpfs_size ())

  let seccomp_profile () =
    get_string ~default:"" "MASC_KEEPER_SANDBOX_SECCOMP_PROFILE"

  let require_rootless () =
    get_bool ~default:false "MASC_KEEPER_SANDBOX_REQUIRE_ROOTLESS"

  let require_userns () =
    get_bool ~default:false "MASC_KEEPER_SANDBOX_REQUIRE_USERNS"
end

(* --------------------------------------------------------------- *)
(* Runtime                                                         *)
(* --------------------------------------------------------------- *)

module Runtime = struct
  (* The general image, not MASC's own development one. A Keeper that has to
     build MASC needs the OCaml toolchain and names it -- the fleet that does
     carries [sandbox_image = "masc-keeper-sandbox:local"] -- but a Keeper that
     declared no image is far more likely to be working on something else, and
     handing it an OCaml image it cannot install out of is the worse default.
     `masc sandbox-image` builds what this names. *)
  let docker_image () =
    get_string ~default:Keeper_sandbox_image.default_tag
      "MASC_KEEPER_SANDBOX_DOCKER_IMAGE"

  (* container's guest resolver points at the gateway, and the gateway
     refuses DNS from inside the guest even though the same port answers
     from the host. Without a nameserver the guest routes fine and resolves
     nothing, which reads as a dead network. Empty means "pass no --dns",
     which is the right answer once container fixes its default.

     The default is read from the host's own /etc/resolv.conf rather than
     named here. A literal was wrong on this machine: it said 1.1.1.1 while
     the host resolves through 168.126.63.1, so every guest lookup left for
     a resolver the operator had not chosen -- and a split-horizon or
     VPN-only name would simply not resolve. *)
  let host_nameserver () =
    match In_channel.with_open_text "/etc/resolv.conf" In_channel.input_all with
    | contents ->
      contents
      |> String.split_on_char '\n'
      |> List.filter_map (fun line ->
        match String.split_on_char ' ' (String.trim line) with
        | [ "nameserver"; server ] when String.trim server <> "" ->
          Some (String.trim server)
        | _ -> None)
      |> (function first :: _ -> Some first | [] -> None)
    | exception _ -> None
  ;;

  (* Removing a guest is a VM shutdown, not a container kill. Measured
     2026-08-28 on container 1.3.0: `container delete --force` took 66.7s,
     and stop-then-delete 63.0s. The Cleanup_rm bucket is 10s and the Io
     bucket 30s -- both were picked for docker, and either turns every
     removal into a timeout. *)
  let microvm_remove_timeout_sec () =
    max 30.0 (get_float ~default:180.0 "MASC_KEEPER_MICROVM_REMOVE_TIMEOUT_SEC")
  ;;

  let microvm_dns () =
    match get_string ~default:"" "MASC_KEEPER_MICROVM_DNS" with
    | "" -> (match host_nameserver () with Some server -> server | None -> "")
    | configured -> configured
  ;;

  let microvm_memory () = get_string ~default:"" "MASC_KEEPER_MICROVM_MEMORY"

  let microvm_cpus () = get_string ~default:"" "MASC_KEEPER_MICROVM_CPUS"

  let microvm_work_volume_size () =
    get_string ~default:"256g" "MASC_KEEPER_MICROVM_WORK_VOLUME_SIZE"
  ;;

  (* Measured 2026-09-02 on the keeper image: dune and ocaml live in the opam
     switch, off the shim's fixed default PATH. The value is written into the
     guest's shim config as [path=], so it is the host's statement about the
     image it boots; another image states another value here. *)
  let microvm_payload_path () =
    get_string
      ~default:"/home/opam/.opam/5.5/bin:/usr/local/bin:/usr/bin:/bin"
      "MASC_KEEPER_MICROVM_PAYLOAD_PATH"
  ;;

  let docker_playground_enabled () =
    Feature_flag_registry.get_bool "MASC_KEEPER_DOCKER_PLAYGROUND"

  (** @category Sandbox
      @ops_class operator *)
  let docker_playground_container_root () =
    get_string ~default:"/home/keeper/playground"
      "MASC_KEEPER_DOCKER_PLAYGROUND_ROOT"
end

(* --------------------------------------------------------------- *)
(* Preflight                                                       *)
(* --------------------------------------------------------------- *)

module Preflight = struct
  let enabled () =
    get_bool ~default:true "MASC_KEEPER_SANDBOX_PREFLIGHT_ENABLED"

  let ssh_ttl_sec () =
    max 0 (get_int ~default:60 "MASC_KEEPER_SSH_PREFLIGHT_TTL_SEC")

  let ssh_disk_free_min_kib () =
    max 0
      (get_int ~default:1_048_576
         "MASC_KEEPER_SSH_PREFLIGHT_DISK_FREE_MIN_KIB")
end

(* --------------------------------------------------------------- *)
(* Shell_timeout — typed-bucket SSOT                               *)
(* --------------------------------------------------------------- *)

module Shell_timeout = struct
  type bucket =
    | Io
    | Read
    | User_max
    | Cleanup_rm
    | Unknown of string

  let global_default_sec = 30.0

  let bucket_key = function
    | Io -> "io"
    | Read -> "read"
    | User_max -> "user_max"
    | Cleanup_rm -> "cleanup_rm"
    | Unknown s -> s

  let known_default_sec = function
    | Io -> Some 30.0
    | Read -> Some 15.0
    | User_max -> Some 180.0
    | Cleanup_rm -> Some 10.0
    | Unknown _ -> None

  let upper_case s =
    s
    |> String.map (fun c ->
         if c >= 'a' && c <= 'z' then
           Char.chr (Char.code c - 32)
         else if c = '-' then '_'
         else c)

  let per_bucket_env_var ~bucket =
    Printf.sprintf "MASC_KEEPER_SHELL_TIMEOUT_%s_SEC"
      (upper_case (bucket_key bucket))

  let global_env_var = "MASC_KEEPER_SHELL_TIMEOUT_DEFAULT_SEC"

  (** Empty-string env vars (used by test clearing patterns) must NOT
      be treated as "set". *)
  let trimmed_value_opt name =
    match raw_value_opt name with
    | Some v ->
      let t = String.trim v in
      if t = "" then None else Some t
    | None -> None

  let timeout_sec ~bucket () =
    let per_bucket_env = per_bucket_env_var ~bucket in
    match trimmed_value_opt per_bucket_env with
    | Some v ->
      Safe_ops.float_of_string_with_default
        ~default:global_default_sec v
    | None ->
      (match known_default_sec bucket with
       | Some d -> d
       | None ->
         match trimmed_value_opt global_env_var with
         | Some v ->
           Safe_ops.float_of_string_with_default
             ~default:global_default_sec v
         | None -> global_default_sec)
end
