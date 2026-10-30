(** Process-local startup config and first-endpoint shim verification.
    Runtime bootstrap calls [initialize] synchronously before admitting
    endpoints. Every endpoint, including an attached guest, calls [verify].
    No runtime/guest is created, removed or restarted by this module. *)

type initialization_failure =
  | Startup_shim_missing of Unix.error

type verification_failure =
  | Guest_shim_missing of Unix.error
  | Sidecar_rejected of string

type config_failure =
  | Config_missing
  | Recovery_context_unavailable
  | Config_inspection_failed of Fs_compat.owned_regular_file_read_error
  | Config_not_canonical
  | Config_owner_or_mode_refused
  | Recovery_registry_failed of Fs_compat.Publication_recovery.registry_error
  | Recovery_lane_failed of Fs_compat.Publication_recovery.lane_open_error
  | Recovery_lane_release_failed of
      { primary : error option
      ; release_failure : Fs_compat.Publication_recovery.lane_release_failure
      }
  | Recovery_target_invalid of Fs_compat.capability_publication_target_error
  | Recovery_publication_failed of Fs_compat.capability_write_error
  | Recovery_sync_failed of Fs_compat.owned_regular_file_read_error
  | Recovery_io_failed of exn

and error =
  | Invalid_base_path of Config_dir_resolver.canonical_base_path_error
  | Not_initialized
  | Initialization_conflict
  | Initialization_failed of initialization_failure
  | Verification_failed of verification_failure
  | Verification_invalidated
  | Config_unavailable of config_failure

val error_message : error -> string
(** Safe endpoint diagnostics: no native paths, configured PATH or raw sidecar
    error is rendered. Typed values retain the original diagnostic evidence. *)

val initialize :
  fs:Eio.Fs.dir_ty Eio.Path.t -> base_path:string -> payload_path:string ->
  (unit, error) result
(** Write the shared canonical shim config once for a successful process/base
    initialization. Identical successful calls preserve the existing config;
    a different payload PATH is a conflict. Concurrent identical initializers
    share one attempt. After failure, a later call reconciles the actual config
    without replacing a file that appeared in the meantime.

    The explicit filesystem is used for config-publication recovery and is not
    taken from the global Fs_compat reference. This is one-server-per-base
    process coordination, not arbitration between concurrent server processes. *)

val current_fs : unit -> (Eio.Fs.dir_ty Eio.Path.t, error) result
(** The current server's filesystem, not a capability retained from an older
    server lifetime. Absence or a non-Eio execution context is an error. *)

val ensure_config : fs:Eio.Fs.dir_ty Eio.Path.t -> base_path:string -> (unit, error) result
(** Reconcile startup and the generated host config without selecting or
    starting a guest. A captured endpoint calls this before each Read, so it
    keeps its original route while observing a deleted config. *)

val verify :
  fs:Eio.Fs.dir_ty Eio.Path.t -> base_path:string -> backend:Keeper_microvm_backend.t -> guest_name:string ->
  (unit, error) result
(** Await or reconcile this base's actual initialization outcome, then verify
    the canonical executable/sidecar once per successful (base, backend, actual
    guest) key. Check the generated host config on every admission, outside that
    cache. If absent, publish the canonical file with durable no-replace; an
    existing noncanonical or unreadable file is preserved and reported. A
    publication with an uncertain result is reconciled before the next check.
    Missing initialization and a completed startup failure remain distinct.
    Canonical [Shim_unverified] is allowed; no new hand-built-shim gate is added.
    Failed checks are not cached, so a later endpoint call may observe repair.
    Concurrent same-key calls share work; unrelated keys can run independently.
    Cancellation/fatal exceptions propagate, with no cached guessed success.
    Host config readiness does not prove the guest can see or read its mount. *)

val forget : backend:Keeper_microvm_backend.t -> guest_name:string -> unit
(** Call only after the guest is confirmed stopped, absent or deleted, or
    before admitting its replacement.
    Invalidate every matching base conservatively, including an in-flight
    check: its old result cannot authorize the replacement. No TTL or retry
    scheduler is involved. *)
