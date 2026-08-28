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

(** [container] spells the closed network [--network none], the same token
    Docker uses. Kept as its own function so the two backends cannot drift
    into disagreeing about what "no network" is called. *)
let network_args (mode : Keeper_types_profile_sandbox.network_mode) =
  match mode with
  | Keeper_types_profile_sandbox.Network_none -> [ "--network"; "none" ]
  | Keeper_types_profile_sandbox.Network_inherit -> []
;;
