(** Process-local startup config and first-endpoint shim verification.
    Runtime bootstrap calls [initialize] synchronously before admitting
    endpoints. Every endpoint, including an attached guest, calls [verify].
    No runtime/guest is created, removed or restarted by this module. *)

type initialization_failure =
  | Startup_shim_missing of Unix.error
  | Config_write_failed of Fs_compat.atomic_replace_failure

type verification_failure =
  | Guest_shim_missing of Unix.error
  | Sidecar_rejected of string

type error =
  | Invalid_base_path of Config_dir_resolver.canonical_base_path_error
  | Not_initialized
  | Initialization_conflict
  | Initialization_failed of initialization_failure
  | Verification_failed of verification_failure
  | Verification_invalidated

val error_message : error -> string
(** Safe endpoint diagnostics: no native paths, configured PATH or raw sidecar
    error is rendered. Typed values retain the original diagnostic evidence. *)

val initialize : base_path:string -> payload_path:string -> (unit, error) result
(** Write the shared canonical shim config once for a successful process/base
    initialization. Identical successful calls preserve the existing config;
    a different payload PATH is a conflict. Concurrent identical initializers
    share one attempt. A repeated explicit call after failure may perform one
    new actual attempt; verification alone never retries initialization.

    Uses the canonical strict atomic writer on a blocking worker, independent
    of the global Fs_compat filesystem reference. This is one-server-per-base
    process coordination, not arbitration between concurrent server processes. *)

val verify :
  base_path:string -> backend:Keeper_microvm_backend.t -> guest_name:string ->
  (unit, error) result
(** Await this base's actual initialization outcome, then verify the canonical
    executable/sidecar once per successful (base, backend, actual guest) key.
    Missing initialization and a completed startup failure remain distinct.
    Canonical [Shim_unverified] is allowed; no new hand-built-shim gate is added.
    Failed checks are not cached, so a later endpoint call may observe repair.
    Concurrent same-key calls share work; unrelated keys can run independently.
    Cancellation/fatal exceptions propagate, with no cached guessed success. *)

val forget : backend:Keeper_microvm_backend.t -> guest_name:string -> unit
(** Call only after the guest is confirmed stopped, absent or deleted, or
    before admitting its replacement.
    Invalidate every matching base conservatively, including an in-flight
    check: its old result cannot authorize the replacement. No TTL or retry
    scheduler is involved. *)
