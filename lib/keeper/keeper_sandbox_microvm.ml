(** microVM argv for the [Micro_vm] sandbox profile.

    Every builder here takes the runtime the keeper declared
    ({!Keeper_microvm_backend.t}). Before #32837 the lifecycle surfaces took
    it and the boot, exec, image and listing surfaces did not, so a keeper
    naming [microsandbox] booted under Apple's [container] and was then
    stopped and inspected with [msb] -- two runtimes for one guest, and
    nothing able to reap the one that actually booted.

    One lightweight VM per container through Virtualization.framework, so an
    Apple guest runs its own Linux kernel instead of sharing the host's.
    Measured
    2026-08-28 on macOS 26.6.1 / M3 Max with container CLI 1.3.0: about
    460 MB of host memory per running guest, and the guest reporting
    [Linux <uuid> 6.18.35].

    Cost is per keeper, not per call. Booting a guest takes 1.3-2.4s, but
    #31340 made the guest keeper-lifetime, so a turn pays [container exec]
    at 0.06-0.10s -- under Docker's 0.6-0.9s per-call container start. An
    earlier version of this comment quoted 4.0-4.4s per call: that was
    measured before guests were adopted across turns, and stayed here after
    the number stopped being true.

    This module builds the command and nothing else; [Keeper_turn_sandbox_runtime]
    runs the boot and lifecycle argv, and the remote lane
    ([Keeper_sandbox_remote]) drives the guest's shim over [container exec].
    The guest owns its working tree on a per-keeper volume (RFC-0400): the
    host playground is never mounted into it. *)

module Backend = Keeper_microvm_backend

(* The backend a call builds argv for. Every builder below takes it, so the
   choice travels with the call instead of sitting in module state that a
   second keeper on a second backend would race. *)
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
    tree lives here, on ext4, and this path is the remote lane's
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

(** What each runtime is told about the network.

    A closed network is an isolation property, so it is spelled per runtime
    rather than in one grammar handed to all three. [container] and
    [nerdctl] take Docker's [--network none] / [--dns]. [msb] takes neither:
    [msb run --network none] answers "unexpected argument '--network' found"
    and [--dns] the same (0.6.16, 2026-09-04). Its own spellings are
    [--no-net] ("Disable all network access by default... without rules, the
    guest has no network reachability"), [--net <PROFILE>], and
    [--dns-nameserver <ADDR>].

    [Network_inherit] is a refusal for [msb]: leaving the flags off would
    hand the guest whatever msb's unstated default network is, and that is
    the difference between a keeper that reaches GitHub and one that reaches
    the host. What msb's default is has not been measured, so it is not
    assumed. [--no-net] answers [Network_none] and that is the only mode this
    module can say in msb's grammar today.

    Below is what was measured for Apple's runtime.

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
let network_args_for backend ~dns (mode : Keeper_types_profile_sandbox.network_mode) =
  match (backend : Backend.t) with
  | Backend.Apple_container | Backend.Nerdctl_kata ->
    Ok
      (match mode with
       | Keeper_types_profile_sandbox.Network_none -> [ "--network"; "none" ]
       | Keeper_types_profile_sandbox.Network_inherit ->
         (match dns with
          | Some server when String.trim server <> "" -> [ "--dns"; String.trim server ]
          | Some _ | None -> []))
  | Backend.Microsandbox ->
    (match mode with
     | Keeper_types_profile_sandbox.Network_none -> Ok [ "--no-net" ]
     | Keeper_types_profile_sandbox.Network_inherit ->
       Error
         "microvm_network_mode_unexpressible: msb 0.6.16 rejects --network \
          and --dns and spells its own policy --no-net / --net <PROFILE> / \
          --dns-nameserver. --no-net answers network_mode = \"none\", but \
          what msb's network is with no flag at all has not been measured, \
          so network_mode = \"inherit\" is not handed to it as an omission. \
          Next: set network_mode = \"none\" on this Keeper, or measure msb's \
          default network and name the profile that matches inherit.")
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

(** The shapes a machine-readable image answer arrives in.

    Measured 2026-09-04, container 1.3.1 and msb 0.6.16:

    {v
      container image list --format json     [ {...}, ... ]   array
      container image inspect <ref>          [ {...} ]        array
      msb image list --format json           [ {...}, ... ]   array
      msb image inspect --format json <ref>  { ... }          object
      nerdctl images --format '{{json .}}'   one object/line  lines
    v}

    An object read with the array check would call a healthy answer malformed
    and turn "image is present" into "the probe could not say" -- which is
    what an earlier version of this module did to every [msb] keeper. The
    shape is chosen by the runtime and the question, never assumed. *)
type json_shape =
  | Json_array
  | Json_object
  | Json_lines

let json_array_error raw =
  match Yojson.Safe.from_string raw with
  | `List _ -> None
  | _ -> Some "expected a JSON array"
  | exception Yojson.Json_error detail -> Some ("invalid JSON: " ^ detail)
;;

let json_object_error raw =
  match Yojson.Safe.from_string raw with
  | `Assoc _ -> None
  | _ -> Some "expected a JSON object"
  | exception Yojson.Json_error detail -> Some ("invalid JSON: " ^ detail)
;;

let json_lines_error raw =
  String.split_on_char '\n' raw
  |> List.map String.trim
  |> List.filter (fun line -> not (String.equal line ""))
  |> List.fold_left
       (fun found line ->
         match found with
         | Some _ -> found
         | None ->
           (match Yojson.Safe.from_string line with
            | _ -> None
            | exception Yojson.Json_error detail ->
              Some ("invalid JSON line: " ^ detail)))
       None
;;

let json_shape_error shape raw =
  match shape with
  | Json_array -> json_array_error raw
  | Json_object -> json_object_error raw
  | Json_lines -> json_lines_error raw
;;

let probe_failure ~phase ~status ~stdout ~stderr ~reason =
  Image_probe_failed { phase; status; stdout; stderr; reason }
;;

let classify_image_probe
      ~inspect_shape
      ~listing_shape
      ~inspect:(inspect_status, inspect_stdout, inspect_stderr)
      ~listing
  =
  match inspect_status with
  | Unix.WEXITED 0 ->
    (match json_shape_error inspect_shape inspect_stdout with
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
       (match json_shape_error listing_shape stdout with
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
  | Image_list -> "image listing"
;;

(* Each runtime keeps its own image store, so the refusal names the CLI that
   was asked. Telling an [msb] keeper to install Apple container -- which the
   Apple-only wording did -- sends the operator to fix a runtime the keeper
   does not use. *)
let image_present_result_for backend ~image = function
  | Image_present -> Ok ()
  | Image_missing ->
    Error
      (Printf.sprintf
         "microvm_image_missing: %s is not in %s's image store. Each microVM \
          runtime keeps its images apart from Docker's, and none of these \
          runs has a --pull=never, so running without this check fetches from \
          a registry instead of failing. Next: build or load the image into \
          %s before starting a microvm keeper."
         image
         (Backend.cli_name backend)
         (Backend.cli_name backend))
  | Image_cli_unavailable ->
    Error
      (Printf.sprintf
         "microvm_cli_unavailable: keeper declares microvm_backend = %s and \
          the `%s` CLI is not on PATH. Next: install it, name a runtime this \
          host has (%s), or move the keeper to sandbox_profile = \"docker\"."
         (Backend.to_string backend)
         (Backend.cli_name backend)
         (String.concat ", " Backend.valid_strings))
  | Image_probe_failed failure ->
    Error
      (Printf.sprintf
         "microvm_image_probe_failed: `%s %s` did not establish whether image \
          %s exists (%s; %s: %s). Next: check that the %s runtime is running."
         (Backend.cli_name backend)
         (phase_label failure.phase)
         image
         failure.reason
         (Keeper_sandbox_exec_failure.status_label failure.status)
         (output_for_log ~stdout:failure.stdout ~stderr:failure.stderr)
         (Backend.cli_name backend))
;;

(* [nerdctl] has no [image list]; its listing is [images]. Its command
   reference documents both [--format=json] and the Go template; the template
   is the spelling used here because it is the one whose per-line output this
   module's [Json_lines] reader is written against. [container image list
   --format json] and [msb image list --format json] both answer an array,
   measured 0.6.16 and 1.3.1 on 2026-09-04. *)
let image_listing_argv_for backend =
  match (backend : Backend.t) with
  | Backend.Apple_container | Backend.Microsandbox ->
    command_argv_for backend @ [ "image"; "list"; "--format"; "json" ]
  | Backend.Nerdctl_kata ->
    command_argv_for backend @ [ "images"; "--format"; "{{json .}}" ]
;;

let image_listing_shape_for backend =
  match (backend : Backend.t) with
  | Backend.Apple_container | Backend.Microsandbox -> Json_array
  | Backend.Nerdctl_kata -> Json_lines
;;

(* [container image inspect] answers JSON with no flag; [msb image inspect]
   answers a human table unless [--format json] is asked for, and then answers
   a bare object rather than an array. [nerdctl image inspect] documents
   [--mode=(dockercompat|native)] with no stated default, so the mode is named
   rather than assumed -- dockercompat, which is Docker's array-of-one shape
   this module already reads. *)
let image_inspect_argv_for backend ~image =
  match (backend : Backend.t) with
  | Backend.Apple_container -> command_argv_for backend @ [ "image"; "inspect"; image ]
  | Backend.Microsandbox ->
    command_argv_for backend @ [ "image"; "inspect"; "--format"; "json"; image ]
  | Backend.Nerdctl_kata ->
    command_argv_for backend
    @ [ "image"; "inspect"; "--mode"; "dockercompat"; image ]
;;

let image_inspect_shape_for backend =
  match (backend : Backend.t) with
  | Backend.Apple_container | Backend.Nerdctl_kata -> Json_array
  | Backend.Microsandbox -> Json_object
;;

let image_probe_for backend ~image ~timeout_sec =
  let inspect =
    Process_eio.run_argv_with_status_split
      ~timeout_sec
      (image_inspect_argv_for backend ~image)
  in
  let listing =
    match inspect with
    | Unix.WEXITED 1, _, _ ->
      Some
        (Process_eio.run_argv_with_status_split
           ~timeout_sec
           (image_listing_argv_for backend))
    | _ -> None
  in
  classify_image_probe
    ~inspect_shape:(image_inspect_shape_for backend)
    ~listing_shape:(image_listing_shape_for backend)
    ~inspect
    ~listing
;;

let image_present_for backend ~image ~timeout_sec =
  image_probe_for backend ~image ~timeout_sec |> image_present_result_for backend ~image
;;

(* ── Turn-container argv ─────────────────────────────────────────────

   The guest model is shared and the spellings are not. One detached guest
   per keeper holding [tail -f /dev/null], commands delivered by [exec],
   the working tree on the per-keeper work volume, no host playground:
   that is RFC-0400's model and it does not change with the hypervisor
   under it. What changes is how each CLI is told, so the flags come from
   {!Keeper_microvm_backend} and the guarantees the boot asks for are
   named rather than spelled.

   Apple's spellings were accepted by a live container 1.3.0 run on
   2026-08-28; [exec] propagated exit codes (observed rc=7) and stdin
   ([bash -l -s] echoed piped input).

   Deliberately absent against the Docker turn argv, stated so a reader
   does not infer parity: seccomp / --security-opt / --pids-limit
   (container rejects them; the guest kernel is the boundary), the
   workspace-state mounts, the /etc/passwd identity mounts ([--user
   uid:gid] is passed directly), and the host playground itself -- the
   guest's tree is its work volume, which arrives in [mount_args].

   [mount_args] carries what the caller projects -- config, GitHub
   identity, the work volume and the shim. Measured 2026-08-28 against
   masc-keeper-sandbox:local, an Apple guest reads through
   [-v host:container:ro] and takes [--env-file], both in Docker's own
   spelling. Neither is established for msb: it rejects [--env-file]
   outright (0.6.16, 2026-09-04), and [:ro] is not among the volume
   options its help documents. *)

(** The runtime a guest was booted on, written on the guest itself. Every
    other surface reads the keeper's TOML; this one is on the object, so a
    listing can tell an [msb] guest from an Apple one without a second read. *)
let microvm_backend_label_key = "masc.mcp.microvm_backend"

(** The [Lifecycle] guarantees this runtime could not spell, so the drop is
    on the guest rather than only in a log line the boot already emitted. *)
let microvm_dropped_constraints_label_key = "masc.mcp.microvm_dropped"

type constraint_refusal =
  { guest_constraint : Backend.guest_constraint
  ; reason : string
  }

let constraint_refusals_message backend refusals =
  Printf.sprintf
    "microvm_constraint_unexpressible: %s cannot express %s"
    (Backend.to_string backend)
    (String.concat
       "; "
       (List.map
          (fun (refusal : constraint_refusal) ->
            Printf.sprintf
              "%s (%s)"
              (Backend.guest_constraint_to_string refusal.guest_constraint)
              refusal.reason)
          refusals))
;;

let turn_start_argv_for
      backend
      ~container_name
      ~label_args
      ~uid
      ~gid
      ~memory
      ~cpus
      ~network_args
      ~mount_args
      ~image
      ~constraints
  =
  let expressed, refused, dropped =
    List.fold_left
      (fun (expressed, refused, dropped) guest_constraint ->
        match Backend.run_constraint_argv backend guest_constraint with
        | Backend.Expressed tokens -> expressed @ tokens, refused, dropped
        | Backend.Not_expressible reason ->
          (match Backend.constraint_class guest_constraint with
           | Backend.Isolation ->
             ( expressed
             , ({ guest_constraint; reason } : constraint_refusal) :: refused
             , dropped )
           | Backend.Lifecycle -> expressed, refused, guest_constraint :: dropped))
      ([], [], [])
      constraints
  in
  match List.rev refused with
  | _ :: _ as refusals -> Error refusals
  | [] ->
    let dropped_label_args =
      match List.rev dropped with
      | [] -> []
      | dropped ->
        [ "--label"
        ; microvm_dropped_constraints_label_key
          ^ "="
          ^ String.concat "," (List.map Backend.guest_constraint_to_string dropped)
        ]
    in
    Ok
      (command_argv_for backend
       @ [ "run"; "-d"; "--name"; container_name ]
       @ label_args
       @ [ "--label"; microvm_backend_label_key ^ "=" ^ Backend.to_string backend ]
       @ dropped_label_args
       @ [ "--user"; Printf.sprintf "%d:%d" uid gid ]
       @ expressed
       @ [ "--memory"; memory ]
       @ (match cpus with
          | Some count -> [ "--cpus"; count ]
          | None -> [])
       @ Backend.run_runtime_args backend
       @ mount_args
       @ [ "--workdir"; work_volume_guest_root ]
       @ network_args
       @ Backend.command_separator backend
       @ [ image; "tail"; "-f"; "/dev/null" ])
;;

(* [--user uid:gid] is a value [container exec] and [nerdctl exec] document
   and [msb exec] does not -- see {!shim_exec_prefix_for} for the whole
   reading. Every msb caller of this builder is behind an earlier refusal
   today ({!ensure_work_volume_for}), so the numeric form never reaches msb.
   Lifting that refusal without settling the identity would make this the
   place a keeper's tree gets written under the wrong uid. *)
let exec_argv_for backend ~container_name ~uid ~gid ~container_cwd ~stdin ~command_argv =
  command_argv_for backend
  @ [ "exec" ]
  @ (if stdin then Backend.exec_stdin_args backend else [])
  @ [ "--user"; Printf.sprintf "%d:%d" uid gid; "-w"; container_cwd ]
  @ [ container_name ]
  @ Backend.command_separator backend
  @ command_argv
;;

(** The prefix the remote lane delivers a framed shim request through.

    It differs from {!exec_argv_for} in one thing the shim cannot do without:
    the guest has to be told where its config is, and that travels as an
    environment entry on the exec. All three CLIs document that entry --
    [msb exec] has [-e, --env <ENV>] the same as the other two.

    What [msb] does not document is the identity the shim runs under.
    [container exec --user] documents [name|uid[:gid]] and nerdctl takes
    Docker's, so the mapped [uid:gid] this lane runs the keeper's commands as
    is a value those CLIs accept. [msb exec -u, --user <USER>] documents
    "Run the command as the specified guest user" and no numeric form
    (0.6.16, 2026-09-04). Sending [501:20] there would be a value read from
    no help output, and if msb resolved it as a user name the shim would run
    as somebody else on a tree owned by that uid -- a silent wrong-identity
    write, not a failed call. So this refuses. Settling it means either msb
    documenting the numeric form or the lane naming a guest user, which is a
    decision about identity rather than a spelling. *)
let shim_exec_prefix_for backend ~container_name ~uid ~gid ~remote_root ~shim_config_path =
  match (backend : Backend.t) with
  | Backend.Apple_container | Backend.Nerdctl_kata ->
    Ok
      (command_argv_for backend
       @ [ "exec" ]
       @ Backend.exec_stdin_args backend
       @ [ "--user"
         ; Printf.sprintf "%d:%d" uid gid
         ; "-w"
         ; remote_root
         ; "--env"
         ; Exec_ssh_protocol.shim_config_env_var ^ "=" ^ shim_config_path
         ; container_name
         ]
       @ Backend.command_separator backend)
  | Backend.Microsandbox ->
    Error
      "microvm_shim_exec_unsupported: msb 0.6.16 exec takes the environment \
       entry the shim needs (-e/--env), but its --user documents a guest \
       user name and no uid:gid form, so the identity this lane runs a \
       keeper's commands under cannot be named. Sent anyway, msb would \
       either reject it or resolve it as somebody else's name and write to \
       the keeper's tree as that user. Next: name a guest user for the lane, \
       or use a runtime whose --user takes uid:gid (RFC-0405 follow-up)."
;;

(* The two runtimes spell removal differently -- [container delete --force]
   against [msb remove --force] -- and stop the same way. Measured against
   msb 0.6.16 on 2026-09-03; a spelling this file guesses at would fail every
   call rather than fail once, so each is written from that CLI's own help. *)
let stop_argv_for backend ~container_name =
  command_argv_for backend @ [ "stop"; container_name ]
;;

let delete_force_argv_for backend ~container_name =
  match (backend : Backend.t) with
  | Backend.Apple_container ->
    command_argv_for backend @ [ "delete"; "--force"; container_name ]
  | Backend.Microsandbox ->
    command_argv_for backend @ [ "remove"; "--force"; container_name ]
  | Backend.Nerdctl_kata ->
    command_argv_for backend @ [ "rm"; "--force"; container_name ]
;;

(* ── The work volume and the shim (RFC-0400) ────────────────────────── *)

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

(** Apple's spelling of a sized volume. It is named after the runtime rather
    than left as the lane's default because the other two do not share it:
    [msb] rejects [-s] and wants [--kind disk --size] (measured 0.6.16), and
    [nerdctl volume create] documents [--label] only and no size flag at all.
    {!ensure_work_volume_for} is the entry that answers for all three. *)
let apple_volume_create_argv ~volume_name ~size =
  command_argv_for Backend.Apple_container
  @ [ "volume"; "create"; "-s"; size; volume_name ]
;;

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
    work volume, the payload PATH is the image's, and the env allowlist
    names the config env the endpoint injects with every request
    ({!Keeper_sandbox_runtime.config_env_names}) -- the shim drops any
    request env it was not told to accept, and the guest is given the
    config mount, so it must be told the names that point at it. *)
let shim_config_content ~payload_path =
  Printf.sprintf
    "remote_root=%s\npath=%s\nenv_allowlist=%s\n"
    work_volume_guest_root
    payload_path
    (String.concat "," Keeper_sandbox_runtime.config_env_names)
;;

(** What the guest endpoint declares to the remote runner. No caller env
    crosses into a guest today (typed guest dispatch refuses env), so the
    allowlist is empty; the session ceiling mirrors the OpenSSH default, and
    the connect budget covers a [container exec] that has to wait on a
    guest still settling after boot. *)
let remote_env_allowlist : string list = []
let remote_connect_timeout_sec = 10
let remote_max_concurrent_sessions = 8

(* ── Provisioning the work volume ──────────────────────────────────── *)

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
    already holds a keeper's working tree. *)
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

let apple_volume_probe ~volume_name ~timeout_sec =
  let cli = command_argv_for Backend.Apple_container in
  let inspect_argv = cli @ [ "volume"; "inspect"; volume_name ] in
  let inspect = Process_eio.run_argv_with_status_split ~timeout_sec inspect_argv in
  let listing =
    match inspect with
    | Unix.WEXITED 1, _, _ ->
      let list_argv = cli @ [ "volume"; "list"; "--format"; "json" ] in
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
let ensure_apple_work_volume ~volume_name ~size ~timeout_sec =
  match apple_volume_probe ~volume_name ~timeout_sec with
  | Volume_present -> Ok `Already_present
  | Volume_probe_failed message ->
    Error (Printf.sprintf "microvm_work_volume_probe_failed: %s" message)
  | Volume_absent ->
    let argv = apple_volume_create_argv ~volume_name ~size in
    (match Process_eio.run_argv_with_status_split ~timeout_sec argv with
     | Unix.WEXITED 0, _, _ -> Ok `Created
     | status, stdout, stderr ->
       Error
         (Printf.sprintf
            "microvm_work_volume_create_failed: %s (%s; %s)"
            volume_name
            (match status with
             | Unix.WEXITED code -> Printf.sprintf "exit %d" code
             | Unix.WSIGNALED n -> Printf.sprintf "signalled %d" n
             | Unix.WSTOPPED n -> Printf.sprintf "stopped %d" n)
            (output_for_log ~stdout ~stderr)))
;;

(** The work volume, for whichever runtime this keeper declared.

    Only Apple's grammar is established here, so the other two refuse instead
    of guessing at one.

    For [msb] the create is known ([volume create --kind disk --size],
    measured 0.6.16, [-s] rejected), and so is half of the existence check:
    [msb volume list --format json] is documented and answers an array
    (measured, [[]] on a host with no volumes). The other half is not.
    [msb volume inspect] carries no [--format], so it answers a human table,
    and this probe is written as inspect-then-listing the way Apple's is:
    a create over a volume that already holds a keeper's working tree is the
    failure the check exists for, and human prose is not a protocol to settle
    it on. Establishing the row shape of the listing -- which needs an msb
    volume to observe, and this host has none -- is what would let the pair
    be rewritten as a listing-only check.

    For [nerdctl] there is nothing to establish -- its [volume create]
    documents [--label] and no size flag (nerdctl command reference), so the
    sized per-keeper volume RFC-0400 asks for has no nerdctl spelling. *)
let ensure_work_volume_for backend ~volume_name ~size ~timeout_sec =
  match (backend : Backend.t) with
  | Backend.Apple_container -> ensure_apple_work_volume ~volume_name ~size ~timeout_sec
  | Backend.Microsandbox ->
    Error
      "microvm_work_volume_unsupported: msb 0.6.16 creates a sized volume \
       with `volume create --kind disk --size` (-s is rejected), and `msb \
       volume list --format json` is machine-readable, but `msb volume \
       inspect` carries no --format and answers a human table, so the \
       inspect half of the existence check this provisioning runs has no \
       machine form. Creating over a volume that already holds a keeper's \
       working tree is the failure that check exists for. Next: settle \
       existence from the listing alone, which needs the row shape of `msb \
       volume list --format json` observed against a real volume."
  | Backend.Nerdctl_kata ->
    Error
      "microvm_work_volume_unsupported: nerdctl volume create documents \
       --label only and no size flag, so the sized per-keeper work volume \
       RFC-0400 puts the keeper's tree on has no nerdctl spelling."
;;

(** The keeper's root on the work volume, created inside the guest.

    The host cannot create it: it lives inside the volume's ext4 image. The
    volume root is initially owned by root, and Apple Container's user
    namespace refuses even guest root changing a mode afterwards, so the
    directory is made as root with the mode it will keep. [-m] applies only
    to a newly created directory; an existing keeper-owned root is untouched.
    Idempotent. *)
let work_root_dir_mode = "0777"

let keeper_work_root_mkdir_argv_for backend ~container_name ~keeper_name =
  exec_argv_for
    backend
    ~container_name
    ~uid:0
    ~gid:0
    ~container_cwd:work_volume_guest_root
    ~stdin:false
    ~command_argv:
      [ "mkdir"; "-p"; "-m"; work_root_dir_mode; keeper_work_root ~keeper_name ]
;;

(** Boot invariant (RFC-0052): {!work_volume_guest_root} must be a real
    mountpoint inside the guest, not a directory on the guest rootfs.

    The check exists because the two probes below cannot tell the difference:
    [mkdir -p] and a write both succeed against a writable rootfs directory,
    so a guest whose volume mount is absent at boot would pass them and then
    serve an ephemeral tree -- every keeper write evaporating on the next
    boot, with the delivery log still saying "delivered" (2026-09-04: an
    analyst guest served a turn off a stale rootfs tree). [/proc/mounts] is
    the kernel's own answer and the pattern names the mountpoint field with
    its surrounding spaces, so a prefix like [/masc-work-stale] cannot match.
    [-F] makes the match a fixed string structurally rather than by the
    pattern happening to carry no regex metacharacters. [grep] over
    [/proc/mounts] rather than [mountpoint(1)]: the image
    (Dockerfile.keeper-sandbox, ubuntu-24.04) ships grep as essential and
    util-linux's mountpoint is not in the apt list. Runs as root from [/] so
    the answer does not depend on the keeper's uid or a workdir that is the
    very thing under test. *)
let work_volume_mounted_probe_argv_for backend ~container_name =
  exec_argv_for
    backend
    ~container_name
    ~uid:0
    ~gid:0
    ~container_cwd:"/"
    ~stdin:false
    ~command_argv:
      [ "grep"; "-qF"; Printf.sprintf " %s " work_volume_guest_root; "/proc/mounts" ]
;;

(** The write that follows the mkdir, as the uid the keeper's commands run
    under. The mkdir proves the root exists; only a write as that uid proves
    the keeper can use it. The tree below the root can carry any ownership
    -- one imported from elsewhere under another uid reads identically to
    [ls] and refuses every write (2026-09-02: trees copied as 501 into a
    guest the server enters as 502) -- so the refusal names the owner and
    mode of the root, which is what has to change. *)
let keeper_work_root_write_probe_script =
  "d=\"$1\"; t=$(mktemp \"$d/.masc-probe.XXXXXX\") && unlink \"$t\" || { stat -c \
   \"owner=%u:%g mode=%a %n\" \"$d\" >&2; exit 1; }"
;;

let keeper_work_root_write_probe_argv_for backend ~container_name ~uid ~gid ~keeper_name =
  exec_argv_for
    backend
    ~container_name
    ~uid
    ~gid
    ~container_cwd:work_volume_guest_root
    ~stdin:false
    ~command_argv:
      [ "sh"; "-c"; keeper_work_root_write_probe_script; "masc-probe"
      ; keeper_work_root ~keeper_name ]
;;

(** Label value distinguishing a keeper-lifetime guest from turn
    containers. The guest outlives turns, so it carries no turn id. *)
let keeper_vm_container_kind = "keeper-vm"

(** [container inspect] answers JSON; state lives at [.[0].status.state]
    ("running" observed live). A missing container exits 1, which the
    caller maps to absent before parsing. *)
(* Two runtimes, two shapes, measured 2026-09-03:

     container inspect      [ { "status": { "state": "running" } } ]
     msb inspect --format json
                            { "name": ..., "status": "Running" }

   A list against an object, a nested state against a flat one, lowercase
   against capitalised. Neither parser is written to tolerate the other's
   shape: a shape this code does not know is [Error], never [Ok false]. Read
   as "not running", an unrecognised answer would take a live guest down and
   boot a second one beside it. *)
let running_of_microsandbox_inspect_json raw =
  match Yojson.Safe.from_string raw with
  | `Assoc fields ->
    (match List.assoc_opt "status" fields with
     | Some (`String status) ->
       Ok (String.equal (String.lowercase_ascii status) "running")
     | Some _ | None -> Error "msb inspect: status missing")
  | _ -> Error "msb inspect: unparseable JSON"
  | exception Yojson.Json_error _ -> Error "msb inspect: unparseable JSON"
;;

(* [nerdctl inspect --format "{{json .State.Running}}"] answers the bare
   literal, the same template masc already sends Docker. Anything else is an
   [Error]: a template that stopped resolving prints an empty line, and read
   as "not running" that takes a live guest down. *)
let running_of_nerdctl_state_json raw =
  match String.trim raw with
  | "true" -> Ok true
  | "false" -> Ok false
  | other ->
    Error
      (Printf.sprintf
         "nerdctl inspect: expected the State.Running literal, got %S"
         other)
;;

let running_of_apple_inspect_json raw =
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

let running_of_inspect_json_for backend raw =
  match (backend : Backend.t) with
  | Backend.Apple_container -> running_of_apple_inspect_json raw
  | Backend.Microsandbox -> running_of_microsandbox_inspect_json raw
  | Backend.Nerdctl_kata -> running_of_nerdctl_state_json raw
;;

(* [container inspect] answers JSON by default; [msb inspect] answers a
   human table unless asked, so the machine form is requested explicitly. *)
let inspect_argv_for backend ~container_name =
  match (backend : Backend.t) with
  | Backend.Apple_container -> command_argv_for backend @ [ "inspect"; container_name ]
  | Backend.Microsandbox ->
    command_argv_for backend @ [ "inspect"; container_name; "--format"; "json" ]
  (* [nerdctl inspect] documents [--mode=(dockercompat|native)] and states no
     default, so the mode is named. [{{json .State.Running}}] resolves only
     in dockercompat; inherited from an unstated default it would be a
     template that stops resolving the day the default moves, which prints an
     empty line and reads as "not running". Asking for the one field rather
     than the whole document keeps the parse to a literal. *)
  | Backend.Nerdctl_kata ->
    command_argv_for backend
    @ [ "inspect"
      ; "--mode"
      ; "dockercompat"
      ; "--format"
      ; "{{json .State.Running}}"
      ; container_name
      ]
;;

(* [container logs] takes [-n]; [msb logs] rejects [-n] and takes [--tail]
   (measured 0.6.16, 2026-09-04: "unexpected argument '-n' found"), and
   nerdctl documents [-n, --tail]. *)
let logs_tail_argv_for backend ~tail ~container_id =
  match (backend : Backend.t) with
  | Backend.Apple_container ->
    command_argv_for backend @ [ "logs"; "-n"; string_of_int tail; container_id ]
  | Backend.Microsandbox | Backend.Nerdctl_kata ->
    command_argv_for backend @ [ "logs"; "--tail"; string_of_int tail; container_id ]
;;

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
          let int_member name json =
            match json |> member name with
            | `Int value -> Some value
            | _ -> None
          in
          let network =
            match entry |> member "status" |> member "networks" with
            | `List (network :: _) -> Some network
            | `List [] | `Null | _ -> None
          in
          let network_string name =
            Option.bind network (fun row -> row |> member name |> json_string_opt)
          in
          let resources = configuration |> member "resources" in
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
                ; cpus = int_member "cpus" resources
                ; memory_bytes = int_member "memoryInBytes" resources
                ; hostname = network_string "hostname"
                ; ipv4_address = network_string "ipv4Address"
                ; ipv6_address = network_string "ipv6Address"
                ; gateway = network_string "ipv4Gateway"
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

(** How a runtime answers "which guests are here", and whether that answer
    carries the labels the scoping above reads.

    What the sweep needs from a row is not just "which guests" but "whose":
    the base path hash, the keeper name, and the owner pid it decides
    abandonment on. Filtering is not enough -- the pid has to be read back.

    Apple's [container list -a --format json] answers a JSON array whose
    entries nest [configuration.labels], which is where all three live.

    [msb list] documents [--label <LABEL>] (repeatable, AND-matched), so a
    guest can be scoped server-side; what its [--format json] rows carry is
    only created_at, image, name and status, with no label values at all
    (measured 0.6.16, 2026-09-04). The owner pid the sweep needs is therefore
    not in the answer, and msb keeps labels in [inspect] under
    [active_config.labels] -- one call per guest rather than one listing.

    [nerdctl] has no [list] subcommand (it is [ps]), and its command
    reference does document [--format=json]. What the reference does not
    document for those rows is a [.Labels] field, so the nested labels object
    this scoping reads has no established nerdctl shape; nerdctl is not
    installed on this host, so it could not be measured either.

    Naming the gap rather than running the Apple argv is the point: read as
    "no guests", an unscopable listing is exactly the answer that leaves a
    guest running with nothing able to reap it. *)
type container_listing =
  | Labelled_json_array of string list
  | Listing_not_established of string

let container_listing_for backend =
  match (backend : Backend.t) with
  | Backend.Apple_container ->
    Labelled_json_array
      (command_argv_for backend @ [ "list"; "-a"; "--format"; "json" ])
  | Backend.Microsandbox ->
    Listing_not_established
      "msb list can be scoped server-side with --label, but its --format \
       json rows report only {created_at, image, name, status} and echo no \
       label values, so the owner pid this sweep decides abandonment on \
       cannot be read back from the listing; msb keeps labels in `inspect` \
       under active_config.labels, one call per guest"
  | Backend.Nerdctl_kata ->
    Listing_not_established
      "nerdctl has no `list` subcommand (it is `ps`), and while its reference \
       documents `--format=json` it documents no .Labels field on those rows, \
       so the nested labels object this scoping reads has no established \
       nerdctl shape"
;;

let list_live_containers_for backend ~base_path ~keeper_name ~timeout_sec =
  match container_listing_for backend with
  | Listing_not_established reason ->
    Error
      (Printf.sprintf
         "microvm_container_listing_unsupported: %s: %s"
         (Backend.to_string backend)
         reason)
  | Labelled_json_array argv ->
    (match Process_eio.run_argv_with_status_split ~timeout_sec argv with
     | Unix.WEXITED 0, stdout, _ ->
       (match Yojson.Safe.from_string stdout with
        | json -> live_containers_of_json ~base_path ~keeper_name json
        | exception Yojson.Json_error detail ->
          Error ("microvm container list returned invalid JSON: " ^ detail))
     | status, stdout, stderr ->
       Error
         (Printf.sprintf
            "microvm container list failed (%s): %s"
            (Keeper_sandbox_exec_failure.status_label status)
            (output_for_log ~stdout ~stderr)))
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

(* One runtime's share of the sweep. Returns what it did rather than
   raising: a guest that refuses to stop is worth reporting, and is not a
   reason to fail whatever asked for the sweep. A listing that cannot be read
   removes nothing. *)
let sweep_one_backend backend ~base_path ~timeout_sec ~is_pid_alive ~run_argv listing =
  match run_argv ~timeout_sec listing with
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
            (delete_force_argv_for backend ~container_name:candidate.container_id)
        with
        | Unix.WEXITED 0, _ -> { acc with removed = candidate.container_id :: acc.removed }
        | _, detail ->
          { acc with failed = (candidate.container_id, detail) :: acc.failed })
      { removed = []; failed = [] }
      candidates
  | _, _ -> { removed = []; failed = [] }
;;

(** Remove every abandoned guest, per runtime.

    No keeper is in scope here and none should be: a guest this process did
    not boot belongs to a keeper this process may not have. What is in scope
    is the set of runtimes, so each is asked for its own guests with its own
    argv and removed with its own removal spelling. *)
let sweep_abandoned_guests
      ~base_path
      ~command_available
      ~timeout_sec
      ~is_pid_alive
      ~run_argv
  =
  List.filter_map
    (fun backend ->
      if not (command_available (Backend.cli_name backend))
      then None
      else (
        match container_listing_for backend with
        | Listing_not_established _ -> None
        | Labelled_json_array listing ->
          Some
            ( backend
            , sweep_one_backend
                backend
                ~base_path
                ~timeout_sec
                ~is_pid_alive
                ~run_argv
                listing )))
    Backend.all
;;
