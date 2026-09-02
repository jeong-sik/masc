(** Apple [container] argv for the [Micro_vm] sandbox profile.

    One lightweight VM per container through Virtualization.framework, so a
    guest runs its own Linux kernel instead of sharing the host's. Measured
    2026-08-28 on macOS 26.6.1 / M3 Max with container CLI 1.3.0: about
    460 MB of host memory per running guest, and the guest reporting
    [Linux <uuid> 6.18.35].

    Cost is per keeper, not per call. Booting a guest takes 1.3-2.4s, but
    #31340 made the guest keeper-lifetime, so a turn pays [container exec]
    at 0.06-0.10s -- under Docker's 0.6-0.9s per-call container start. An
    earlier version of this comment quoted 4.0-4.4s per call: that was
    measured before guests were adopted across turns, and stayed here after
    the number stopped being true.

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
    check is a gate, not a probe that itself fetches.

    A missing image and a dead service both exit 1. Human error prose is not a
    protocol, so a failed inspect is classified as missing only after
    [container image list --format json] proves that the service and image
    store are readable. *)
type image_probe_phase =
  | Image_inspect
  | Image_list

type image_probe_failure =
  { phase : image_probe_phase
  ; status : Unix.process_status
  ; stdout : string
  ; stderr : string
  ; reason : string
  }

type image_probe_outcome =
  | Image_present
  | Image_missing
  | Image_cli_unavailable
  | Image_probe_failed of image_probe_failure

let json_array_error raw =
  match Yojson.Safe.from_string raw with
  | `List _ -> None
  | _ -> Some "expected a JSON array"
  | exception Yojson.Json_error detail -> Some ("invalid JSON: " ^ detail)
;;

let probe_failure ~phase ~status ~stdout ~stderr ~reason =
  Image_probe_failed { phase; status; stdout; stderr; reason }
;;

let classify_image_probe ~inspect:(inspect_status, inspect_stdout, inspect_stderr) ~listing =
  match inspect_status with
  | Unix.WEXITED 0 ->
    (match json_array_error inspect_stdout with
     | None -> Image_present
     | Some reason ->
       probe_failure
         ~phase:Image_inspect
         ~status:inspect_status
         ~stdout:inspect_stdout
         ~stderr:inspect_stderr
         ~reason)
  | Unix.WEXITED 127 -> Image_cli_unavailable
  | Unix.WEXITED 1 ->
    (match listing with
     | Some (Unix.WEXITED 0 as status, stdout, stderr) ->
       (match json_array_error stdout with
        | None -> Image_missing
        | Some reason ->
          probe_failure ~phase:Image_list ~status ~stdout ~stderr ~reason)
     | Some (status, stdout, stderr) ->
       probe_failure
         ~phase:Image_list
         ~status
         ~stdout
         ~stderr
         ~reason:"image store listing failed after inspect exited 1"
     | None ->
       probe_failure
         ~phase:Image_inspect
         ~status:inspect_status
         ~stdout:inspect_stdout
         ~stderr:inspect_stderr
         ~reason:"image store listing evidence was not collected")
  | status ->
    probe_failure
      ~phase:Image_inspect
      ~status
      ~stdout:inspect_stdout
      ~stderr:inspect_stderr
      ~reason:"image inspect failed"
;;

let output_for_log ~stdout ~stderr =
  [ stdout; stderr ]
  |> List.map String.trim
  |> List.filter (fun part -> part <> "")
  |> String.concat "\n"
  |> Keeper_sandbox_runtime.docker_failure_output_for_log
;;

let phase_label = function
  | Image_inspect -> "image inspect"
  | Image_list -> "image list --format json"
;;

let image_present_result ~image = function
  | Image_present -> Ok ()
  | Image_missing ->
    Error
      (Printf.sprintf
         "microvm_image_missing: %s is not in the container image store. \
          container keeps its images apart from Docker, and container run \
          has no --pull=never, so running without this check fetches from a \
          registry instead of failing. Next: build or load the image with \
          `container image` before starting a microvm keeper."
         image)
  | Image_cli_unavailable ->
    Error
      "microvm_cli_unavailable: the `container` CLI is not on PATH. Next: \
       install Apple container, or move the keeper to sandbox_profile = \
       \"docker\"."
  | Image_probe_failed failure ->
    Error
      (Printf.sprintf
         "microvm_image_probe_failed: `container %s` did not establish whether \
          image %s exists (%s; %s: %s). Next: check that the \
          container system is running with `container system status`."
         (phase_label failure.phase)
         image
         failure.reason
         (Keeper_sandbox_exec_failure.status_label failure.status)
         (output_for_log ~stdout:failure.stdout ~stderr:failure.stderr))
;;

let image_probe ~image ~timeout_sec =
  let inspect_argv = command_argv () @ [ "image"; "inspect"; image ] in
  let inspect = Process_eio.run_argv_with_status_split ~timeout_sec inspect_argv in
  let listing =
    match inspect with
    | Unix.WEXITED 1, _, _ ->
      let list_argv = command_argv () @ [ "image"; "list"; "--format"; "json" ] in
      Some (Process_eio.run_argv_with_status_split ~timeout_sec list_argv)
    | _ -> None
  in
  classify_image_probe ~inspect ~listing
;;

let image_present ~image ~timeout_sec =
  image_probe ~image ~timeout_sec |> image_present_result ~image
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
   workspace-state mounts, and the /etc/passwd identity mounts
   ([--user uid:gid] is passed directly).

   [mount_args] carries what the caller projects -- config, GitHub
   identity, secret files and --env-file. These were absent because they
   had not been wired, not because container refuses them: measured
   2026-08-28 against masc-keeper-sandbox:local, a guest reads through
   [-v host:container:ro] and takes [--env-file], both in Docker's own
   spelling. A keeper that pushes to GitHub or reads a connector credential
   needs them, and edgar.a.poe on microvm had neither. *)

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
      ~mount_args
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
  @ mount_args
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

(** Build output lives on a block device, not on the virtiofs share.

    {b Why.} Apple's virtiofs opens an [O_PATH] descriptor on the host for
    every inode the guest touches and closes it only on [FUSE_FORGET], which
    arrives when the guest kernel evicts the dentry. A host descriptor pins a
    host vnode, so a build that writes 200,000 files pins 200,000 vnodes --
    and [kern.maxvnodes] is 263,168 by default. When the table fills with
    nothing reclaimable, [vnode_create] fails, file-backed page faults become
    SIGBUS, and a SIGBUS in launchd is a kernel panic. That happened three
    times between 2026-08-30 and 2026-09-01.

    {b Measured} on macOS 26.6.1 / M3 Max with container CLI 1.3.1, writing
    20,000 files and counting host descriptors on the VM process:

    - ext4 volume ([/dev/vdX]): 26 -> 26. The host holds one [volume.img].
    - virtiofs bind mount: 26 -> 20,027. One descriptor per inode, exactly.
    - [_build] symlinked onto the ext4 volume: 59 -> 61.

    Reclaiming without a restart was tried and does not work: writing
    [/proc/sys/vm/drop_caches] to force [FUSE_FORGET] is denied under
    [--cap-drop ALL]. Deleting the tree does release the descriptors
    (20,027 -> 59), but that is the build cache the directory exists to hold.

    {b Why a symlink and not [DUNE_BUILD_DIR].} An absolute value is shared by
    every checkout in the playground, so two builds would write the same
    directory. A relative value that escapes the workspace is refused by dune
    ("path outside the workspace", measured on dune 3.24.1). The symlink binds
    per checkout, needs no dune-specific knowledge, and covers every tool that
    writes [_build].

    The link is created on the host and points at a guest path, so it dangles
    when read from macOS. That is intended: the host never builds, and the
    host-side readers under [Playground_paths] read sources, not build
    output. *)
let build_volume_guest_root = "/masc-build"

(** Volume names reach [container] as an argument and become a directory name
    under its state directory, so a name outside this set is refused rather
    than escaped. Keeper names already satisfy it -- they are the same names
    that appear in [masc-keeper-vm-<name>-<hash>]. *)
let valid_volume_segment segment =
  (not (String.equal segment ""))
  && String.for_all
       (function
         | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '.' | '_' | '-' -> true
         | _ -> false)
       segment

let build_volume_name ~keeper_name =
  if valid_volume_segment keeper_name
  then Ok ("masc-keeper-build-" ^ keeper_name)
  else Error ("unsupported keeper name for a build volume: " ^ keeper_name)
;;

let build_volume_create_argv ~volume_name ~size =
  command_argv () @ [ "volume"; "create"; "-s"; size; volume_name ]
;;

let build_volume_mount_args ~volume_name =
  [ "--volume"; volume_name ^ ":" ^ build_volume_guest_root ]
;;

(* ── The work volume and the shim (RFC-0400) ────────────────────────── *)

(** Guest mount point of the per-keeper work volume. The keeper's working
    tree lives here, on ext4, and this path is the remote lane's
    [remote_root] for the guest: the same role [\[exec.ssh.endpoints\]
    .remote_root] plays for an OpenSSH endpoint. *)
let work_volume_guest_root = "/masc-work"

let work_volume_name ~keeper_name =
  if valid_volume_segment keeper_name
  then Ok ("masc-keeper-work-" ^ keeper_name)
  else Error ("unsupported keeper name for a work volume: " ^ keeper_name)
;;

let work_volume_mount_args ~volume_name =
  [ "--volume"; volume_name ^ ":" ^ work_volume_guest_root ]
;;

(** The keeper's root on the work volume: [<work root>/<keeper>], the
    directory the shim jails every request under. *)
let keeper_work_root ~keeper_name =
  Filename.concat work_volume_guest_root (Playground_paths.sanitize_keeper_name keeper_name)
;;

(** Where the guest finds [masc-exec-shim] and its config: one host directory
    mounted read-only. The guest root is read-only and [/etc] is the image's,
    so the config travels beside the binary and the transport names it
    through [MASC_EXEC_SHIM_CONFIG]. *)
let shim_guest_dir = "/opt/masc-exec-shim"
let shim_binary_name = "masc-exec-shim"
let shim_config_name = "masc-exec-shim.conf"
let shim_guest_path = Filename.concat shim_guest_dir shim_binary_name
let shim_config_guest_path = Filename.concat shim_guest_dir shim_config_name

let shim_mount_args ~host_dir =
  [ "--volume"; host_dir ^ ":" ^ shim_guest_dir ^ ":ro" ]
;;

(** The config the host writes for the guest's shim: the jail root is the
    work volume, and the payload PATH is the image's. *)
let shim_config_content ~payload_path =
  Printf.sprintf "remote_root=%s\npath=%s\n" work_volume_guest_root payload_path
;;

(** What the guest endpoint declares to the remote runner. No caller env
    crosses into a guest today (typed guest dispatch refuses env), so the
    allowlist is empty; the session ceiling mirrors the OpenSSH default, and
    the connect budget covers a [container exec] that has to wait on a
    guest still settling after boot. *)
let remote_env_allowlist : string list = []
let remote_connect_timeout_sec = 10
let remote_max_concurrent_sessions = 8

(** A checkout's build directory on the volume.

    The playground-relative path is flattened with [:] so the target needs no
    parent directories -- the guest cannot [mkdir -p] through a symlink whose
    parent is missing, and the host cannot write into the disk image at all.
    A path segment already containing [:] would make two checkouts share one
    build directory, so it is refused instead. *)
let build_link_separator = ':'

let build_link_target ~playground_relative =
  let segments = String.split_on_char '/' playground_relative in
  let empty = List.exists (fun s -> String.equal s "") segments in
  let collides = String.contains playground_relative build_link_separator in
  if List.is_empty segments || empty
  then Error ("empty path segment in playground path: " ^ playground_relative)
  else if collides
  then
    Error
      (Printf.sprintf
         "playground path contains %c, which the build link uses as a separator: %s"
         build_link_separator
         playground_relative)
  else
    Ok
      (Filename.concat
         build_volume_guest_root
         (String.concat (String.make 1 build_link_separator) segments))
;;

(** What [_build] is right now, as far as the plan cares. *)
type build_link_state =
  | Build_absent
  | Build_symlink of string
  | Build_real_directory

type build_link_plan =
  | Link_create of string
  | Link_retarget of string
  | Link_already_correct
  | Link_refused_real_directory

(** Deciding is separate from acting so the refusal is testable.

    A real [_build] is not deleted. It holds build output this module did not
    create, and silently discarding it to install a link would trade a vnode
    problem for lost work; the caller reports it and leaves the checkout on
    virtiofs. Retargeting a stale link is different -- removing a symlink
    removes no data. *)
let plan_build_link ~target = function
  | Build_absent -> Link_create target
  | Build_symlink existing when String.equal existing target -> Link_already_correct
  | Build_symlink _ -> Link_retarget target
  | Build_real_directory -> Link_refused_real_directory
;;

(* ── Provisioning the build volume ─────────────────────────────────── *)

(** Volume ids in a [container volume list --format json] payload. *)
let volume_names_of_json = function
  | `List entries ->
    let open Yojson.Safe.Util in
    Ok
      (List.filter_map
         (fun entry ->
           match member "id" entry with
           | `String id -> Some id
           | _ ->
             (match entry |> member "configuration" |> member "name" with
              | `String name -> Some name
              | _ -> None))
         entries)
  | _ -> Error "container volume list did not return a JSON array"
;;

type volume_probe_outcome =
  | Volume_present
  | Volume_absent
  | Volume_probe_failed of string

(** [container volume inspect] answers 0 for present, but its 1 covers "no
    such volume" together with a stopped container system and other faults,
    so a 1 is confirmed against the listing rather than trusted. This mirrors
    [classify_image_probe], and for the same reason: treating an ambiguous
    exit code as "absent" would make provisioning try to create a volume that
    already holds a keeper's build cache. *)
let classify_volume_probe ~volume_name ~inspect ~listing =
  let described label (status, stdout, stderr) =
    Printf.sprintf
      "container volume %s: %s (%s)"
      label
      (match status with
       | Unix.WEXITED code -> Printf.sprintf "exit %d" code
       | Unix.WSIGNALED n -> Printf.sprintf "signalled %d" n
       | Unix.WSTOPPED n -> Printf.sprintf "stopped %d" n)
      (output_for_log ~stdout ~stderr)
  in
  match inspect with
  | Unix.WEXITED 0, _, _ -> Volume_present
  | Unix.WEXITED 1, _, _ ->
    (match listing with
     | None ->
       Volume_probe_failed
         "container volume inspect exited 1 and no listing was taken to           confirm whether the volume is absent"
     | Some (Unix.WEXITED 0, stdout, _) ->
       (match Yojson.Safe.from_string stdout with
        | exception Yojson.Json_error message ->
          Volume_probe_failed ("container volume list emitted invalid JSON: " ^ message)
        | json ->
          (match volume_names_of_json json with
           | Error message -> Volume_probe_failed message
           | Ok names ->
             if List.exists (String.equal volume_name) names
             then Volume_present
             else Volume_absent))
     | Some outcome -> Volume_probe_failed (described "list" outcome))
  | outcome -> Volume_probe_failed (described "inspect" outcome)
;;

let volume_probe ~volume_name ~timeout_sec =
  let inspect_argv = command_argv () @ [ "volume"; "inspect"; volume_name ] in
  let inspect = Process_eio.run_argv_with_status_split ~timeout_sec inspect_argv in
  let listing =
    match inspect with
    | Unix.WEXITED 1, _, _ ->
      let list_argv = command_argv () @ [ "volume"; "list"; "--format"; "json" ] in
      Some (Process_eio.run_argv_with_status_split ~timeout_sec list_argv)
    | _ -> None
  in
  classify_volume_probe ~volume_name ~inspect ~listing
;;

(** Create the volume when it is absent, and say so when it cannot be
    established either way.

    [container volume create] is not idempotent -- a second call errors with
    "already exists" -- so existence is settled by the probe above rather than
    by reading that message. The size is a ceiling: the image is sparse, and
    4 GiB nominal measured 84 MB on disk. *)
type volume_kind =
  | Build_volume
  | Work_volume

let volume_kind_label = function
  | Build_volume -> "build"
  | Work_volume -> "work"
;;

let ensure_volume ~kind ~volume_name ~size ~timeout_sec =
  match volume_probe ~volume_name ~timeout_sec with
  | Volume_present -> Ok `Already_present
  | Volume_probe_failed message ->
    Error
      (Printf.sprintf
         "microvm_%s_volume_probe_failed: %s"
         (volume_kind_label kind)
         message)
  | Volume_absent ->
    let argv = build_volume_create_argv ~volume_name ~size in
    (match Process_eio.run_argv_with_status_split ~timeout_sec argv with
     | Unix.WEXITED 0, _, _ -> Ok `Created
     | status, stdout, stderr ->
       Error
         (Printf.sprintf
            "microvm_%s_volume_create_failed: %s (%s; %s)"
            (volume_kind_label kind)
            volume_name
            (match status with
             | Unix.WEXITED code -> Printf.sprintf "exit %d" code
             | Unix.WSIGNALED n -> Printf.sprintf "signalled %d" n
             | Unix.WSTOPPED n -> Printf.sprintf "stopped %d" n)
            (output_for_log ~stdout ~stderr)))
;;

let ensure_build_volume = ensure_volume ~kind:Build_volume

(* ── Binding a checkout's _build to the volume ─────────────────────── *)

(** What [_build] is on the host right now.

    Anything that is neither absent nor a symlink -- a directory, but also a
    plain file -- reads as [Build_real_directory] so the plan refuses it. The
    conservative reading is the safe one: the only action taken on that answer
    is to leave the path alone. *)
let build_link_state_of_path path =
  match Unix.lstat path with
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> Build_absent
  | exception Unix.Unix_error _ -> Build_real_directory
  | { Unix.st_kind = Unix.S_LNK; _ } ->
    (match Unix.readlink path with
     | target -> Build_symlink target
     | exception Unix.Unix_error _ -> Build_real_directory)
  | _ -> Build_real_directory
;;

(** Carry out one plan.

    The link points at a guest path, so on the host it dangles by
    construction. [Unix.symlink] does not care, and the host never follows it:
    the readers under [Playground_paths] read sources, not build output. *)
let apply_build_link ~path plan =
  match plan with
  | Link_already_correct -> Ok `Unchanged
  | Link_create target ->
    (match Unix.symlink target path with
     | () -> Ok `Linked
     | exception Unix.Unix_error (err, _, _) ->
       Error (Printf.sprintf "could not link %s: %s" path (Unix.error_message err)))
  | Link_retarget target ->
    (match
       Unix.unlink path;
       Unix.symlink target path
     with
     | () -> Ok `Relinked
     | exception Unix.Unix_error (err, _, _) ->
       Error (Printf.sprintf "could not relink %s: %s" path (Unix.error_message err)))
  | Link_refused_real_directory ->
    Error
      (Printf.sprintf
         "%s is a real directory holding build output this code did not           create; it is left on the virtiofs share rather than deleted. Next:           remove or move it by hand if the build cache is not wanted, and the           link is installed on the following turn."
         path)
;;

(* ── Finding the checkouts that build ──────────────────────────────── *)

(** How far below a keeper's playground a checkout is looked for.

    Observed layouts put them at depth 1 ([polisher/masc-t362]) and depth 2
    ([lane-smith/repos/wt-370]). Three leaves room for one more level without
    turning this into a whole-tree walk. *)
let build_root_scan_depth = 3

(** A checkout is a directory holding [dune-project].

    That is the marker for the build output this addresses: [_build] is
    dune's name and dune's alone. Other ecosystems pin host descriptors the
    same way through their own output directories -- [node_modules],
    [target], [dist] -- and are {i not} handled here. The mechanism carries
    over unchanged; only the marker and the directory name differ. Naming
    that gap is deliberate, so a reader does not read this as covering every
    keeper. *)
let build_root_marker = "dune-project"

let build_output_dir_name = "_build"

(** Directories skipped rather than descended.

    [_build] because it is the thing being moved and holds the file counts
    that make a walk expensive -- one measured at 61,602 entries. [.git]
    because nothing under it builds. *)
let build_scan_skipped = [ build_output_dir_name; ".git" ]

let build_roots_under ~playground_root =
  let rec walk dir depth acc =
    if depth > build_root_scan_depth
    then acc
    else (
      let acc =
        if Sys.file_exists (Filename.concat dir build_root_marker)
        then dir :: acc
        else acc
      in
      match Sys.readdir dir with
      | exception Sys_error _ -> acc
      | entries ->
        Array.sort String.compare entries;
        Array.fold_left
          (fun acc entry ->
            if List.exists (String.equal entry) build_scan_skipped
            then acc
            else (
              let child = Filename.concat dir entry in
              (* [lstat], not [stat]: a symlink is never followed, which keeps
                 the walk from looping and from descending through the very
                 links this module installs. *)
              match Unix.lstat child with
              | { Unix.st_kind = Unix.S_DIR; _ } -> walk child (depth + 1) acc
              | _ | (exception Unix.Unix_error _) -> acc))
          acc
          entries)
  in
  match Unix.lstat playground_root with
  | { Unix.st_kind = Unix.S_DIR; _ } -> List.rev (walk playground_root 0 [])
  | _ | (exception Unix.Unix_error _) -> []
;;

(** The path of [dir] relative to [playground_root], or [None] when it is not
    below it. *)
let playground_relative ~playground_root dir =
  let root =
    let n = String.length playground_root in
    if n > 1 && Char.equal playground_root.[n - 1] '/'
    then String.sub playground_root 0 (n - 1)
    else playground_root
  in
  let root_slash = root ^ "/" in
  let n = String.length root_slash in
  if String.length dir > n && String.equal (String.sub dir 0 n) root_slash
  then Some (String.sub dir n (String.length dir - n))
  else None
;;

type build_link_row =
  { path : string
  ; target : string option
  ; outcome : ([ `Linked | `Relinked | `Unchanged ], string) result
  }

(** Point every checkout's [_build] at the volume, and report each one.

    A row per checkout rather than a single verdict: one refusal must not hide
    the checkouts that were linked, and the caller has to be able to say which
    one stayed on the share. [target] carries the guest path so the caller can
    create it -- see {!build_target_mkdir_argv} for why that is a separate
    step. *)
let ensure_build_links ~playground_root =
  build_roots_under ~playground_root
  |> List.map (fun root ->
    let path = Filename.concat root build_output_dir_name in
    match playground_relative ~playground_root root with
    | None ->
      { path
      ; target = None
      ; outcome = Error (Printf.sprintf "%s is not below %s" root playground_root)
      }
    | Some relative ->
      (match build_link_target ~playground_relative:relative with
       | Error message -> { path; target = None; outcome = Error message }
       | Ok target ->
         { path
         ; target = Some target
         ; outcome =
             apply_build_link ~path (plan_build_link ~target (build_link_state_of_path path))
         }))
;;

(** What each checkout's [_build] is, without changing any of it.

    The status surface needs the same walk [ensure_build_links] does but must
    not act: an operator opening a tab should not install links as a side
    effect of looking. A checkout still holding a real [_build] is the row
    that matters -- it is the one still writing to the virtiofs share, and
    the one a person has to clear by hand. *)
let observe_build_links ~playground_root =
  build_roots_under ~playground_root
  |> List.map (fun root ->
    let path = Filename.concat root build_output_dir_name in
    path, build_link_state_of_path path)
;;

(** Create the link targets inside the guest.

    Measured, and the reason this step exists: dune does not create the
    directory a [_build] symlink points at. It lstats [_build], sees something
    there, and opens [_build/.lock] straight away --

    {v Error: open(_build/.lock): No such file or directory v}

    The host cannot create it either, because it lives inside the volume's
    ext4 image. The volume root is initially owned by root, so creation runs
    as root with an explicit writable mode. [-m] applies only to newly created
    directories: existing Keeper-owned targets remain untouched, which matters
    because Apple Container's user namespace refuses even guest root changing
    their mode. One command covers every target and is idempotent. *)
let build_target_dir_mode = "0777"

let build_target_mkdir_argv ~container_name ~targets =
  exec_argv
    ~container_name
    ~uid:0
    ~gid:0
    ~container_cwd:build_volume_guest_root
    ~stdin:false
    ~command_argv:("mkdir" :: "-p" :: "-m" :: build_target_dir_mode :: targets)
;;

(** The keeper's root on the work volume, created the same way and for the
    same reason: the volume root is root-owned, and the user namespace
    refuses a later chmod, so the directory is made as root with the mode it
    will keep. Idempotent. *)
let keeper_work_root_mkdir_argv ~container_name ~keeper_name =
  exec_argv
    ~container_name
    ~uid:0
    ~gid:0
    ~container_cwd:work_volume_guest_root
    ~stdin:false
    ~command_argv:
      [ "mkdir"; "-p"; "-m"; build_target_dir_mode; keeper_work_root ~keeper_name ]
;;

(** Targets that a build will write through, from the rows above.

    A refused checkout contributes nothing: it keeps its real [_build] on the
    share, so there is no volume directory for it to need. *)
let build_link_targets_to_create rows =
  List.filter_map
    (fun row ->
      match row.outcome, row.target with
      | Ok (`Linked | `Relinked | `Unchanged), Some target -> Some target
      | _ -> None)
    rows
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

(** Guests whose owning server is gone.

    A guest is keeper-lifetime, so age says nothing: one running for days
    belongs to a keeper that has been busy for days. What marks a guest as
    abandoned is its [masc.mcp.owner_pid] label naming a process that no
    longer exists -- the server that booted it died without reaching
    shutdown finalization, which is the one path that removes a guest
    (#31413). Each is about 460 MB, so they are worth collecting.

    Owner liveness is a fact rather than a heuristic, which is why this does
    not fall back to a time cutoff when the label is missing or unreadable:
    a guest it cannot account for is left alone and reported, not removed.
    Removing somebody's running guest to tidy up is worse than leaking. *)
type sweep_candidate =
  { container_id : string
  ; keeper_name : string option
  ; owner_pid : int option
  }

let label_of entry key =
  let open Yojson.Safe.Util in
  match entry |> member "configuration" |> member "labels" |> member key with
  | `String value -> Some value
  | _ -> None
;;

let json_string_opt = function
  | `String value -> Some value
  | _ -> None
;;

let container_id_of_entry entry =
  let open Yojson.Safe.Util in
  match entry |> member "id" |> json_string_opt with
  | Some id -> Some id
  | None -> entry |> member "configuration" |> member "id" |> json_string_opt
;;

let live_containers_of_json ~base_path ~keeper_name = function
  | `List entries ->
    let open Yojson.Safe.Util in
    let expected_base_path_hash = Keeper_sandbox_runtime.base_path_hash base_path in
    let expected_keeper_name = Keeper_sandbox_runtime.sanitize_label_value keeper_name in
    let belongs_to_keeper entry =
      String.equal
        (Option.value ~default:""
           (label_of entry Keeper_sandbox_runtime.sandbox_component_label_key))
        Keeper_sandbox_runtime.sandbox_component_label_value
      && String.equal
           (Option.value ~default:""
              (label_of entry Keeper_sandbox_runtime.sandbox_base_path_hash_label_key))
           expected_base_path_hash
      && String.equal
           (Option.value ~default:""
              (label_of entry Keeper_sandbox_runtime.sandbox_keeper_label_key))
           expected_keeper_name
      && String.equal
           (Option.value ~default:""
              (label_of entry Keeper_sandbox_runtime.sandbox_kind_label_key))
           keeper_vm_container_kind
    in
    let decode entry =
      if not (belongs_to_keeper entry) then Ok None
      else
        match container_id_of_entry entry with
        | None ->
          Error
            (Printf.sprintf "microvm live container for %s is malformed: missing id"
               keeper_name)
        | Some id ->
          try
          let configuration = entry |> member "configuration" in
          let image = configuration |> member "image" |> member "reference" |> to_string in
          let state = entry |> member "status" |> member "state" |> to_string in
          let labels = configuration |> member "labels" in
          let label name = labels |> member name |> json_string_opt in
          let float_label name = Option.bind (label name) float_of_string_opt in
          let owner_pid =
            Option.bind
              (label Keeper_sandbox_runtime.sandbox_owner_pid_label_key)
              int_of_string_opt
          in
          Ok
            (Some
               ({ id
                ; name = id
                ; image
                ; status = state
                ; running = Some (String.equal state "running")
                ; created_at = configuration |> member "creationDate" |> json_string_opt
                ; keeper_name = label Keeper_sandbox_runtime.sandbox_keeper_label_key
                ; container_kind = label Keeper_sandbox_runtime.sandbox_kind_label_key
                ; network_label = label Keeper_sandbox_runtime.sandbox_network_label_key
                ; owner_pid
                ; started_at = float_label Keeper_sandbox_runtime.sandbox_started_at_label_key
                ; ttl_sec = float_label Keeper_sandbox_runtime.sandbox_ttl_sec_label_key
                } : Keeper_sandbox_runtime.live_container))
          with Yojson.Safe.Util.Type_error (detail, _) ->
            Error
              (Printf.sprintf "microvm live container for %s is malformed: %s"
                 keeper_name detail)
    in
    List.fold_right
      (fun entry result ->
         match decode entry, result with
         | Error detail, _ | _, Error detail -> Error detail
         | Ok None, Ok containers -> Ok containers
         | Ok (Some container), Ok containers -> Ok (container :: containers))
      entries
      (Ok [])
  | _ -> Error "microvm container list must be a JSON array"
;;

let list_live_containers ~base_path ~keeper_name ~timeout_sec =
  let argv = command_argv () @ [ "list"; "-a"; "--format"; "json" ] in
  match Process_eio.run_argv_with_status_split ~timeout_sec argv with
  | Unix.WEXITED 0, stdout, _ -> (
    match Yojson.Safe.from_string stdout with
    | json -> live_containers_of_json ~base_path ~keeper_name json
    | exception Yojson.Json_error detail ->
      Error ("microvm container list returned invalid JSON: " ^ detail))
  | status, stdout, stderr ->
    Error
      (Printf.sprintf
         "microvm container list failed (%s): %s"
         (Keeper_sandbox_exec_failure.status_label status)
         (output_for_log ~stdout ~stderr))
;;

let sweep_candidates_of_json ~base_path ~is_pid_alive json =
  let open Yojson.Safe.Util in
  let base_path_hash = Keeper_sandbox_runtime.base_path_hash base_path in
  match json with
  | `List entries ->
    List.filter_map
      (fun entry ->
         let kind = label_of entry Keeper_sandbox_runtime_setup.sandbox_kind_label_key in
         let component =
           label_of entry Keeper_sandbox_runtime_setup.sandbox_component_label_key
         in
         let entry_base_path_hash =
           label_of entry Keeper_sandbox_runtime_setup.sandbox_base_path_hash_label_key
         in
         let id =
           match entry |> member "configuration" |> member "id" with
           | `String id -> Some id
           | _ -> None
         in
         match component, entry_base_path_hash, kind, id with
         | ( Some component
           , Some entry_base_path_hash
           , Some kind
           , Some container_id )
           when String.equal component Keeper_sandbox_runtime_setup.sandbox_component_label_value
                && String.equal entry_base_path_hash base_path_hash
                && String.equal kind keeper_vm_container_kind ->
           let owner_pid =
             Option.bind (label_of entry Keeper_sandbox_runtime_setup.sandbox_owner_pid_label_key) int_of_string_opt
           in
           (match owner_pid with
            (* No label, or one that does not parse: this build cannot say
               whose guest it is, so it stays. *)
            | None -> None
            | Some pid -> if is_pid_alive pid then None else Some { container_id; keeper_name = label_of entry Keeper_sandbox_runtime_setup.sandbox_keeper_label_key; owner_pid })
         | _ -> None)
      entries
  | _ -> []
;;

type sweep_outcome =
  { removed : string list
  ; failed : (string * string) list
  }

(** Remove every guest whose owning server is gone.

    Returns what it did rather than raising: a guest that refuses to stop is
    worth reporting, and is not a reason to fail whatever asked for the
    sweep. A listing that cannot be read removes nothing. *)
let sweep_abandoned_guests
      ~base_path
      ~command_available
      ~timeout_sec
      ~is_pid_alive
      ~run_argv
  =
  match command_argv () with
  | [] -> invalid_arg "microvm CLI argv is empty"
  | command :: _ when not (command_available command) -> None
  | _ ->
    let listing = command_argv () @ [ "list"; "-a"; "--format"; "json" ] in
    Some
      (match run_argv ~timeout_sec listing with
       | Unix.WEXITED 0, out ->
         let candidates =
           match Yojson.Safe.from_string out with
           | json -> sweep_candidates_of_json ~base_path ~is_pid_alive json
           | exception Yojson.Json_error _ -> []
         in
         List.fold_left
           (fun acc candidate ->
              match
                run_argv
                  ~timeout_sec
                  (delete_force_argv ~container_name:candidate.container_id)
              with
              | Unix.WEXITED 0, _ ->
                { acc with removed = candidate.container_id :: acc.removed }
              | _, detail ->
                { acc with
                  failed = (candidate.container_id, detail) :: acc.failed
                })
           { removed = []; failed = [] }
           candidates
       | _, _ -> { removed = []; failed = [] })
;;
