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

(** What [container] can be told about the network, or why it cannot.

    [Network_none] maps to [--network none], the same token Docker uses.

    [Network_inherit] has no equivalent and is refused. Docker spells it
    [--network host]; container has no host network -- [container network
    list] shows only [default] (192.168.64.0/24), and [--network host] fails
    with "network host not found". Measured 2026-08-28 on container 1.3.0:
    the default network does not reach outside either, so a guest on it
    cannot fetch https://example.com.

    Returning [] here would hand the keeper a guest with no route while its
    profile still said [inherit], and git would fail for reasons the keeper
    could not see. The refusal names the mismatch instead. *)
let network_args (mode : Keeper_types_profile_sandbox.network_mode) =
  match mode with
  | Keeper_types_profile_sandbox.Network_none -> Ok [ "--network"; "none" ]
  | Keeper_types_profile_sandbox.Network_inherit ->
    Error
      "microvm_network_unsupported: network_mode=inherit has no container \
       equivalent -- container has no host network and its default network \
       does not route outside. Next: set network_mode = \"none\" for this \
       keeper, or keep it on sandbox_profile = \"docker\" if it needs the \
       host network."
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
