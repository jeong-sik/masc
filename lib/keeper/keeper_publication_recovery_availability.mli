(** Live publication-recovery capability supplied to Keeper turns.

    Runtime bootstrap owns the provider. Read-only and non-file turns carry it
    without reading it. Each file edit/write reads it immediately before the
    effect, so an initializing result is not pinned across later tool calls or
    turns. *)

type availability =
  | Initializing
  | Available of Fs_compat.publication_recovery_registry
  | Registry_unavailable of Fs_compat.publication_recovery_registry_error
  | Initialization_crashed of Eio.Exn.with_bt
  | Non_runtime

type provider = unit -> availability

type unavailable =
  | Runtime_initializing
  | Runtime_registry_unavailable of Fs_compat.publication_recovery_registry_error
  | Runtime_initialization_crashed of Eio.Exn.with_bt
  | Runtime_non_runtime
  | Lane_unavailable of Fs_compat.publication_recovery_lane_open_error

type turn_context =
  { provider : provider
  ; keeper_name : string
  }

val constant : availability -> provider
val non_runtime_provider : provider

val with_access
  :  turn_context
  -> (Fs_compat.publication_recovery_access -> 'a)
  -> ('a, unavailable) result
(** Reads the live provider once and, only when available, borrows the exact
    owner lane for the dynamic extent of [use]. Callback exceptions and
    cancellation propagate only after the lane access is released. *)

val unavailable_to_string : unavailable -> string
val unavailable_to_yojson : unavailable -> Yojson.Safe.t
