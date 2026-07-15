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
  -> ('a Fs_compat.Publication_recovery.lane_outcome, unavailable) result
(** Reads the live provider once and, only when available, borrows the exact
    owner lane for the dynamic extent of [use]. Callback exceptions and
    cancellation propagate only after the lane access is released. A callback
    value returned before lane-scope release fails remains available in the
    typed [Lane_release_failed] outcome. *)

(** Stable tool-facing category detail. Embedded recovery evidence remains in
    the typed [unavailable] value and is never rendered here. *)
val unavailable_to_string : unavailable -> string

(** Stable tool-facing failure projection. It contains state/category and
    no owner, path, operation ID, exception, or backtrace evidence. *)
val unavailable_to_yojson : unavailable -> Yojson.Safe.t
