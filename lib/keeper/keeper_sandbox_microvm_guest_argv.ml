module Backend = Keeper_microvm_backend
open Keeper_sandbox_microvm_base
open Keeper_sandbox_microvm_network

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

let render_turn_start_argv_for
      backend
      ~container_name
      ~label_args
      ~backend_label_args
      ~user
      ~(guest_size : Keeper_microvm_guest_size.t)
      ~network_args
      ~mount_args
      ~image
      ~constraints
      ~grant_args
      ~working_directory
      ~command:(executable, arguments)
  =
  let entrypoint_args, command_args =
    match backend with
    | Backend.Apple_container -> ["--entrypoint"; executable], arguments
    | Backend.Nerdctl_kata | Backend.Microsandbox -> [], executable :: arguments
  in
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
           | Backend.Lifecycle | Backend.Observation ->
             expressed, refused, guest_constraint :: dropped))
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
       @ backend_label_args
       @ dropped_label_args
       (* msb [run] has no [--user] (0.6.16); its guest runs as root and the
          per-mount [uid=,gid=] option on the work volume maps writes back to the
          host uid, so identity travels with the mount rather than the process.
          container and nerdctl take [--user uid:gid] and keep it here. *)
       @ (match backend with
          | Backend.Microsandbox -> []
          | Backend.Apple_container | Backend.Nerdctl_kata ->
            [ "--user"; user ])
       @ expressed
       (* What the plan gives back after the constraints: added
          capabilities and published sockets. *)
       @ grant_args
       (* Always both. Leaving [--cpus] off took the CLI's own default, which
          is a size nobody configured and the status surface could not show. *)
       @ [ "--memory"
         ; Keeper_microvm_guest_size.memory_argv guest_size.Keeper_microvm_guest_size.memory
         ]
       @ [ "--cpus"
         ; string_of_int
             (Keeper_microvm_guest_size.cpus_count guest_size.Keeper_microvm_guest_size.cpus)
         ]
       @ Backend.run_runtime_args backend
       @ mount_args
       @ [ "--workdir"; working_directory ]
       @ network_args
       @ entrypoint_args
       @ Backend.command_separator backend
       @ [ image ] @ command_args)
;;

let turn_start_argv_for backend ~container_name ~label_args ~uid ~gid
      ~guest_size ~network_args ~mount_args ~image ~constraints =
  render_turn_start_argv_for backend ~container_name ~label_args
    ~backend_label_args:["--label"; microvm_backend_label_key ^ "=" ^ Backend.to_string backend]
    ~user:(Printf.sprintf "%d:%d" uid gid) ~guest_size ~network_args ~mount_args
    ~image ~constraints ~grant_args:[] ~working_directory:work_volume_guest_root
    ~command:("tail", ["-f"; "/dev/null"])
;;

type apple_boot_failure =
  | Apple_invalid_boot_plan of Keeper_microvm_boot_plan.invalid_plan list
  | Apple_network_unavailable of string
  | Apple_constraints_unexpressible of constraint_refusal list

let apple_turn_start_argv ~container_name ~(plan : Keeper_microvm_boot_plan.t)
      ~lifecycle_labels ~dns ~policy_proxy =
  let module Plan = Keeper_microvm_boot_plan in
  let open Result.Syntax in
  let execution_environment = match plan.network with
    | Plan.Network_none | Plan.Network_inherit -> []
    | Plan.Network_policy _ ->
      (match policy_proxy with None -> [] | Some proxy -> apple_policy_environment proxy) in
  let* () = Plan.validate_boot ~plan ~lifecycle_labels ~execution_environment
    |> Result.map_error (fun errors -> Apple_invalid_boot_plan errors) in
  let* command = match plan.command with
    | [] -> Error (Apple_invalid_boot_plan [Plan.Missing_executable])
    | executable :: arguments -> Ok (executable, arguments) in
  let network_args = apple_network_args ~dns ~policy_proxy plan.network
    |> Result.map_error (fun detail -> Apple_network_unavailable detail) in
  Result.bind network_args (fun network_args ->
    let mount_args = List.concat_map (function
      | Plan.Tmpfs {destination} -> ["--tmpfs"; destination]
      | Plan.Host_dir {source; destination; read_only} ->
        ["-v"; source ^ ":" ^ destination ^ (if read_only then ":ro" else "")]
      | Plan.Named_volume {name; destination} -> ["--volume"; name ^ ":" ^ destination])
      plan.mounts in
    let environment_args = List.concat_map
      (fun (key, value) -> ["--env"; key ^ "=" ^ value]) plan.environment in
    let label_args = List.concat_map
      (fun (key, value) -> ["--label"; key ^ "=" ^ value])
      (plan.labels @ lifecycle_labels @ [Plan.label_key, Plan.digest plan]) in
    let grant_args =
      List.concat_map (fun capability -> ["--cap-add"; Plan.capability_to_string capability])
        plan.capabilities_added
      @ List.concat_map (fun {Plan.host_path; guest_path} ->
          ["--publish-socket"; host_path ^ ":" ^ guest_path]) plan.published_sockets in
    render_turn_start_argv_for Backend.Apple_container ~container_name ~label_args
      ~backend_label_args:[]
      ~user:plan.user ~guest_size:plan.guest_size ~network_args
      ~mount_args:(environment_args @ mount_args) ~image:plan.image
      ~constraints:plan.isolation ~grant_args ~working_directory:plan.working_directory
      ~command
    |> Result.map_error (fun refusals -> Apple_constraints_unexpressible refusals))
;;

(* [--user uid:gid] is a value [container exec] ([name|uid[:gid]]) and
   [nerdctl exec] (Docker's) document and [msb exec] does not -- see
   {!shim_exec_prefix_for} for the msb reading. Every msb caller of this
   builder is behind an earlier refusal today ({!ensure_work_volume_for}), so
   the numeric form never reaches msb. Lifting that refusal without settling
   the identity would make this the place a keeper's tree gets written under
   the wrong uid. *)
let exec_argv_for backend ~container_name ~uid ~gid ~container_cwd ~stdin ~command_argv =
  command_argv_for backend
  @ [ "exec" ]
  @ (if stdin then Backend.exec_stdin_args backend else [])
  (* msb [exec] has [--user], but it names a guest user string, not the uid:gid
     this lane maps ownership with; sending "501:20" would be read as a user
     name and write under the wrong identity. The work volume's [uid=,gid=]
     mount already places writes at the right host uid, so msb runs as its guest
     default and no per-exec [--user] is sent. *)
  @ (match backend with
     | Backend.Microsandbox -> [ "-w"; container_cwd ]
     | Backend.Apple_container | Backend.Nerdctl_kata ->
       [ "--user"; Printf.sprintf "%d:%d" uid gid; "-w"; container_cwd ])
  @ [ container_name ]
  @ Backend.command_separator backend
  @ command_argv
;;

(* What a request finds in its environment however it reaches the guest:
   [--env] on each exec below, or the agent's own environment when the agent
   serves it ({!Keeper_microvm_agent_socket.plan}). *)
let request_environment ~shim_config_path =
  [ "HOME", Backend.scratch_guest_root
  ; Exec_ssh_protocol.shim_config_env_var, shim_config_path
  ]
;;

(** The prefix the remote lane delivers a framed shim request through, for a
    runtime that takes each request as one exec ({!Backend.request_delivery}).

    It differs from {!exec_argv_for} in one thing the shim cannot do without:
    the guest has to be told where its config is, and that travels as an
    environment entry on the exec. Both CLIs document that entry --
    [msb exec] has [-e, --env <ENV>] the same as nerdctl.

    What [msb] does not document is numeric [uid:gid] under [--user].
    nerdctl takes Docker's, so the mapped [uid:gid] this lane runs the
    keeper's commands as is a value it accepts. [msb exec -u, --user <USER>]
    documents "Run the command as the specified guest user" and no numeric
    form (0.6.16, 2026-09-04). For msb, [--user] is omitted; the work volume's
    [uid=,gid=] mount places writes at the right host uid. *)
let shim_exec_prefix_for ?(stdin = true) runtime ~container_name ~uid ~gid ~remote_root ~shim_config_path =
  let environment_args =
    List.concat_map (fun (key, value) -> [ "--env"; key ^ "=" ^ value ])
      (request_environment ~shim_config_path) in
  match (runtime : Backend.exec_runtime) with
  | Backend.Nerdctl_kata_exec ->
    let backend = Backend.Nerdctl_kata in
    Ok
      (command_argv_for backend
       @ [ "exec" ]
       @ (if stdin then Backend.exec_stdin_args backend else [])
       @ [ "--user"; Printf.sprintf "%d:%d" uid gid; "-w"; remote_root ]
       @ environment_args
       @ [ container_name ]
       @ Backend.command_separator backend)
  | Backend.Microsandbox_exec ->
    let backend = Backend.Microsandbox in
    (* msb [exec --user] names a guest user, not the uid:gid this lane maps
       ownership with, so it is left off -- the work volume's [uid=,gid=] mount
       already places the keeper's writes at the right host uid, and msb runs as
       its guest default. The shim config still travels as [--env], which msb
       documents the same as nerdctl. *)
    Ok
      (command_argv_for backend
       @ [ "exec" ]
       @ (if stdin then Backend.exec_stdin_args backend else [])
       @ [ "-w"; remote_root ]
       @ environment_args
       @ [ container_name ]
       @ Backend.command_separator backend)
;;

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
