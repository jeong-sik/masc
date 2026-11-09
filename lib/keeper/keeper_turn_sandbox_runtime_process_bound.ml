open Keeper_meta_contract
open Keeper_turn_sandbox_runtime_registry
open Keeper_turn_sandbox_runtime_work_root
open Keeper_turn_sandbox_runtime_boot
open Keeper_turn_sandbox_runtime_record
open Keeper_turn_sandbox_runtime_run_argv
open Keeper_turn_sandbox_runtime_container
open Keeper_turn_sandbox_runtime_work_volume
open Keeper_turn_sandbox_runtime_start_failure

let start_process_bound_microvm_container ?timeout_sec (t : t) =
  (* The runtime is read once, before anything is spawned. A keeper whose
     TOML names none is refused here rather than booted on an assumed one,
     which is what pointed a boot and its cleanup at two CLIs (#32837). *)
  match microvm_backend_of t with
  | Error detail -> Error (Backend_unresolved detail)
  | Ok backend ->
  match t.image with
  | Error error -> Error (Image_unresolved error)
  | Ok image -> (
    (* Resolved before anything is probed or removed: a running guest is
       compared against this size, and a fresh one boots with it. *)
    match
      Env_config_sandbox.Runtime.microvm_guest_size
        ~memory:t.meta.microvm_memory
        ~cpus:t.meta.microvm_cpus
    with
    | Error detail -> Error (Guest_size_invalid detail)
    | Ok guest_size ->
    let container_name = keeper_vm_name t in
    let adopt snapshot =
      bind_github_identity_snapshot t (Process_identity snapshot);
      set_state t (Running { container_name });
      Ok container_name
    in
    let rec remove_previous_modes = function
      | [] -> Ok ()
      | mode :: rest when mode = t.network_mode -> remove_previous_modes rest
      | mode :: rest ->
        let previous =
          microvm_container_name ~config:t.config ~keeper_name:t.meta.name
            ~network_mode:mode
        in
        (match stop_and_delete_microvm_container ?timeout_sec ~backend previous with
         | Ok () -> remove_previous_modes rest
         | Error detail ->
           Error (Previous_mode_guest_not_removed { container_name = previous; detail }))
    in
    (* The guest is stopped and deleted only after the nameserver it will be
       booted with is known: see {!microvm_boot_nameserver}. *)
    let boot_after remove_guest =
      match
        Result.map_error
          (fun detail -> "microvm_guest_dns_unusable: " ^ detail)
          (microvm_boot_nameserver ~backend ~network_mode:t.network_mode)
      with
      | Error detail -> `Error (Network_unexpressible detail)
      | Ok nameserver ->
        (match remove_guest () with
         | Ok () ->
           (* All modes attach the same Keeper-scoped work/build volumes.
              Failed or unknown removal is not just a leaked guest: proceeding
              could recreate an attached build volume or trim a live work
              volume. Warm adoption does neither and needs no sibling cleanup. *)
           (match remove_previous_modes Keeper_types_profile_sandbox.all_network_modes with
            | Ok () -> `Boot nameserver
            | Error failure -> `Error failure)
         | Error detail -> `Error (Unadoptable_guest_not_removed detail))
    in
    let start_state =
      match
        probe_microvm_container_state
          ?timeout_sec
          ~backend
          container_name
      with
      | Ok Keeper_sandbox_runtime.Docker_container_running ->
        (match bind_registered_microvm_identity t container_name with
         | Some snapshot ->
           (match
              microvm_adoption
                ~booted:(microvm_boot container_name)
                ~image
                ~guest_size
                ~network_mode:t.network_mode
                ~bound_port:(bound_egress_proxy_port t)
            with
            | Adopt_running_guest -> `Adopt snapshot
            | Replace_running_guest reasons ->
              (* The guest is intact and its snapshot is ours, but it was not
                 booted with what the keeper asks for now: its one route
                 points at a port this process no longer holds, or it runs
                 another image or size. Adopting it keeps the keeper on the
                 old one with nothing said. Replace it. *)
              boot_after (fun () ->
                Log.Keeper.info
                  "microvm guest replaced instead of adopted keeper=%s name=%s: %s"
                  t.meta.name
                  container_name
                  (String.concat
                     "; "
                     (List.map microvm_replacement_reason_to_string reasons));
                stop_and_delete_microvm_container ?timeout_sec ~backend container_name))
         | None ->
           (* A guest from an older server process can still be running, but
              its temp snapshot capability died with that process. It is not
              safe to guess the mount or use credentials we cannot redact.
              Replace the guest with one whose snapshot this process owns. *)
           boot_after (fun () ->
             stop_and_delete_microvm_container ?timeout_sec ~backend container_name))
      | Error probe_error ->
        `Error (Guest_state_unreadable probe_error)
      | Ok Keeper_sandbox_runtime.Docker_container_stopped ->
        boot_after (fun () ->
          stop_and_delete_microvm_container ?timeout_sec ~backend container_name)
      | Ok Keeper_sandbox_runtime.Docker_container_absent ->
        boot_after (fun () -> Ok ())
    in
    match start_state with
    | `Adopt snapshot ->
      (* A running guest proves its process is up, not that its work volume
         is mounted: a guest that booted without the mount serves a writable
         rootfs directory at the same path, and every keeper write there
         evaporates on the next boot. Adopting on process state alone would
         hand turns to exactly that guest, so the mount invariant is checked
         here the same as on a fresh boot, and a guest that fails it is
         refused rather than adopted. The guest is left running for an
         operator to inspect; a later start probes again. A failed probe may
         recover without the guest being removed. *)
      (match
         ensure_microvm_work_volume_mounted ?timeout_sec t ~backend ~container_name
       with
       | Ok () -> adopt snapshot
       | Error detail -> Error (Adopted_guest_volume_unverified detail))
    | `Error error -> Error error
    | `Boot nameserver ->
      (* The current name and all previous modes are confirmed absent before
         reaching any volume operation. A record still held for this name
         describes one that stopped or vanished without passing through
         [stop_and_delete_microvm_container]. Dropped before the boot: only
         this boot's own success writes the name's record again. *)
      forget_microvm_boot container_name;
      let image_timeout =
        match timeout_sec with
        | Some sec -> sec
        | None -> Env_config_sandbox.Shell_timeout.timeout_sec ~bucket:Io ()
      in
      (match
         Result.bind
           (Keeper_sandbox_microvm.image_present_for
              backend
              ~name:t.meta.sandbox_image
              ~image
              ~timeout_sec:image_timeout)
           (fun () -> microvm_guest_provisions t ~backend ~timeout_sec:image_timeout)
       with
       | Error detail -> Error (Guest_provisions_unavailable detail)
       | Ok provisions ->
         (* Reuse the snapshot a previous turn left mounted: the guest is
            keeper-lifetime, so its mounts must keep pointing at the same
            directory. Only a fresh boot builds a new one. *)
         let github_identity_result =
           match (Atomic.get t.github_identity_snapshots).current with
           | Some (Process_identity snapshot) -> Ok (snapshot, false)
           | Some (Guest_identity _) | None ->
             (match microvm_identity_snapshot container_name with
              | Some snapshot -> Ok (snapshot, false)
              | None ->
                (match
                   Keeper_github_identity.docker_args_for_tool
                     ~config:t.config
                     ~keeper_name:t.meta.name
                     ~container_masc_dir:
                       (Keeper_sandbox_runtime_setup.container_masc_dir
                          ~container_root:t.container_root)
                 with
                 | Error _ as error -> error
                 | Ok projection ->
                   let snapshot =
                     { args = projection.args
                     ; host_dir = projection.host_snapshot_dir
                     ; revision = projection.revision
                     ; cleanup = projection.cleanup
                     }
                   in
                   (match claim_microvm_identity_snapshot container_name snapshot with
                    | `Claimed -> Ok (snapshot, true)
                    | `Existing existing ->
                      snapshot.cleanup ();
                      Ok (existing, false))))
         in
         (match github_identity_result with
          | Error err ->
            Error (Github_identity_invalid err)
          | Ok (github_identity, github_identity_is_new) ->
         let release_unmounted_identity () =
           if github_identity_is_new then
             (* Snapshot cleanup removes the directory through Fs_compat,
                which can yield. Protect the registry take and that removal
                together before propagating a pre-boot cancellation. *)
             Eio.Cancel.protect (fun () ->
               release_registered_microvm_identity ~expected:github_identity container_name)
         in
         (* The network policy is spelled by the runtime, and one of the three
            cannot say every mode. Resolved before the argv so a boot refuses
            rather than handing msb Docker's flags, which it rejects at
            argument parsing with no statement of what the guest's network
            would have been. *)
         (match ensure_policy_network backend ~keeper_name:t.meta.name t.network_mode with
          | Error detail ->
            release_unmounted_identity ();
            Error (Policy_network_unavailable detail)
          | exception (Eio.Cancel.Cancelled _ as cancelled) ->
            release_unmounted_identity ();
            raise cancelled
          | Ok policy_gateway ->
         let policy_proxy =
           (* The port is read from the keeper's registry entry rather than
              carried in this state: the proxy is bound once per keeper lane
              and a guest boots per turn, so the two ends have different
              lifetimes and the entry is what both can see. *)
           match policy_gateway, bound_egress_proxy_port t with
           | Some gateway, Some port -> Some { Keeper_sandbox_microvm.gateway; port }
           (* Either half missing means the guest cannot be told its one
              route. [network_args_for] refuses on [None] rather than booting
              a guest that reaches nothing silently. *)
           | Some _, None | None, _ -> None
         in
         (match
            Keeper_sandbox_microvm.network_args_for
              backend
              ~dns:(Option.map Ipaddr.to_string nameserver)
              ~keeper_name:t.meta.name
              ~policy_proxy
              t.network_mode
          with
          | Error detail ->
            release_unmounted_identity ();
            Error (Network_unexpressible detail)
          | Ok network_args ->
         let argv_result =
           Keeper_sandbox_microvm.turn_start_argv_for
             backend
             ~container_name
             ~label_args:
               (Keeper_sandbox_runtime.docker_label_args
                  ~base_path:t.config.base_path
                  ~keeper_name:t.meta.name
                  ~container_kind:
                    Keeper_sandbox_microvm.keeper_vm_container_kind
                  ~network_label:
                    (Keeper_types_profile_sandbox.network_mode_to_string
                       t.network_mode)
                  ())
             ~uid:t.uid
             ~gid:t.gid
             ~guest_size
             ~network_args
             (* Config and the GitHub identity. Config has no cleanup, so it
                travels as-is. The identity does: the Docker lane runs that
                cleanup under [Eio_guard] at turn end, which would delete the
                credential out from under a guest that outlives the turn, so
                the guest holds its snapshot for its own lifetime instead
                ([keep] on adopt, released at teardown).

                The secret projection is still absent. It hands back the same
                turn-scoped cleanup and has no keeper-lifetime holder yet, so
                a microvm keeper reaches its connectors without it. *)
             ~mount_args:
               (Keeper_sandbox_runtime.docker_config_mount_args
                  ~base_path:t.config.base_path
                  ~container_root:t.container_root
                @ github_identity.args
                (* The working tree (RFC-0400): the keeper's checkouts live
                   on the work volume, a block device rather than the
                   virtiofs share that pinned one host vnode per file, and
                   the shim the remote lane drives is mounted read-only
                   beside its config. *)
                @ Keeper_sandbox_microvm.work_volume_mount_args
                    ~volume_name:provisions.work_volume_name
                (* Derived build output, on its own disposable volume
                   so it can be deleted and recreated without
                   touching the checkout above -- absent on backends whose
                   work volume already returns host disk on a guest
                   delete. *)
                @ (match provisions.build_volume_name with
                   | Some volume_name ->
                     Keeper_sandbox_microvm.build_volume_mount_args ~volume_name
                   | None -> [])
                @ Keeper_sandbox_microvm.shim_mount_args
                    ~host_dir:provisions.shim_host_dir)
             ~image
             (* Asked for by name, so a runtime with no flag for one of them
                refuses the boot instead of running a keeper on a weaker
                sandbox than the profile it declared. *)
             ~constraints:Keeper_microvm_backend.all_guest_constraints
           |> Result.map_error (fun refusals -> Constraints_unexpressible {backend; refusals})
         in
         (match argv_result with
          | Error failure ->
            release_unmounted_identity ();
            Error failure
          | Ok argv ->
         let booted =
           { policy_port =
               Option.map
                 (fun (proxy : Keeper_sandbox_microvm.policy_proxy) -> proxy.port)
                 policy_proxy
           ; image
           ; guest_size
           }
         in
         let st, out = run_argv_with_status ?timeout_sec argv in
         (* A guest that came up but that the runtime confirms is not
            there, or that cannot hold the keeper's root on its volume, is
            taken down again: the remote lane has nowhere to run in it, and
            leaving it would hand the next turn a guest that adopts cleanly
            and fails on every call. *)
         let take_down_after_boot ~check ~detail =
           let removed =
             match
               stop_and_delete_microvm_container
                 ?timeout_sec
                 ~backend
                 container_name
             with
             | Ok () -> true
             | Error _ -> false
           in
           if github_identity_is_new && removed
           then
             release_registered_microvm_identity
               ~expected:github_identity
               container_name;
           Error (Booted_guest_unusable { check; container_name; detail })
         in
         (match st with
          | Unix.WEXITED 0 ->
            (* Recorded as soon as the runtime says the guest booted, before
               anything below can fail. Every later failure either takes the
               guest down, which forgets the record with it, or leaves the
               guest running; a running guest this process booted with no
               record would be replaced on every start instead of adopted --
               including the one [microvm_remote_endpoint] exists to adopt,
               whose [mkdir] failed and whose take-down failed too. *)
            record_microvm_boot container_name booted;
            (* The same probe as every other step. Listed in any state, it is
               the guest this call booted; a stopped one fails the work root
               check below. Confirmed absent, it is taken down. Unknown, it is
               left running with its snapshot and record: taking down a guest
               nobody could ask about may delete one that is up. *)
            (match
               probe_microvm_container_state ?timeout_sec ~backend container_name
             with
             | Ok
                 ( Keeper_sandbox_runtime.Docker_container_running
                 | Keeper_sandbox_runtime.Docker_container_stopped ) ->
               (match
                  ensure_microvm_keeper_work_root
                    ?timeout_sec
                    t
                    ~backend
                    ~container_name
                with
                | Ok () ->
                  mark_microvm_work_root_ready ~base_path:t.config.base_path ~backend ~container_name;
                  adopt github_identity
                | Error detail ->
                  take_down_after_boot
                    ~check:Work_root_unusable
                    ~detail)
             | Ok Keeper_sandbox_runtime.Docker_container_absent ->
               take_down_after_boot
                 ~check:Runtime_does_not_list
                 ~detail:"the runtime's listing does not name the guest"
             | Error detail -> Error (Booted_guest_state_unknown { container_name; detail }))
          | Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _ ->
            (* Two turns of one keeper can race to boot the shared name;
               the loser's run fails on the name and the guest the winner
               booted is the one both wanted. *)
            (match
               probe_microvm_container_state
                 ?timeout_sec
                 ~backend
                 container_name
             with
             | Ok Keeper_sandbox_runtime.Docker_container_running ->
               (* No boot is recorded for this guest. [booted] is what this
                  call asked for, and the run that booted the guest may be
                  another one: an earlier start whose run timed out before
                  its guest came up, from a TOML that has changed since, or
                  a start in another server process. Nothing here tells those
                  apart from this call's own run failing while its guest came
                  up. The name's record was dropped before this boot, so the
                  next start finds none and replaces the guest rather than
                  adopting an image or size nobody can vouch for. *)
               (* The stable-name race adopted the snapshot claimed before
                  either launch. Both launch argv values therefore point at
                  the same immutable directory.

                  Running proves the winner's process is up, not that its
                  work volume is mounted -- the race loser must not reach a
                  guest the mount invariant has not verified, so it adopts
                  through the same probe as the plain adopt path. A failure
                  fails closed with the guest left running: it may be serving
                  the winner's turn off the shared snapshot, which is why the
                  registered identity is kept here as it is when the state
                  probe itself fails below. *)
               (match
                  ensure_microvm_work_volume_mounted
                    ?timeout_sec
                    t
                    ~backend
                    ~container_name
                with
                | Ok () -> adopt github_identity
                | Error detail -> Error (Adopted_guest_volume_unverified detail))
             | Ok Keeper_sandbox_runtime.Docker_container_stopped
             | Ok Keeper_sandbox_runtime.Docker_container_absent ->
               let removed =
                 match
                   stop_and_delete_microvm_container
                     ?timeout_sec
                     ~backend
                     container_name
                 with
                 | Ok () -> true
                 | Error _ -> false
               in
               if github_identity_is_new && removed
               then
                 release_registered_microvm_identity
                   ~expected:github_identity
                   container_name;
               Error (Boot_command_failed { status = st; output = out })
             | Error _ ->
               (* The guest state is unknown. Keep the registered snapshot:
                  deleting it could invalidate a mount on a guest that did
                  start even though the probe failed. Teardown owns recovery. *)
               Error (Boot_command_failed { status = st; output = out })))))))))
;;
