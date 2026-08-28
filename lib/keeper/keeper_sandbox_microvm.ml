(** Apple [container] argv for the [Micro_vm] sandbox profile.

    One lightweight VM per container through Virtualization.framework, so a
    guest runs its own Linux kernel instead of sharing the host's. Measured
    2026-08-28 on macOS 26.6.1 / M3 Max with container CLI 1.3.0: 4.0-4.4s to
    start against Docker's 0.6-0.9s, about 400 MB of host memory per running
    container, and the guest reporting [Linux <uuid> 6.18.35].

    This module builds the command and nothing else. Dispatch still refuses
    [Micro_vm] until a later change routes it here, so the argv is covered by
    tests before it can run anything. *)

let command_argv () = [ "container" ]

(** Flags Docker takes that [container run] rejects outright.

    [container] errors on an unknown option rather than ignoring it, so
    passing these would fail every call instead of quietly weakening the
    sandbox -- which is why they are listed here rather than discovered at
    runtime.

    {b --security-opt no-new-privileges}: bars a setuid binary from gaining
    privilege mid-exec. In a shared-kernel container that privilege is the
    host's; in a per-container VM it stops at the guest kernel.

    {b --pids-limit}: caps process count against a fork bomb exhausting the
    host's process table. A guest VM has its own table and its own memory
    ceiling, so the blast radius is the VM.

    Neither is a free drop. Both narrow what a compromised guest can do to
    itself, and a keeper that needs them should stay on [Docker]. The trade
    is stated here so a reader does not have to infer it from an absence. *)
let unsupported_docker_flags = [ "--security-opt"; "--pids-limit" ]

let run_argv
      ~container_name
      ~container_root
      ~container_cwd
      ~host_root
      ~image
      ~network_args
      ~uid
      ~gid
      ~env_args
      ~memory
  =
  command_argv ()
  @ [ "run"; "--rm"; "--name"; container_name ]
  @ [ "-i"; "--user"; Printf.sprintf "%d:%d" uid gid ]
  @ env_args
  @ [ "--cap-drop"; "ALL"; "--read-only" ]
  @ [ "--memory"; memory ]
  @ [ "--volume"; host_root ^ ":" ^ container_root ]
  @ [ "--workdir"; container_cwd ]
  @ network_args
  @ [ image; "bash"; "-l"; "-s" ]
;;

(** What [container] is told about the network.

    [Network_none] closes it with [--network none].

    [Network_inherit] uses container's default network, which is a NAT
    ([container network inspect default] reports mode "nat"). A guest on it
    gets an address and a default route and reaches the outside: measured
    2026-08-28 on container 1.3.0, ping 8.8.8.8 answered in 39 ms, and with
    a nameserver supplied, HTTPS to api.github.com and `git ls-remote`
    against this repository both succeeded.

    The nameserver has to be supplied. The guest's /etc/resolv.conf points at
    the gateway, and the gateway does not answer DNS from inside the guest
    ("connection refused") even though the same port answers from the host.
    Without [--dns] the guest routes fine and resolves nothing, which reads
    as "no network" -- it is what made an earlier version of this module
    refuse [inherit] outright, on a claim that was wrong.

    [--network host] is a separate matter and still has no equivalent:
    container has no host network, and asking for one fails with "network
    host not found". [inherit] therefore means container's NAT, not the
    host's namespace, and the two differ in what the guest can reach on
    localhost. *)
let network_args ~dns (mode : Keeper_types_profile_sandbox.network_mode) =
  match mode with
  | Keeper_types_profile_sandbox.Network_none -> [ "--network"; "none" ]
  | Keeper_types_profile_sandbox.Network_inherit ->
    (match dns with
     | Some server when String.trim server <> "" -> [ "--dns"; String.trim server ]
     | Some _ | None -> [])
;;

(** Whether [image] is in container's own store.

    container keeps its images separately from the Docker daemon: a
    [masc-keeper-sandbox:local] built for Docker is invisible here. And
    [container run] has no [--pull=never], so a missing image is not an
    error -- it is a fetch. Observed 2026-08-28: the first live call through
    masc's own entry point reached out to registry-1.docker.io and came back
    401, and with credentials present it would have pulled a stranger's
    image under the keeper's name instead.

    [container image inspect] answers from the local store without touching
    the network -- verified against a present and an absent image -- so the
    check is a gate, not a probe that itself fetches. *)
let image_present ~image ~timeout_sec =
  let argv = command_argv () @ [ "image"; "inspect"; image ] in
  match
    Process_eio.run_argv_with_status ~timeout_sec argv
  with
  | Unix.WEXITED 0, _ -> Ok ()
  | _ ->
    Error
      (Printf.sprintf
         "microvm_image_missing: %s is not in the container image store. \
          container keeps its images apart from Docker, and container run \
          has no --pull=never, so running without this check fetches from a \
          registry instead of failing. Next: build or load the image with \
          `container image` before starting a microvm keeper."
         image)
;;

(* ── Turn-container argv ─────────────────────────────────────────────

   The turn model mirrors the Docker lane: one detached guest per turn
   holding [tail -f /dev/null], commands delivered by [exec], the
   container gone on [stop] because it was started with [--rm]. Every
   flag below was accepted by a live container 1.3.0 run on 2026-08-28;
   [exec] propagated exit codes (observed rc=7) and stdin
   ([bash -l -s] echoed piped input).

   Deliberately absent against the Docker turn argv, stated so a reader
   does not infer parity: seccomp / --security-opt / --pids-limit
   (container rejects them; the guest kernel is the boundary), the
   secret and GitHub identity projections, the config and
   workspace-state mounts, and the /etc/passwd identity mounts
   ([--user uid:gid] is passed directly). A microvm turn sees its
   playground and nothing else. *)

let turn_start_argv
      ~container_name
      ~label_args
      ~uid
      ~gid
      ~memory
      ~cpus
      ~host_root
      ~container_root
      ~network_args
      ~image
  =
  command_argv ()
  @ [ "run"; "-d"; "--rm"; "--name"; container_name ]
  @ label_args
  @ [ "--user"; Printf.sprintf "%d:%d" uid gid ]
  @ [ "--cap-drop"; "ALL"; "--read-only" ]
  @ [ "--memory"; memory ]
  @ (match cpus with
     | Some count -> [ "--cpus"; count ]
     | None -> [])
  @ [ "--volume"; host_root ^ ":" ^ container_root ]
  @ [ "--workdir"; container_root ]
  @ network_args
  @ [ image; "tail"; "-f"; "/dev/null" ]
;;

(* [~command_argv] shadows the CLI-prefix function of the same name, so
   the prefix is captured under another binding first. *)
let cli_prefix = command_argv

let exec_argv ~container_name ~uid ~gid ~container_cwd ~stdin ~command_argv =
  cli_prefix ()
  @ [ "exec" ]
  @ (if stdin then [ "-i" ] else [])
  @ [ "--user"; Printf.sprintf "%d:%d" uid gid; "-w"; container_cwd ]
  @ (container_name :: command_argv)
;;

let stop_argv ~container_name = command_argv () @ [ "stop"; container_name ]

let delete_force_argv ~container_name =
  command_argv () @ [ "delete"; "--force"; container_name ]
;;

(** Label value distinguishing a keeper-lifetime guest from turn
    containers. The guest outlives turns, so it carries no turn id. *)
let keeper_vm_container_kind = "keeper-vm"

(** [container inspect] answers JSON; state lives at [.[0].status.state]
    ("running" observed live). A missing container exits 1, which the
    caller maps to absent before parsing. *)
let running_of_inspect_json raw =
  match Yojson.Safe.from_string raw with
  | `List (`Assoc fields :: _) ->
    (match List.assoc_opt "status" fields with
     | Some (`Assoc status) ->
       (match List.assoc_opt "state" status with
        | Some (`String state) -> Ok (String.equal state "running")
        | Some _ | None -> Error "container inspect: status.state missing")
     | Some _ | None -> Error "container inspect: status missing")
  | _ -> Error "container inspect: unparseable JSON"
  | exception Yojson.Json_error _ ->
    Error "container inspect: unparseable JSON"
;;

let inspect_argv ~container_name = command_argv () @ [ "inspect"; container_name ]
