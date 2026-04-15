(** Reactive health tracking for cascade providers.

    Tracks per-provider success/failure rates using a rolling time window.
    Providers in cooldown (consecutive failures exceed threshold) are
    temporarily skipped.

    Thread-safe via internal [Stdlib.Mutex].

    @since 0.137.0 *)

(** Opaque health tracker state. *)
type t

(** Create a new empty tracker. *)
val create : unit -> t

(** Record a successful provider call. Clears cooldown and resets
    consecutive failure counter. *)
val record_success : t -> provider_key:string -> unit

(** Record a failed provider call. Increments consecutive failure
    counter; triggers cooldown when threshold is reached. *)
val record_failure : t -> provider_key:string -> unit

(** Success rate in the rolling window (0.0 to 1.0).
    Returns 1.0 for unknown providers (optimistic default). *)
val success_rate : t -> provider_key:string -> float

(** Whether the provider is currently in cooldown (should be skipped). *)
val is_in_cooldown : t -> provider_key:string -> bool

(** Compute effective weight for weighted cascade selection.

    [effective_weight = config_weight * success_rate]

    Returns 0 for providers in cooldown.
    Returns full [config_weight] for unknown providers. *)
val effective_weight : t -> provider_key:string -> config_weight:int -> int

(** Human-readable summary for debugging/telemetry. *)
val provider_summary : t -> provider_key:string -> string

(** Structured summary for telemetry/dashboard consumption.

    @since 0.139.0 *)
type provider_info = {
  provider_key : string;
  success_rate : float;               (** 0.0 to 1.0, 1.0 if unknown *)
  consecutive_failures : int;
  in_cooldown : bool;
  cooldown_expires_at : float option; (** Unix timestamp, Some iff [in_cooldown] *)
  events_in_window : int;             (** Events retained in rolling window *)
}

(** Structured info for a single provider. Returns [None] if untracked.
    @since 0.139.0 *)
val provider_info : t -> provider_key:string -> provider_info option

(** Snapshot of all tracked providers.
    Useful for dashboards and telemetry endpoints.
    @since 0.139.0 *)
val all_providers : t -> provider_info list

(** Global singleton tracker shared across all cascade calls.
    Use this for production; use {!create} for isolated tests. *)
val global : t
