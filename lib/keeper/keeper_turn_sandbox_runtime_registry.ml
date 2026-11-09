type process_github_identity_snapshot =
  { args : string list
  ; host_dir : string
  ; revision : string
  ; cleanup : unit -> unit
  }

type github_identity_snapshot =
  | Process_identity of process_github_identity_snapshot
  | Guest_identity of Keeper_microvm_github_identity.snapshot

let identity_host_dir = function
  | Process_identity snapshot -> snapshot.host_dir
  | Guest_identity snapshot -> Keeper_microvm_github_identity.path snapshot

let identity_revision = function
  | Process_identity snapshot -> snapshot.revision
  | Guest_identity snapshot -> Keeper_microvm_github_identity.revision snapshot

type github_identity_snapshots =
  { current : github_identity_snapshot option
  ; retired : github_identity_snapshot list
  }

let no_github_identity_snapshots = { current = None; retired = [] }

(* Backends whose inspect cannot establish a full boot identity retain their
   process-owned snapshots. Apple credentials belong to its durable guest
   store and are never registered for turn/process cleanup. *)
let microvm_identity_snapshots :
  (string * process_github_identity_snapshot) list Atomic.t
  =
  Atomic.make []
;;

(* A Keeper's guest names and volumes share lifecycle ownership. Different
   Keepers must not wait behind an unrelated slow container CLI or boot.
   Inventory maintenance still excludes all owners from listing to deletion,
   preserving the stable-name adoption boundary. *)
let microvm_lifecycle = Keeper_microvm_lifecycle.create ()

let with_microvm_lifecycle_lock ~keeper_name ~operation f =
  match Fs_compat.execution_context () with
  | Fs_compat.Non_eio -> f ()
  | Fs_compat.Eio_fiber ->
    let requested_at = Time_compat.now () in
    Keeper_microvm_lifecycle.with_keeper microvm_lifecycle ~keeper_name (fun () ->
      Log.Keeper.debug "microvm lifecycle admitted keeper=%s operation=%s wait_ms=%.3f"
        keeper_name operation ((Time_compat.now () -. requested_at) *. 1000.0);
      f ())
;;

let with_microvm_inventory_lock f =
  match Fs_compat.execution_context () with
  | Fs_compat.Non_eio -> f ()
  | Fs_compat.Eio_fiber -> Keeper_microvm_lifecycle.with_inventory microvm_lifecycle f
;;

let sweep_process_bound_microvm_guests
      ~base_path ~command_available ~timeout_sec ~is_pid_alive ~run_argv =
  Keeper_sandbox_microvm.sweep_abandoned_guests ~base_path
    ~command_available:(fun command ->
      not (String.equal command (Keeper_microvm_backend.cli_name Keeper_microvm_backend.Apple_container))
      && command_available command)
    ~timeout_sec ~is_pid_alive ~run_argv
;;

let microvm_identity_snapshot container_name =
  Atomic.get microvm_identity_snapshots |> List.assoc_opt container_name
;;

let rec claim_microvm_identity_snapshot container_name snapshot =
  let current = Atomic.get microvm_identity_snapshots in
  match List.assoc_opt container_name current with
  | Some existing -> `Existing existing
  | None ->
    if Atomic.compare_and_set
         microvm_identity_snapshots
         current
         ((container_name, snapshot) :: current)
    then `Claimed
    else claim_microvm_identity_snapshot container_name snapshot
;;

let rec take_microvm_identity_snapshot_if container_name expected =
  let current = Atomic.get microvm_identity_snapshots in
  match List.assoc_opt container_name current with
  | None -> None
  | Some snapshot when Option.for_all (fun value -> value == snapshot) expected ->
    let updated = List.remove_assoc container_name current in
    if Atomic.compare_and_set microvm_identity_snapshots current updated
    then Some snapshot
    else take_microvm_identity_snapshot_if container_name expected
  | Some _ -> None
;;

let release_registered_microvm_identity ?expected container_name =
  match take_microvm_identity_snapshot_if container_name expected with
  | None -> ()
  | Some snapshot -> snapshot.cleanup ()
;;
