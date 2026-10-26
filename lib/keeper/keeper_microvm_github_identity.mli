(** Guest-lifetime immutable credentials. Calls borrow the existing Keeper
    lifecycle owner inline; do not run concurrent calls within one owner or
    retain results as mutation authority. No guest is started or removed here. *)

type snapshot
val path : snapshot -> string
val revision : snapshot -> string
val environment : snapshot -> container_config_dir:string -> (string * string) list

type error =
  | Scope_unavailable of Keeper_microvm_lifecycle.scope_error
  | Inventory_unavailable of Keeper_microvm_guest_inventory.error
  | Guest_present
  | Snapshot_already_exists
  | Invalid_snapshot of string
  | Filesystem_unavailable of Fs_compat.owned_regular_file_read_error
  | Registry_unavailable of Fs_compat.Publication_recovery.registry_error
  | Lane_unavailable of Fs_compat.Publication_recovery.lane_open_error
  | Lane_release_failed of
      { primary : error option
      ; failure : Fs_compat.Publication_recovery.lane_release_failure }
  | Invalid_publication_target of Fs_compat.capability_publication_target_error
  | Publication_failed of Fs_compat.capability_write_error
  | Filesystem_operation_failed of exn * Printexc.raw_backtrace

val error_message : error -> string
(** Diagnostics contain no captured credential bytes. *)

val host_path :
  base_path:string -> keeper_name:string -> backend:Keeper_microvm_backend.t ->
  network_mode:Keeper_types_profile_sandbox.network_mode -> string
(** Pure deterministic mount source; does not provision a directory. *)

val load :
  fs:Eio.Fs.dir_ty Eio.Path.t ->
  coordinator:Keeper_microvm_lifecycle.t -> scope:Keeper_microvm_lifecycle.keeper_scope ->
  base_path:string -> keeper_name:string -> backend:Keeper_microvm_backend.t ->
  network_mode:Keeper_types_profile_sandbox.network_mode ->
  (snapshot option, error) result
(** Fresh canonical reconciliation, followed by held-descriptor validation and
    fsync of the complete existing chain and known regular files. [None] means
    missing; an existing empty sealed directory is an unconfigured snapshot.
    The existing shared [microvm] ancestor must be owned, no-follow and not
    writable by group/others; its observed mode is preserved through settlement.
    Credential-exclusive [identity]/backend parents remain exactly 0700 and the
    guest exactly 0500.
    Unknown entries, links, wrong modes/UID and lane release failures refuse.
    Never reads the mutable central login state. *)

val publish_if_guest_absent :
  fs:Eio.Fs.dir_ty Eio.Path.t ->
  coordinator:Keeper_microvm_lifecycle.t -> scope:Keeper_microvm_lifecycle.keeper_scope ->
  base_path:string -> keeper_name:string -> backend:Keeper_microvm_backend.t ->
  network_mode:Keeper_types_profile_sandbox.network_mode -> timeout_sec:float ->
  Keeper_github_identity.captured_tool_identity -> (snapshot, error) result
(** Reads an actual successful full backend inventory inside the borrowed
    owner before publication. Existing snapshots are never overwritten. Uses
    the canonical directory publisher for newly created 0700 parents and the
    0500 guest with 0400 files. An existing safe shared [microvm] ancestor keeps
    its observed mode; it is never chmod/chown repaired. Credential-exclusive
    parents remain exactly 0700. A publication error, including [Target_created],
    stays an error in this call. A later load must independently settle recovery, permissions,
    bytes, fsync and lane release before returning a snapshot. *)
