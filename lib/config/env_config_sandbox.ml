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
  (* container's guest resolver points at the gateway, and the gateway
     refuses DNS from inside the guest even though the same port answers
     from the host. Without a nameserver the guest routes fine and resolves
     nothing, which reads as a dead network. So a guest on the default
     network is always handed one.

     The default is read from the host's own /etc/resolv.conf rather than
     named here. A literal was wrong on this machine: it said 1.1.1.1 while
     the host resolves through 168.126.63.1, so every guest lookup left for
     a resolver the operator had not chosen -- and a split-horizon or
     VPN-only name would simply not resolve.

     Reading it is not enough. Measured 2026-10-16: the host resolved through
     fe80::f4be:ecff:fee7:64%en0, the guest was handed that text as it stood,
     and every name lookup in every guest failed (#40915). The zone names an
     interface of the host. A resolver that means nothing in the guest is
     refused when the guest is booted, with the operator's way out named,
     instead of becoming a dead network. *)
  let first_nameserver_of contents =
    contents
    |> String.split_on_char '\n'
    |> List.filter_map (fun line ->
      let tokens =
        String.map (function '\t' -> ' ' | c -> c) line
        |> String.split_on_char ' '
        |> List.filter (fun token -> token <> "")
      in
      match tokens with
      | "nameserver" :: server :: _ -> Some server
      | _ -> None)
    |> function first :: _ -> Some first | [] -> None
  ;;

  let host_nameserver () =
    match In_channel.with_open_text "/etc/resolv.conf" In_channel.input_all with
    | contents -> first_nameserver_of contents
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

  type nameserver_refusal =
    | Not_an_address
    | Zone_scoped
    | Unspecified
    | Loopback
    | Link_local
    | Multicast

  (* Ipaddr's IPv6 link-local range is fe80::/64, so febf::1 and fe81::1 would
     read as global. The range is fe80::/10 (RFC 4291 2.5.6). 0.0.0.0/8 is
     "this network" (RFC 1122 3.2.1.3): Ipaddr calls only 0.0.0.0 itself
     unspecified. *)
  let host_only_refusal address =
    if Ipaddr.is_multicast address
    then Some Multicast
    else (
      match address with
      | Ipaddr.V4 v4 when Char.code (Ipaddr.V4.to_octets v4).[0] = 0 -> Some Unspecified
      | Ipaddr.V6 v6
        when
          let octets = Ipaddr.V6.to_octets v6 in
          Char.code octets.[0] = 0xfe && Char.code octets.[1] land 0xc0 = 0x80 ->
        Some Link_local
      | Ipaddr.V4 _ | Ipaddr.V6 _ ->
        (match Ipaddr.scope address with
         | Ipaddr.Point -> Some Unspecified
         | Ipaddr.Interface -> Some Loopback
         | Ipaddr.Link -> Some Link_local
         | Ipaddr.Admin | Ipaddr.Site | Ipaddr.Organization | Ipaddr.Global -> None))
  ;;

  (* The zone is looked for before parsing. Ipaddr refuses '%' as an invalid
     character, which would file a zone-scoped address under [Not_an_address]
     and lose the one fact that explains the refusal. *)
  let nameserver_of_string raw =
    let text = String.trim raw in
    if String.contains text '%'
    then Error Zone_scoped
    else (
      match Ipaddr.of_string text with
      | Error (`Msg _) -> Error Not_an_address
      | Ok address ->
        (match host_only_refusal address with
         | Some refusal -> Error refusal
         | None -> Ok address))
  ;;

  let nameserver_refusal_to_string = function
    | Not_an_address -> "is not an IP address"
    | Zone_scoped ->
      "names an interface of the host (a %zone), which a guest does not have"
    | Unspecified -> "is the unspecified address or on 'this network' (0.0.0.0/8, ::)"
    | Loopback -> "is a loopback address, which inside a guest is the guest itself"
    | Link_local -> "is link-local, reachable only over the host's own link"
    | Multicast -> "is a multicast address"
  ;;

  let microvm_dns_env = "MASC_KEEPER_MICROVM_DNS"
  let microvm_dns_toml_key = "sandbox.microvm_dns"

  (* What the workspace named, apart from anything the host supplies. Blank is
     unset. A value that is set and is not a usable address is refused, and
     the refusal names both spellings of the setting: the operator wrote one
     and the process reads the other. *)
  let configured_nameserver raw =
    match String.trim raw with
    | "" -> Ok None
    | value ->
      (match nameserver_of_string value with
       | Ok address -> Ok (Some address)
       | Error refusal ->
         Error
           (Printf.sprintf
              "%s (%s)=%S %s"
              microvm_dns_toml_key
              microvm_dns_env
              value
              (nameserver_refusal_to_string refusal)))
  ;;

  let host_nameserver_for_guest = function
    | None ->
      Error
        (Printf.sprintf
           "the host has no nameserver in /etc/resolv.conf for a guest to copy; set %s \
            in runtime.toml (read at server start) to the resolver a guest should use"
           microvm_dns_toml_key)
    | Some text ->
      nameserver_of_string text
      |> Result.map_error (fun refusal ->
        Printf.sprintf
          "the host's resolver %s %s; set %s in runtime.toml (read at server start) to \
           a resolver a guest can reach"
          text
          (nameserver_refusal_to_string refusal)
          microvm_dns_toml_key)
  ;;

  let microvm_dns_from ~configured ~host =
    match configured_nameserver configured with
    | Error _ as refused -> refused
    | Ok (Some address) -> Ok address
    | Ok None -> host_nameserver_for_guest host
  ;;

  let microvm_dns_effective_from ~configured ~host =
    match configured_nameserver configured with
    | Error detail -> Error detail
    | Ok (Some address) -> Ok (Ipaddr.to_string address)
    | Ok None ->
      (match host_nameserver_for_guest host with
       | Ok address -> Ok (Ipaddr.to_string address)
       | Error detail -> Ok ("unusable: " ^ detail))
  ;;

  let microvm_dns () =
    microvm_dns_from
      ~configured:(get_string ~default:"" microvm_dns_env)
      ~host:(host_nameserver ())
  ;;

  let microvm_dns_effective () =
    microvm_dns_effective_from
      ~configured:(get_string ~default:"" microvm_dns_env)
      ~host:(host_nameserver ())
  ;;

  (* Measured 2026-09-18: a keeper build inside a 2 GiB guest timed out or was
     killed (exit 137). The defaults stay what guests booted with until now;
     a keeper that builds names its own size, or the workspace raises these
     in runtime.toml ([sandbox]). *)
  let microvm_memory_key = "MASC_KEEPER_MICROVM_MEMORY"
  let microvm_memory_default = "2g"
  let microvm_cpus_key = "MASC_KEEPER_MICROVM_CPUS"
  let microvm_cpus_default = 4

  (* The workspace size is read from the boot override store, where the
     [sandbox] table of runtime.toml leaves it, and never from the process
     environment. [masc restart] gives the server the environment of the shell
     that ran it, so a variable read here let that shell, not the file, decide
     the size of every guest. The keys keep their old names only because the
     store is keyed by them.

     Blank is unset, as it is for [get_int]. A value that is set and does not
     parse is refused rather than read as the default: the operator asked for
     a size, and booting on another one would say nothing. The refusal names
     the runtime.toml key. *)
  let configured_guest_dimension ~key ~toml_key ~default parse =
    let raw =
      match Config_boot_overrides.get_opt key with
      | Some value when String.trim value <> "" -> value
      | Some _ | None -> default
    in
    parse raw |> Result.map_error (fun detail -> toml_key ^ ": " ^ detail)
  ;;

  let microvm_memory () =
    configured_guest_dimension
      ~key:microvm_memory_key
      ~toml_key:"sandbox.microvm_memory"
      ~default:microvm_memory_default
      Keeper_microvm_guest_size.memory_of_string
  ;;

  let microvm_cpus () =
    configured_guest_dimension
      ~key:microvm_cpus_key
      ~toml_key:"sandbox.microvm_cpus"
      ~default:(string_of_int microvm_cpus_default)
      Keeper_microvm_guest_size.cpus_of_string
  ;;

  let microvm_guest_size ~memory ~cpus =
    Keeper_microvm_guest_size.resolve
      ~memory
      ~cpus
      ~default_memory:microvm_memory
      ~default_cpus:microvm_cpus
  ;;

  let microvm_work_volume_size () =
    get_string ~default:"256g" "MASC_KEEPER_MICROVM_WORK_VOLUME_SIZE"
  ;;

  let microvm_build_volume_size () =
    get_string ~default:"128g" "MASC_KEEPER_MICROVM_BUILD_VOLUME_SIZE"
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
    get_bool ~default:false "MASC_KEEPER_DOCKER_PLAYGROUND"

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
    | Cleanup_rm

  let global_default_sec = 30.0

  let bucket_key = function
    | Io -> "io"
    | Read -> "read"
    | Cleanup_rm -> "cleanup_rm"

  let bucket_default_sec = function
    | Io -> 30.0
    | Read -> 15.0
    | Cleanup_rm -> 10.0

  let per_bucket_env_var ~bucket =
    Printf.sprintf "MASC_KEEPER_SHELL_TIMEOUT_%s_SEC"
      (String.uppercase_ascii (bucket_key bucket))

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
    | None -> bucket_default_sec bucket
end
