open Keeper_meta_contract
open Keeper_turn_sandbox_runtime_registry
open Keeper_turn_sandbox_runtime_work_root
open Keeper_turn_sandbox_runtime_boot
open Keeper_turn_sandbox_runtime_record
open Keeper_turn_sandbox_runtime_run_argv
open Keeper_turn_sandbox_runtime_container

(** The work volume (RFC-0400): Apple's working tree is on a guest ext4 disk;
    Linux nerdctl uses a persistent runtime-managed directory, without Apple's
    capacity or flat host-descriptor guarantee. Created if
    it is not there yet; refusing rather than booting without it follows
    [image_present] in the same lane -- a guest with no work volume has no
    tree, and the remote lane has nowhere to run. *)
let microvm_work_volume ~backend ~keeper_name ~timeout_sec =
  match Keeper_sandbox_microvm.work_volume_name ~keeper_name with
  | Error message -> Error ("microvm_work_volume_unnamed: " ^ message)
  | Ok volume_name ->
    (match
       Keeper_sandbox_microvm.ensure_work_volume_for
         backend
         ~volume_name
         ~size:(Env_config_sandbox.Runtime.microvm_work_volume_size ())
         ~timeout_sec
     with
     | Error _ as err -> err
     | Ok _ -> Ok volume_name)
;;

(** The build volume (RFC-keeper-build-output-returns-to-a-disposable-volume),
    `Apple_container` only: `msb` and `nerdctl`
    back their named work volumes with a host directory, so a guest [rm -rf
    _build] already returns host disk immediately there and this volume is
    not provisioned for them -- [None], not a refusal, since its absence
    costs a `Micro_vm` keeper on those backends nothing. On Apple, absence
    is a refusal like {!microvm_work_volume}'s: a guest that cannot get the
    volume this RFC's disk-reclaim path depends on does not start rather
    than fall back to writing `_build` onto the unified work volume, which
    is exactly the unbounded growth this exists to bound. Recreated, not
    merely ensured: this runs only on a fresh [container run] (never on
    adoption of an already-running guest, the same boundary
    {!microvm_work_volume} keeps its own volume across), so "fresh boot"
    and "empty build volume" coincide by construction, and every guest
    restart is the host-disk reclaim this RFC exists for. *)
let microvm_build_volume ~backend ~keeper_name ~timeout_sec =
  match (backend : Keeper_microvm_backend.t) with
  | Keeper_microvm_backend.Microsandbox | Keeper_microvm_backend.Nerdctl_kata -> Ok None
  | Keeper_microvm_backend.Apple_container ->
    (match Keeper_sandbox_microvm.build_volume_name ~keeper_name with
     | Error message -> Error ("microvm_build_volume_unnamed: " ^ message)
     | Ok volume_name ->
       (match
          Keeper_sandbox_microvm.recreate_apple_build_volume
            ~volume_name
            ~size:(Env_config_sandbox.Runtime.microvm_build_volume_size ())
            ~timeout_sec
        with
        | Error _ as err -> err
        | Ok _ -> Ok (Some volume_name)))
;;

let microvm_shim_host_dir (t : t) =
  Config_dir_resolver.microvm_shim_dir ~base_path:t.config.base_path
;;

let verify_microvm_shim ~base_path ~backend ~guest_name =
  Result.bind (Keeper_microvm_shim_readiness.current_fs ()) (fun fs ->
    Keeper_microvm_shim_readiness.verify ~fs ~base_path ~backend ~guest_name)
;;

(* Startup installs the shared config before endpoint admission. Every guest
   reaches the same once-per-process verification authority, including adoption
   and attached reads; provisioning does not rewrite the mounted config. *)
let prepare_microvm_shim_dir (t : t) ~backend =
  verify_microvm_shim ~base_path:t.config.base_path ~backend
    ~guest_name:(keeper_vm_name t)
  |> Result.map (fun () -> microvm_shim_host_dir t)
  |> Result.map_error Keeper_microvm_shim_readiness.error_message
;;

type microvm_guest_provisions =
  { work_volume_name : string
  ; build_volume_name : string option
        (** [Some] on `Apple_container`; [None] on backends whose
            work volume already returns host disk on a guest delete. *)
  ; shim_host_dir : string
  }

(* Both legacy helper names are shared across workspaces. A complete listing
   can show a helper is present, but cannot establish who owns it or stop an
   older process from starting one after this observation. *)
let ensure_apple_volume_helpers_absent ~keeper_name ~timeout_sec =
  let module Inventory = Keeper_microvm_guest_inventory in
  let unknown error =
    Error ("microvm_volume_helper_inventory_unverified: " ^ Inventory.error_message error)
  in
  match Inventory.read_apple ~timeout_sec with
  | Error error -> unknown error
  | Ok inventory ->
    let rec check = function
      | [] -> Ok ()
      | name :: rest ->
        (match Inventory.presence ~guest_name:name inventory with
         | Ok Inventory.Absent -> check rest
         | Ok Inventory.Present ->
           Error
             (Printf.sprintf
                "microvm_volume_helper_ownership_unverified: helper %s is present; its workspace owner is unknown"
                name)
         | Error error -> unknown error)
    in
    check [ Keeper_sandbox_microvm.work_volume_trim_name ~keeper_name
          ; Keeper_sandbox_microvm.volume_repair_name ~keeper_name ]
;;

(* A fresh Apple boot requires a successful claim-helper report before it can
   use a volume shared across workspaces. This is not an independent marker
   readback or proof about a legacy or already-paused Keeper. *)
let claim_work_volume_at_boot (t : t) ~backend ~volume_name ~timeout_sec =
  match (backend : Keeper_microvm_backend.t) with
  | Keeper_microvm_backend.Microsandbox | Keeper_microvm_backend.Nerdctl_kata -> Ok ()
  | Keeper_microvm_backend.Apple_container ->
    let claimant =
      Keeper_sandbox_runtime_setup.normalize_base_path_for_hash t.config.base_path
    in
    (match t.image with
     | Error error ->
       Error ("microvm_volume_claim_unconfirmed: " ^ image_unresolved_message error)
     | Ok image ->
       Keeper_sandbox_microvm.add_apple_work_volume_claim
         ~run:(fun ~timeout_sec argv -> run_argv_with_status_split ~timeout_sec argv)
         ~timeout_sec
         ~keeper_name:t.meta.name
         ~volume_name
         ~image
         ~claimant
       |> Result.map_error (fun detail -> "microvm_volume_claim_unconfirmed: " ^ detail))
;;

(** Everything a guest boot mounts besides config and identity, established
    before [container run] so a boot never starts without one of them. *)
let microvm_guest_provisions (t : t) ~backend ~timeout_sec =
  (* Until helper and volume ownership are bound to a workspace, boot must
     neither launch a name-scoped trim helper nor delete a possible peer's
     helper. A present or unreadable helper inventory refuses provisioning.
     The observation does not fence an older process from starting one later. *)
  let helper_check = match (backend : Keeper_microvm_backend.t) with
    | Keeper_microvm_backend.Apple_container ->
      ensure_apple_volume_helpers_absent ~keeper_name:t.meta.name ~timeout_sec
    | Keeper_microvm_backend.Microsandbox | Keeper_microvm_backend.Nerdctl_kata -> Ok ()
  in
  match helper_check with
  | Error _ as error -> error
  | Ok () ->
    (match microvm_work_volume ~backend ~keeper_name:t.meta.name ~timeout_sec with
     | Error _ as err -> err
     | Ok work_volume_name ->
       let open Result.Syntax in
       let* () = claim_work_volume_at_boot t ~backend ~volume_name:work_volume_name ~timeout_sec in
       let* build_volume_name = microvm_build_volume ~backend ~keeper_name:t.meta.name ~timeout_sec in
       let* shim_host_dir = prepare_microvm_shim_dir t ~backend in
       Ok { work_volume_name; build_volume_name; shim_host_dir })
;;

(** Boot invariant (RFC-0052), fail-closed:
    {!Keeper_sandbox_microvm.work_volume_guest_root} must be a real mountpoint
    inside the guest before anything is written there. The
    mkdir and write probe below both succeed against a writable rootfs
    directory, so without this check a guest whose volume mount is absent at
    boot serves an ephemeral tree silently -- keeper writes evaporate on the
    next boot and a delivered paste's log line is a lie (2026-09-04, analyst
    guest on a stale rootfs tree). *)
let ensure_microvm_work_volume_mounted ?timeout_sec (t : t) ~backend ~container_name =
  match Keeper_sandbox_microvm.work_volume_name ~keeper_name:t.meta.name with
  | Error detail -> Error ("microvm_work_volume_unnamed: " ^ detail)
  | Ok volume_name ->
    let probe =
      Keeper_sandbox_microvm.work_volume_mounted_probe_argv_for backend ~container_name
    in
    let status, stdout, stderr = run_argv_with_status_split ?timeout_sec probe in
    (match Keeper_sandbox_microvm.work_volume_mount_probe_of_result ~status ~stdout ~stderr with
     | Keeper_sandbox_microvm.Work_volume_mounted -> Ok ()
     | Keeper_sandbox_microvm.Work_volume_not_mounted ->
       Error
         (Printf.sprintf
            "microvm_work_volume_not_mounted: guest %s reported that %s is not a mountpoint (volume %s); the guest cannot be used until its work volume is mounted"
            container_name
            Keeper_sandbox_microvm.work_volume_guest_root
            volume_name)
     | Keeper_sandbox_microvm.Work_volume_probe_unverified { status; stdout; stderr } ->
       let detail =
         output_for_status ~stdout ~stderr
         |> Keeper_sandbox_runtime.docker_failure_output_for_log
       in
       Error
         (Printf.sprintf
            "microvm_work_volume_probe_unverified: could not verify %s in guest %s (volume %s; %s)%s; inspect the guest and its execution transport before recovery"
            Keeper_sandbox_microvm.work_volume_guest_root
            container_name
            volume_name
            (Keeper_sandbox_exec_failure.status_label status)
            (if String.equal (String.trim detail) "" then ""
             else "; unverified probe output: " ^ detail)))
;;

(** The keeper's root on the work volume, made inside the guest once it is
    up. The volume outlives the guest, so this is a no-op after the first
    boot; it runs as root because the volume root is root-owned. The mount
    invariant runs first: existence and writability of the root prove nothing
    while {!Keeper_sandbox_microvm.work_volume_guest_root} itself may be a
    rootfs directory. *)
let ensure_microvm_keeper_work_root ?timeout_sec (t : t) ~backend ~container_name =
  let prepare_volume =
    match ensure_microvm_work_volume_mounted ?timeout_sec t ~backend ~container_name with
    | Error _ as err -> err
    | Ok () ->
      (match Keeper_sandbox_microvm.work_volume_search_argv_for backend ~container_name with
       | None -> Ok ()
       | Some argv ->
         match run_argv_with_status ?timeout_sec argv with
         | Unix.WEXITED 0, _ -> Ok ()
         | (Unix.WEXITED _, out) | (Unix.WSIGNALED _, out) | (Unix.WSTOPPED _, out) ->
           Error
             ("microvm_work_volume_search_failed: "
              ^ Keeper_sandbox_runtime.docker_failure_output_for_log out))
  in
  match prepare_volume with
  | Error _ as err -> err
  | Ok () ->
  let root = Keeper_sandbox_microvm.keeper_work_root ~keeper_name:t.meta.name in
  let mkdir =
    Keeper_sandbox_microvm.keeper_work_root_mkdir_argv_for
      backend
      ~container_name
      ~keeper_name:t.meta.name
  in
  match run_argv_with_status ?timeout_sec mkdir with
  | Unix.WEXITED 0, _ ->
    (* Existence is root's doing; use is the keeper's. The probe writes as
       the uid every command of this keeper will run as, so a root the
       keeper cannot write -- imported under another uid, or a mode the
       volume kept from an earlier life -- is refused here, with its owner
       and mode, instead of on the first Write of a turn. *)
    let probe =
      Keeper_sandbox_microvm.keeper_work_root_write_probe_argv_for
        backend
        ~container_name
        ~uid:t.uid
        ~gid:t.gid
        ~keeper_name:t.meta.name
    in
    (match run_argv_with_status ?timeout_sec probe with
     | Unix.WEXITED 0, _ -> Ok ()
     | ((Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _) as status), out ->
       let detail = Keeper_sandbox_runtime.docker_failure_output_for_log out in
       Error
         (Printf.sprintf
            "microvm_keeper_work_root_probe_unverified: write access to %s as %d:%d was not established (%s)%s"
            root
            t.uid
            t.gid
            (Keeper_sandbox_exec_failure.status_label status)
            (if String.equal (String.trim detail) "" then "" else "; probe output: " ^ detail)))
  | (Unix.WEXITED _, out) | (Unix.WSIGNALED _, out) | (Unix.WSTOPPED _, out) ->
    Error
      (Printf.sprintf
         "microvm_keeper_work_root_failed: %s: %s"
         root
         (Keeper_sandbox_runtime.docker_failure_output_for_log out))
;;

module For_testing_microvm = struct
  type build_link_generation = unit ref

  let build_link_generation ~base_path ~backend ~container_name =
    match microvm_work_root_entry ~base_path ~backend ~container_name with
    | Some entry when entry.root_ready -> Some entry.generation
    | Some _ | None -> None
  ;;

  let complete_build_link_scan ~base_path ~backend ~container_name generation =
    set_microvm_build_links_state ~base_path ~backend ~container_name generation
      ~expected:Build_links_not_prepared Build_links_prepared
  ;;

  let build_link_scan_prepared ~base_path ~backend ~container_name =
    match microvm_work_root_entry ~base_path ~backend ~container_name with
    | Some { build_links_state = Build_links_prepared; root_ready; _ } -> root_ready
    | Some { build_links_state = (Build_links_not_prepared | Build_links_effect_unverified); _ }
    | None -> false
  ;;

  let microvm_container_name = microvm_container_name
  let mark_microvm_work_root_ready = mark_microvm_work_root_ready
  let microvm_work_root_ready = microvm_work_root_ready

  let microvm_identity_snapshot_registered ~container_name =
    Option.is_some (microvm_identity_snapshot container_name)
  ;;

  let mark_microvm_guest_booted ~(config : Workspace.config) ~(meta : keeper_meta) () =
    let container_name =
      microvm_container_name
        ~config
        ~keeper_name:meta.name
        ~network_mode:meta.network_mode
    in
    Option.iter (fun backend ->
      mark_microvm_work_root_ready ~base_path:config.base_path ~backend ~container_name)
      meta.microvm_backend
  ;;

  let record_process_boot ~container_name boot = record_microvm_boot container_name boot
  let process_boot ~container_name = microvm_boot container_name
  let register_process_identity ~container_name ~cleanup =
    match claim_microvm_identity_snapshot container_name
        {args=[]; host_dir=""; revision="fixture"; cleanup} with
    | `Claimed -> true
    | `Existing _ -> false

  let ensure_work_volume_mounted = ensure_microvm_work_volume_mounted
  let ensure_keeper_work_root = ensure_microvm_keeper_work_root

  let provision_guest t ~backend ~timeout_sec =
    microvm_guest_provisions t ~backend ~timeout_sec |> Result.map (fun _ -> ())
end

(** Apple build-link preparation. Its caller admits execution only after the
    current generation is prepared. A read-only scan failure can be
    retried by a later turn. Once an effect may have been sent, its unknown
    outcome survives guest readiness invalidation for this server process.
    A process restart loses this evidence; retention does not establish
    workspace ownership or fence an effect already in flight. *)
let ensure_microvm_build_links ?timeout_sec (t : t) ~container_name ~generation =
    let backend = Keeper_microvm_backend.Apple_container in
    let keeper_work_root = Keeper_sandbox_microvm.keeper_work_root ~keeper_name:t.meta.name in
    let scan =
      Keeper_sandbox_microvm.build_scan_argv_for
        backend
        ~container_name
        ~keeper_work_root
        ~uid:t.uid
        ~gid:t.gid
    in
    let scanned = Fd_accountant.observe ~kind:Fd_accountant.Docker_spawn (fun () ->
      Keeper_microvm_cli_output.read_with_environment ?timeout_sec
        ~stdout_limit:Common.max_process_capture_head_bytes
        ~stderr_limit:Common.max_process_capture_tail_bytes
        ~env:(sandbox_environment ()) ~cwd:(Config_dir_resolver.current_working_dir ())
        ~argv:scan ()) in
    let mark ~expected state =
      set_microvm_build_links_state ~base_path:t.config.base_path ~backend ~container_name generation ~expected state in
    let prepared ~expected = ignore (mark ~expected Build_links_prepared) in
    let effect_unverified () =
      Log.Keeper.warn ~keeper_name:t.meta.name
        "microvm_build_link_effect_unverified: preparation did not complete in this readiness generation; uncertain persistent symlink applications are retained without replay, while a fresh scan after invalidation may recreate disposable targets; see Keeper User Manual: Build preparation reports a failure" in
    let effect_failed operation status =
      Log.Keeper.warn ~keeper_name:t.meta.name "%s: %s"
        operation (Keeper_sandbox_exec_failure.status_label status);
      (match status with
       | Unix.WEXITED 127 ->
         Log.Keeper.warn ~keeper_name:t.meta.name
           "microvm_build_link_interpreter_unverified: check guest /usr/bin/python3 and /usr/local/bin/python3 as the user executing this step; exit 127 alone does not establish the cause or effect outcome"
       | Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _ -> ());
      effect_unverified () in
    (match scanned with
     | Ok (Unix.WEXITED 0, stdout, _) ->
       (match Keeper_sandbox_microvm.build_scan_rows_of_output stdout with
        | Error detail ->
          Log.Keeper.warn ~keeper_name:t.meta.name "microvm_build_scan_failed: %s" detail
        | Ok scanned ->
       let rows = Keeper_sandbox_microvm.build_link_rows_of_scan scanned in
       List.iter
         (fun (row : Keeper_sandbox_microvm.build_link_row) ->
           match Keeper_sandbox_microvm.build_link_warning row.plan with
           | Some message -> Log.Keeper.warn ~keeper_name:t.meta.name "%s" message
           | None -> ())
         rows;
       let effects = register_microvm_work_effects ~backend ~keeper_name:t.meta.name in
       let actions = if effects.links_unverified then (
           effect_unverified ();
           [])
         else Keeper_sandbox_microvm.build_link_actions rows in
       (* Already-correct links need their target too: a fresh boot recreates
          the build volume empty while the work volume keeps the links.
          Keep planned targets even when apply is unresolved: an earlier
          symlink can arrive after this scan, and mkdir does not replay it. *)
       (match Keeper_sandbox_microvm.build_link_targets rows with
        | [] -> prepared ~expected:Build_links_not_prepared
        | _ :: _ as targets ->
          if mark ~expected:Build_links_not_prepared Build_links_effect_unverified then (
          let mkdir = Keeper_sandbox_microvm.build_target_mkdir_requests ~container_name ~targets in
          (try match run_build_link_effects ?timeout_sec mkdir, actions with
           | Unix.WEXITED 0, [] -> prepared ~expected:Build_links_effect_unverified
           | Unix.WEXITED 0, _ :: _ ->
             (* This is a local check only: it cannot cancel an already sent
                guest operation or fence an externally replaced guest. *)
             let generation_retained =
               match microvm_work_root_entry ~base_path:t.config.base_path ~backend ~container_name with
               | Some entry -> entry.generation == generation
                 && entry.build_links_state = Build_links_effect_unverified
               | None -> false in
             if not generation_retained then effect_unverified () else
             let apply =
               Keeper_sandbox_microvm.build_link_apply_requests_for
                 backend
                 ~container_name
                 ~keeper_work_root
                 ~uid:t.uid
                 ~gid:t.gid
                 ~actions
             in
             let reserved = update_microvm_work_effects ~backend ~keeper_name:t.meta.name
                 (fun entry -> if entry.links_unverified then None
                   else Some {entry with links_unverified=true}) in
             if not reserved then effect_unverified () else
             (match run_build_link_effects ?timeout_sec apply with
              | Unix.WEXITED 0 ->
                ignore (update_microvm_work_effects ~backend ~keeper_name:t.meta.name
                  (fun entry -> Some {entry with links_unverified=false}));
                prepared ~expected:Build_links_effect_unverified
              | (Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _) as status ->
                effect_failed "microvm_build_link_apply_failed" status)
           | ((Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _) as status), _ ->
             effect_failed "microvm_build_link_mkdir_failed" status
           with exn -> effect_unverified (); raise exn))))
     | Ok (((Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _) as status), _, _) ->
       Log.Keeper.warn ~keeper_name:t.meta.name
         "microvm_build_scan_failed: %s; inspect guest find and readlink support"
         (Keeper_sandbox_exec_failure.status_label status)
     | Error ({ reason = Keeper_microvm_cli_output.Capture_limit_exceeded; _ } as error) ->
       Log.Keeper.warn ~keeper_name:t.meta.name
         "microvm_build_scan_failed: %s; limit %d bytes; reduce scanned checkouts before retrying"
         (Keeper_microvm_cli_output.error_message error)
         Common.max_process_capture_head_bytes
     | Error ({ reason =
                  ( Keeper_microvm_cli_output.Capture_directory_unavailable
                  | Keeper_microvm_cli_output.Capture_incomplete
                  | Keeper_microvm_cli_output.Capture_failed
                  | Keeper_microvm_cli_output.Capture_unreadable
                  | Keeper_microvm_cli_output.Capture_permissions_invalid
                  | Keeper_microvm_cli_output.Capture_length_mismatch
                  | Keeper_microvm_cli_output.Capture_cleanup_failed ); _ } as error) ->
       Log.Keeper.warn ~keeper_name:t.meta.name
         "microvm_build_scan_failed: %s"
         (Keeper_microvm_cli_output.error_message error))
;;
