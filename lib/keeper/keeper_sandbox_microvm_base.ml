module Backend = Keeper_microvm_backend

type build_link_state = Keeper_microvm_build_plan.build_link_state =
  | Build_absent
  | Build_symlink of string
  | Build_real_directory

type build_link_plan = Keeper_microvm_build_plan.build_link_plan =
  | Link_create of string
  | Link_preserve_symlink of { existing : string; expected : string }
  | Link_already_correct
  | Link_refused_real_directory
  | Link_refused_invalid_path of { detail : string; state : build_link_state }

type build_scan_row = Keeper_microvm_build_plan.build_scan_row =
  { checkout : string
  ; state : build_link_state
  }

type build_link_row = Keeper_microvm_build_plan.build_link_row =
  { checkout : string
  ; target : string option
  ; plan : build_link_plan
  }

include
  (Keeper_microvm_build_plan :
    module type of Keeper_microvm_build_plan
      with type build_link_state := build_link_state
       and type build_link_plan := build_link_plan
       and type build_scan_row := build_scan_row
       and type build_link_row := build_link_row)

(* The backend a call builds argv for. Every builder below takes it, so the
   choice travels with the call instead of sitting in module state that a
   second keeper on a second backend would race. *)
(** The CLI prefix for one backend. *)
let command_argv_for backend = [ Backend.cli_name backend ]

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

(** Guest mount point of the per-keeper work volume. The keeper's working
    tree lives here (an ext4 disk on Apple, a managed directory on nerdctl),
    and this path is the remote lane's
    [remote_root] for the guest: the same role [\[exec.ssh.endpoints\]
    .remote_root] plays for an OpenSSH endpoint.

    Why a volume and not the virtiofs share: Apple's virtiofs opens an
    [O_PATH] descriptor on the host for every inode the guest touches and
    closes it only on [FUSE_FORGET], so a host descriptor -- a host vnode --
    is pinned per file. A build that writes 200,000 files pins 200,000
    vnodes against a [kern.maxvnodes] of 263,168, and a full table turns
    file-backed page faults into SIGBUS; that panicked the host three times
    between 2026-08-30 and 2026-09-01. Measured on container 1.3.1 writing
    20,000 files: ext4 volume 26 -> 26 host descriptors, virtiofs 26 ->
    20,027. *)
let work_volume_guest_root = "/masc-work"

let output_for_log ~stdout ~stderr =
  [ stdout; stderr ]
  |> List.map String.trim
  |> List.filter (fun part -> part <> "")
  |> String.concat "\n"
  |> Keeper_sandbox_runtime.docker_failure_output_for_log
;;
